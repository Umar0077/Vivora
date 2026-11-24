import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vivora/features/ai_assistant/application/ai_assistant_controller.dart';
import 'package:vivora/features/ai_assistant/data/ai_provider.dart';
import 'package:vivora/features/ai_assistant/data/ai_usage_limiter.dart';
import 'package:vivora/features/ai_assistant/data/gemini_ai_provider.dart';
import 'package:vivora/features/ai_assistant/domain/ai_context_builder.dart';
import 'package:vivora/features/ai_assistant/domain/ai_failure.dart';
import 'package:vivora/features/ai_assistant/domain/ai_models.dart';
import 'package:vivora/features/ai_assistant/domain/ai_response_validator.dart';
import 'package:vivora/features/behavior_analysis/domain/behavior_analysis_engine.dart';
import 'package:vivora/features/behavior_analysis/domain/behavior_models.dart';
import 'package:vivora/features/insights/data/history_data.dart';
import 'package:vivora/features/insights/services/recommendation_service.dart';
import 'package:vivora/features/reminders/reminder_service.dart';

import 'support/ai_fakes.dart';
import 'support/behavior_builders.dart';

const BehaviorAnalysisEngine _engine = BehaviorAnalysisEngine();
const AiContextBuilder _builder = AiContextBuilder();
const AiResponseValidator _validator = AiResponseValidator();

