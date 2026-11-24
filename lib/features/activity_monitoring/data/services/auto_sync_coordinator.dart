import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../models/activity_sync_snapshot.dart';
import '../models/activity_sync_state.dart';
import 'activity_sync_service.dart';
import 'activity_tracking_controller.dart';

/// Android background sync (WorkManager, see `BackgroundSyncWorker.kt`).
abstract class BackgroundSyncScheduler {
  /// Registers the periodic background job (idempotent: one unique job).
  Future<void> schedule();

  /// Removes it (on sign-out).
  Future<void> cancel();
}

class MethodChannelBackgroundSync implements BackgroundSyncScheduler {
  const MethodChannelBackgroundSync();

  static const MethodChannel _channel = MethodChannel('vivora/background_sync');

  @override
  Future<void> schedule() => _call('schedule');

  @override
  Future<void> cancel() => _call('cancel');

  Future<void> _call(String method) async {
    try {
      await _channel.invokeMethod<void>(method);
    } catch (error) {
      // Not available (tests, other platforms): foreground sync still works.
      debugPrint('Background sync $method unavailable: $error');
    }
  }
}

/// Owns *when* activity is synchronised; [ActivitySyncService] owns *how*.
///
/// One app-wide instance, driven by the app lifecycle and the signed-in user
/// (wired once in `VivoraApp`), never by individual screens, so opening a
/// screen can never start another loop.
///
/// * While the app is in the foreground: one sync every [interval] (5 min),
///   measured on a monotonic clock from the end of the previous attempt, so
///   attempts never overlap or bunch up. A single [Timer] at a time.
/// * On resume: syncs at once if the interval has passed (or the last result
///   needs attention, e.g. Usage Access was just granted); otherwise waits for
///   the remainder.
/// * In the background: the timer is cancelled; the Android WorkManager job
///   (every 15 min at best, when Android allows) takes over.
/// * Sign-in / account switch: resets everything for the new account and
///   syncs; sign-out: stops the timer and cancels the background job.
/// * Failures retry after [retryDelay], doubling up to [interval]: never a
///   tight loop.
class AutoSyncCoordinator {
  AutoSyncCoordinator({
    required ActivitySyncService service,
    BackgroundSyncScheduler? background,
    this.interval = const Duration(minutes: 5),
    this.retryDelay = const Duration(minutes: 1),
    Timer Function(Duration delay, void Function() callback)? timerFactory,
    Duration Function()? monotonic,
    ActivityTrackingController? tracking,
  }) : _service = service,
       _background = background,
       _tracking = tracking,
       _createTimer = timerFactory ?? Timer.new,
       _monotonic = monotonic ?? _stopwatchElapsed {
    tracking?.addListener(_onTrackingChanged);
  }

  static final Stopwatch _stopwatch = Stopwatch()..start();
  static Duration _stopwatchElapsed() => _stopwatch.elapsed;

  static final AutoSyncCoordinator instance = AutoSyncCoordinator(
    service: ActivitySyncService.instance,
    background: const MethodChannelBackgroundSync(),
    tracking: ActivityTrackingController.instance,
  );

  final ActivitySyncService _service;

  /// The Settings switch. Null only in tests that predate it (always on).
  final ActivityTrackingController? _tracking;
  final BackgroundSyncScheduler? _background;
  final Timer Function(Duration, void Function()) _createTimer;
  final Duration Function() _monotonic;
  final Duration interval;
  final Duration retryDelay;

  /// When the next automatic sync is due (for display), null when none is
  /// scheduled (signed out, app in background).
  final ValueNotifier<DateTime?> nextSyncAt = ValueNotifier<DateTime?>(null);

  bool _initialised = false;
  String? _uid;
  bool _foreground = true;
  int _epoch = 0;
  Timer? _timer;
  Future<void>? _running;
  int _runningEpoch = -1;
  Duration? _lastAttempt;
  int _failures = 0;

  bool _resolving = false;
  bool? _applied;

  bool get isForeground => _foreground;

  /// Signed in and the account's Automatic Activity Tracking is ON.
  bool get isActive {
    final String? uid = _uid;
    return uid != null && (_tracking?.allows(uid) ?? true);
  }

  bool get hasTimer => _timer?.isActive ?? false;

