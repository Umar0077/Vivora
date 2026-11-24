import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;

import '../models/activity_date_utils.dart';
import '../models/activity_sync_snapshot.dart';
import '../models/activity_sync_state.dart';
import '../models/app_usage_entry.dart';
import '../models/daily_activity_log.dart';
import '../repositories/activity_repository.dart';
import 'activity_tracking_controller.dart';
import 'android_activity_bridge.dart';
import 'app_category_service.dart';

/// Single source of truth for today's automatically collected data.
///
/// Flow of one sync:
///  1. read permissions;
///  2. capture the current local day from Android (recomputed from scratch, so
///     repeating it can never inflate totals);
///  3. apply the user's category overrides;
///  4. publish the result locally ([today]) so every screen shows the same
///     snapshot immediately, online or not;
///  5. upload to Firestore and report [cloudStatus] honestly: `synced` only
///     after the server acknowledged the write.
class ActivitySyncService {
  ActivitySyncService({
    required ActivityDataSource dataSource,
    required ActivityRepository repository,
    required String? Function() currentUserId,
    AppCategoryService categoryService = const AppCategoryService(),
    DateTime Function()? clock,
    ActivityTrackingGate? tracking,
    this.cloudAckTimeout = const Duration(seconds: 15),
    this.readTimeout = const Duration(seconds: 6),
  }) : _tracking = tracking,
       _dataSource = dataSource,
       _repository = repository,
       _currentUserId = currentUserId,
       _categoryService = categoryService,
       _clock = clock ?? DateTime.now;

  static final ActivitySyncService instance = ActivitySyncService(
    dataSource: AndroidActivityBridge.instance,
    repository: ActivityRepository(),
    currentUserId: () => FirebaseAuth.instance.currentUser?.uid,
    tracking: ActivityTrackingController.instance,
  );

  /// The "Automatic Activity Tracking" switch. Null only in tests that
  /// predate it (then everything is allowed, as before).
  final ActivityTrackingGate? _tracking;
  final ActivityDataSource _dataSource;
  final ActivityRepository _repository;
  final String? Function() _currentUserId;
  final AppCategoryService _categoryService;
  final DateTime Function() _clock;
  final Duration cloudAckTimeout;
  final Duration readTimeout;

  /// Minimum gap between automatic (non-forced) captures.
  static const Duration throttleWindow = Duration(minutes: 2);

  final ValueNotifier<ActivitySyncState> syncState =
      ValueNotifier<ActivitySyncState>(ActivitySyncState.idle);
  final ValueNotifier<ActivityPermissionSnapshot> permissions =
      ValueNotifier<ActivityPermissionSnapshot>(
        ActivityPermissionSnapshot.unknown,
      );
  final ValueNotifier<TodayActivity?> today = ValueNotifier<TodayActivity?>(
    null,
  );
  final ValueNotifier<CloudSyncStatus> cloudStatus =
      ValueNotifier<CloudSyncStatus>(CloudSyncStatus.idle);
  final ValueNotifier<ActivitySyncResult?> latestResult =
      ValueNotifier<ActivitySyncResult?>(null);

  Future<ActivitySyncResult>? _inFlight;
  String? _uid;
  DateTime? _lastCaptureAt;
  Map<String, AppCategory>? _overrides;
  int _uploadToken = 0;
  String? _ackedSignature;
  _AppDetailState? _details;

  Future<ActivityPermissionSnapshot> refreshPermissions() async {
    final ActivityPermissionSnapshot snapshot = await _dataSource
        .getPermissionSnapshot();
    permissions.value = snapshot;
    return snapshot;
  }

  Future<ActivityPermissionSnapshot> getPermissionSnapshot() =>
      refreshPermissions();

  Future<void> openUsageAccessSettings() =>
      _dataSource.openUsageAccessSettings();

  Future<bool> requestActivityPermission() async {
    final bool granted = await _dataSource.requestActivityPermission();
    final String? uid = _currentUserId();
    if (granted && uid != null && _trackingOn(uid)) {
      await _dataSource.scheduleBackgroundSync();
    }
    await refreshPermissions();
    return granted;
  }

