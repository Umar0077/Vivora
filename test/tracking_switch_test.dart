import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:vivora/core/theme/vivora_palette.dart';
import 'package:vivora/features/activity_monitoring/data/models/activity_sync_snapshot.dart';
import 'package:vivora/features/activity_monitoring/data/models/activity_sync_state.dart';
import 'package:vivora/features/activity_monitoring/data/models/daily_activity_log.dart';
import 'package:vivora/features/activity_monitoring/data/services/activity_sync_service.dart';
import 'package:vivora/features/activity_monitoring/data/services/activity_tracking_controller.dart';
import 'package:vivora/features/activity_monitoring/data/services/auto_sync_coordinator.dart';
import 'package:vivora/features/activity_monitoring/presentation/widgets/activity_tracking_section.dart';
import 'package:vivora/features/activity_monitoring/presentation/widgets/tracking_status_card.dart';
import 'package:vivora/features/behavior_analysis/domain/behavior_analysis_engine.dart';
import 'package:vivora/features/behavior_analysis/domain/behavior_models.dart';
import 'package:vivora/features/insights/data/history_data.dart';
import 'package:vivora/features/productivity_scoring/data/models/productivity_models.dart';
import 'package:vivora/features/focus_mode/data/focus_session_repository.dart';
import 'package:vivora/features/activity_monitoring/data/models/app_usage_entry.dart';

import 'support/fakes.dart';
import 'support/layout_harness.dart';
import 'support/sync_fakes.dart';

