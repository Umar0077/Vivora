import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vivora/features/ai_assistant/application/ai_assistant_controller.dart';
import 'package:vivora/features/ai_assistant/data/ai_provider.dart';
import 'package:vivora/features/ai_assistant/data/ai_usage_limiter.dart';
import 'package:vivora/features/ai_assistant/domain/ai_context_builder.dart';
import 'package:vivora/features/ai_assistant/domain/ai_failure.dart';
import 'package:vivora/features/ai_assistant/domain/ai_prompts.dart';
import 'package:vivora/features/ai_assistant/domain/ai_models.dart';
import 'package:vivora/features/behavior_analysis/domain/behavior_models.dart';
import 'support/ai_fakes.dart';
import 'support/behavior_builders.dart';

const goalJson =
    '{"goalSuggestions":[{"goal":"study","suggestedHours":2.5,"reason":"Build gradually from your recorded average."}]}';

class GatedProvider implements AiProvider {
  @override
  String get modelName => 'test-model';
  final advice = Completer<String>();
  final goals = Completer<String>();
  @override
  Future<String> generate(AiRequest request) =>
      request.format == AiOutputFormat.goals ? goals.future : advice.future;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'weekly projection preserves dates statistics patterns and missingness',
    () {
      final ctx = const AiContextBuilder().build(
        FakeInsightsProvider(richHistory()).analysisFor(AnalysisPeriod.week)!,
        trackingEnabled: false,
      );
      final data = AiPrompts.weeklySummaryData(ctx);
      expect(data['period'], ctx.data['period']);
      expect(data['dataQuality'], ctx.data['dataQuality']);
      expect(
        data['loggedManually']['studyHours']['average'],
        ctx.data['loggedManually']['studyHours']['average'],
      );
      expect(data['loggedManually']['sleepHours']['daysWithData'], 7);
      expect(data['calculated']['score']['average'], 62);
      expect(data['detectedPatterns'], isNotEmpty);
      expect(data.containsKey('previousAdviceFeedback'), isFalse);
      expect(
        AiPrompts.summaryPrompt(SummaryKind.weekly, ctx),
        contains('Do not copy dates'),
      );
    },
  );
  test(
    'compact context preserves evidence, coverage and original fingerprint',
    () {
      final ctx = const AiContextBuilder().build(
        FakeInsightsProvider(richHistory()).analysisFor(AnalysisPeriod.week)!,
        trackingEnabled: false,
      );
      final before = ctx.toJson();
      for (final format in [
        AiOutputFormat.advice,
        AiOutputFormat.goals,
        AiOutputFormat.summary,
        AiOutputFormat.studyPlan,
      ]) {
        final compact = AiPrompts.compactData(ctx, format);
        expect(jsonEncode(compact).length, lessThan(before.length));
        expect(compact['dataQuality'], ctx.data['dataQuality']);
        expect(compact['noDataFor'], ctx.data['noDataFor']);
        expect(compact['goals'], ctx.data['goals']);
        for (final group in [
          'measuredByPhone',
          'trackedByFocusMode',
          'loggedManually',
          'calculated',
        ]) {
          final original = ctx.data[group] as Map?;
          if (original == null) continue;
          for (final id in original.keys) {
            expect(compact[group][id]['average'], original[id]['average']);
            expect(
              compact[group][id]['daysWithData'],
              original[id]['daysWithData'],
            );
            expect(compact[group][id]['unit'], original[id]['unit']);
          }
        }
      }
      expect(ctx.toJson(), before);
    },
  );

  test(
    'goals succeed after recommendations fail and persist independently',
    () async {
      final provider = FakeAiProvider([
        const AiFailure(AiFailureKind.server),
        goalJson,
      ]);
      final store = InMemoryAiStore();
      final c = AiAssistantController(
        insights: FakeInsightsProvider(richHistory()),
        provider: provider,
        store: store,
        currentUserId: () => 'a',
        clock: () => bNow,
        limiter: AiUsageLimiter(minInterval: Duration.zero),
      );
      await c.generateAdvice();
      await c.generateGoals();
      expect(c.adviceError?.kind, AiFailureKind.server);
      expect(c.goalsError, isNull);
      expect(c.goalSuggestions.single.suggestedHours, 2.5);
      expect(store.advice['a']!.goalSuggestions, hasLength(1));
      expect(provider.requests.map((r) => r.format), [
        AiOutputFormat.advice,
        AiOutputFormat.goals,
      ]);
      c.dispose();
    },
  );

  for (final goalsFirst in [true, false]) {
    test(
      'concurrent goals and advice retain both outputs: goalsFirst=$goalsFirst',
      () async {
        final p = GatedProvider();
        final store = InMemoryAiStore();
        final c = AiAssistantController(
          insights: FakeInsightsProvider(richHistory()),
          provider: p,
          store: store,
          currentUserId: () => 'a',
          clock: () => bNow,
          limiter: AiUsageLimiter(minInterval: Duration.zero),
        );
        final advice = c.generateAdvice();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        final goals = c.generateGoals();
        if (goalsFirst) {
          p.goals.complete(goalJson);
          await goals;
          p.advice.complete(adviceJson());
        } else {
          p.advice.complete(adviceJson());
          await advice;
          p.goals.complete(goalJson);
        }
        await Future.wait([advice, goals]);
        expect(c.currentRecommendations, isNotEmpty);
        expect(c.goalSuggestions, hasLength(1));
        expect(store.advice['a']!.goalSuggestions, hasLength(1));
        c.dispose();
      },
    );
  }

  test('account switch discards late goal response', () async {
    final p = GatedProvider();
    final store = InMemoryAiStore();
    var uid = 'a';
    final c = AiAssistantController(
      insights: FakeInsightsProvider(richHistory()),
      provider: p,
      store: store,
      currentUserId: () => uid,
      clock: () => bNow,
      limiter: AiUsageLimiter(minInterval: Duration.zero),
    );
    final pending = c.generateGoals();
    await Future<void>.delayed(Duration.zero);
    uid = 'b';
    p.goals.complete(goalJson);
    await pending;
    expect(c.goalSuggestions, isEmpty);
    expect(store.advice, isEmpty);
    c.dispose();
  });
}
