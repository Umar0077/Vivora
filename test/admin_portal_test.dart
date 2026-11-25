import 'dart:io';
import 'dart:ui' as ui;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vivora/core/theme/app_theme.dart';
import 'package:vivora/features/admin/data/admin_models.dart';
import 'package:vivora/features/admin/data/admin_repository.dart';
import 'package:vivora/features/admin/data/admin_session.dart';
import 'package:vivora/features/admin/presentation/admin_login_screen.dart';
import 'package:vivora/features/admin/presentation/admin_portal_screen.dart';
import 'package:vivora/features/admin/presentation/admin_user_detail.dart';
import 'package:vivora/features/admin/presentation/admin_widgets.dart';
import 'package:vivora/features/insights/data/history_data.dart';
import 'package:vivora/features/productivity_scoring/data/models/productivity_models.dart';
import 'package:vivora/features/first_time_setup/data/models/user_profile_model.dart';

// Synthetic test fixtures only. These tests do not claim live Firebase access.
class FixtureRepository implements AdminRepository {
  int pageCalls = 0, historyCalls = 0, aiCalls = 0;
  bool fail = false, empty = false;
  final user = AdminUser(
    'fixture',
    {
      'fullName': 'Sample Student — automated test',
      'email': 'student@example.test',
      'createdAt': Timestamp.fromDate(DateTime(2026, 11, 20)),
      'latestProductivityScore': 72.0,
      'goals': {
        'targetSleepHours': '8 hours',
        'targetFocusHours': '2 hours',
        'targetStudyHours': '3 hours',
      },
    },
    tracking: true,
    lastActivity: DateTime(2026, 11, 25),
    studyHours: 3,
    focusSeconds: 1500,
    focusCount: 1,
    scoreSum: 144,
    scoreCount: 2,
  );
  @override
  Future<int> userCount() async => empty ? 0 : 1;
  @override
  Future<List<AdminUser>> recentUsers() async => empty ? [] : [user];
  @override
  Future<AdminPage> page([
    DocumentSnapshot<Map<String, dynamic>>? after,
  ]) async {
    pageCalls++;
    if (fail) {
      throw FirebaseException(
        plugin: 'cloud_firestore',
        code: 'permission-denied',
      );
    }
    return AdminPage(empty ? [] : [user], null, false);
  }

  @override
  Future<HistoryData> history(AdminUser user) async {
    historyCalls++;
    final now = DateTime.now();
    return HistoryData(
      today: now,
      activityLogs: [],
      appUsageByDay: {},
      focusSessions: [],
      goals: UserGoals(
        targetSleepHours: '8 hours',
        targetFocusHours: '2 hours',
      ),
      scores: [
        SavedDailyScore.fromMap({
          'date': Timestamp.fromDate(now),
          'actualSleepHours': 7.0,
          'actualStudyHours': 3.0,
          'actualFocusHours': 1.0,
          'overallScore': 72.0,
          'scoreCoverage': 0.5,
          'suggestions': <String>[],
          'missingComponents': <String>[],
        }),
      ],
    );
  }