  /// Clears everything held for the previous account. Called on sign-in/out so
  /// one user can never see another user's data.
  void onUserChanged(String? uid) {
    if (uid == _uid) {
      return;
    }
    _uid = uid;
    _overrides = null;
    _lastCaptureAt = null;
    _ackedSignature = null;
    _details = null;
    today.value = null;
    latestResult.value = null;
    cloudStatus.value = CloudSyncStatus.idle;
    syncState.value = ActivitySyncState.idle;
  }

  static const String trackingOffMessage =
      'Activity tracking is turned off in Settings.';

  bool _trackingOn(String uid) => _tracking?.allows(uid) ?? true;

  /// Still the same account, still ON, and not switched off and on again
  /// since [generation] was read.
  bool _stillAllowed(String uid, int generation) =>
      _uid == uid &&
      _trackingOn(uid) &&
      (_tracking == null || _tracking.generation == generation);

  /// Called when tracking is switched off: shows the paused state. Data
  /// already on screen stays as the last recorded values.
  void showTrackingOff() {
    _publish(
      ActivitySyncState.trackingOff,
      trackingOffMessage,
      today: today.value,
    );
  }

  /// Measures only the parts of [start, end) during which tracking was on
  /// (all of it when no switch is attached). Null when nothing was tracked.
  Future<_DayCapture?> _captureTracked(DateTime start, DateTime end) async {
    final ActivityTrackingGate? gate = _tracking;
    if (gate == null) {
      return _DayCapture(
        await _dataSource.captureActivityRange(start: start, end: end),
        null,
      );
    }
    final List<(DateTime, DateTime)> ranges = gate.trackedRanges(start, end);
    if (ranges.isEmpty) return null;
    final List<ActivityCaptureSnapshot> parts = <ActivityCaptureSnapshot>[
      for (final (DateTime s, DateTime e) in ranges)
        await _dataSource.captureActivityRange(start: s, end: e),
    ];
    return _DayCapture(mergeCaptures(parts, start, end), ranges);
  }

  /// Adds up captures of separate (non-overlapping) periods of one day.
  static ActivityCaptureSnapshot mergeCaptures(
    List<ActivityCaptureSnapshot> parts,
    DateTime start,
    DateTime end,
  ) {
    if (parts.length == 1) return parts.single;
    int? sum(int? Function(ActivityCaptureSnapshot) f) {
      final List<int> values = parts.map(f).whereType<int>().toList();
      return values.isEmpty ? null : values.fold<int>(0, (a, b) => a + b);
    }

    final Map<String, AppUsageEntry> apps = <String, AppUsageEntry>{};
    for (final ActivityCaptureSnapshot p in parts) {
      for (final AppUsageEntry e in p.appUsageEntries) {
        final AppUsageEntry? prev = apps[e.packageName];
        apps[e.packageName] = prev == null
            ? e
            : AppUsageEntry(
                packageName: e.packageName,
                appName: e.appName,
                iconBase64: e.iconBase64 ?? prev.iconBase64,
                usageMinutes: prev.usageMinutes + e.usageMinutes,
                foregroundDuration:
                    prev.foregroundDuration + e.foregroundDuration,
                lastUsedAt: e.lastUsedAt ?? prev.lastUsedAt,
                category: e.category,
                isSystemApp: e.isSystemApp,
                isLauncher: e.isLauncher,
              );
      }
    }
    final ActivityCaptureSnapshot last = parts.last;
    return ActivityCaptureSnapshot(
      start: start,
      end: end,
      usagePermissionGranted: parts.every((p) => p.usagePermissionGranted),
      activityPermissionGranted: last.activityPermissionGranted,
      notificationPermissionGranted: last.notificationPermissionGranted,
      syncStatus: last.syncStatus,
      appUsageEntries: apps.values.toList(),
      screenTimeMinutes: sum((p) => p.screenTimeMinutes),
      appUsageMinutes: sum((p) => p.appUsageMinutes),
      interactiveScreenTimeSeconds: sum((p) => p.interactiveScreenTimeSeconds),
      screenOnCount: sum((p) => p.screenOnCount),
      screenOffCount: sum((p) => p.screenOffCount),
      phoneUnlockCount: sum((p) => p.phoneUnlockCount),
      walkingMinutes: sum((p) => p.walkingMinutes),
      runningMinutes: sum((p) => p.runningMinutes),
      stillMinutes: sum((p) => p.stillMinutes),
      vehicleMinutes: sum((p) => p.vehicleMinutes),
      unknownActivityMinutes: sum((p) => p.unknownActivityMinutes),
      movementStatus: last.movementStatus,
      source: last.source,
    );
  }