BehaviorAnalysis _week(HistoryData h) =>
    _engine.analyze(h, AnalysisPeriod.week, calculatedAt: bNow);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('AiContextBuilder (Module 3 → Module 6)', () {
    test('groups values by source with units and evidence', () {
      final AiContext ctx = _builder.build(_week(richHistory()));
      final Map<String, dynamic> d = ctx.data;
      expect(d['period']['name'], 'week');
      expect(d['period']['lastDay'], '2026-10-15');
      expect(d['measuredByPhone']['appUsageMinutes']['unit'], 'minutes');
      expect(d['measuredByPhone']['appUsageMinutes']['average'], 300);
      expect(d['loggedManually']['deepFocusHours']['average'], 1.5);
      expect(d['loggedManually']['studyHours']['unit'], 'hours');
      expect(d['trackedByFocusMode'], contains('focusSessionMinutes'));
      expect(d['calculated']['score']['average'], 62);
      expect(d['dataQuality']['daysWithDailyLog'], 7);
      expect(d['dataQuality']['overallEvidence'], 'strong');
      expect(ctx.hasData, isTrue);
      expect(
        ctx.metricsWithData,
        containsAll(<String>['studyHours', 'appUsageMinutes']),
      );
    });

    test('lists missing metrics instead of inventing them', () {
      final AiContext ctx = _builder.build(_week(richHistory()));
      expect(ctx.data['noDataFor'], contains('sensorActiveMinutes'));
      expect(ctx.metricsWithData, isNot(contains('sensorActiveMinutes')));
    });

    test('goals carry targets, type and achievement', () {
      final AiContext ctx = _builder.build(_week(richHistory()));
      expect(ctx.goalTargets[SuggestedGoal.focus], 2);
      expect(ctx.goalTargets[SuggestedGoal.screenLimit], 3);
      expect(ctx.observedAverageHours[SuggestedGoal.focus], closeTo(1.5, 1e-9));
      expect(
        ctx.observedAverageHours[SuggestedGoal.screenLimit],
        closeTo(5, 1e-9),
      );
      final List<dynamic> goals = ctx.data['goals'] as List<dynamic>;
      expect(goals.map((g) => g['goal']), contains('focus'));
    });

    test('contains no personal identifiers', () {
      final String json = _builder
          .build(
            _week(richHistory()),
            preferences: const StudyPreferences(preferredStudyTime: 'Evening'),
          )
          .toJson();
      for (final String banned in <String>[
        'email',
        '@',
        'fullName',
        'uid',
        'institution',
      ]) {
        expect(json.contains(banned), isFalse, reason: banned);
      }
      expect(json, contains('Evening'));
    });

    test('no data → hasData false', () {
      final AiContext ctx = _builder.build(_week(bHistory()));
      expect(ctx.hasData, isFalse);
      expect(ctx.data['dataQuality']['overallEvidence'], 'none');
    });

    test('fingerprint changes with data but not with feedback', () {
      final BehaviorAnalysis a = _week(richHistory());
      final AiContext plain = _builder.build(a);
      final AiContext withFeedback = _builder.build(
        a,
        feedback: <AiRecommendation>[
          _rec('x', status: RecommendationStatus.dismissed),
        ],
      );
      expect(withFeedback.fingerprint, plain.fingerprint);
      expect(withFeedback.data['previousAdviceFeedback']['dismissed'], <String>[
        'x',
      ]);
      expect(
        _builder.build(_week(richHistory(study: 3))).fingerprint,
        isNot(plain.fingerprint),
      );
      expect(_builder.build(a).fingerprint, plain.fingerprint);
    });
  });

  group('AiResponseValidator', () {
    final AiContext ctx = _builder.build(_week(richHistory()));

    test('goal evidence preserves recorded mean through persistence', () {
      final context = _builder.build(_week(richHistory()));
      context.observedAverageHours[SuggestedGoal.study] = 2.75;
      context.goalTargets.remove(SuggestedGoal.study);
      final goal = _validator.goalSuggestion({
        'goal': 'study',
        'suggestedHours': 3,
        'reason': 'Increase gradually from the recorded study average.',
      }, context)!;
      expect(goal.observedAverageHours, 2.75);
      expect(GoalSuggestion.fromMap(goal.toMap())?.observedAverageHours, 2.75);
    });

    test('parses valid advice, sorted by priority', () {
      final AdviceBatch b = _validator.advice(adviceJson(), ctx, now: bNow);
      expect(b.recommendations, hasLength(2));
      expect(b.recommendations.first.priority, RecommendationPriority.high);
      expect(b.recommendations.first.category, RecommendationCategory.focus);
      expect(b.recommendations.first.sourceMetrics, <String>['deepFocusHours']);
      expect(b.recommendations.map((r) => r.id).toSet(), hasLength(2));
      expect(b.fingerprint, ctx.fingerprint);
    });

    test('accepts JSON wrapped in a Markdown fence', () {
      final AdviceBatch b = _validator.advice(
        '```json\n${adviceJson()}\n```',
        ctx,
        now: bNow,
      );
      expect(b.recommendations, hasLength(2));
    });

    test('rejects malformed, empty and non-object responses', () {
      for (final String? raw in <String?>[
        null,
        '',
        'not json',
        '[1,2]',
        '{"x":1}',
      ]) {
        expect(
          () => _validator.advice(raw, ctx, now: bNow),
          throwsA(
            isA<AiFailure>().having(
              (f) => f.kind,
              'kind',
              AiFailureKind.malformed,
            ),
          ),
          reason: '$raw',
        );
      }
    });

    test(
      'drops unsupported categories, missing fields and data-less advice',
      () {
        Map<String, Object?> base(Map<String, Object?> o) => <String, Object?>{
          'title': 'T',
          'description': 'D',
          'category': 'focus',
          'priority': 'low',
          'reason': 'R',
          'sourceMetrics': <String>['studyHours'],
          'suggestion': 'S',
          ...o,
        };
        final AdviceBatch b = _validator.advice(
          adviceJson(
            recommendations: <Map<String, Object?>>[
              base(<String, Object?>{'title': 'Gaming', 'category': 'gaming'}),
              base(<String, Object?>{'title': 'No reason', 'reason': null}),
              base(<String, Object?>{
                'title': 'Walking',
                'sourceMetrics': <String>['sensorActiveMinutes'],
              }),
              base(<String, Object?>{
                'title': 'Invented metric',
                'sourceMetrics': <String>['heartRate'],
              }),
              base(<String, Object?>{'title': 'Kept', 'priority': 'urgent'}),
            ],
          ),
          ctx,
          now: bNow,
        );
        expect(b.recommendations.map((r) => r.title), <String>['Kept']);
        // Unknown priority falls back to medium.
        expect(
          b.recommendations.single.priority,
          RecommendationPriority.medium,
        );
      },
    );

    test('shortens long text and drops absurdly long fields', () {
      final String long = List<String>.filled(100, 'word').join(' ');
      final AdviceBatch b = _validator.advice(
        adviceJson(
          recommendations: <Map<String, Object?>>[
            <String, Object?>{
              'title': 'Long description',
              'description': long,
              'category': 'study',
              'priority': 'low',
              'reason': 'R',
              'sourceMetrics': <String>['studyHours'],
              'suggestion': 'S',
            },
            <String, Object?>{
              'title': 'x' * 2000,
              'description': 'D',
              'category': 'study',
              'priority': 'low',
              'reason': 'R',
              'sourceMetrics': <String>['studyHours'],
              'suggestion': 'S',
            },
          ],
        ),
        ctx,
        now: bNow,
      );
      expect(b.recommendations, hasLength(1));
      expect(
        b.recommendations.single.description.length,
        lessThanOrEqualTo(320),
      );
      expect(b.recommendations.single.description, endsWith('…'));
    });

    test('removes duplicates and suppressed (dismissed) titles; caps at 5', () {
      Map<String, Object?> r(String t) => <String, Object?>{
        'title': t,
        'description': 'D',
        'category': 'study',
        'priority': 'medium',
        'reason': 'R',
        'sourceMetrics': <String>['studyHours'],
        'suggestion': 'S',
      };
      final AdviceBatch b = _validator.advice(
        adviceJson(
          recommendations: <Map<String, Object?>>[
            r('Study earlier'),
            r('study earlier!'),
            r('Dismissed one'),
            for (int i = 0; i < 8; i++) r('Tip $i'),
          ],
        ),
        ctx,
        now: bNow,
        suppressedTitles: <String>['Dismissed One'],
      );
      expect(b.recommendations, hasLength(5));
      expect(b.recommendations.first.title, 'Study earlier');
      expect(
        b.recommendations.map((x) => x.title),
        isNot(contains('Dismissed one')),
      );
    });

    group('goal suggestions', () {
      GoalSuggestion? g(String goal, Object hours) =>
          _validator.goalSuggestion(<String, dynamic>{
            'goal': goal,
            'suggestedHours': hours,
            'reason': 'Because',
          }, ctx);

      test('accepts a gradual change grounded in data', () {
        final GoalSuggestion s = g('focus', 2.4)!;
        expect(s.suggestedHours, 2.5); // rounded to 30 minutes
        expect(s.currentTargetHours, 2);
        expect(s.observedAverageHours, 1.5);
        expect(g('screenLimit', 4)!.suggestedHours, 4);
      });

      test('rejects unrealistic, unchanged, unknown or data-less goals', () {
        expect(
          g('focus', 4),
          isNull,
          reason: 'jump of 2.5h over recorded 1.5h',
        );
        expect(g('study', 3), isNull, reason: 'same as current goal');
        expect(g('screenLimit', 2), isNull, reason: 'cut below 70% of 5h use');
        expect(g('sleep', 12), isNull, reason: 'outside 6-10h');
        expect(g('reading', 1), isNull);
        expect(g('focus', 'lots'), isNull);
        final AiContext empty = _builder.build(_week(bHistory(goals: bGoals)));
        expect(
          _validator.goalSuggestion(<String, dynamic>{
            'goal': 'focus',
            'suggestedHours': 2.5,
            'reason': 'R',
          }, empty),
          isNull,
        );
      });

      test('keeps at most one suggestion per goal', () {
        final AdviceBatch b = _validator.advice(
          adviceJson(
            goals: <Map<String, Object?>>[
              <String, Object?>{
                'goal': 'focus',
                'suggestedHours': 2.5,
                'reason': 'a',
              },
              <String, Object?>{
                'goal': 'focus',
                'suggestedHours': 2.0 + 0.5,
                'reason': 'b',
              },
              <String, Object?>{
                'goal': 'sleep',
                'suggestedHours': 7,
                'reason': 'c',
              },
            ],
          ),
          ctx,
          now: bNow,
        );
        expect(b.goalSuggestions.map((s) => s.goal), <SuggestedGoal>[
          SuggestedGoal.focus,
          SuggestedGoal.sleep,
        ]);
      });
    });

    test('weekly rejects numerical claims with a safe field category', () {
      // Reproduction of the strict numeric-validation failure path, not a
      // purported copy of the historical response (which was not retained).
      for (final field in ['headline', 'overview']) {
        final data = jsonDecode(summaryJson()) as Map<String, dynamic>;
        data[field] = field == 'headline'
            ? 'Your week ending 2026-10-15'
            : 'You achieved a fabricated score of 99.';
        expect(
          () => _validator.summary(
            jsonEncode(data),
            SummaryKind.weekly,
            ctx,
            now: bNow,
          ),
          throwsA(
            isA<AiFailure>().having(
              (e) => e.detail,
              'category',
              'summary_numeric_$field',
            ),
          ),
        );
      }
    });

    test(
      'weekly rejects incomplete arrays but permits explicit empty content',
      () {
        final data = jsonDecode(summaryJson()) as Map<String, dynamic>;
        data.remove('highlights');
        expect(
          () => _validator.summary(
            jsonEncode(data),
            SummaryKind.weekly,
            ctx,
            now: bNow,
          ),
          throwsA(isA<AiFailure>()),
        );
        data['highlights'] = [
          {'label': 'Study'},
        ];
        expect(
          () => _validator.summary(
            jsonEncode(data),
            SummaryKind.weekly,
            ctx,
            now: bNow,
          ),
          throwsA(isA<AiFailure>()),
        );
        data['highlights'] = [];
        data['improvements'] = [];
        expect(
          _validator
              .summary(jsonEncode(data), SummaryKind.weekly, ctx, now: bNow)
              .highlights,
          isEmpty,
        );
      },
    );

    test('summary: limits next steps for a daily summary', () {
      final AiSummary s = _validator.summary(
        summaryJson(),
        SummaryKind.daily,
        ctx,
        now: bNow,
      );
      expect(s.nextSteps, hasLength(2));
      expect(s.highlights.single.label, 'Study');
      expect(
        _validator
            .summary(summaryJson(), SummaryKind.weekly, ctx, now: bNow)
            .nextSteps,
        hasLength(3),
      );
      expect(
        () => _validator.summary(
          '{"overview":"x"}',
          SummaryKind.daily,
          ctx,
          now: bNow,
        ),
        throwsA(isA<AiFailure>()),
      );
    });

    test(
      'study plan: realistic plans only; preferred time never from the model',
      () {
        final StudyPlan p = _validator.studyPlan(
          planJson(),
          ctx,
          now: bNow,
          preferences: const StudyPreferences(preferredStudyTime: 'Evening'),
        );
        expect(p.dailyStudyMinutes, 150);
        expect(p.preferredTime, 'Evening');
        expect(
          _validator.studyPlan(planJson(), ctx, now: bNow).preferredTime,
          isNull,
        );
        for (final String raw in <String>[
          planJson(daily: 600), // far above recorded 2h / goal 3h
          planJson(daily: 60, sessions: 8, length: 90), // sessions exceed total
          planJson(length: 200),
          '{"overview":"x"}',
        ]) {
          expect(
            () => _validator.studyPlan(raw, ctx, now: bNow),
            throwsA(isA<AiFailure>()),
          );
        }
      },
    );

    test('chat reply: cleaned, capped, never empty', () {
      expect(_validator.chatReply('  **Recorded:** 2h  '), 'Recorded: 2h');
      expect(_validator.chatReply('a ' * 3000).length, lessThanOrEqualTo(2001));
      expect(() => _validator.chatReply('   '), throwsA(isA<AiFailure>()));
    });
  });

  group('models', () {
    test('recommendation round-trips and tolerates damaged documents', () {
      final AiRecommendation r = _rec(
        'Title',
        status: RecommendationStatus.helpful,
      );
      final AiRecommendation back = AiRecommendation.fromMap(r.toMap())!;
      expect(back.title, 'Title');
      expect(back.status, RecommendationStatus.helpful);
      expect(back.sourceMetrics, <String>['studyHours']);
      expect(AiRecommendation.fromMap(<String, dynamic>{'title': 'x'}), isNull);
      expect(
        AiRecommendation.fromMap(<String, dynamic>{
          ...r.toMap(),
          'category': 'gaming',
        }),
        isNull,
      );
    });

    test('category parsing accepts labels and rejects unknown values', () {
      expect(
        RecommendationCategory.tryParse('Screen Time'),
        RecommendationCategory.screenTime,
      );
      expect(
        RecommendationCategory.tryParse('screen_time'),
        RecommendationCategory.screenTime,
      );
      expect(
        RecommendationCategory.tryParse('General Productivity'),
        RecommendationCategory.general,
      );
      expect(RecommendationCategory.tryParse('gaming'), isNull);
      expect(RecommendationCategory.tryParse(3), isNull);
    });

    test('summary, plan and chat round-trip', () {
      final AiContext ctx = _builder.build(_week(richHistory()));
      final AiSummary s = _validator.summary(
        summaryJson(),
        SummaryKind.weekly,
        ctx,
        now: bNow,
      );
      expect(AiSummary.fromMap(s.toMap())!.headline, s.headline);
      final StudyPlan p = _validator.studyPlan(planJson(), ctx, now: bNow);
      expect(StudyPlan.fromMap(p.toMap())!.sessionMinutes, 30);
      final ChatMessage m = ChatMessage(
        id: 'a',
        role: ChatRole.assistant,
        text: 'hi',
        createdAt: bNow,
      );
      expect(ChatMessage.fromMap('a', m.toMap())!.role, ChatRole.assistant);
      expect(ChatMessage.fromMap('a', <String, dynamic>{'role': 'x'}), isNull);
    });
  });

  group('error mapping', () {
    test('maps direct API, network and server errors to friendly kinds', () {
      AiFailureKind k(Object e) => mapAiError(e).kind;
      expect(k(TimeoutException('t')), AiFailureKind.timeout);
      expect(k(const SocketException('down')), AiFailureKind.offline);
      expect(mapAiHttpError(429, 'per minute').kind, AiFailureKind.rateLimited);
      expect(mapAiHttpError(429, 'per day').kind, AiFailureKind.quotaExceeded);
      expect(mapAiHttpError(403).kind, AiFailureKind.notConfigured);
      expect(mapAiHttpError(404).kind, AiFailureKind.modelUnavailable);
      expect(mapAiHttpError(503).kind, AiFailureKind.server);
      expect(k(const FormatException('bad')), AiFailureKind.malformed);
      expect(k(StateError('?')), AiFailureKind.unknown);
    });

    test('every failure has a plain message without technical detail', () {
      for (final AiFailureKind kind in AiFailureKind.values) {
        final AiFailure f = AiFailure(kind, 'stack trace here');
        expect(f.message, isNot(contains('stack')));
        expect(f.message, isNot(contains('Exception')));
        expect(f.message.length, greaterThan(20));
      }
    });
  });

  group('AiUsageLimiter', () {
    test('enforces a per-user daily budget and a cool-down', () async {
      DateTime now = bNow;
      final AiUsageLimiter l = AiUsageLimiter(dailyLimit: 2, clock: () => now);
      await l.acquire('a');
      await expectLater(l.acquire('a'), throwsA(isA<AiFailure>()));
      now = now.add(const Duration(seconds: 5));
      await l.acquire('a');
      now = now.add(const Duration(seconds: 5));
      await expectLater(
        l.acquire('a'),
        throwsA(
          isA<AiFailure>().having(
            (f) => f.kind,
            'kind',
            AiFailureKind.localLimit,
          ),
        ),
      );
      expect(await l.remaining('a'), 0);
      // Other users have their own budget.
      await l.acquire('b');
      // Next day resets.
      now = DateTime(bNow.year, bNow.month, bNow.day + 1, 9);
      expect(await l.remaining('a'), 2);
      await l.acquire('a');
    });
  });

  group('AiAssistantController (mocked AI)', () {
    late FakeInsightsProvider insights;
    late FakeAiProvider ai;
    late InMemoryAiStore store;
    late String? uid;
    late List<String> appliedGoals;

    AiAssistantController make({
      Future<StudyPreferences?> Function(String)? prefs,
    }) => AiAssistantController(
      insights: insights,
      provider: ai,
      store: store,
      currentUserId: () => uid,
      limiter: AiUsageLimiter(minInterval: Duration.zero, clock: () => bNow),
      clock: () => bNow,
      loadPreferences: prefs,
      applyGoal: (u, g, h) async => appliedGoals.add('$u:${g.name}:$h'),
      behaviorInsights: () => const <Recommendation>[
        Recommendation(
          id: 'rule',
          title: 'Rule-based tip',
          action: 'Do X',
          evidence: 'Y',
          priority: 1,
        ),
      ],
    );

    setUp(() {
      insights = FakeInsightsProvider(richHistory());
      ai = FakeAiProvider();
      store = InMemoryAiStore();
      uid = 'alice';
      appliedGoals = <String>[];
    });

    test(
      'advice is generated from Module 3 data and stored for the user',
      () async {
        ai.responses.add(adviceJson());
        final AiAssistantController c = make();
        await c.open();
        expect(ai.requests, isEmpty, reason: 'opening never calls the AI');
        await c.generateAdvice();
        expect(c.adviceError, isNull);
        expect(c.currentRecommendations, hasLength(2));
        expect(store.recs['alice'], hasLength(2));
        final AiRequest req = ai.requests.single;
        expect(req.format, AiOutputFormat.advice);
        expect(req.prompt, contains('"deepFocusHours"'));
        expect(req.prompt, contains('"average":1.5'));
        expect(req.prompt, contains('"measuredByPhone"'));
        expect(c.adviceIsStale, isFalse);
      },
    );

    test('no recorded data: no AI call, clear message', () async {
      insights.setHistory(bHistory(goals: bGoals));
      final AiAssistantController c = make();
      await c.generateAdvice();
      expect(ai.requests, isEmpty);
      expect(c.adviceError!.kind, AiFailureKind.notEnoughData);
    });

    test('rapid repeated taps send one request', () async {
      ai.gate = Completer<void>();
      ai.responses.add(adviceJson());
      final AiAssistantController c = make();
      final Future<void> a = c.generateAdvice();
      final Future<void> b = c.generateAdvice();
      ai.gate!.complete();
      await Future.wait(<Future<void>>[a, b]);
      expect(ai.requests, hasLength(1));
    });

    test(
      'account switch mid-request: result is discarded, not shown or saved',
      () async {
        ai.gate = Completer<void>();
        ai.responses.add(adviceJson());
        final AiAssistantController c = make();
        final Future<void> pending = c.generateAdvice();
        await Future<void>.delayed(Duration.zero);
        uid = 'bob';
        ai.gate!.complete();
        await pending;
        expect(c.currentRecommendations, isEmpty);
        expect(c.advice, isNull);
        expect(store.recs, isEmpty);
      },
    );

    test('each account only sees its own saved results', () async {
      ai.responses.add(adviceJson());
      final AiAssistantController c = make();
      await c.open();
      await c.generateAdvice();
      expect(c.currentRecommendations, hasLength(2));
      uid = 'bob';
      expect(c.currentRecommendations, isEmpty);
      await c.open();
      expect(c.currentRecommendations, isEmpty);
      uid = 'alice';
      await c.open();
      expect(c.currentRecommendations, hasLength(2));
    });

    test(
      'failure shows a friendly error, keeps rule-based insights, retry recovers',
      () async {
        ai.responses.addAll(<Object>[
          const AiFailure(AiFailureKind.rateLimited),
          adviceJson(),
        ]);
        final AiAssistantController c = make();
        await c.generateAdvice();
        expect(c.adviceError!.kind, AiFailureKind.rateLimited);
        expect(c.adviceError!.canRetry, isTrue);
        expect(c.currentRecommendations, isEmpty);
        expect(c.behaviorInsights.single.title, 'Rule-based tip');
        await c.generateAdvice();
        expect(c.adviceError, isNull);
        expect(c.currentRecommendations, hasLength(2));
      },
    );

    test('malformed AI output is never shown', () async {
      ai.responses.add('Sure! Here are some tips: sleep more.');
      final AiAssistantController c = make();
      await c.generateAdvice();
      expect(c.adviceError!.kind, AiFailureKind.malformed);
      expect(c.currentRecommendations, isEmpty);
      expect(store.recs, isEmpty);
    });

    test(
      'feedback is stored, hides dismissed advice and is sent next time',
      () async {
        ai.responses.addAll(<Object>[adviceJson(), adviceJson()]);
        // Each generation happens at a different time, as on a real phone.
        DateTime now = bNow;
        final AiAssistantController c = AiAssistantController(
          insights: insights,
          provider: ai,
          store: store,
          currentUserId: () => uid,
          limiter: AiUsageLimiter(minInterval: Duration.zero, clock: () => now),
          clock: () => now = now.add(const Duration(minutes: 1)),
        );
        await c.generateAdvice();
        final AiRecommendation first = c.currentRecommendations.first;
        await c.setStatus(first, RecommendationStatus.dismissed);
        expect(
          c.currentRecommendations.map((r) => r.title),
          isNot(contains(first.title)),
        );
        expect(c.recentAdvice.map((r) => r.title), contains(first.title));
        expect(store.statusUpdates.single, 'alice:${first.id}:dismissed');

        await c.generateAdvice();
        final Map<String, dynamic> data =
            jsonDecode(ai.requests.last.prompt.split('DATA:\n').last)
                as Map<String, dynamic>;
        expect(data['previousAdviceFeedback']['dismissed'], <String>[
          first.title,
        ]);
        // The model repeated it anyway; the validator filtered it out.
        expect(c.currentRecommendations.map((r) => r.title), <String>[
          'Keep phone use in check',
        ]);
      },
    );

    test('advice is marked out of date when the records change', () async {
      ai.responses.add(adviceJson());
      final AiAssistantController c = make();
      await c.generateAdvice();
      expect(c.adviceIsStale, isFalse);
      insights.setHistory(richHistory(study: 3));
      expect(c.adviceIsStale, isTrue);
    });

    test(
      'goal suggestions: applied only through the confirmed callback',
      () async {
        ai.responses.add(
          adviceJson(
            goals: <Map<String, Object?>>[
              <String, Object?>{
                'goal': 'focus',
                'suggestedHours': 2.5,
                'reason': 'Gradual',
              },
              <String, Object?>{
                'goal': 'sleep',
                'suggestedHours': 7,
                'reason': 'Closer to now',
              },
            ],
          ),
        );
        final AiAssistantController c = make();
        await c.generateAdvice();
        expect(appliedGoals, isEmpty, reason: 'nothing changes automatically');
        expect(c.goalSuggestions, hasLength(2));
        await c.acceptGoalSuggestion(c.goalSuggestions.first);
        expect(appliedGoals, <String>['alice:focus:2.5']);
        await c.rejectGoalSuggestion(c.goalSuggestions.single);
        expect(c.goalSuggestions, isEmpty);
        expect(store.advice['alice']!.goalSuggestions, isEmpty);
      },
    );

    test('summaries are cached and not regenerated on reopen', () async {
      ai.responses.add(summaryJson());
      final AiAssistantController c = make();
      await c.generateSummary(SummaryKind.weekly);
      expect(c.summary(SummaryKind.weekly)!.headline, 'A steady week');
      expect(c.summaryIsStale(SummaryKind.weekly), isFalse);

      final AiAssistantController reopened = make();
      await reopened.open();
      expect(reopened.summary(SummaryKind.weekly)!.headline, 'A steady week');
      expect(ai.requests, hasLength(1));

      insights.setHistory(richHistory(focus: 2));
      expect(reopened.summaryIsStale(SummaryKind.weekly), isTrue);
    });

    test('daily summary for yesterday analyses that day only', () async {
      ai.responses.add(summaryJson(headline: 'Yesterday'));
      final AiAssistantController c = make();
      await c.selectSummaryDay(SummaryDay.yesterday);
      await c.generateSummary(SummaryKind.daily);
      expect(
        ai.requests.single.prompt,
        contains('daily summary for 2026-10-14'),
      );
      expect(c.summary(SummaryKind.daily)!.periodKey, '2026-10-14');
      await c.selectSummaryDay(SummaryDay.today);
      expect(c.summary(SummaryKind.daily), isNull);
    });

    test(
      'study plan uses stated preferences and applies the goal only on request',
      () async {
        ai.responses.add(planJson());
        final AiAssistantController c = make(
          prefs: (_) async =>
              const StudyPreferences(preferredStudyTime: 'Evening'),
        );
        await c.open();
        await c.generateStudyPlan();
        final StudyPlan plan = c.studyPlan!;
        expect(plan.preferredTime, 'Evening');
        expect(ai.requests.single.prompt, contains('statedPreferences'));
        expect(c.studyGoalFromPlan(plan), 2.5);
        expect(appliedGoals, isEmpty);
        await c.applyPlanAsStudyGoal(plan);
        expect(appliedGoals, <String>['alice:study:2.5']);
      },
    );

    test(
      'chat: real context, limited history, retry without duplicates, clear',
      () async {
        final List<ChatMessage> old = <ChatMessage>[
          for (int i = 0; i < 20; i++)
            ChatMessage(
              id: 'old$i',
              role: i.isEven ? ChatRole.user : ChatRole.assistant,
              text: 'message $i ${'x' * (i == 19 ? 900 : 1)}',
              createdAt: bNow.subtract(Duration(minutes: 30 - i)),
            ),
        ];
        store.chats['alice'] = old;
        ai.responses.addAll(<Object>[
          const AiFailure(AiFailureKind.timeout),
          'Recorded: you studied about 2 hours a day.',
        ]);
        final AiAssistantController c = make();
        await c.open();
        await c.sendChat('  How much did I study?  ');
        expect(c.chatError!.kind, AiFailureKind.timeout);
        expect(c.chat.last.text, 'How much did I study?');
        expect(c.canRetryChat, isTrue);

        await c.retryChat();
        expect(c.chatError, isNull);
        expect(c.chat, hasLength(22));
        expect(
          c.chat.where((m) => m.text == 'How much did I study?'),
          hasLength(1),
        );
        expect(c.chat.last.role, ChatRole.assistant);

        final AiRequest req = ai.requests.last;
        expect(req.format, AiOutputFormat.text);
        expect(
          req.history.length,
          lessThanOrEqualTo(AiAssistantController.chatHistoryTurns),
        );
        expect(req.history.first.role, ChatRole.user);
        expect(
          req.history.every(
            (t) => t.text.length <= AiAssistantController.chatTurnChars + 1,
          ),
          isTrue,
        );
        expect(req.prompt, contains('"last7Days"'));
        expect(req.prompt, contains('QUESTION:\nHow much did I study?'));
        expect(store.chats['alice'], hasLength(22));

        await c.clearChat();
        expect(c.chat, isEmpty);
        expect(store.chats['alice'], isNull);
      },
    );

    test('daily AI budget stops requests on this phone', () async {
      ai.responses.addAll(<Object>[summaryJson(), summaryJson()]);
      final AiAssistantController c = AiAssistantController(
        insights: insights,
        provider: ai,
        store: store,
        currentUserId: () => uid,
        limiter: AiUsageLimiter(
          dailyLimit: 1,
          minInterval: Duration.zero,
          clock: () => bNow,
        ),
        clock: () => bNow,
      );
      await c.generateSummary(SummaryKind.weekly);
      await c.generateSummary(SummaryKind.daily);
      expect(ai.requests, hasLength(1));
      expect(c.summaryError(SummaryKind.daily)!.kind, AiFailureKind.localLimit);
    });
  });

  group('Module 3 helpers', () {
    test('HistoryData.asOf drops later records', () {
      final HistoryData h = richHistory().asOf(bDay(2));
      expect(h.todayKey, '2026-10-13');
      expect(h.scores.every((s) => !s.date.isAfter(bDay(2, 23, 59))), isTrue);
      expect(h.activityLogs, hasLength(5));
      final BehaviorAnalysis a = _engine.analyze(h, AnalysisPeriod.day);
      expect(a.dataQuality.excludedRecords['future_date'], isNull);
      expect(a.metrics['studyHours']!.mean, 2);
    });
  });

  group('ReminderService', () {
    late FakeReminderPlatform platform;
    late ReminderService service;

    setUp(() {
      platform = FakeReminderPlatform();
      service = ReminderService(platform: platform, clock: () => bNow);
    });

    test(
      'turning a reminder on asks for permission; refused keeps it off',
      () async {
        final bool ok = await service.update(
          const ReminderSettings(dailyLog: true),
        );
        expect(ok, isFalse);
        expect(platform.permissionRequests, 1);
        expect(service.settings.value.dailyLog, isFalse);
        expect(platform.scheduled, isEmpty);
      },
    );

    test(
      'schedules, re-schedules without duplicates, cancels and persists',
      () async {
        platform.grantOnRequest = true;
        expect(
          await service.update(
            const ReminderSettings(
              dailyLog: true,
              study: true,
              studyTime: TimeOfDay(hour: 17, minute: 30),
            ),
          ),
          isTrue,
        );
        expect(platform.scheduled[ReminderService.dailyLogId], 'daily 21:0');
        expect(platform.scheduled[ReminderService.studyId], 'daily 17:30');
        await service.update(
          service.settings.value.copyWith(
            studyTime: const TimeOfDay(hour: 8, minute: 0),
          ),
        );
        expect(platform.scheduled, hasLength(2));
        expect(platform.permissionRequests, 1);

        await service.onLoggedToday();
        expect(
          platform.scheduled[ReminderService.dailyLogId],
          'daily 21:0 from 2026-10-16',
        );

        await service.update(service.settings.value.copyWith(study: false));
        expect(platform.cancelled, contains(ReminderService.studyId));

        final ReminderService reloaded = ReminderService(platform: platform);
        final ReminderSettings s = await reloaded.load();
        expect(s.dailyLog, isTrue);
        expect(s.study, isFalse);
        expect(s.studyTime, const TimeOfDay(hour: 8, minute: 0));
      },
    );

    test('focus end alert only when enabled', () async {
      await service.onFocusRunning(bNow.add(const Duration(minutes: 25)));
      expect(platform.scheduled, isEmpty);
      platform.allowed = true;
      await service.update(const ReminderSettings(focusEnd: true));
      await service.onFocusRunning(bNow.add(const Duration(minutes: 25)));
      expect(
        platform.scheduled[ReminderService.focusEndId],
        startsWith('once'),
      );
      await service.onFocusStopped();
      expect(platform.scheduled, isEmpty);
    });
  });
}

AiRecommendation _rec(
  String title, {
  RecommendationStatus status = RecommendationStatus.active,
}) => AiRecommendation(
  id: 'id_$title',
  title: title,
  description: 'd',
  category: RecommendationCategory.study,
  priority: RecommendationPriority.low,
  reason: 'r',
  sourceMetrics: const <String>['studyHours'],
  period: AnalysisPeriod.week,
  suggestion: 's',
  generatedAt: bNow,
  status: status,
);
