import 'package:vivora/features/ai_assistant/domain/ai_context_builder.dart';
// Opt-in real API probe; no user records or credentials are written.
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vivora/features/ai_assistant/application/ai_assistant_controller.dart';
import 'package:vivora/features/ai_assistant/data/gemini_ai_provider.dart';
import 'package:vivora/features/ai_assistant/data/ai_usage_limiter.dart';
import 'package:vivora/features/ai_assistant/domain/ai_models.dart';
import '../test/support/ai_fakes.dart';
import '../test/support/behavior_builders.dart';
import 'gemini_live_check.dart' show ObservedClient;

void main() {
  test('verified alternate model full feature requests', () async {
    // ignore: invalid_use_of_visible_for_testing_member
      SharedPreferences.setMockInitialValues({});
    final events = <Map<String, Object?>>[];
    final c = AiAssistantController(
      insights: FakeInsightsProvider(richHistory()),
      provider: GeminiAiProvider(
        model: 'gemini-3.6-flash',
        isSignedIn: () => true,
        clientFactory: () => ObservedClient(events),
      ),
      store: InMemoryAiStore(),
      currentUserId: () => 'alternate-local-sample',
      clock: () => bNow,
      limiter: AiUsageLimiter(minInterval: Duration.zero),
      loadPreferences: (_) async =>
          const StudyPreferences(preferredStudyTime: 'Evening'),
    );
    await c.open();
    final rows = <Map<String, Object?>>[];
    for (final feature in ['weekly_summary', 'study_plan', 'recommendations']) {
      final timer = Stopwatch()..start();
      if (feature == 'weekly_summary') {
        await c.generateSummary(SummaryKind.weekly);
      }
      if (feature == 'study_plan') {
        await c.generateStudyPlan();
      }
      if (feature == 'recommendations') {
        await c.generateAdvice();
      }
      final error = feature == 'weekly_summary'
          ? c.summaryError(SummaryKind.weekly)
          : feature == 'study_plan'
          ? c.planError
          : c.adviceError;
      rows.add({
        'feature': feature,
        'elapsedMs': timer.elapsedMilliseconds,
        'failure': error?.kind.name,
        'passed': error == null,
        'httpAttempts': List.of(events),
      });
      events.clear();
      await File(
        'build/gemini-alternate-results.json',
      ).writeAsString(jsonEncode(rows));
    }
    c.dispose();
    expect(
      rows.every((r) => r['passed'] == true),
      true,
      reason: 'See credential-free alternate results',
    );
  }, timeout: const Timeout(Duration(minutes: 5)));
}