  @override
  Future<List<Map<String, dynamic>>> savedAi(String uid) async {
    aiCalls++;
    return [
      {
        '_type': 'Saved summary',
        'headline': 'Synthetic fixture summary',
        'overview': 'Only used to verify layout.',
        'generatedAt': DateTime.now().toIso8601String(),
        'privateToken': 'MUST_NOT_RENDER',
      },
    ];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'admin authorization requires exact role, true active flag and no credentials',
    () {
      expect(
        isActiveAdministrator({'role': 'admin', 'isActive': true}),
        isTrue,
      );
      for (final value in [
        null,
        <String, dynamic>{},
        {'role': 'admin', 'isActive': false},
        {'role': 'admin', 'isActive': 'true'},
        {'role': 'student', 'isActive': true},
        {'role': 'admin', 'isActive': true, 'password': 'fixture'},
      ]) {
        expect(isActiveAdministrator(value), isFalse);
      }
    },
  );
  test('aggregates weight scores by observed daily record counts', () {
    final totals = AdminTotals([
      const AdminUser(
        'a',
        {},
        scoreSum: 160,
        scoreCount: 2,
        studyHours: 4,
        focusSeconds: 3600,
        focusCount: 2,
      ),
      const AdminUser('b', {}, scoreSum: 20, scoreCount: 1, tracking: true),
      const AdminUser('c', {}, loadError: 'missing'),
    ], DateTime(2026, 11, 25));
    expect(totals.averageScore, 60);
    expect(totals.studyHours, 4);
    expect(totals.focusSeconds, 3600);
    expect(totals.tracking, 1);
    expect(totals.incomplete, 1);
  });
  test(
    'missing scores stay unknown and active definition excludes future dates',
    () {
      final now = DateTime(2026, 11, 25);
      expect(AdminTotals([], now).averageScore, isNull);
      expect(
        AdminUser(
          'a',
          {},
          lastActivity: now.subtract(const Duration(days: 7)),
        ).activeAt(now),
        isTrue,
      );
      expect(
        AdminUser(
          'a',
          {},
          lastActivity: now.add(const Duration(seconds: 1)),
        ).activeAt(now),
        isFalse,
      );
      expect(const AdminUser('a', {}).activeAt(now), isFalse);
      for (final v in [double.nan, double.infinity, -1, '100']) {
        expect(adminNumber(v), isNull);
      }
    },
  );
  test('error messages do not expose provider messages or credentials', () {
    expect(
      adminError(
        FirebaseAuthException(code: 'invalid-credential', message: 'SECRET'),
      ),
      isNot(contains('SECRET')),
    );
    expect(adminError(Exception('SECRET')), isNot(contains('SECRET')));
  });

