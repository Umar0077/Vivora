import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vivora/features/activity_monitoring/data/models/app_usage_entry.dart';
import 'package:vivora/features/settings/presentation/settings_screen.dart';
import 'support/layout_harness.dart';
import 'package:vivora/core/services/session.dart';

void main() {
  setUp(() {
    Session.currentUserId = () => null;
    Session.currentEmail = () => null;
  });
  test('historical own-app labels change only for presentation', () {
    final entry = AppUsageEntry.fromMap({
      'packageName': 'com.example.vivora',
      'appName': 'Vivora',
      'foregroundDurationMillis': 120000,
    });
    expect(entry.displayName, 'Personal Digital Twin');
    expect(entry.toMap()['appName'], 'Vivora');
    expect(entry.packageName, 'com.example.vivora');
    expect(entry.foregroundDuration.inMinutes, 2);
    final other = AppUsageEntry.fromMap({
      'packageName': 'org.other.app',
      'appName': 'Another app',
    });
    expect(other.displayName, 'Another app');
  });

  testWidgets('renamed About dialog fits light and dark phone layouts', (
    tester,
  ) async {
    await expectResponsive(
      tester,
      () => const SettingsScreen(),
      widths: const [320, 393, 480],
      scales: const [1.0, 1.75],
      interact: (t) async {
        final about = find.text('About Personal Digital Twin');
        await t.scrollUntilVisible(
          about,
          300,
          scrollable: find.byType(Scrollable).first,
        );
        await t.pumpAndSettle();
        await Scrollable.ensureVisible(t.element(about), alignment: 0.5);
        await t.pumpAndSettle();
        await t.tap(about);
        await t.pumpAndSettle();
        expect(find.byType(AboutDialog), findsOneWidget);
      },
    );
  });
}
