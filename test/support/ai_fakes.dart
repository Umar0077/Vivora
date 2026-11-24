import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:vivora/features/activity_monitoring/data/models/activity_date_utils.dart';
import 'package:vivora/features/activity_monitoring/data/models/daily_activity_log.dart';
import 'package:vivora/features/ai_assistant/data/ai_provider.dart';
import 'package:vivora/features/ai_assistant/data/ai_store.dart';
import 'package:vivora/features/ai_assistant/domain/ai_models.dart';
import 'package:vivora/features/behavior_analysis/domain/behavior_analysis_engine.dart';
import 'package:vivora/features/behavior_analysis/domain/behavior_models.dart';
import 'package:vivora/features/focus_mode/data/focus_session_repository.dart';
import 'package:vivora/features/insights/data/history_data.dart';
import 'package:vivora/features/insights/services/insights_service.dart';
import 'package:vivora/features/productivity_scoring/data/models/productivity_models.dart';
import 'package:vivora/features/reminders/reminder_service.dart';

import 'behavior_builders.dart';

/// Mock AI: answers from a queue (or a handler), records every request, and
/// can be gated to simulate a slow network. Never touches the network.
class FakeAiProvider implements AiProvider {
  FakeAiProvider([List<Object>? responses])
    : responses = responses ?? <Object>[];

  /// Each entry is a String (returned) or an Object (thrown).
  final List<Object> responses;
  final List<AiRequest> requests = <AiRequest>[];
  Completer<void>? gate;

  @override
  String get modelName => 'fake-model';

  @override
  Future<String> generate(AiRequest request) async {
    requests.add(request);
    if (gate != null) await gate!.future;
    if (responses.isEmpty) throw StateError('No fake response queued');
    final Object next = responses.removeAt(0);
    if (next is String) return next;
    throw next;
  }
}

class InMemoryAiStore implements AiStore {
  final Map<String, List<AiRecommendation>> recs =
      <String, List<AiRecommendation>>{};
  final Map<String, StoredAdvice> advice = <String, StoredAdvice>{};
  final Map<String, AiSummary> summaries = <String, AiSummary>{};
  final Map<String, StudyPlan> plans = <String, StudyPlan>{};
  final Map<String, List<ChatMessage>> chats = <String, List<ChatMessage>>{};
  final List<String> statusUpdates = <String>[];

  @override
  Future<List<AiRecommendation>> loadRecommendations(String uid) async =>
      List<AiRecommendation>.of(recs[uid] ?? const <AiRecommendation>[]);

  @override
  Future<StoredAdvice?> loadAdvice(String uid) async => advice[uid];

  @override
  Future<void> saveAdvice(
    String uid,
    AdviceBatch batch, {
    required String model,
  }) async {
    recs[uid] = <AiRecommendation>[...batch.recommendations, ...?recs[uid]];
    advice[uid] = StoredAdvice(
      generatedAt: batch.generatedAt,
      fingerprint: batch.fingerprint,
      goalSuggestions: batch.goalSuggestions,
      model: model,
    );
  }

  @override
  Future<void> saveGoalSuggestions(
    String uid,
    List<GoalSuggestion> remaining,
  ) async {
    final StoredAdvice? a = advice[uid];
    if (a == null) return;
    advice[uid] = StoredAdvice(
      generatedAt: a.generatedAt,
      fingerprint: a.fingerprint,
      goalSuggestions: remaining,
      model: a.model,
    );
  }

  @override
  Future<void> updateStatus(
    String uid,
    String id,
    RecommendationStatus status,
    DateTime at,
  ) async {
    statusUpdates.add('$uid:$id:${status.name}');
    recs[uid] = <AiRecommendation>[
      for (final AiRecommendation r in recs[uid] ?? const <AiRecommendation>[])
        r.id == id ? r.copyWith(status: status, statusChangedAt: at) : r,
    ];
  }

  @override
  Future<AiSummary?> loadSummary(
    String uid,
    SummaryKind kind,
    String periodKey,
  ) async => summaries['$uid/${kind.name}_$periodKey'];

  @override
  Future<void> saveSummary(String uid, AiSummary summary) async =>
      summaries['$uid/${summary.kind.name}_${summary.periodKey}'] = summary;

  @override
  Future<StudyPlan?> loadStudyPlan(String uid) async => plans[uid];

  @override
  Future<void> saveStudyPlan(String uid, StudyPlan plan) async =>
      plans[uid] = plan;

  @override
  Future<List<ChatMessage>> loadChat(String uid, {int limit = 60}) async =>
      List<ChatMessage>.of(chats[uid] ?? const <ChatMessage>[]);

  @override
  Future<void> addChatMessage(String uid, ChatMessage message) async =>
      (chats[uid] ??= <ChatMessage>[]).add(message);

  @override
  Future<void> clearChat(String uid) async => chats.remove(uid);
}

/// Module 3 results computed by the real engine from in-memory history.
class FakeInsightsProvider implements BehaviorInsightsProvider {
  FakeInsightsProvider(HistoryData history) {
    setHistory(history);
  }