  /// Automatic sync (start-up, resume, screen open): throttled.
  Future<ActivitySyncResult> syncIfNeeded() => syncNow(force: false);

  /// Concurrent callers share the in-flight sync instead of starting another.
  Future<ActivitySyncResult> syncNow({bool force = false}) {
    final Future<ActivitySyncResult>? running = _inFlight;
    if (running != null) {
      return running;
    }
    final Future<ActivitySyncResult> future = _sync(force: force);
    _inFlight = future;
    return future.whenComplete(() => _inFlight = null);
  }

  Future<ActivitySyncResult> _sync({required bool force}) async {
    final String? uid = _currentUserId();
    if (uid == null) {
      onUserChanged(null);
      return _publish(
        ActivitySyncState.failed,
        'Sign in to collect activity data.',
      );
    }
    onUserChanged(uid);

    final DateTime now = _clock();
    // Privacy switch: when OFF nothing is measured or uploaded, whoever asks
    // (timer, resume, pull-to-refresh, background worker). Previously saved
    // data is still shown.
    final int generation = _tracking?.generation ?? 0;
    if (!_trackingOn(uid)) {
      unawaited(_loadCachedToday(uid, now));
      return _publish(ActivitySyncState.trackingOff, trackingOffMessage);
    }
    final TodayActivity? current = today.value;
    if (!force &&
        current != null &&
        _lastCaptureAt != null &&
        now.difference(_lastCaptureAt!) < throttleWindow &&
        ActivityDateUtils.isSameDay(current.log.date, now)) {
      return latestResult.value ??
          _publish(syncState.value, 'Up to date.', today: current);
    }

    syncState.value = ActivitySyncState.syncing;
    try {
      final ActivityPermissionSnapshot snapshot = await refreshPermissions();
      if (!snapshot.usageAccessGranted) {
        // Nothing can be measured; still show what the cloud has for today.
        unawaited(_loadCachedToday(uid, now));
        return _publish(
          ActivitySyncState.permissionRequired,
          'Usage Access is required to measure screen time and app usage.',
        );
      }

      final ActivitySyncMetadata metadata = await _dataSource.getSyncMetadata();
      await _closePreviousDay(uid, now, metadata, generation);
      if (_uid != uid) {
        return _publish(ActivitySyncState.idle, 'Account changed.');
      }
      if (!_stillAllowed(uid, generation)) {
        return _publish(ActivitySyncState.trackingOff, trackingOffMessage);
      }

      final ActivityDateRange day = ActivityDateUtils.currentDayRange(now);
      final _DayCapture? measured = await _captureTracked(day.start, day.end);
      if (_uid != uid) {
        // The account changed while the device was being read.
        return _publish(ActivitySyncState.idle, 'Account changed.');
      }
      if (!_stillAllowed(uid, generation)) {
        // Switched OFF while the phone was being read: discard the result.
        return _publish(ActivitySyncState.trackingOff, trackingOffMessage);
      }
      if (measured == null) {
        return _publish(
          syncState.value == ActivitySyncState.syncing
              ? ActivitySyncState.idle
              : syncState.value,
          'Tracking has just started; the first measurement follows shortly.',
        );
      }
      final ActivityCaptureSnapshot capture = measured.capture;
      if (!capture.usagePermissionGranted) {
        return _publish(
          ActivitySyncState.permissionRequired,
          'Usage Access is required to measure screen time and app usage.',
        );
      }

      final Map<String, AppCategory> overrides = await _loadOverrides(uid);
      final List<AppUsageEntry> apps = _categorize(capture, overrides);
      final bool writeDetails = _needsAppDetails(uid, day.start, apps, now);
      // The day document's captureId names the per-app documents that belong
      // to it, so it only changes when those are rewritten (see _upload).
      final String captureId = writeDetails
          ? now.millisecondsSinceEpoch.toString()
          : _details!.captureId;
      final DailyActivityLog log = buildDailyLog(
        capture: capture,
        apps: apps,
        date: day.start,
        captureId: captureId,
        syncedAt: now,
        collectionStartedAt: metadata.collectionStartedAt ?? now,
        trackedRanges: measured.ranges,
        dayEnd: now,
      );

      final TodayActivity todayActivity = TodayActivity(log: log, apps: apps);
      today.value = todayActivity;
      _lastCaptureAt = now;

      await _dataSource.saveSyncMetadata(
        metadata.copyWith(
          lastSuccessfulActivitySync: now,
          lastUsagePermissionState: snapshot.usageAccessGranted,
          lastActivityPermissionState: snapshot.activityPermissionGranted,
          collectionStartedAt: metadata.collectionStartedAt ?? now,
          lastSyncedUserId: uid,
        ),
      );
      if (snapshot.activityPermissionGranted &&
          !snapshot.backgroundSyncEnabled) {
        await _dataSource.scheduleBackgroundSync();
        await refreshPermissions();
      }

      final ActivitySyncState state = log.hasMovementData
          ? ActivitySyncState.success
          : ActivitySyncState.partialData;
      final ActivitySyncResult result = _publish(
        state,
        state == ActivitySyncState.success
            ? 'Device data collected.'
            : 'Screen and app data collected. Movement data is unavailable.',
        today: todayActivity,
      );

      // Last check right before the write: no upload after switching OFF.
      if (_stillAllowed(uid, generation)) {
        await _upload(uid, todayActivity, writeDetails: writeDetails);
      }
      return result;
    } on PlatformException catch (error) {
      return _publish(
        ActivitySyncState.failed,
        'Android activity bridge error: ${error.message ?? error.code}',
      );
    } catch (error) {
      debugPrint('Activity sync failed: $error');
      return _publish(
        ActivitySyncState.failed,
        'Could not read activity from this phone. Please try again.',
      );
    }
  }

