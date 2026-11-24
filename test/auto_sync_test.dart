import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:vivora/core/theme/app_theme.dart';
import 'package:vivora/features/activity_monitoring/data/models/activity_date_utils.dart';
import 'package:vivora/features/activity_monitoring/data/models/activity_sync_snapshot.dart';
import 'package:vivora/features/activity_monitoring/data/models/activity_sync_state.dart';
import 'package:vivora/features/activity_monitoring/data/models/app_usage_entry.dart';
import 'package:vivora/features/activity_monitoring/data/models/daily_activity_log.dart';
import 'package:vivora/features/activity_monitoring/data/services/activity_sync_service.dart';
import 'package:vivora/features/activity_monitoring/data/services/activity_tracking_controller.dart';
import 'package:vivora/features/activity_monitoring/data/services/auto_sync_coordinator.dart';
import 'package:vivora/features/activity_monitoring/presentation/widgets/tracking_status_card.dart';
import 'package:vivora/features/reports/presentation/reports_screen.dart';

import 'support/fakes.dart';
import 'support/sync_fakes.dart';

void main() {
  GoogleFonts.config.allowRuntimeFetching = false;
  late FakeDataSource device;
  late FakeActivityRepository cloud;
  late FakeBackground background;
  late List<FakeTimer> timers;
  late String? uid;
  late DateTime now;
  late Duration mono;
  late ActivitySyncService service;
  late AutoSyncCoordinator coordinator;

  List<FakeTimer> active() => timers.where((t) => t.isActive).toList();

  /// Moves both clocks forward (wall clock and monotonic).
  void advance(Duration d) {
    now = now.add(d);
    mono += d;
  }

  Future<void> settle() async {
    for (int i = 0; i < 5; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  setUp(() {
    device = FakeDataSource();
    cloud = FakeActivityRepository();
    background = FakeBackground();
    timers = <FakeTimer>[];
    uid = 'user-a';
    now = DateTime(2026, 10, 14, 10, 0);
    mono = const Duration(hours: 1);
    service = ActivitySyncService(
      dataSource: device,
      repository: cloud,
      currentUserId: () => uid,
      clock: () => now,
      cloudAckTimeout: const Duration(milliseconds: 50),
      readTimeout: const Duration(milliseconds: 50),
    );
    coordinator = AutoSyncCoordinator(
      service: service,
      background: background,
      timerFactory: (d, cb) {
        final FakeTimer t = FakeTimer(d, cb);
        timers.add(t);
        return t;
      },
      monotonic: () => mono,
    );
  });

  tearDown(() => coordinator.dispose());

  test(
    '1. starts for the signed-in user: first sync + 5-minute timer + background job',
    () async {
      await coordinator.handleUser('user-a');
      expect(device.captureCalls, 1);
      expect(cloud.writes, 1);
      expect(background.scheduled, 1);
      expect(active(), hasLength(1));
      expect(active().single.delay, const Duration(minutes: 5));
    },
  );

  test(
    '2. syncs again every 5 minutes in the foreground (fake clock)',
    () async {
      await coordinator.handleUser('user-a');
      for (int i = 0; i < 3; i++) {
        advance(const Duration(minutes: 5));
        device.appUsageMinutes = 45 + i + 1;
        active().single.fire();
        await settle();
      }
      expect(device.captureCalls, 4);
      expect(active(), hasLength(1));
      expect(service.today.value!.log.appUsageMinutes, 48);
    },
  );

  test(
    '3. no duplicate timers from repeated sign-in events, resumes or screens',
    () async {
      await coordinator.handleUser('user-a');
      await coordinator.handleUser('user-a');
      advance(const Duration(minutes: 1));
      coordinator.handleLifecycle(AppLifecycleState.inactive);
      coordinator.handleLifecycle(AppLifecycleState.resumed);
      coordinator.handleLifecycle(AppLifecycleState.resumed);
      await settle();
      expect(device.captureCalls, 1);
      expect(background.scheduled, 1);
      expect(active(), hasLength(1));
    },
  );

  test('4. a slow sync is never overlapped by another', () async {
    device.captureGate = Completer<void>();
    final Future<void> first = coordinator.handleUser('user-a');
    await settle();
    final Future<void> second = coordinator.syncNow();
    final Future<ActivitySyncResult> manual = service.syncNow(force: true);
    device.captureGate!.complete();
    await Future.wait<Object?>(<Future<Object?>>[first, second, manual]);
    expect(device.captureCalls, 1);
    expect(active(), hasLength(1));
  });

  test(
    '5. repeated syncs store the latest total, never the sum; unchanged data is not rewritten',
    () async {
      device.appUsageMinutes = 20;
      await coordinator.handleUser('user-a');
      advance(const Duration(minutes: 5));
      device.appUsageMinutes = 25;
      active().single.fire();
      await settle();

      expect(cloud.logs.length, 1);
      expect(cloud.logs.values.single.appUsageMinutes, 25);
      expect(cloud.writes, 2);

      // Nothing changed on the phone: no Firestore write, status still synced.
      advance(const Duration(minutes: 5));
      active().single.fire();
      await settle();
      expect(cloud.writes, 2);
      expect(service.cloudStatus.value.state, CloudSyncState.synced);
    },
  );

  test(
    '5b. app icon documents are rewritten only when the app list changes or every 30 min',
    () async {
      await coordinator.handleUser('user-a');
      expect(cloud.lastAppDocsWritten, 3);
      final String? firstCapture = cloud.logs.values.single.captureId;

      advance(const Duration(minutes: 5));
      device.apps = <AppUsageEntry>[
        for (final AppUsageEntry a in device.apps)
          a.packageName == 'com.whatsapp'
              ? app(a.packageName, a.appName, const Duration(minutes: 9))
              : a,
      ];
      active().single.fire();
      await settle();
      expect(cloud.lastAppDocsWritten, 0, reason: 'same apps, minutes only');
      final DailyActivityLog stored = cloud.logs.values.single;
      expect(
        stored.captureId,
        firstCapture,
        reason: 'still names the stored app docs',
      );
      final List<AppUsageEntry> apps = await cloud.getDailyApps(
        uid: 'user-a',
        log: stored,
      );
      expect(
        apps
            .firstWhere((a) => a.packageName == 'com.whatsapp')
            .foregroundDuration,
        const Duration(minutes: 9),
        reason: 'readers get fresh minutes from appSummary',
      );
      expect(apps, hasLength(3));

      advance(const Duration(minutes: 5));
      device.apps = <AppUsageEntry>[
        ...device.apps,
        app('com.android.chrome', 'Chrome', const Duration(minutes: 2)),
      ];
      active().single.fire();
      await settle();
      expect(cloud.lastAppDocsWritten, 4, reason: 'a new app appeared');
    },
  );

  test(
    '6. a capture started for one account is never written to another',
    () async {
      await coordinator.handleUser('user-a');
      final int writesBefore = cloud.writes;
      device.captureGate = Completer<void>();
      advance(const Duration(minutes: 5));
      active().single.fire();
      await settle();

      uid = 'user-b';
      final Future<void> switched = coordinator.handleUser('user-b');
      device.captureGate!.complete();
      await switched;
      await settle();

      expect(
        cloud.writtenDays.where((d) => d.startsWith('user-a/')),
        hasLength(writesBefore),
      );
      expect(service.today.value, isNotNull);
      expect(
        cloud.logs.keys.where((k) => k.startsWith('user-b/')),
        hasLength(1),
      );
      expect(active(), hasLength(1));
    },
  );

  test('6b. sign-out stops the timer and the background job', () async {
    await coordinator.handleUser('user-a');
    uid = null;
    await coordinator.handleUser(null);
    expect(active(), isEmpty);
    expect(background.cancelled, 1);
    expect(service.today.value, isNull);
  });

  test(
    '7. offline: data kept, honest status, recovers automatically',
    () async {
      cloud.writeError = FirebaseException(
        plugin: 'cloud_firestore',
        code: 'unavailable',
      );
      await coordinator.handleUser('user-a');
      expect(service.today.value, isNotNull);
      expect(service.cloudStatus.value.state, CloudSyncState.pendingOffline);
      expect(
        autoSyncStatus(
          syncState: service.syncState.value,
          needsUsage: false,
          cloud: service.cloudStatus.value.state,
          lastSyncAt: now,
          now: now,
        ),
        startsWith('Offline'),
      );

      cloud.writeError = null;
      advance(const Duration(minutes: 5));
      device.appUsageMinutes = 50;
      active().single.fire();
      await settle();
      expect(service.cloudStatus.value.state, CloudSyncState.synced);
    },
  );

  test(
    '7b. a failed device read retries with backoff, not in a tight loop',
    () async {
      device.captureError = StateError('bridge');
      await coordinator.handleUser('user-a');
      expect(service.syncState.value, ActivitySyncState.failed);
      expect(active().single.delay, const Duration(minutes: 1));
      active().single.fire();
      await settle();
      expect(active().single.delay, const Duration(minutes: 2));
      device.captureError = null;
      active().single.fire();
      await settle();
      expect(service.syncState.value, isNot(ActivitySyncState.failed));
      expect(active().single.delay, const Duration(minutes: 5));
    },
  );

  test(
    '8. without Usage Access nothing is captured or overwritten; granting it resumes at once',
    () async {
      await coordinator.handleUser('user-a');
      final int writes = cloud.writes;
      final int? stored = cloud.logs.values.single.appUsageMinutes;

      device.permissions = const ActivityPermissionSnapshot(
        usageAccessGranted: false,
        activityPermissionGranted: true,
        notificationPermissionGranted: true,
        backgroundSyncEnabled: true,
      );
      advance(const Duration(minutes: 5));
      active().single.fire();
      await settle();
      expect(service.syncState.value, ActivitySyncState.permissionRequired);
      expect(device.captureCalls, 1);
      expect(cloud.writes, writes);
      expect(
        cloud.logs.values.single.appUsageMinutes,
        stored,
        reason: 'never zeroed',
      );

      // The user grants access in Android settings and comes back.
      coordinator.handleLifecycle(AppLifecycleState.paused);
      device.permissions = const ActivityPermissionSnapshot(
        usageAccessGranted: true,
        activityPermissionGranted: true,
        notificationPermissionGranted: true,
        backgroundSyncEnabled: true,
      );
      advance(const Duration(seconds: 30));
      coordinator.handleLifecycle(AppLifecycleState.resumed);
      await settle();
      expect(device.captureCalls, 2);
    },
  );

  test(
    '9. resume after more than 5 minutes catches up; sooner just waits the remainder',
    () async {
      await coordinator.handleUser('user-a');
      coordinator.handleLifecycle(AppLifecycleState.paused);
      expect(active(), isEmpty, reason: 'no timer while in the background');

      advance(const Duration(minutes: 2));
      coordinator.handleLifecycle(AppLifecycleState.resumed);
      await settle();
      expect(device.captureCalls, 1);
      expect(active().single.delay, const Duration(minutes: 3));

      coordinator.handleLifecycle(AppLifecycleState.paused);
      advance(const Duration(minutes: 7));
      coordinator.handleLifecycle(AppLifecycleState.resumed);
      await settle();
      expect(device.captureCalls, 2);
    },
  );

  test('10. background job is registered once per account', () async {
    await coordinator.handleUser('user-a');
    coordinator.handleLifecycle(AppLifecycleState.paused);
    coordinator.handleLifecycle(AppLifecycleState.resumed);
    await coordinator.handleUser('user-a');
    expect(background.scheduled, 1);
    uid = 'user-b';
    await coordinator.handleUser('user-b');
    expect(background.scheduled, 2, reason: 'WorkManager KEEP keeps one job');
  });

  test(
    'day change: yesterday is closed with its full total, then today starts',
    () async {
      now = DateTime(2026, 10, 14, 23, 57);
      await coordinator.handleUser('user-a');
      advance(const Duration(minutes: 6)); // 00:03 next day
      active().single.fire();
      await settle();
      final List<String> days = device.capturedDays
          .map(ActivityDateUtils.dayKey)
          .toList();
      expect(days, <String>['2026-10-14', '2026-10-14', '2026-10-15']);
      expect(cloud.logs.length, 2);
      expect(
        ActivityDateUtils.dayKey(service.today.value!.log.date),
        '2026-10-15',
      );
    },
  );

  testWidgets(
    '11. the tracking card updates by itself and has no Sync Now button',
    (tester) async {
      await tester.runAsync(() => coordinator.handleUser('user-a'));
      // The switch is ON for this account.
      final MemoryTrackingStore local = MemoryTrackingStore()
        ..prefs['user-a'] = TrackingPreference(
          enabled: true,
          changedAt: DateTime(2026),
          intervals: <TrackedInterval>[TrackedInterval(DateTime(2026, 10, 1))],
        );
      final ActivityTrackingController on = ActivityTrackingController(
        local: local,
        native: FakeNativeFlag(),
        clock: () => now,
      );
      await tester.runAsync(() => on.resolveForUser('user-a'));
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.lightTheme,
          home: Scaffold(
            body: SingleChildScrollView(
              child: TrackingStatusCard(
                service: service,
                tracking: on,
                now: () => now,
              ),
            ),
          ),
        ),
      );
      expect(find.text('Sync Now'), findsNothing);
      expect(
        find.textContaining('Updates automatically every 5 minutes'),
        findsOneWidget,
      );
      expect(find.text('45m'), findsOneWidget);

      advance(const Duration(minutes: 5));
      device.appUsageMinutes = 52;
      await tester.runAsync(() async {
        active().single.fire();
        await settle();
      });
      await tester.pump();
      expect(find.text('52m'), findsOneWidget);
      expect(find.textContaining('Last updated 10:05'), findsOneWidget);
    },
  );

  test('11b. Reports shows the live day without another read', () {
    final DailyActivityLog stored = DailyActivityLog(
      date: DateTime(2026, 10, 14),
      appUsageMinutes: 20,
    );
    final DailyActivityLog older = DailyActivityLog(
      date: DateTime(2026, 10, 13),
      appUsageMinutes: 90,
    );
    final TodayActivity live = TodayActivity(
      log: DailyActivityLog(date: DateTime(2026, 10, 14), appUsageMinutes: 25),
      apps: const <AppUsageEntry>[],
    );
    final List<DailyActivityLog> merged = withLiveDay(<DailyActivityLog>[
      older,
      stored,
    ], live);
    expect(merged.map((l) => l.appUsageMinutes), <int>[90, 25]);
    expect(withLiveDay(<DailyActivityLog>[older], null), hasLength(1));
  });

  test('status text is honest for every state', () {
    String s({
      ActivitySyncState sync = ActivitySyncState.success,
      bool needsUsage = false,
      CloudSyncState cloud = CloudSyncState.synced,
      DateTime? last,
    }) => autoSyncStatus(
      syncState: sync,
      needsUsage: needsUsage,
      cloud: cloud,
      lastSyncAt: last,
      now: DateTime(2026, 10, 14, 10, 7),
    );
    expect(s(needsUsage: true), startsWith('Waiting for Usage Access'));
    expect(s(sync: ActivitySyncState.syncing), 'Updating activity…');
    expect(
      s(sync: ActivitySyncState.failed),
      contains('try again automatically'),
    );
    expect(
      s(cloud: CloudSyncState.permissionDenied),
      contains('sign in again'),
    );
    expect(s(cloud: CloudSyncState.failed), isNot(contains('Last updated')));
    expect(s(), 'Activity updates automatically.');
    expect(
      s(last: DateTime(2026, 10, 14, 10, 5)),
      endsWith('Last updated 10:05 (2 min ago).'),
    );
  });
}