  final BehaviorAnalysisEngine engine = const BehaviorAnalysisEngine();
  final ValueNotifier<int> _changes = ValueNotifier<int>(0);
  late HistoryData history;
  late Map<AnalysisPeriod, BehaviorAnalysis> analyses;
  int ensureCalls = 0;

  void setHistory(HistoryData h) {
    history = h;
    analyses = engine.analyzeAll(h, calculatedAt: h.today);
    _changes.value++;
  }

  @override
  BehaviorAnalysis? analysisFor(AnalysisPeriod period) => analyses[period];

  @override
  Future<Map<AnalysisPeriod, BehaviorAnalysis>?> ensureAnalyses() async {
    ensureCalls++;
    return analyses;
  }

  @override
  BehaviorAnalysis? analysisForDay(DateTime day) {
    if (ActivityDateUtils.isSameDay(day, history.today)) {
      return analyses[AnalysisPeriod.day];
    }
    return engine.analyze(history.asOf(day), AnalysisPeriod.day);
  }

  @override
  Listenable get changes => _changes;
}

/// A week of realistic records for the fixed test date (Thu 15 Oct 2026).
HistoryData richHistory({double study = 2.0, double focus = 1.5}) => bHistory(
  logs: <SavedDailyScore>[
    for (int d = 0; d <= 6; d++)
      bLog(d, sleep: 6.5, study: study, focus: focus, routine: 60, score: 62),
  ],
  activity: <DailyActivityLog>[
    for (int d = 0; d <= 6; d++) bActivity(d, app: 300, unlocks: 80),
  ],
  sessions: <FocusSession>[for (int d = 1; d <= 4; d++) bSession(d, 10, 25)],
  goals: bGoals,
);

String adviceJson({
  List<Map<String, Object?>>? recommendations,
  List<Map<String, Object?>> goals = const <Map<String, Object?>>[],
}) => jsonEncode(<String, Object?>{
  'recommendations':
      recommendations ??
      <Map<String, Object?>>[
        <String, Object?>{
          'title': 'Add one more focus block',
          'description':
              'Your logged deep focus averaged 1.5 hours against a 2 hour goal.',
          'category': 'focus',
          'priority': 'high',
          'reason': 'Deep focus averaged 1.5h over 7 logged days; goal is 2h.',
          'sourceMetrics': <String>['deepFocusHours'],
          'suggestion': 'Start a 25-minute Focus Mode session before lunch.',
        },
        <String, Object?>{
          'title': 'Keep phone use in check',
          'description': 'Measured app use averaged 5 hours a day.',
          'category': 'screenTime',
          'priority': 'medium',
          'reason': 'App usage averaged 300 minutes over 7 measured days.',
          'sourceMetrics': <String>['appUsageMinutes'],
          'suggestion':
              'Set a 2-hour Digital Wellbeing timer for your top app.',
        },
      ],
  'goalSuggestions': goals,
});

String summaryJson({String headline = 'A steady week'}) =>
    jsonEncode(<String, Object?>{
      'headline': headline,
      'overview': 'Your recorded study routine was consistent.',
      'highlights': <Map<String, String>>[
        <String, String>{
          'label': 'Study',
          'text': 'Study was recorded regularly.',
        },
      ],
      'improvements': <String>['Your logged sleep was below your goal.'],
      'nextSteps': <String>[
        'Aim for lights out 30 minutes earlier.',
        'Keep logging.',
        'Third',
      ],
    });

String planJson({int daily = 150, int sessions = 5, int length = 30}) =>
    jsonEncode(<String, Object?>{
      'overview': 'Build from your 2 hour average towards your 3 hour goal.',
      'dailyStudyMinutes': daily,
      'sessionsPerDay': sessions,
      'sessionMinutes': length,
      'breakMinutes': 5,
      'priorities': <String>['Finish one assignment section'],
      'goalAlignment': 'Moves you closer to your 3 hour study goal.',
      'tips': <String>['Silence notifications during sessions.'],
      'preferredTime': '05:00 every day',
    });

/// Records reminder calls instead of talking to Android.
class FakeReminderPlatform implements ReminderPlatform {
  bool allowed = false;
  bool grantOnRequest = false;
  int permissionRequests = 0;
  final Map<int, String> scheduled = <int, String>{};
  final List<int> cancelled = <int>[];

  @override
  Future<bool> notificationsAllowed() async => allowed;

  @override
  Future<bool> requestPermission() async {
    permissionRequests++;
    allowed = grantOnRequest;
    return allowed;
  }

  @override
  Future<void> scheduleDaily({
    required int id,
    required TimeOfDay time,
    required String title,
    required String body,
    DateTime? notBefore,
  }) async {
    scheduled[id] =
        'daily ${time.hour}:${time.minute}${notBefore == null ? '' : ' from ${ActivityDateUtils.dayKey(notBefore)}'}';
  }

  @override
  Future<void> scheduleOnce({
    required int id,
    required DateTime at,
    required String title,
    required String body,
  }) async {
    scheduled[id] = 'once ${at.toIso8601String()}';
  }

  @override
  Future<void> cancel(int id) async {
    cancelled.add(id);
    scheduled.remove(id);
  }
}