  /// Builds the daily log from a capture. Category totals are summed from exact
  /// durations and rounded once, so they agree with the per-app list.
  static DailyActivityLog buildDailyLog({
    required ActivityCaptureSnapshot capture,
    required List<AppUsageEntry> apps,
    required DateTime date,
    required String captureId,
    required DateTime syncedAt,
    DateTime? collectionStartedAt,

    /// The parts of the day that were measured (tracking switched on), or
    /// null when tracking periods are not recorded (whole day measured).
    List<(DateTime, DateTime)>? trackedRanges,

    /// End of the period this capture covers (now for today).
    DateTime? dayEnd,
  }) {
    final DateTime coverageEnd = dayEnd ?? ActivityDateUtils.nextDayStart(date);
    final int? trackedMinutes = trackedRanges?.fold<int>(
      0,
      (int sum, (DateTime, DateTime) r) =>
          sum + r.$2.difference(r.$1).inMinutes,
    );
    final int coverageMinutes = coverageEnd
        .difference(ActivityDateUtils.dayStart(date))
        .inMinutes;
    int minutesFor(AppCategory category) {
      final int millis = apps
          .where((AppUsageEntry entry) => entry.category == category)
          .fold<int>(
            0,
            (int sum, AppUsageEntry entry) =>
                sum + entry.foregroundDuration.inMilliseconds,
          );
      return (millis / 60000).round();
    }

    return DailyActivityLog(
      date: ActivityDateUtils.dayStart(date),
      screenTimeMinutes: capture.screenTimeMinutes,
      appUsageMinutes: capture.appUsageMinutes,
      interactiveScreenTimeSeconds: capture.interactiveScreenTimeSeconds,
      phoneUnlockCount: capture.phoneUnlockCount,
      screenOnCount: capture.screenOnCount,
      screenOffCount: capture.screenOffCount,
      productiveAppMinutes: minutesFor(AppCategory.productive),
      distractingAppMinutes: minutesFor(AppCategory.distracting),
      neutralAppMinutes: minutesFor(AppCategory.neutral),
      uncategorizedAppMinutes: minutesFor(AppCategory.uncategorized),
      walkingMinutes: capture.walkingMinutes,
      runningMinutes: capture.runningMinutes,
      stillMinutes: capture.stillMinutes,
      vehicleMinutes: capture.vehicleMinutes,
      unknownActivityMinutes: capture.unknownActivityMinutes,
      movementStatus: capture.movementStatus,
      captureId: captureId,
      lastSyncAt: syncedAt,
      collectionStartedAt: collectionStartedAt,
      usagePermissionGranted: capture.usagePermissionGranted,
      activityPermissionGranted: capture.activityPermissionGranted,
      notificationPermissionGranted: capture.notificationPermissionGranted,
      source: capture.source,
      syncStatus: capture.syncStatus,
      appSummary: apps,
      trackedMinutes: trackedMinutes,
      // Whole period measured (1 min tolerance for clock rounding)?
      trackingComplete: switch (trackedMinutes) {
        null => null,
        final int m => m >= coverageMinutes - 1,
      },
      trackedRanges: trackedRanges,
    );
  }

