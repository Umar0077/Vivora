import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/activity_date_utils.dart';

/// A period during which automatic tracking was switched on. [end] is null
/// while it is still on.
@immutable
class TrackedInterval {
  const TrackedInterval(this.start, [this.end]);

  final DateTime start;
  final DateTime? end;

  bool get isOpen => end == null;

  List<int?> toJson() => <int?>[
    start.millisecondsSinceEpoch,
    end?.millisecondsSinceEpoch,
  ];

  static TrackedInterval? fromJson(Object? raw) {
    if (raw is! List || raw.isEmpty || raw.first is! int) return null;
    return TrackedInterval(
      DateTime.fromMillisecondsSinceEpoch(raw.first as int),
      raw.length > 1 && raw[1] is int
          ? DateTime.fromMillisecondsSinceEpoch(raw[1] as int)
          : null,
    );
  }
}

/// The stored choice for one account.
@immutable
class TrackingPreference {
  const TrackingPreference({
    required this.enabled,
    required this.changedAt,
    this.intervals = const <TrackedInterval>[],
  });

  final bool enabled;

  /// When the user last changed it; the newer of the local and cloud copies
  /// wins when they disagree.
  final DateTime changedAt;

  /// Only kept on this phone (it is what the phone may measure).
  final List<TrackedInterval> intervals;
}

/// Per-account copy on this phone, for immediate enforcement (also offline,
/// and in the background engine).
abstract class LocalTrackingStore {
  Future<TrackingPreference?> read(String uid);
  Future<void> write(String uid, TrackingPreference preference);
}

/// The account's copy in Firestore (`users/{uid}/settings/activityTracking`).
abstract class RemoteTrackingStore {
  Future<TrackingPreference?> read(String uid);
  Future<void> write(String uid, TrackingPreference preference);
}

/// What native Android code (the WorkManager worker and the activity
/// recognition receiver) checks before collecting anything.
abstract class NativeTrackingFlag {
  Future<void> set({required bool enabled, required String? uid});
}

class SharedPrefsTrackingStore implements LocalTrackingStore {
  const SharedPrefsTrackingStore();

  static String _key(String uid) => 'vivora_tracking_v1_$uid';

  @override
  Future<TrackingPreference?> read(String uid) async {
    try {
      final SharedPreferences p = await SharedPreferences.getInstance();
      final String? raw = p.getString(_key(uid));
      if (raw == null) return null;
      final Object? json = jsonDecode(raw);
      if (json is! Map || json['enabled'] is! bool || json['at'] is! int) {
        return null;
      }
      return TrackingPreference(
        enabled: json['enabled'] as bool,
        changedAt: DateTime.fromMillisecondsSinceEpoch(json['at'] as int),
        intervals: <TrackedInterval>[
          for (final Object? i in (json['intervals'] as List? ?? const []))
            ?TrackedInterval.fromJson(i),
        ],
      );
    } catch (error) {
      debugPrint('Tracking preference unreadable: $error');
      return null;
    }
  }

  @override
  Future<void> write(String uid, TrackingPreference preference) async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    await p.setString(
      _key(uid),
      jsonEncode(<String, Object?>{
        'enabled': preference.enabled,
        'at': preference.changedAt.millisecondsSinceEpoch,
        'intervals': preference.intervals.map((i) => i.toJson()).toList(),
      }),
    );
  }
}

class FirestoreTrackingStore implements RemoteTrackingStore {
  const FirestoreTrackingStore();

  DocumentReference<Map<String, dynamic>> _doc(String uid) => FirebaseFirestore
      .instance
      .collection('users')
      .doc(uid)
      .collection('settings')
      .doc('activityTracking');

  @override
  Future<TrackingPreference?> read(String uid) async {
    final Map<String, dynamic>? data = (await _doc(uid).get()).data();
    if (data == null || data['enabled'] is! bool || data['changedAt'] is! int) {
      return null;
    }
    return TrackingPreference(
      enabled: data['enabled'] as bool,
      changedAt: DateTime.fromMillisecondsSinceEpoch(data['changedAt'] as int),
    );
  }

  @override
  Future<void> write(String uid, TrackingPreference preference) =>
      _doc(uid).set(<String, dynamic>{
        'enabled': preference.enabled,
        'changedAt': preference.changedAt.millisecondsSinceEpoch,
        'updatedAt': FieldValue.serverTimestamp(),
      });
}