void main() {
  late FakeDataSource device;
  late FakeActivityRepository cloud;
  late FakeBackground background;
  late MemoryTrackingStore local;
  late FakeRemoteTrackingStore remote;
  late FakeNativeFlag native;
  late List<FakeTimer> timers;
  late String? uid;
  late DateTime now;
  late Duration mono;
  late ActivityTrackingController tracking;
  late ActivitySyncService service;
  late AutoSyncCoordinator coordinator;

  List<FakeTimer> active() => timers.where((t) => t.isActive).toList();

  void advance(Duration d) {
    now = now.add(d);
    mono += d;
  }

  Future<void> settle() async {
    for (int i = 0; i < 30; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  ActivityTrackingController newController() => ActivityTrackingController(
    local: local,
    remote: remote,
    native: native,
    clock: () => now,
    remoteTimeout: const Duration(milliseconds: 50),
  );

  void build() {
    tracking = newController();
    service = ActivitySyncService(
      dataSource: device,
      repository: cloud,
      currentUserId: () => uid,
      clock: () => now,
      tracking: tracking,
      cloudAckTimeout: const Duration(milliseconds: 50),
      readTimeout: const Duration(milliseconds: 50),
    );
    coordinator = AutoSyncCoordinator(
      service: service,
      background: background,
      tracking: tracking,
      timerFactory: (d, cb) {
        final FakeTimer t = FakeTimer(d, cb);
        timers.add(t);
        return t;
      },
      monotonic: () => mono,
    );
  }

  void storeChoice(String user, bool enabled, {DateTime? since}) {
    local.prefs[user] = TrackingPreference(
      enabled: enabled,
      changedAt: DateTime(2026, 10, 1),
      intervals: enabled
          ? <TrackedInterval>[TrackedInterval(since ?? DateTime(2026, 10, 1))]
          : const <TrackedInterval>[],
    );
  }

  setUp(() {
    GoogleFonts.config.allowRuntimeFetching = false;
    device = FakeDataSource();
    cloud = FakeActivityRepository();
    background = FakeBackground();
    local = MemoryTrackingStore();
    remote = FakeRemoteTrackingStore();
    native = FakeNativeFlag();
    timers = <FakeTimer>[];
    uid = 'user-a';
    now = DateTime(2026, 10, 14, 10, 0);
    mono = const Duration(hours: 1);
    build();
  });

  tearDown(() => coordinator.dispose());

  group('preference', () {
    test(
      '1. a new user starts with tracking OFF; nothing is collected',
      () async {
        await coordinator.handleUser('user-a');
        expect(tracking.isResolved, isTrue);
        expect(tracking.isEnabled, isFalse);
        expect(native.enabled, isFalse);
        expect(device.captureCalls, 0);
        expect(cloud.writes, 0);
        expect(background.scheduled, 0);
        expect(active(), isEmpty);
      },
    );

    test(
      '2. an existing stored choice is respected; the newer copy wins',
      () async {
        storeChoice('user-a', true);
        await coordinator.handleUser('user-a');
        expect(tracking.isEnabled, isTrue);
        expect(native.enabled, isTrue);

        // Turned off on another phone later: the cloud copy is newer.
        remote.prefs['user-b'] = TrackingPreference(
          enabled: false,
          changedAt: DateTime(2026, 10, 12),
        );
        storeChoice('user-b', true);
        uid = 'user-b';
        await coordinator.handleUser('user-b');
        expect(tracking.isEnabled, isFalse);
      },
    );

    test(
      '7/8. the choice survives a restart (OFF stays OFF, ON stays ON)',
      () async {
        await coordinator.handleUser('user-a');
        await tracking.setEnabled(true);
        coordinator.dispose();
        build(); // simulated restart, same phone storage
        await coordinator.handleUser('user-a');
        expect(tracking.isEnabled, isTrue);

        await tracking.setEnabled(false);
        coordinator.dispose();
        build();
        await coordinator.handleUser('user-a');
        expect(tracking.isEnabled, isFalse);
        expect(
          device.captureCalls,
          0,
          reason: 'no tracked time had passed yet',
        );
      },
    );

    test(
      'offline change is kept locally and pushed to the account later',
      () async {
        remote.offline = true;
        await coordinator.handleUser('user-a');
        await tracking.setEnabled(true);
        await settle();
        expect(remote.prefs, isEmpty);
        remote.offline = false;
        coordinator.dispose();
        build();
        await coordinator.handleUser('user-a');
        await settle();
        expect(tracking.isEnabled, isTrue);
        expect(remote.prefs['user-a']!.enabled, isTrue);
      },
    );
  });

  group('ON / OFF', () {
    test(
      '3/23/24. switching ON syncs now, every 5 minutes, and in the background',
      () async {
        await coordinator.handleUser('user-a');
        expect(device.captureCalls, 0);
        await tracking.setEnabled(true);
        await settle();
        // The initial sync runs, but measuring starts now: nothing to read yet.
        expect(device.captureCalls, 0);
        expect(background.scheduled, 1);
        expect(native.enabled, isTrue);
        expect(active().single.delay, const Duration(minutes: 5));

        advance(const Duration(minutes: 5));
        active().single.fire();
        await settle();
        expect(device.captureCalls, 1);
        expect(device.capturedDays.single, DateTime(2026, 10, 14, 10, 0));
        expect(cloud.writes, 1);

        advance(const Duration(minutes: 5));
        device.appUsageMinutes = 50;
        active().single.fire();
        await settle();
        expect(device.captureCalls, 2);
        expect(active(), hasLength(1));
      },
    );

    test(
      '4/5. switching OFF stops the timer, the background job and the native flag',
      () async {
        storeChoice('user-a', true);
        await coordinator.handleUser('user-a');
        expect(active(), hasLength(1));
        await tracking.setEnabled(false);
        await settle();
        expect(active(), isEmpty);
        expect(background.cancelled, 1);
        expect(native.enabled, isFalse);
        expect(service.syncState.value, ActivitySyncState.trackingOff);
      },
    );

    test('9/10. no sync on launch or resume while OFF', () async {
      await coordinator.handleUser('user-a');
      coordinator.handleLifecycle(AppLifecycleState.paused);
      advance(const Duration(minutes: 30));
      coordinator.handleLifecycle(AppLifecycleState.resumed);
      await settle();
      expect(device.captureCalls, 0);
      expect(active(), isEmpty);
    });

    test(
      '6/16. any other caller (pull-to-refresh, background entry) is refused while OFF',
      () async {
        await coordinator.handleUser('user-a');
        final ActivitySyncResult r = await service.syncNow(force: true);
        expect(r.state, ActivitySyncState.trackingOff);
        expect(device.captureCalls, 0);
        expect(cloud.writes, 0);
        // Re-categorising an app does not upload either.
        await service.setCategoryOverride(
          'com.whatsapp',
          AppCategory.distracting,
        );
        expect(cloud.writes, 0);
      },
    );

    test(
      '21. rapid toggling leaves exactly one timer and one background job',
      () async {
        await coordinator.handleUser('user-a');
        await tracking.setEnabled(true);
        await tracking.setEnabled(false);
        await tracking.setEnabled(true);
        await tracking.setEnabled(false);
        await tracking.setEnabled(true);
        await settle();
        expect(active(), hasLength(1));
        expect(tracking.isEnabled, isTrue);
        expect(native.enabled, isTrue);
        // Initial OFF + 2 OFFs cancel; 3 ONs schedule; the last action was ON
        // (WorkManager KEEP keeps a single unique job).
        expect(background.scheduled, 3);
        expect(background.cancelled, 3);
      },
    );

    test('22. unchanged data is not written twice while ON', () async {
      storeChoice('user-a', true);
      await coordinator.handleUser('user-a');
      advance(const Duration(minutes: 5));
      active().single.fire();
      await settle();
      expect(cloud.writes, 1);
    });
  });

  group('races', () {
    test(
      '14. switching OFF during a sync: the result is not shown or uploaded',
      () async {
        storeChoice('user-a', true);
        await coordinator.handleUser('user-a');
        final int writes = cloud.writes;
        final int? shown = service.today.value!.log.appUsageMinutes;

        device.captureGate = Completer<void>();
        device.appUsageMinutes = 99;
        advance(const Duration(minutes: 5));
        active().single.fire();
        await settle();
        await tracking.setEnabled(false);
        device.captureGate!.complete();
        await settle();

        expect(cloud.writes, writes);
        expect(service.today.value!.log.appUsageMinutes, shown);
        expect(service.syncState.value, ActivitySyncState.trackingOff);
        expect(
          active(),
          isEmpty,
          reason: 'the finished run does not reschedule',
        );
      },
    );

    test(
      '15. a late preference load for a previous account cannot turn tracking on',
      () async {
        storeChoice('user-a', true);
        remote.gate = Completer<void>();
        final Future<void> a = coordinator.handleUser('user-a');
        await settle();
        uid = 'user-b';
        remote.gate!.complete();
        remote.gate = null;
        await coordinator.handleUser('user-b');
        await a;
        await settle();
        expect(tracking.uid, 'user-b');
        expect(tracking.isEnabled, isFalse);
        expect(native.enabled, isFalse);
        expect(device.captureCalls, 0);
        expect(active(), isEmpty);
      },
    );

    test(
      '11/13. each account uses its own choice; nothing leaks across',
      () async {
        storeChoice('user-a', true);
        await coordinator.handleUser('user-a');
        expect(cloud.logs.keys.single, startsWith('user-a/'));

        uid = 'user-b';
        await coordinator.handleUser('user-b');
        expect(tracking.isEnabled, isFalse);
        expect(native.uid, 'user-b');
        expect(native.enabled, isFalse);
        expect(service.today.value, isNull);
        expect(active(), isEmpty);
        expect(background.cancelled, 1);
        expect(cloud.logs.keys.where((k) => k.startsWith('user-b/')), isEmpty);
      },
    );

    test('12. sign-out stops everything', () async {
      storeChoice('user-a', true);
      await coordinator.handleUser('user-a');
      uid = null;
      await coordinator.handleUser(null);
      expect(active(), isEmpty);
      expect(native.enabled, isFalse);
      expect(background.cancelled, 1);
    });
  });

  group('data', () {
    test(
      '17. ON without Usage Access waits; nothing is captured or zeroed',
      () async {
        storeChoice('user-a', true);
        device.permissions = const ActivityPermissionSnapshot(
          usageAccessGranted: false,
          activityPermissionGranted: true,
          notificationPermissionGranted: true,
          backgroundSyncEnabled: true,
        );
        await coordinator.handleUser('user-a');
        expect(service.syncState.value, ActivitySyncState.permissionRequired);
        expect(device.captureCalls, 0);
        expect(cloud.writes, 0);
      },
    );

    test('18. previously saved activity stays visible while OFF', () async {
      cloud.logs['user-a/2026_10_14'] = DailyActivityLog(
        date: DateTime(2026, 10, 14),
        appUsageMinutes: 77,
      );
      await coordinator.handleUser('user-a');
      await service.syncNow(force: true);
      await settle();
      expect(service.today.value!.log.appUsageMinutes, 77);
      expect(cloud.logs.length, 1);
      expect(cloud.writes, 0);
    });

    test(
      '20. switching ON measures from that moment only (no backfill)',
      () async {
        now = DateTime(2026, 10, 14, 14, 0);
        await coordinator.handleUser('user-a');
        await tracking.setEnabled(true);
        await settle();
        advance(const Duration(minutes: 5));
        active().single.fire();
        await settle();
        expect(device.capturedDays.single, DateTime(2026, 10, 14, 14, 0));
        final DailyActivityLog log = service.today.value!.log;
        expect(log.trackingComplete, isFalse);
        expect(log.trackedMinutes, 5);

        // Off 15:00-18:00, then on again: only the two tracked periods.
        advance(const Duration(minutes: 55));
        await tracking.setEnabled(false);
        advance(const Duration(hours: 3));
        await tracking.setEnabled(true);
        await settle();
        device.capturedDays.clear();
        advance(const Duration(minutes: 5));
        active().single.fire();
        await settle();
        expect(device.capturedDays, <DateTime>[
          DateTime(2026, 10, 14, 14, 0),
          DateTime(2026, 10, 14, 18, 0),
        ]);
        expect(service.today.value!.log.trackedMinutes, 65);
        expect(service.today.value!.log.isPartiallyTracked, isTrue);
      },
    );

    test('measurements of separate periods are added, not double counted', () {
      final ActivityCaptureSnapshot a = ActivityCaptureSnapshot(
        start: DateTime(2026, 10, 14, 9),
        end: DateTime(2026, 10, 14, 10),
        usagePermissionGranted: true,
        activityPermissionGranted: true,
        notificationPermissionGranted: true,
        syncStatus: ActivitySyncState.success,
        appUsageMinutes: 20,
        phoneUnlockCount: 3,
        appUsageEntries: <AppUsageEntry>[
          app('com.whatsapp', 'WhatsApp', const Duration(minutes: 5)),
        ],
      );
      final ActivityCaptureSnapshot b = ActivityCaptureSnapshot(
        start: DateTime(2026, 10, 14, 18),
        end: DateTime(2026, 10, 14, 19),
        usagePermissionGranted: true,
        activityPermissionGranted: true,
        notificationPermissionGranted: true,
        syncStatus: ActivitySyncState.success,
        appUsageMinutes: 15,
        phoneUnlockCount: 2,
        appUsageEntries: <AppUsageEntry>[
          app('com.whatsapp', 'WhatsApp', const Duration(minutes: 7)),
          app('com.android.chrome', 'Chrome', const Duration(minutes: 4)),
        ],
      );
      final ActivityCaptureSnapshot m = ActivitySyncService.mergeCaptures(
        <ActivityCaptureSnapshot>[a, b],
        DateTime(2026, 10, 14),
        DateTime(2026, 10, 15),
      );
      expect(m.appUsageMinutes, 35);
      expect(m.phoneUnlockCount, 5);
      expect(m.screenTimeMinutes, isNull, reason: 'not reported is not zero');
      expect(
        m.appUsageEntries
            .firstWhere((e) => e.packageName == 'com.whatsapp')
            .foregroundDuration,
        const Duration(minutes: 12),
      );
    });

    test('19. a partly tracked past day is not read as low or zero usage', () {
      final DateTime today = DateTime(2026, 10, 15, 18);
      HistoryData history(bool? complete) => HistoryData(
        today: today,
        activityLogs: <DailyActivityLog>[
          for (int d = 1; d <= 3; d++)
            DailyActivityLog(
              date: DateTime(2026, 10, 15 - d),
              appUsageMinutes: d == 1 ? 30 : 300,
              screenTimeMinutes: d == 1 ? 40 : 320,
              trackingComplete: d == 1 ? complete : true,
            ),
        ],
        appUsageByDay: const <String, List<AppUsageEntry>>{},
        scores: const <SavedDailyScore>[],
        focusSessions: const <FocusSession>[],
      );
      const BehaviorAnalysisEngine engine = BehaviorAnalysisEngine();
      final BehaviorAnalysis partial = engine.analyze(
        history(false),
        AnalysisPeriod.week,
      );
      expect(partial.metrics['appUsageMinutes']!.count, 2);
      expect(partial.metrics['appUsageMinutes']!.mean, 300);
      expect(partial.dataQuality.excludedRecords['partial_tracking'], 1);

      final BehaviorAnalysis full = engine.analyze(
        history(true),
        AnalysisPeriod.week,
      );
      expect(full.metrics['appUsageMinutes']!.count, 3);
    });

    test('coverage fields round-trip through Firestore maps', () {
      final DailyActivityLog log = DailyActivityLog(
        date: DateTime(2026, 10, 14),
        appUsageMinutes: 10,
        trackedMinutes: 120,
        trackingComplete: false,
        trackedRanges: <(DateTime, DateTime)>[
          (DateTime(2026, 10, 14, 14), DateTime(2026, 10, 14, 16)),
        ],
      );
      final DailyActivityLog back = DailyActivityLog.fromMap(
        log.toMap(),
        documentId: log.documentId,
      );
      expect(back.trackedMinutes, 120);
      expect(back.isPartiallyTracked, isTrue);
      expect(back.trackedRanges!.single.$1, DateTime(2026, 10, 14, 14));
      // Records written before the switch existed count as whole days.
      expect(
        DailyActivityLog.fromMap(<String, dynamic>{
          'appUsageMinutes': 5,
        }, documentId: '2026_10_13').isPartiallyTracked,
        isFalse,
      );
    });
  });

  group('UI', () {
    Widget settings() => Scaffold(
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          ActivityTrackingSection(tracking: tracking, service: service),
          const SizedBox(height: 16),
          TrackingStatusCard(service: service, tracking: tracking),
        ],
      ),
    );

    testWidgets('paused tracking does not imply permissions are granted', (
      tester,
    ) async {
      await tester.runAsync(() => coordinator.handleUser('user-a'));
      service.permissions.value = ActivityPermissionSnapshot.unknown;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: TrackingStatusCard(service: service, tracking: tracking),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Not allowed'), findsNWidgets(2));
      expect(find.text('Enabled'), findsNothing);
      expect(find.text('Allowed, not registered'), findsNothing);
    });

    testWidgets('switch turns tracking on and off; texts match the state', (
      tester,
    ) async {
      await tester.runAsync(() => coordinator.handleUser('user-a'));
      await tester.pumpWidget(
        MaterialApp(theme: ThemeData.light(), home: settings()),
      );
      await tester.pump();
      expect(find.text('Automatic Activity Tracking'), findsOneWidget);
      expect(find.text(ActivityTrackingSection.offDescription), findsOneWidget);
      expect(find.text('Activity tracking is paused.'), findsOneWidget);
      expect(
        find.text('Activity tracking is turned off in Settings.'),
        findsOneWidget,
      );
      expect(find.text('Sync Now'), findsNothing);

      await tester.runAsync(() async {
        await tester.tap(find.byType(Switch));
        await settle();
      });
      await tester.pump();
      expect(tracking.isEnabled, isTrue);
      expect(find.text(ActivityTrackingSection.onDescription), findsOneWidget);
      expect(find.text('Automatic activity tracking is on.'), findsOneWidget);
      expect(
        find.text(
          'Updates approximately every 5 minutes while the app is open.',
        ),
        findsOneWidget,
      );

      // Five minutes later the first measurement arrives.
      await tester.runAsync(() async {
        advance(const Duration(minutes: 5));
        active().single.fire();
        await settle();
      });
      await tester.pump();
      expect(find.text('45m'), findsOneWidget);

      await tester.runAsync(() async {
        await tester.tap(find.byType(Switch));
        await settle();
      });
      await tester.pump();
      expect(tracking.isEnabled, isFalse);
      expect(
        find.text(
          'No new phone usage data is being collected or synchronized.',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('Showing the last recorded values'),
        findsOneWidget,
      );
    });

    testWidgets(
      'ON without Usage Access shows the explanation and settings action',
      (tester) async {
        storeChoice('user-a', true);
        device.permissions = const ActivityPermissionSnapshot(
          usageAccessGranted: false,
          activityPermissionGranted: true,
          notificationPermissionGranted: true,
          backgroundSyncEnabled: true,
        );
        await tester.runAsync(() => coordinator.handleUser('user-a'));
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData.dark().copyWith(
              extensions: <ThemeExtension<dynamic>>[VivoraPalette.dark],
            ),
            home: settings(),
          ),
        );
        await tester.pump();
        expect(
          find.text('Tracking is on but waiting for Usage Access.'),
          findsOneWidget,
        );
        expect(find.text('Open Usage Access settings'), findsOneWidget);
      },
    );

    testWidgets('25/26. responsive in light and dark, on and off', (
      tester,
    ) async {
      // Only fakes are involved, so this runs inside the test's fake time.
      await coordinator.handleUser('user-a');
      await expectResponsive(tester, settings, heights: const <double>[640]);
      await tracking.setEnabled(true);
      await tester.pump();
      await expectResponsive(tester, settings, heights: const <double>[640]);
    });
  });
}