  /// Signed-in user changed (or first known). Safe to call repeatedly.
  Future<void> handleUser(String? uid) async {
    if (_initialised && uid == _uid) return;
    _initialised = true;
    _uid = uid;
    _epoch++;
    _cancelTimer();
    _lastAttempt = null;
    _failures = 0;
    _applied = null;
    final int epoch = _epoch;
    _service.onUserChanged(uid);
    // Nothing is tracked until this account's own choice is known.
    _resolving = true;
    try {
      await _tracking?.resolveForUser(uid);
    } finally {
      if (epoch == _epoch) _resolving = false;
    }
    if (epoch != _epoch) return;
    if (uid == null) {
      _applied = false;
      await _background?.cancel();
      return;
    }
    await _applyTracking();
  }

  void _onTrackingChanged() {
    final ActivityTrackingController? t = _tracking;
    if (t == null || _resolving || !t.isResolved || t.uid != _uid) return;
    if (isActive == _applied) return;
    unawaited(_applyTracking());
  }

  /// Starts or stops everything to match the switch.
  Future<void> _applyTracking() async {
    final bool active = isActive;
    _applied = active;
    if (active) {
      await _background?.schedule();
      if (_foreground && isActive) await syncNow();
      return;
    }
    // OFF: no timer, no background job, and any sync still running loses
    // its right to reschedule (its result is also discarded by the service).
    _epoch++;
    _cancelTimer();
    _lastAttempt = null;
    _failures = 0;
    await _background?.cancel();
    if (_uid != null) _service.showTrackingOff();
  }

  void handleLifecycle(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        _foreground = true;
        _onResume();
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        // Android may suspend the process at any time now; WorkManager takes
        // over and the timer would not fire reliably anyway.
        _foreground = false;
        _cancelTimer();
      case AppLifecycleState.inactive:
        // Transient (dialogs, notification shade): keep the schedule.
        break;
    }
  }

  void _onResume() {
    if (!isActive) return;
    final Duration? since = _lastAttempt == null
        ? null
        : _monotonic() - _lastAttempt!;
    final ActivitySyncState last = _service.syncState.value;
    final bool needsAttention =
        last == ActivitySyncState.permissionRequired ||
        last == ActivitySyncState.failed ||
        !_service.permissions.value.usageAccessGranted;
    if (since == null || since >= interval || needsAttention) {
      unawaited(syncNow());
    } else if (!hasTimer) {
      _schedule(interval - since);
    }
  }

  /// Runs one sync now unless one is already running for the same account
  /// (then joins it). A sync still running for a previous account is waited
  /// for, then a fresh one runs for the current account.
  Future<void> syncNow() {
    final Future<void>? current = _running;
    if (current != null && _runningEpoch == _epoch) return current;
    final Future<void> next = (current ?? Future<void>.value()).then(
      (_) => _run(),
    );
    _running = next;
    _runningEpoch = _epoch;
    unawaited(
      next.whenComplete(() {
        if (identical(_running, next)) _running = null;
      }),
    );
    return next;
  }

  Future<void> _run() async {
    final String? uid = _uid;
    if (uid == null || !isActive) return;
    final int epoch = _epoch;
    _cancelTimer();
    _lastAttempt = _monotonic();
    ActivitySyncResult? result;
    try {
      result = await _service.syncIfNeeded();
    } catch (error) {
      debugPrint('Automatic sync failed: $error');
    }
    // Signed out / switched account meanwhile: that account's schedule is
    // owned by the newer call.
    if (epoch != _epoch) return;
    final bool failed =
        result == null || result.state == ActivitySyncState.failed;
    _failures = failed ? _failures + 1 : 0;
    final Duration next = failed
        ? Duration(
            milliseconds: math.min(
              interval.inMilliseconds,
              retryDelay.inMilliseconds * (1 << math.min(_failures - 1, 8)),
            ),
          )
        : interval;
    if (_foreground && isActive) _schedule(next);
  }

  void _schedule(Duration delay) {
    _cancelTimer();
    final int epoch = _epoch;
    nextSyncAt.value = DateTime.now().add(delay);
    _timer = _createTimer(delay, () {
      _timer = null;
      if (epoch == _epoch && _foreground && isActive) unawaited(syncNow());
    });
  }

  void _cancelTimer() {
    _timer?.cancel();
    _timer = null;
    nextSyncAt.value = null;
  }

  @visibleForTesting
  void dispose() {
    _cancelTimer();
    _epoch++;
  }
}