class MethodChannelTrackingFlag implements NativeTrackingFlag {
  const MethodChannelTrackingFlag();

  static const MethodChannel _channel = MethodChannel('vivora/background_sync');

  @override
  Future<void> set({required bool enabled, required String? uid}) async {
    try {
      await _channel.invokeMethod<void>('setTrackingEnabled', <String, Object?>{
        'enabled': enabled,
        'uid': uid,
      });
    } catch (error) {
      debugPrint('Native tracking flag not set: $error');
    }
  }
}

/// What [ActivitySyncService] asks before measuring or uploading.
abstract class ActivityTrackingGate {
  /// True only when [uid]'s resolved choice is ON.
  bool allows(String uid);

  /// Changes on every ON/OFF change and account change; an operation started
  /// under another generation must not publish or upload its result.
  int get generation;

  /// The parts of [start, end) during which tracking was on (never later than
  /// now). Only these are measured, so a paused period is never backfilled.
  List<(DateTime, DateTime)> trackedRanges(DateTime start, DateTime end);
}

/// The single source of truth for the "Automatic Activity Tracking" switch.
///
/// * Resolved per account before anything is tracked: until then (and for a
///   new account with no stored choice) tracking is OFF.
/// * The local copy applies at once (offline too); the Firestore copy follows
///   the account to other phones. The newer `changedAt` wins.
/// * Every change bumps [generation] and updates the native flag that the
///   Android worker and receiver check independently of Dart.
class ActivityTrackingController extends ChangeNotifier
    implements ActivityTrackingGate {
  ActivityTrackingController({
    LocalTrackingStore local = const SharedPrefsTrackingStore(),
    RemoteTrackingStore? remote,
    NativeTrackingFlag native = const MethodChannelTrackingFlag(),
    DateTime Function()? clock,
    this.remoteTimeout = const Duration(seconds: 6),
  }) : _local = local,
       _remote = remote,
       _native = native,
       _clock = clock ?? DateTime.now;

  static final ActivityTrackingController instance = ActivityTrackingController(
    remote: const FirestoreTrackingStore(),
  );

  final LocalTrackingStore _local;
  final RemoteTrackingStore? _remote;
  final NativeTrackingFlag _native;
  final DateTime Function() _clock;
  final Duration remoteTimeout;

  /// Tracked intervals older than this are dropped (only recent days are
  /// ever re-measured).
  static const Duration intervalRetention = Duration(days: 5);

  String? _uid;
  bool _resolved = false;
  bool _enabled = false;
  bool _saving = false;
  DateTime? _changedAt;
  List<TrackedInterval> _intervals = const <TrackedInterval>[];
  int _generation = 0;
  int _resolveToken = 0;

  String? get uid => _uid;

  /// The account's choice is known (until then everything is OFF).
  bool get isResolved => _resolved;

  /// The user's choice (not whether permission allows measuring).
  bool get isEnabled => _resolved && _enabled;

  /// A change is being saved; the switch ignores taps meanwhile.
  bool get isSaving => _saving;

  @override
  int get generation => _generation;

  @override
  bool allows(String uid) => _resolved && _enabled && uid == _uid;

  List<TrackedInterval> get intervals =>
      List<TrackedInterval>.unmodifiable(_intervals);

  /// Loads [uid]'s choice. Nothing may be tracked until this completes.
  Future<void> resolveForUser(String? uid) async {
    final int token = ++_resolveToken;
    _uid = uid;
    _resolved = false;
    _enabled = false;
    _intervals = const <TrackedInterval>[];
    _generation++;
    notifyListeners();
    if (uid == null) {
      await _native.set(enabled: false, uid: null);
      return;
    }
    // Native code must not track for this account until its choice is known.
    await _native.set(enabled: false, uid: uid);

    final TrackingPreference? local = await _local.read(uid);
    TrackingPreference? remote;
    try {
      remote = await _remote?.read(uid).timeout(remoteTimeout);
    } catch (error) {
      debugPrint('Tracking preference: cloud copy unavailable ($error)');
    }
    if (token != _resolveToken) return; // account changed meanwhile

    final DateTime now = _clock();
    TrackingPreference chosen =
        local ??
        remote ??
        TrackingPreference(enabled: false, changedAt: DateTime(0));
    if (local != null &&
        remote != null &&
        remote.changedAt.isAfter(local.changedAt)) {
      // Changed on another phone more recently.
      chosen = TrackingPreference(
        enabled: remote.enabled,
        changedAt: remote.changedAt,
        intervals: local.intervals,
      );
    }
    List<TrackedInterval> intervals = _reconcile(
      chosen.intervals,
      chosen.enabled,
      now,
    );
    _enabled = chosen.enabled;
    _changedAt = chosen.changedAt;
    _intervals = intervals;
    _resolved = true;
    _generation++;
    final TrackingPreference effective = TrackingPreference(
      enabled: _enabled,
      changedAt: chosen.changedAt,
      intervals: intervals,
    );
    if (local == null ||
        local.enabled != effective.enabled ||
        local.intervals.length != intervals.length) {
      await _safe(() => _local.write(uid, effective));
    }
    // A local change made offline is pushed to the account.
    if (local != null &&
        (remote == null || local.changedAt.isAfter(remote.changedAt))) {
      unawaited(_safe(() => _remote?.write(uid, effective) ?? Future.value()));
    }
    if (token != _resolveToken) return;
    await _native.set(enabled: _enabled, uid: uid);
    notifyListeners();
  }

  /// Turns tracking on or off for the signed-in account. Returns false when
  /// nothing could be changed (no account, not resolved, already saving).
  Future<bool> setEnabled(bool enabled) async {
    final String? uid = _uid;
    if (uid == null || !_resolved || _saving) return false;
    if (enabled == _enabled) return true;
    final DateTime now = _clock();
    // Effective immediately: in-flight work sees the new generation at its
    // next check and drops its result.
    _enabled = enabled;
    _changedAt = now;
    _generation++;
    _intervals = _reconcile(_intervals, enabled, now);
    _saving = true;
    notifyListeners();
    final TrackingPreference pref = TrackingPreference(
      enabled: enabled,
      changedAt: now,
      intervals: _intervals,
    );
    try {
      await _native.set(enabled: enabled, uid: uid);
      await _safe(() => _local.write(uid, pref));
      // Firestore queues this while offline; not awaited past the timeout.
      unawaited(
        _safe(
          () => (_remote?.write(uid, pref) ?? Future<void>.value()).timeout(
            remoteTimeout,
          ),
        ),
      );
    } finally {
      if (_uid == uid) {
        _saving = false;
        notifyListeners();
      }
    }
    return true;
  }

  /// Opens an interval when on, closes the open one when off, and drops
  /// intervals that are too old to matter.
  List<TrackedInterval> _reconcile(
    List<TrackedInterval> current,
    bool enabled,
    DateTime now,
  ) {
    final DateTime cutoff = now.subtract(intervalRetention);
    final List<TrackedInterval> out = <TrackedInterval>[
      for (final TrackedInterval i in current)
        if (i.end == null || i.end!.isAfter(cutoff)) i,
    ];
    final bool open = out.isNotEmpty && out.last.isOpen;
    if (enabled && !open) {
      // No backfill: measuring starts now, not at the start of the day.
      out.add(TrackedInterval(now));
    } else if (!enabled && open) {
      out[out.length - 1] = TrackedInterval(out.last.start, now);
    }
    return out;
  }

  @override
  List<(DateTime, DateTime)> trackedRanges(DateTime start, DateTime end) {
    final DateTime now = _clock();
    final DateTime limit = end.isAfter(now) ? now : end;
    final List<(DateTime, DateTime)> out = <(DateTime, DateTime)>[];
    for (final TrackedInterval i in _intervals) {
      final DateTime s = i.start.isAfter(start) ? i.start : start;
      final DateTime iEnd = i.end ?? now;
      final DateTime e = iEnd.isBefore(limit) ? iEnd : limit;
      if (e.isAfter(s)) out.add((s, e));
    }
    return out;
  }

  /// When tracking (re)started today, for the "measured since" note.
  DateTime? trackedSinceToday() {
    final DateTime now = _clock();
    final List<(DateTime, DateTime)> today = trackedRanges(
      ActivityDateUtils.dayStart(now),
      ActivityDateUtils.nextDayStart(now),
    );
    return today.isEmpty ? null : today.first.$1;
  }

  DateTime? get changedAt => _changedAt;

  static Future<void> _safe(Future<void> Function() f) async {
    try {
      await f();
    } catch (error) {
      debugPrint('Tracking preference not saved: $error');
    }
  }
}