  /// Per-app documents carry app icons, so rewriting all of them every few
  /// minutes would waste bandwidth and Firestore writes. They are rewritten
  /// when the set of apps changes, at most every [appDetailInterval]
  /// otherwise, and on a day's closing pass. In between, the day document's
  /// `appSummary` (compact, no icons) carries the fresh per-app minutes.
  static const Duration appDetailInterval = Duration(minutes: 30);

  bool _needsAppDetails(
    String uid,
    DateTime day,
    List<AppUsageEntry> apps,
    DateTime now,
  ) {
    final _AppDetailState? d = _details;
    return d == null ||
        d.uid != uid ||
        !ActivityDateUtils.isSameDay(d.day, day) ||
        now.difference(d.writtenAt) >= appDetailInterval ||
        now.isBefore(d.writtenAt) ||
        !setEquals(d.packages, apps.map((a) => a.packageName).toSet());
  }

  List<AppUsageEntry> _categorize(
    ActivityCaptureSnapshot capture,
    Map<String, AppCategory> overrides,
  ) => _categoryService.categorizeEntries(
    capture.appUsageEntries,
    overrides: overrides,
  )..sort((a, b) => b.foregroundDuration.compareTo(a.foregroundDuration));

  /// When the last capture was on an earlier day, that day's final minutes
  /// (e.g. 23:57-24:00) were never uploaded. Recapture the whole of that day
  /// once and replace its record. Only for this install's own last account,
  /// only within the last 3 days, and never with a capture lacking Usage
  /// Access (which would read as zero).
  Future<void> _closePreviousDay(
    String uid,
    DateTime now,
    ActivitySyncMetadata metadata,
    int generation,
  ) async {
    final DateTime? last =
        _lastCaptureAt ??
        (metadata.lastSyncedUserId == uid
            ? metadata.lastSuccessfulActivitySync
            : null);
    if (last == null || ActivityDateUtils.isSameDay(last, now)) return;
    final DateTime lastDay = ActivityDateUtils.dayStart(last);
    if (lastDay.isAfter(now) ||
        ActivityDateUtils.dayStart(now).difference(lastDay).inDays > 3) {
      return;
    }
    try {
      // Only the parts of that day during which tracking was on.
      final _DayCapture? measured = await _captureTracked(
        lastDay,
        ActivityDateUtils.nextDayStart(lastDay),
      );
      if (measured == null) return;
      final ActivityCaptureSnapshot capture = measured.capture;
      if (_uid != uid ||
          !_stillAllowed(uid, generation) ||
          !capture.usagePermissionGranted ||
          capture.appUsageMinutes == null) {
        return;
      }
      final List<AppUsageEntry> apps = _categorize(
        capture,
        await _loadOverrides(uid),
      );
      final DailyActivityLog log = buildDailyLog(
        capture: capture,
        apps: apps,
        date: lastDay,
        captureId: '${now.millisecondsSinceEpoch}_final',
        syncedAt: now,
        collectionStartedAt: metadata.collectionStartedAt,
        trackedRanges: measured.ranges,
      );
      final Future<void> write = _repository.upsertDailyActivityLog(
        uid: uid,
        log: log,
        appUsageEntries: apps,
      );
      // Queued offline by Firestore if there is no connection.
      await write.timeout(cloudAckTimeout, onTimeout: () {});
    } catch (error) {
      debugPrint('Closing pass for the previous day failed: $error');
    }
  }