  Future<void> pump(
    WidgetTester tester,
    Widget child, {
    Size size = const Size(390, 844),
    bool dark = false,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: dark ? AppTheme.darkTheme : AppTheme.lightTheme,
        home: Scaffold(body: child),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final size in [
    const Size(320, 640),
    const Size(390, 844),
    const Size(430, 932),
    const Size(1200, 900),
  ]) {
    for (final dark in [false, true]) {
      testWidgets('login and dashboard fit ${size.width} dark=$dark', (
        tester,
      ) async {
        await pump(tester, const AdminLoginScreen(), size: size, dark: dark);
        expect(tester.takeException(), isNull);
        final repo = FixtureRepository();
        await pump(
          tester,
          AdminDirectory(
            repository: repo,
            dashboard: true,
            heading: 'Dashboard',
            onSelect: (_) {},
          ),
          size: size,
          dark: dark,
        );
        expect(find.text('Registered user profiles'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }
  testWidgets('login validates fields before calling authentication', (
    tester,
  ) async {
    var calls = 0;
    await pump(
      tester,
      AdminLoginScreen(
        authenticate: (a, b) async {
          calls++;
        },
      ),
    );
    await tester.ensureVisible(find.text('Login to Admin Portal'));
    await tester.tap(find.text('Login to Admin Portal'));
    await tester.pumpAndSettle();
    expect(find.text('Enter a valid email address.'), findsOneWidget);
    expect(find.text('Enter your password.'), findsOneWidget);
    expect(calls, 0);
  });
  testWidgets('normal or inactive account is denied and password is cleared', (
    tester,
  ) async {
    await pump(
      tester,
      AdminLoginScreen(
        authenticate: (a, b) async {
          throw const AdminAccessException();
        },
      ),
    );
    await tester.enterText(
      find.byType(TextFormField).at(0),
      'student@example.test',
    );
    await tester.enterText(
      find.byType(TextFormField).at(1),
      'synthetic-password',
    );
    await tester.ensureVisible(find.text('Login to Admin Portal'));
    await tester.tap(find.text('Login to Admin Portal'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Administrator access is not enabled'),
      findsOneWidget,
    );
    expect(find.text('synthetic-password'), findsNothing);
  });
  testWidgets('empty and denied directory states are honest', (tester) async {
    final repo = FixtureRepository()..empty = true;
    await pump(
      tester,
      AdminDirectory(
        repository: repo,
        dashboard: false,
        heading: 'All Users',
        onSelect: (_) {},
      ),
    );
    expect(
      find.text('No matching profiles in the loaded results.'),
      findsOneWidget,
    );
    repo.fail = true;
    await tester.tap(find.text('Refresh data'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Access denied.'), findsOneWidget);
  });
  testWidgets('name/email search is scoped to loaded data', (tester) async {
    final repo = FixtureRepository();
    await pump(
      tester,
      AdminDirectory(
        repository: repo,
        dashboard: false,
        heading: 'All Users',
        onSelect: (_) {},
      ),
    );
    await tester.enterText(find.byType(TextField), 'absent');
    await tester.pumpAndSettle();
    expect(
      find.text('No matching profiles in the loaded results.'),
      findsOneWidget,
    );
    await tester.enterText(find.byType(TextField), 'student@example');
    await tester.pumpAndSettle();
    expect(find.text(repo.user.name), findsOneWidget);
  });
  testWidgets('details are lazy and saved AI does not expose unknown fields', (
    tester,
  ) async {
    final repo = FixtureRepository();
    await pump(
      tester,
      AdminUserDetail(user: repo.user, repository: repo, onBack: () {}),
    );
    expect(repo.historyCalls, 0);
    expect(repo.aiCalls, 0);
    await tester.tap(find.text('AI Insights'));
    await tester.pumpAndSettle();
    expect(repo.aiCalls, 1);
    expect(repo.historyCalls, 0);
    expect(find.text('MUST_NOT_RENDER'), findsNothing);
    await tester.tap(find.text('Productivity'));
    await tester.pumpAndSettle();
    expect(repo.historyCalls, 1);
    expect(tester.takeException(), isNull);
  });
  testWidgets('details fit narrow screen and large text for every section', (
    tester,
  ) async {
    final repo = FixtureRepository();
    for (var i = 0; i < 6; i++) {
      await pump(
        tester,
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.4)),
          child: AdminUserDetail(
            key: ValueKey(i),
            user: repo.user,
            repository: repo,
            initialSection: i,
            onBack: () {},
          ),
        ),
        size: const Size(320, 700),
      );
      expect(tester.takeException(), isNull);
    }
  });
  testWidgets('metric cards accept long values without overflow', (
    tester,
  ) async {
    await pump(
      tester,
      const SingleChildScrollView(
        child: AdminMetricGrid([
          ('Recorded duration', '12345678.9 h', Icons.timer),
          ('Unknown', 'Not recorded', Icons.info),
        ]),
      ),
      size: const Size(320, 640),
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets('capture clearly labeled automated layout previews', (
    tester,
  ) async {
    await tester.runAsync(() async {
      for (final font in {
        'PlusJakartaSans': 'assets/fonts/PlusJakartaSans.ttf',
        'MaterialIcons': 'fonts/MaterialIcons-Regular.otf',
      }.entries) {
        final loader = FontLoader(font.key)
          ..addFont(rootBundle.load(font.value));
        await loader.load();
      }
    });
    final key = GlobalKey();
    final repo = FixtureRepository();
    for (final dark in [false, true]) {
      await pump(
        tester,
        RepaintBoundary(
          key: key,
          child: Material(
            color: dark
                ? AppTheme.darkTheme.scaffoldBackgroundColor
                : AppTheme.lightTheme.scaffoldBackgroundColor,
            child: Column(
              children: [
                const Material(
                  child: Padding(
                    padding: EdgeInsets.all(8),
                    child: Text('AUTOMATED UI PREVIEW · SYNTHETIC DATA'),
                  ),
                ),
                Expanded(
                  child: AdminDirectory(
                    key: ValueKey(dark),
                    repository: repo,
                    dashboard: true,
                    heading: 'Dashboard',
                    onSelect: (_) {},
                  ),
                ),
              ],
            ),
          ),
        ),
        size: const Size(1100, 1000),
        dark: dark,
      );
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final dir = Directory('build/admin-screenshots')
          ..createSync(recursive: true);
        File(
          '${dir.path}/dashboard-${dark ? 'dark' : 'light'}-fixture.png',
        ).writeAsBytesSync(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
  });
}
