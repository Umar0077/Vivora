import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vivora/features/ai_assistant/application/ai_assistant_controller.dart';
import 'package:vivora/features/ai_assistant/data/ai_provider.dart';
import 'package:vivora/features/ai_assistant/data/ai_usage_limiter.dart';
import 'package:vivora/features/ai_assistant/data/gemini_ai_provider.dart';
import 'package:vivora/features/ai_assistant/domain/ai_config.dart';
import 'package:vivora/features/ai_assistant/domain/ai_context_builder.dart';
import 'package:vivora/features/ai_assistant/domain/ai_failure.dart';
import 'package:vivora/features/ai_assistant/domain/ai_models.dart';
import 'package:vivora/features/ai_assistant/domain/ai_response_validator.dart';
import 'package:vivora/features/behavior_analysis/domain/behavior_models.dart';

import 'support/ai_fakes.dart';
import 'support/behavior_builders.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));
  const validator = AiResponseValidator();
  AiContext context() => const AiContextBuilder().build(
    FakeInsightsProvider(richHistory()).analysisFor(AnalysisPeriod.week)!,
  );

  test('configuration rejects disabled service and malformed model ids', () {
    expect(() => AiConfig.validate(AiConfig.model), returnsNormally);
    expect(
      () => AiConfig.validate(AiConfig.model, isEnabled: false),
      throwsA(
        isA<AiFailure>().having(
          (e) => e.kind,
          'kind',
          AiFailureKind.notConfigured,
        ),
      ),
    );
    for (final model in ['', 'gpt-4', 'gemini-x?key=secret', ' gemini-flash']) {
      expect(
        () => AiConfig.validate(model),
        throwsA(
          isA<AiFailure>().having(
            (e) => e.kind,
            'kind',
            AiFailureKind.modelUnavailable,
          ),
        ),
      );
    }
  });

  test('provider with placeholder key reports not configured', () async {
    await expectLater(
      GeminiAiProvider(
        apiKey: 'PASTE_YOUR_GEMINI_API_KEY_HERE',
      ).generate(const AiRequest(format: AiOutputFormat.text, prompt: 'test')),
      throwsA(
        isA<AiFailure>().having(
          (e) => e.kind,
          'kind',
          AiFailureKind.notConfigured,
        ),
      ),
    );
  });

  test('direct API authentication and temporary server failures differ', () {
    expect(
      mapAiHttpError(403, 'key invalid').kind,
      AiFailureKind.notConfigured,
    );
    expect(mapAiHttpError(503, 'overloaded').kind, AiFailureKind.server);
  });

  test(
    'concurrent reservations cannot overspend the local daily budget',
    () async {
      final limiter = AiUsageLimiter(dailyLimit: 1, minInterval: Duration.zero);
      final results = await Future.wait(
        List.generate(10, (_) async {
          try {
            await limiter.acquire('a');
            return true;
          } on AiFailure {
            return false;
          }
        }),
      );
      expect(results.where((v) => v), hasLength(1));
      expect(await limiter.remaining('a'), 0);
    },
  );

  test('malformed nested arrays do not throw cast errors', () {
    final Map<String, dynamic> advice = jsonDecode(adviceJson());
    advice['recommendations'][0]['sourceMetrics'] = 'studyHours';
    expect(
      validator
          .advice(jsonEncode(advice), context(), now: bNow)
          .recommendations,
      hasLength(1),
    );
    final Map<String, dynamic> summary = jsonDecode(summaryJson());
    summary['highlights'] = 42;
    expect(
      () => validator.summary(
        jsonEncode(summary),
        SummaryKind.weekly,
        context(),
        now: bNow,
      ),
      throwsA(
        isA<AiFailure>().having(
          (e) => e.detail,
          'safe category',
          'weekly_structure_highlights',
        ),
      ),
    );
  });

  test('summary numerical measurements are rejected; facts come from app', () {
    for (final text in ['Your score was 99.', 'You studied twenty hours.']) {
      expect(
        () => validator.summary(
          summaryJson(headline: text),
          SummaryKind.weekly,
          context(),
          now: bNow,
        ),
        throwsA(isA<AiFailure>()),
      );
    }
    expect(
      validator
          .summary(summaryJson(), SummaryKind.weekly, context(), now: bNow)
          .nextSteps,
      isNotEmpty,
    );
  });

  test('study sessions must add up to the daily target', () {
    expect(
      () => validator.studyPlan(planJson(sessions: 4), context(), now: bNow),
      throwsA(isA<AiFailure>()),
    );
    final plan = validator.studyPlan(planJson(), context(), now: bNow);
    expect(plan.dailyStudyMinutes, plan.sessionsPerDay * plan.sessionMinutes);
    expect(StudyPlan.fromMap(plan.accept(bNow).toMap())!.acceptedAt, bNow);
    expect(
      StudyPlan.fromMap(<String, dynamic>{
        'generatedAt': bNow.toIso8601String(),
        'dailyStudyMinutes': 'bad',
      }),
      isNull,
    );
  });

  group('controller with mocked provider; no live Gemini calls', () {
    late FakeAiProvider provider;
    late FakeInsightsProvider insights;
    late InMemoryAiStore store;
    late String? uid;
    AiAssistantController make({bool tracking = false}) =>
        AiAssistantController(
          insights: insights,
          provider: provider,
          store: store,
          currentUserId: () => uid,
          trackingEnabled: () => tracking,
          limiter: AiUsageLimiter(minInterval: Duration.zero),
          clock: () => bNow,
        );
    setUp(() {
      provider = FakeAiProvider();
      insights = FakeInsightsProvider(richHistory());
      store = InMemoryAiStore();
      uid = 'alice';
    });

    test(
      'diagnostic is minimal, validated, deduplicated and not persisted',
      () async {
        provider.responses.add('VIVORA_OK');
        provider.gate = Completer<void>();
        final c = make();
        final first = c.testConnection();
        await c.testConnection();
        provider.gate!.complete();
        await first;
        expect(c.diagnosticSucceeded, isTrue);
        expect(provider.requests, hasLength(1));
        expect(provider.requests.single.prompt, isNot(contains('DATA')));
        expect(provider.requests.single.history, isEmpty);
        expect(provider.requests.single.maxOutputTokens, 32);
        expect(insights.ensureCalls, 0);
        expect(store.chats, isEmpty);
        c.dispose();
      },
    );

    test(
      'diagnostic validates reply and retains exact failure category',
      () async {
        provider.responses.addAll([
          'Hello',
          const AiFailure(AiFailureKind.appCheck),
        ]);
        final c = make();
        await c.testConnection();
        expect(c.diagnosticError!.kind, AiFailureKind.malformed);
        await c.testConnection();
        expect(c.diagnosticError!.kind, AiFailureKind.appCheck);
        expect(c.diagnosticSucceeded, isFalse);
        uid = null;
        await c.testConnection();
        expect(c.diagnosticError!.kind, AiFailureKind.signedOut);
        expect(provider.requests, hasLength(2));
        c.dispose();
      },
    );

    test(
      'switch before async context completes never sends previous records',
      () async {
        final c = make();
        final pending = c.generateAdvice();
        uid = 'bob';
        await pending;
        expect(provider.requests, isEmpty);
        expect(store.recs, isEmpty);
        c.dispose();
      },
    );

    test('disposing during request discards reply without notifying', () async {
      provider.responses.add('VIVORA_OK');
      provider.gate = Completer<void>();
      final c = make();
      final pending = c.testConnection();
      await Future<void>.delayed(Duration.zero);
      c.dispose();
      provider.gate!.complete();
      await pending;
      expect(c.diagnosticSucceeded, isFalse);
    });

    test(
      'tracking OFF is explicit, no sync or automatic generation occurs',
      () async {
        provider.responses.add(adviceJson());
        final c = make();
        await c.open();
        expect(provider.requests, isEmpty);
        await c.generateAdvice();
        expect(
          provider.requests.single.prompt,
          contains('"automaticTracking":"off"'),
        );
        expect(provider.requests.single.prompt, contains('never zero'));
        insights.setHistory(richHistory(study: 3));
        expect(c.adviceIsStale, isTrue);
        expect(provider.requests, hasLength(1));
        c.dispose();
      },
    );

    test('accepted plans persist only on explicit action', () async {
      provider.responses.add(planJson());
      final c = make();
      await c.generateStudyPlan();
      final plan = c.studyPlan!;
      expect(store.plans['alice']!.acceptedAt, isNull);
      await c.acceptStudyPlan(plan);
      expect(store.plans['alice']!.acceptedAt, bNow);
      uid = 'bob';
      await expectLater(c.acceptStudyPlan(plan), throwsA(isA<AiFailure>()));
      expect(store.plans['bob'], isNull);
      c.dispose();
    });
  });
}