  Future<void> _upload(
    String uid,
    TodayActivity data, {
    bool writeDetails = true,
  }) async {
    final int token = ++_uploadToken;
    final String signature = _signature(uid, data.log);
    if (signature == _ackedSignature) {
      // Identical to what the server already confirmed: nothing to write.
      _setCloudStatus(token, CloudSyncState.synced);
      return;
    }
    cloudStatus.value = CloudSyncStatus(CloudSyncState.uploading, at: _clock());
    final Future<void> write = _repository.upsertDailyActivityLog(
      uid: uid,
      log: data.log,
      appUsageEntries: writeDetails ? data.apps : const <AppUsageEntry>[],
    );
    if (writeDetails) {
      _details = _AppDetailState(
        uid: uid,
        day: data.log.date,
        captureId: data.log.captureId ?? '',
        packages: data.apps.map((a) => a.packageName).toSet(),
        writtenAt: data.log.lastSyncAt ?? _clock(),
      );
    }
    void acked() {
      _ackedSignature = signature;
      _setCloudStatus(token, CloudSyncState.synced);
    }

    try {
      await write.timeout(cloudAckTimeout);
      acked();
    } on TimeoutException {
      // Firestore keeps the batch in its offline queue and retries it; report
      // the honest state now and flip to synced if the server acknowledges it.
      _setCloudStatus(
        token,
        CloudSyncState.pendingOffline,
        'No response from Firestore within ${cloudAckTimeout.inSeconds}s. '
        'Data is kept on this device and will upload when online.',
      );
      unawaited(
        write.then(
          (_) => acked(),
          onError: (Object error) {
            _details = null;
            _setCloudStatus(token, _classify(error), '$error');
          },
        ),
      );
    } catch (error) {
      // Nothing was stored: rewrite the per-app documents next time.
      _details = null;
      _setCloudStatus(token, _classify(error), '$error');
    }
  }

  /// Everything that would be written, minus fields that change on every
  /// capture without changing the data (sync time, capture id).
  static String _signature(String uid, DailyActivityLog log) {
    final Map<String, dynamic> map = log.toMap()
      ..remove('lastSyncAt')
      ..remove('captureId')
      ..remove('updatedAt')
      // Coverage grows with the clock even when nothing was used; it is
      // written along with the next real change.
      ..remove('trackedMinutes')
      ..remove('trackedRanges');
    return '$uid|${log.documentId}|$map';
  }

  void _setCloudStatus(int token, CloudSyncState state, [String? message]) {
    // Ignore late results for an older upload.
    if (token != _uploadToken) {
      return;
    }
    cloudStatus.value = CloudSyncStatus(state, message: message, at: _clock());
  }

  static CloudSyncState _classify(Object error) {
    if (error is FirebaseException) {
      switch (error.code) {
        case 'permission-denied':
          return CloudSyncState.permissionDenied;
        case 'unauthenticated':
          return CloudSyncState.unauthenticated;
        case 'unavailable':
        case 'deadline-exceeded':
          return CloudSyncState.pendingOffline;
      }
    }
    return CloudSyncState.failed;
  }

  Future<Map<String, AppCategory>> _loadOverrides(String uid) async {
    final Map<String, AppCategory>? cached = _overrides;
    if (cached != null) {
      return cached;
    }
    try {
      final Map<String, AppCategory> loaded = await _repository
          .getCategoryOverrides(uid: uid)
          .timeout(readTimeout);
      _overrides = loaded;
      return loaded;
    } catch (error) {
      // Offline on first launch: categorise with defaults now, retry next sync.
      debugPrint('Category overrides unavailable: $error');
      return const <String, AppCategory>{};
    }
  }

  /// Changes an app's category for every day and re-publishes today's data.
  Future<void> setCategoryOverride(
    String packageName,
    AppCategory category,
  ) async {
    final String? uid = _currentUserId();
    if (uid == null) {
      return;
    }
    final Map<String, AppCategory> overrides = <String, AppCategory>{
      ...await _loadOverrides(uid),
    };
    if (category == AppCategory.uncategorized) {
      overrides.remove(packageName);
    } else {
      overrides[packageName] = category;
    }
    _overrides = overrides;

    final TodayActivity? current = today.value;
    if (current != null) {
      final List<AppUsageEntry> apps = current.apps.map((AppUsageEntry entry) {
        if (entry.packageName != packageName) {
          return entry;
        }
        return category == AppCategory.uncategorized
            ? _categoryService.categorizeEntry(entry)
            : entry.withCategory(category, userOverride: true);
      }).toList();
      final DailyActivityLog log = buildDailyLog(
        capture: _captureFromLog(current.log),
        apps: apps,
        date: current.log.date,
        captureId:
            current.log.captureId ?? '${_clock().millisecondsSinceEpoch}',
        syncedAt: current.log.lastSyncAt ?? _clock(),
        collectionStartedAt: current.log.collectionStartedAt,
        trackedRanges: current.log.trackedRanges,
        dayEnd: current.log.lastSyncAt,
      );
      today.value = TodayActivity(log: log, apps: apps);
      // Re-categorising is not new measurement, but uploads still respect
      // the switch.
      if (_trackingOn(uid)) unawaited(_upload(uid, today.value!));
    }
    try {
      await _repository
          .setCategoryOverride(
            uid: uid,
            packageName: packageName,
            category: category,
          )
          .timeout(cloudAckTimeout);
    } on TimeoutException {
      // Queued in Firestore's offline cache; it uploads when back online.
    }
  }

  ActivityCaptureSnapshot _captureFromLog(DailyActivityLog log) {
    return ActivityCaptureSnapshot(
      start: log.date,
      end: ActivityDateUtils.nextDayStart(log.date),
      screenTimeMinutes: log.screenTimeMinutes,
      appUsageMinutes: log.appUsageMinutes,
      interactiveScreenTimeSeconds: log.interactiveScreenTimeSeconds,
      screenOnCount: log.screenOnCount,
      screenOffCount: log.screenOffCount,
      phoneUnlockCount: log.phoneUnlockCount,
      walkingMinutes: log.walkingMinutes,
      runningMinutes: log.runningMinutes,
      stillMinutes: log.stillMinutes,
      vehicleMinutes: log.vehicleMinutes,
      unknownActivityMinutes: log.unknownActivityMinutes,
      movementStatus: log.movementStatus,
      usagePermissionGranted: log.usagePermissionGranted ?? true,
      activityPermissionGranted: log.activityPermissionGranted ?? false,
      notificationPermissionGranted: log.notificationPermissionGranted ?? false,
      source: log.source,
      syncStatus: log.syncStatus,
      appUsageEntries: const <AppUsageEntry>[],
    );
  }

  /// Loads today's last uploaded snapshot (used when the device cannot measure,
  /// e.g. Usage Access revoked). Never overwrites a fresher local capture.
  Future<void> _loadCachedToday(String uid, DateTime now) async {
    try {
      final DailyActivityLog? log = await _repository
          .getDailyActivityLog(uid: uid, date: now)
          .timeout(readTimeout);
      if (log == null || today.value != null || _uid != uid) {
        return;
      }
      final List<AppUsageEntry> apps = await _repository
          .getDailyApps(uid: uid, log: log)
          .timeout(readTimeout);
      if (today.value == null && _uid == uid) {
        today.value = TodayActivity(log: log, apps: apps);
      }
    } catch (error) {
      debugPrint('Cached activity unavailable: $error');
    }
  }

  ActivitySyncResult _publish(
    ActivitySyncState state,
    String message, {
    TodayActivity? today,
  }) {
    final ActivitySyncResult result = ActivitySyncResult(
      state: state,
      message: message,
      permissionSnapshot: permissions.value,
      syncedAt: _clock(),
      today: today,
    );
    latestResult.value = result;
    syncState.value = state;
    return result;
  }
}

/// Which per-app documents were last written for a day.
class _AppDetailState {
  const _AppDetailState({
    required this.uid,
    required this.day,
    required this.captureId,
    required this.packages,
    required this.writtenAt,
  });

  final String uid;
  final DateTime day;
  final String captureId;
  final Set<String> packages;
  final DateTime writtenAt;
}

class _DayCapture {
  const _DayCapture(this.capture, this.ranges);
  final ActivityCaptureSnapshot capture;

  /// Measured periods, or null when no tracking switch is attached.
  final List<(DateTime, DateTime)>? ranges;
}
