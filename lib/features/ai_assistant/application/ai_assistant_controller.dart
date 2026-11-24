import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../behavior_analysis/domain/behavior_models.dart';
import '../../insights/services/insights_service.dart';
import '../../insights/services/recommendation_service.dart';
import '../data/ai_provider.dart';
import '../data/ai_store.dart';
import '../data/ai_usage_limiter.dart';
import '../domain/ai_context_builder.dart';
import '../domain/ai_failure.dart';
import '../domain/ai_models.dart';
import '../domain/ai_prompts.dart';
import '../domain/ai_response_validator.dart';

enum SummaryDay { today, yesterday }

/// Module 6 state and actions, independent of widgets.
///
/// * Nothing is generated automatically: every AI request starts from an
///   explicit action (button), and cached results are shown otherwise.
/// * Every request is checked against the current user before and after it
///   runs; results that finish after an account switch are discarded.
/// * One request per section at a time (repeated taps are ignored), plus the
///   per-day budget in [AiUsageLimiter].
/// * Model output only changes stored goals through [applyGoal], which the
///   UI calls after the student confirms.
class AiAssistantController extends ChangeNotifier {
  AiAssistantController({
    required BehaviorInsightsProvider insights,
    required AiProvider provider,
    required AiStore store,
    required String? Function() currentUserId,
    AiUsageLimiter? limiter,
    Future<StudyPreferences?> Function(String uid)? loadPreferences,
    Future<void> Function(String uid, SuggestedGoal goal, double hours)?
    applyGoal,
    List<Recommendation> Function()? behaviorInsights,
    bool? Function()? trackingEnabled,
    Listenable? trackingChanges,
    DateTime Function()? clock,
    this.builder = const AiContextBuilder(),
    this.validator = const AiResponseValidator(),
  }) : _insights = insights,
       _provider = provider,
       _store = store,
       _currentUserId = currentUserId,
       _limiter = limiter ?? AiUsageLimiter(),
       _loadPreferences = loadPreferences,
       _applyGoal = applyGoal,
       _behaviorInsights = behaviorInsights,
       _trackingEnabled = trackingEnabled,
       _trackingChanges = trackingChanges,
       _clock = clock ?? DateTime.now {
    _insights.changes.addListener(_onInsightsChanged);
    _trackingChanges?.addListener(_onInsightsChanged);
  }

  final BehaviorInsightsProvider _insights;
  final AiProvider _provider;
  final AiStore _store;
  final String? Function() _currentUserId;
  final AiUsageLimiter _limiter;
  final Future<StudyPreferences?> Function(String uid)? _loadPreferences;
  final Future<void> Function(String uid, SuggestedGoal goal, double hours)?
  _applyGoal;
  final List<Recommendation> Function()? _behaviorInsights;
  final bool? Function()? _trackingEnabled;
  final Listenable? _trackingChanges;
  bool? _ctxTracking;
  final DateTime Function() _clock;
  final AiContextBuilder builder;
  final AiResponseValidator validator;

  static const int chatHistoryTurns = 8;
  static const int chatTurnChars = 600;
  static const int maxQuestionChars = 500;

  String get modelName => _provider.modelName;

  // --- Per-user state ------------------------------------------------------
  String? _uid;
  int _epoch = 0;
  String? _openedFor;
  bool _opening = false;
  StudyPreferences? _preferences;

  List<AiRecommendation> _recommendations = <AiRecommendation>[];
  StoredAdvice? _advice;
  List<GoalSuggestion> _goalSuggestions = <GoalSuggestion>[];
  bool adviceLoading = false;
  AiFailure? adviceError;
  bool goalsLoading = false;
  AiFailure? goalsError;

  final Map<String, AiSummary> _summaries = <String, AiSummary>{};
  final Map<SummaryKind, bool> _summaryLoading = <SummaryKind, bool>{};
  final Map<SummaryKind, AiFailure?> _summaryError =
      <SummaryKind, AiFailure?>{};
  SummaryDay summaryDay = SummaryDay.today;

  StudyPlan? _plan;
  bool planLoading = false;
  AiFailure? planError;

  List<ChatMessage> _chat = <ChatMessage>[];
  bool chatSending = false;
  bool chatClearing = false;
  bool diagnosticLoading = false;
  bool diagnosticSucceeded = false;
  AiFailure? diagnosticError;
  bool _disposed = false;
  AiFailure? chatError;
  String? _unanswered;

  final Map<String, BehaviorAnalysis?> _dayCache =
      <String, BehaviorAnalysis?>{};
  final Map<BehaviorAnalysis, AiContext> _ctxCache =
      <BehaviorAnalysis, AiContext>{};
  List<AiRecommendation>? _ctxRecs;
  StudyPreferences? _ctxPrefs;

  // --- Read-only views -----------------------------------------------------

  bool get isOpening => _opening;
  String? get userId => _uid;
  bool get hasAnalysis => _insights.analysisFor(AnalysisPeriod.week) != null;

  /// Deterministic Module 3 suggestions, shown (and labelled as such) when AI
  /// output is unavailable.
  List<Recommendation> get behaviorInsights =>
      _behaviorInsights?.call() ?? const <Recommendation>[];

  // Every read first checks the signed-in user, so a widget can never show
  // the previous account's results after a switch, even before it is told.
  StoredAdvice? get advice {
    _ensureUser();
    return _advice;
  }

  List<GoalSuggestion> get goalSuggestions {
    _ensureUser();
    return List<GoalSuggestion>.unmodifiable(_goalSuggestions);
  }

  /// The latest batch, minus dismissed and completed items.
  List<AiRecommendation> get currentRecommendations {
    _ensureUser();
    final DateTime? at = _advice?.generatedAt;
    return _recommendations
        .where((r) => r.status.isVisible && at != null && r.generatedAt == at)
        .toList();
  }

  /// Earlier advice and advice the student completed or dismissed.
  List<AiRecommendation> get recentAdvice {
    _ensureUser();
    final DateTime? at = _advice?.generatedAt;
    return _recommendations
        .where((r) => !r.status.isVisible || r.generatedAt != at)
        .take(10)
        .toList();
  }

  /// True when the student's records changed after the advice was made.
  bool get adviceIsStale {
    final StoredAdvice? a = _advice;
    final AiContext? c = _context(AnalysisPeriod.week);
    return a != null && c != null && a.fingerprint != c.fingerprint;
  }

  AiSummary? summary(SummaryKind kind) {
    _ensureUser();
    final AiContext? c = _summaryContext(kind);
    final String key = _summaryKey(kind, c?.periodKey ?? _periodKey(kind));
    return _summaries[key];
  }

  bool summaryIsStale(SummaryKind kind) {
    final AiSummary? s = summary(kind);
    final AiContext? c = _summaryContext(kind);
    return s != null && c != null && s.fingerprint != c.fingerprint;
  }

  bool summaryLoading(SummaryKind kind) => _summaryLoading[kind] ?? false;
  AiFailure? summaryError(SummaryKind kind) => _summaryError[kind];

  StudyPlan? get studyPlan {
    _ensureUser();
    return _plan;
  }

  bool get planIsStale {
    final StudyPlan? p = _plan;
    final AiContext? c = _context(AnalysisPeriod.week);
    return p != null && c != null && p.fingerprint != c.fingerprint;
  }

  List<ChatMessage> get chat {
    _ensureUser();
    return List<ChatMessage>.unmodifiable(_chat);
  }

  bool get canRetryChat => _unanswered != null && !chatSending;

  // --- User isolation --------------------------------------------------------

  /// Resets everything when the signed-in user changed. Returns the uid.
  String? _ensureUser() {
    final String? uid = _currentUserId();
    if (uid != _uid) {
      _uid = uid;
      _epoch++;
      _openedFor = null;
      _opening = false;
      _preferences = null;
      _recommendations = <AiRecommendation>[];
      _advice = null;
      _goalSuggestions = <GoalSuggestion>[];
      adviceLoading = false;
      adviceError = null;
      goalsLoading = false;
      goalsError = null;
      _summaries.clear();
      _summaryLoading.clear();
      _summaryError.clear();
      summaryDay = SummaryDay.today;
      _plan = null;
      planLoading = false;
      planError = null;
      _chat = <ChatMessage>[];
      chatSending = false;
      chatClearing = false;
      diagnosticLoading = false;
      diagnosticSucceeded = false;
      diagnosticError = null;
      chatError = null;
      _unanswered = null;
      _dayCache.clear();
      _ctxCache.clear();
    }
    return uid;
  }

  bool _current(int epoch, String uid) =>
      !_disposed && epoch == _epoch && uid == _currentUserId();

  void _onInsightsChanged() {
    _dayCache.clear();
    _ensureUser();
    notifyListeners();
  }

  // --- Loading cached results (no AI calls) ---------------------------------

  /// Loads Module 3 analyses and saved AI results. Safe to call repeatedly.
  Future<void> open({bool force = false}) async {
    final String? uid = _ensureUser();
    if (uid == null || _opening || (_openedFor == uid && !force)) {
      notifyListeners();
      return;
    }
    final int epoch = _epoch;
    _opening = true;
    notifyListeners();

    Future<Object?> soft(Future<Object?> f) async {
      try {
        return await f;
      } catch (e) {
        debugPrint('AI open: ${e.runtimeType}');
        return null;
      }
    }

    final DateTime now = _clock();
    final List<Object?> r = await Future.wait<Object?>(<Future<Object?>>[
      soft(_insights.ensureAnalyses()),
      soft(_store.loadRecommendations(uid)),
      soft(_store.loadAdvice(uid)),
      soft(_store.loadSummary(uid, SummaryKind.daily, _dayKey(now))),
      soft(_store.loadSummary(uid, SummaryKind.weekly, _dayKey(now))),
      soft(_store.loadStudyPlan(uid)),
      soft(_store.loadChat(uid)),
      if (_loadPreferences != null)
        soft(_loadPreferences(uid))
      else
        Future<Object?>.value(),
    ]);
    if (!_current(epoch, uid)) return;
    _recommendations = (r[1] as List<AiRecommendation>?) ?? _recommendations;
    _advice = (r[2] as StoredAdvice?) ?? _advice;
    _goalSuggestions = _advice?.goalSuggestions ?? _goalSuggestions;
    for (final AiSummary? s in <AiSummary?>[
      r[3] as AiSummary?,
      r[4] as AiSummary?,
    ]) {
      if (s != null) _summaries[_summaryKey(s.kind, s.periodKey)] = s;
    }
    _plan = (r[5] as StudyPlan?) ?? _plan;
    final List<ChatMessage>? stored = r[6] as List<ChatMessage>?;
    if (stored != null && _chat.isEmpty) _chat = stored;
    _preferences = r[7] as StudyPreferences?;
    _openedFor = uid;
    _opening = false;
    notifyListeners();
  }

  // --- Recommendations and goal suggestions ---------------------------------

  Future<void> generateAdvice() async {
    if (adviceLoading) return;
    final String? uid = _ensureUser();
    if (uid == null) {
      adviceError = const AiFailure(AiFailureKind.signedOut);
      notifyListeners();
      return;
    }
    final int epoch = _epoch;
    adviceLoading = true;
    adviceError = null;
    notifyListeners();
    try {
      final AiContext ctx = await _requireContext(AnalysisPeriod.week);
      if (!_current(epoch, uid)) return;
      await _limiter.acquire(uid);
      if (!_current(epoch, uid)) return;
      final String raw = await _provider.generate(
        AiRequest(
          format: AiOutputFormat.advice,
          prompt: AiPrompts.advicePrompt(ctx),
          maxOutputTokens: 1400,
          timeout: const Duration(seconds: 65),
        ),
      );
      final AdviceBatch generated = validator.advice(
        raw,
        ctx,
        now: _clock(),
        suppressedTitles: _recommendations
            .where(
              (r) =>
                  r.status != RecommendationStatus.active &&
                  r.status != RecommendationStatus.helpful,
            )
            .map((r) => r.title),
      );
      if (!_current(epoch, uid)) return;
      final batch = AdviceBatch(
        recommendations: generated.recommendations,
        goalSuggestions: generated.goalSuggestions.isNotEmpty
            ? generated.goalSuggestions
            : _goalSuggestions,
        generatedAt: generated.generatedAt,
        fingerprint: generated.fingerprint,
        period: generated.period,
      );
      final Set<String> ids = batch.recommendations.map((r) => r.id).toSet();
      _recommendations = <AiRecommendation>[
        ...batch.recommendations,
        ..._recommendations.where((r) => !ids.contains(r.id)),
      ];
      _goalSuggestions = batch.goalSuggestions;
      _advice = StoredAdvice(
        generatedAt: batch.generatedAt,
        fingerprint: batch.fingerprint,
        goalSuggestions: batch.goalSuggestions,
        model: _provider.modelName,
      );
      await _quietly(_store.saveAdvice(uid, batch, model: _provider.modelName));
    } catch (e) {
      if (_current(epoch, uid)) adviceError = _failure(e);
    } finally {
      if (epoch == _epoch) {
        adviceLoading = false;
        notifyListeners();
      }
    }
  }

  /// Separate AI request: a recommendation failure never prevents goal generation.
  Future<void> generateGoals() async {
    if (goalsLoading) return;
    final uid = _ensureUser();
    if (uid == null) {
      goalsError = const AiFailure(AiFailureKind.signedOut);
      notifyListeners();
      return;
    }
    final epoch = _epoch;
    goalsLoading = true;
    goalsError = null;
    notifyListeners();
    try {
      final ctx = await _requireContext(AnalysisPeriod.week);
      if (!_current(epoch, uid)) return;
      await _limiter.acquire(uid);
      if (!_current(epoch, uid)) return;
      final raw = await _provider.generate(
        AiRequest(
          format: AiOutputFormat.goals,
          prompt: AiPrompts.goalsPrompt(ctx),
          maxOutputTokens: 500,
          timeout: const Duration(seconds: 65),
        ),
      );
      final decoded = validator.decodeObject(raw);
      if (decoded['goalSuggestions'] is! List) {
        throw const AiFailure(AiFailureKind.malformed);
      }
      final batch = validator.advice(
        jsonEncode({...decoded, 'recommendations': <Object>[]}),
        ctx,
        now: _clock(),
      );
      if (!_current(epoch, uid)) return;
      _goalSuggestions = batch.goalSuggestions;
      final previous = _advice;
      _advice = StoredAdvice(
        generatedAt: previous?.generatedAt ?? batch.generatedAt,
        fingerprint: previous?.fingerprint ?? batch.fingerprint,
        goalSuggestions: _goalSuggestions,
        model: previous?.model ?? _provider.modelName,
      );
      if (previous == null) {
        await _quietly(
          _store.saveAdvice(uid, batch, model: _provider.modelName),
        );
      } else {
        await _quietly(_store.saveGoalSuggestions(uid, _goalSuggestions));
      }
    } catch (error) {
      if (_current(epoch, uid)) goalsError = _failure(error);
    } finally {
      if (_current(epoch, uid)) {
        goalsLoading = false;
        notifyListeners();
      }
    }
  }

  /// Records feedback. Dismissed and completed advice leaves "For you";
  /// all feedback is sent (as titles only) with the next request so similar
  /// advice is not repeated. The model itself is not retrained.
  Future<void> setStatus(
    AiRecommendation rec,
    RecommendationStatus status,
  ) async {
    final String? uid = _ensureUser();
    if (uid == null) return;
    if (!_recommendations.any((r) => r.id == rec.id)) return;
    final int epoch = _epoch;
    final DateTime at = _clock();
    await _store.updateStatus(uid, rec.id, status, at);
    if (!_current(epoch, uid)) return;
    _recommendations = <AiRecommendation>[
      for (final AiRecommendation r in _recommendations)
        r.id == rec.id ? r.copyWith(status: status, statusChangedAt: at) : r,
    ];
    notifyListeners();
  }

  /// Applies a goal suggestion. Call only after the student confirmed.
  Future<void> acceptGoalSuggestion(GoalSuggestion s) async {
    final String? uid = _ensureUser();
    final Future<void> Function(String, SuggestedGoal, double)? apply =
        _applyGoal;
    if (uid == null || apply == null) {
      throw const AiFailure(AiFailureKind.signedOut);
    }
    if (!_goalSuggestions.contains(s)) {
      throw const AiFailure(AiFailureKind.malformed, 'stale goal suggestion');
    }
    final int epoch = _epoch;
    await apply(uid, s.goal, s.suggestedHours);
    if (_current(epoch, uid)) await _dropGoalSuggestion(uid, s);
  }

  Future<void> rejectGoalSuggestion(GoalSuggestion s) async {
    final String? uid = _ensureUser();
    if (uid != null && _goalSuggestions.contains(s)) {
      await _dropGoalSuggestion(uid, s);
    }
  }

  Future<void> _dropGoalSuggestion(String uid, GoalSuggestion s) async {
    _goalSuggestions = _goalSuggestions.where((g) => g.goal != s.goal).toList();
    notifyListeners();
    await _quietly(_store.saveGoalSuggestions(uid, _goalSuggestions));
  }

  // --- Summaries -------------------------------------------------------------

  Future<void> selectSummaryDay(SummaryDay day) async {
    final String? uid = _ensureUser();
    summaryDay = day;
    notifyListeners();
    final AiContext? c = _summaryContext(SummaryKind.daily);
    final String key = c?.periodKey ?? _periodKey(SummaryKind.daily);
    if (uid == null ||
        _summaries.containsKey(_summaryKey(SummaryKind.daily, key))) {
      return;
    }
    final int epoch = _epoch;
    try {
      final AiSummary? s = await _store.loadSummary(
        uid,
        SummaryKind.daily,
        key,
      );
      if (s != null && _current(epoch, uid)) {
        _summaries[_summaryKey(s.kind, s.periodKey)] = s;
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> generateSummary(SummaryKind kind) async {
    if (summaryLoading(kind)) return;
    final String? uid = _ensureUser();
    if (uid == null) {
      _summaryError[kind] = const AiFailure(AiFailureKind.signedOut);
      notifyListeners();
      return;
    }
    final int epoch = _epoch;
    _summaryLoading[kind] = true;
    _summaryError[kind] = null;
    notifyListeners();
    try {
      await _insights.ensureAnalyses();
      final AiContext? ctx = _summaryContext(kind);
      if (ctx == null || !ctx.hasData) {
        throw const AiFailure(AiFailureKind.notEnoughData);
      }
      if (!_current(epoch, uid)) return;
      await _limiter.acquire(uid);
      if (!_current(epoch, uid)) return;
      final String raw = await _provider.generate(
        AiRequest(
          format: AiOutputFormat.summary,
          prompt: AiPrompts.summaryPrompt(kind, ctx),
          maxOutputTokens: kind == SummaryKind.weekly ? 1100 : 800,
          timeout: Duration(seconds: kind == SummaryKind.weekly ? 75 : 55),
        ),
      );
      final AiSummary s = validator.summary(raw, kind, ctx, now: _clock());
      if (kDebugMode && kind == SummaryKind.weekly) {
        debugPrint('PDT_WEEKLY validated');
      }
      if (!_current(epoch, uid)) return;
      _summaries[_summaryKey(kind, s.periodKey)] = s;
      await _quietly(_store.saveSummary(uid, s));
    } catch (e) {
      if (kDebugMode && kind == SummaryKind.weekly) {
        // Fixed categories only: never log model text or exception details.
        final detail = e is AiFailure ? e.detail : null;
        final safe =
            detail != null &&
                RegExp(
                  r'^(summary_numeric_(headline|overview|highlights|improvements)|weekly_structure_(highlights|improvements|nextSteps))$',
                ).hasMatch(detail)
            ? detail
            : _failure(e).kind.name;
        debugPrint('PDT_WEEKLY rejected:$safe');
      }
      if (_current(epoch, uid)) _summaryError[kind] = _failure(e);
    } finally {
      if (epoch == _epoch) {
        _summaryLoading[kind] = false;
        notifyListeners();
      }
    }
  }

  // --- Study plan --------------------------------------------------------------

  Future<void> generateStudyPlan() async {
    if (planLoading) return;
    final String? uid = _ensureUser();
    if (uid == null) {
      planError = const AiFailure(AiFailureKind.signedOut);
      notifyListeners();
      return;
    }
    final int epoch = _epoch;
    planLoading = true;
    planError = null;
    notifyListeners();
    try {
      final AiContext ctx = await _requireContext(AnalysisPeriod.week);
      if (!_current(epoch, uid)) return;
      await _limiter.acquire(uid);
      if (!_current(epoch, uid)) return;
      final String raw = await _provider.generate(
        AiRequest(
          format: AiOutputFormat.studyPlan,
          prompt: AiPrompts.studyPlanPrompt(ctx),
          maxOutputTokens: 800,
          timeout: const Duration(seconds: 55),
        ),
      );
      final StudyPlan plan = validator.studyPlan(
        raw,
        ctx,
        now: _clock(),
        preferences: _preferences,
      );
      if (!_current(epoch, uid)) return;
      _plan = plan;
      await _quietly(_store.saveStudyPlan(uid, plan));
    } catch (e) {
      if (_current(epoch, uid)) planError = _failure(e);
    } finally {
      if (epoch == _epoch) {
        planLoading = false;
        notifyListeners();
      }
    }
  }

  /// The plan's daily amount as a Study goal (rounded to 30 minutes, within
  /// the Goals screen's range). Null when it would not change anything.
  double? studyGoalFromPlan(StudyPlan plan) {
    final double hours = ((plan.dailyStudyMinutes / 60) * 2).round() / 2;
    final double clamped = hours.clamp(
      SuggestedGoal.study.minHours,
      SuggestedGoal.study.maxHours,
    );
    final double? current = _context(
      AnalysisPeriod.week,
    )?.goalTargets[SuggestedGoal.study];
    return current != null && (current - clamped).abs() < 0.25 ? null : clamped;
  }

  /// Saves the plan's daily amount as the Study goal. Call only after the
  /// student confirmed.
  Future<void> applyPlanAsStudyGoal(StudyPlan plan) async {
    final String? uid = _ensureUser();
    if (!identical(plan, _plan)) {
      throw const AiFailure(AiFailureKind.malformed, 'stale plan');
    }
    final double? hours = studyGoalFromPlan(plan);
    final Future<void> Function(String, SuggestedGoal, double)? apply =
        _applyGoal;
    if (hours == null) return;
    if (uid == null || apply == null) {
      throw const AiFailure(AiFailureKind.signedOut);
    }
    final int epoch = _epoch;
    await apply(uid, SuggestedGoal.study, hours);
    if (_current(epoch, uid)) notifyListeners();
  }

  // --- Chat --------------------------------------------------------------------

  Future<void> acceptStudyPlan(StudyPlan plan) async {
    final String? uid = _ensureUser();
    if (uid == null) throw const AiFailure(AiFailureKind.signedOut);
    if (!identical(plan, _plan)) {
      throw const AiFailure(AiFailureKind.malformed, 'stale plan');
    }
    final int epoch = _epoch;
    final StudyPlan accepted = plan.accept(_clock());
    await _store.saveStudyPlan(uid, accepted);
    if (!_current(epoch, uid)) return;
    _plan = accepted;
    notifyListeners();
  }

  Future<void> sendChat(String text) async {
    final String question = text.trim();
    if (question.isEmpty || chatSending || chatClearing) return;
    final String? uid = _ensureUser();
    if (uid == null) {
      chatError = const AiFailure(AiFailureKind.signedOut);
      notifyListeners();
      return;
    }
    final DateTime now = _clock();
    final ChatMessage message = ChatMessage(
      id: 'm_${now.microsecondsSinceEpoch}',
      role: ChatRole.user,
      text: question.length > maxQuestionChars
          ? question.substring(0, maxQuestionChars)
          : question,
      createdAt: now,
    );
    _chat = <ChatMessage>[..._chat, message];
    unawaited(_quietly(_store.addChatMessage(uid, message)));
    await _ask(uid, message);
  }

  /// Asks the last unanswered question again (no duplicate user message).
  Future<void> retryChat() async {
    final String? uid = _ensureUser();
    final String? id = _unanswered;
    if (uid == null || id == null || chatSending || chatClearing) return;
    final ChatMessage? message = _chat.where((m) => m.id == id).firstOrNull;
    if (message != null) await _ask(uid, message);
  }

  Future<void> _ask(String uid, ChatMessage message) async {
    final int epoch = _epoch;
    chatSending = true;
    chatError = null;
    _unanswered = message.id;
    notifyListeners();
    try {
      await _insights.ensureAnalyses();
      final List<ChatMessage> earlier = _chat
          .takeWhile((m) => m.id != message.id)
          .toList();
      final List<AiTurn> history = earlier
          .skip(
            earlier.length > chatHistoryTurns
                ? earlier.length - chatHistoryTurns
                : 0,
          )
          .map(
            (m) => AiTurn(
              m.role,
              m.text.length > chatTurnChars
                  ? '${m.text.substring(0, chatTurnChars)}…'
                  : m.text,
            ),
          )
          .toList();
      // Gemini expects the conversation to start with a user turn.
      while (history.isNotEmpty && history.first.role != ChatRole.user) {
        history.removeAt(0);
      }
      if (!_current(epoch, uid)) return;
      await _limiter.acquire(uid);
      if (!_current(epoch, uid)) return;
      final String raw = await _provider.generate(
        AiRequest(
          format: AiOutputFormat.text,
          history: history,
          prompt: AiPrompts.chatPrompt(
            question: message.text,
            today: _context(AnalysisPeriod.day),
            week: _context(AnalysisPeriod.week),
            now: _clock(),
          ),
          maxOutputTokens: 800,
        ),
      );
      final String reply = validator.chatReply(raw);
      if (!_current(epoch, uid)) return;
      final DateTime at = _clock();
      final ChatMessage answer = ChatMessage(
        id: 'm_${at.microsecondsSinceEpoch}_a',
        role: ChatRole.assistant,
        text: reply,
        createdAt: at,
      );
      _chat = <ChatMessage>[..._chat, answer];
      _unanswered = null;
      unawaited(_quietly(_store.addChatMessage(uid, answer)));
    } catch (e) {
      if (_current(epoch, uid)) chatError = _failure(e);
    } finally {
      if (epoch == _epoch) {
        chatSending = false;
        notifyListeners();
      }
    }
  }

  Future<void> clearChat() async {
    final String? uid = _ensureUser();
    if (uid == null || chatSending || chatClearing) return;
    final int epoch = _epoch;
    chatClearing = true;
    notifyListeners();
    try {
      await _store.clearChat(uid);
      if (!_current(epoch, uid)) return;
      _chat = <ChatMessage>[];
      _unanswered = null;
      chatError = null;
    } finally {
      if (_current(epoch, uid)) {
        chatClearing = false;
        notifyListeners();
      }
    }
  }

  /// Manual probe with no student records or history. Success covers this call.
  Future<void> testConnection() async {
    final String? uid = _ensureUser();
    if (diagnosticLoading) return;
    diagnosticSucceeded = false;
    diagnosticError = null;
    if (uid == null) {
      diagnosticError = const AiFailure(AiFailureKind.signedOut);
      notifyListeners();
      return;
    }
    final int epoch = _epoch;
    diagnosticLoading = true;
    notifyListeners();
    try {
      await _limiter.acquire(uid);
      if (!_current(epoch, uid)) return;
      final String raw = await _provider.generate(
        const AiRequest(
          format: AiOutputFormat.diagnostic,
          prompt:
              'Connection diagnostic for Personal Digital Twin productivity assistant. '
              'Reply with exactly VIVORA_OK and no other text.',
          maxOutputTokens: 32,
        ),
      );
      if (!_current(epoch, uid)) return;
      if (raw.trim() != 'VIVORA_OK') {
        throw const AiFailure(AiFailureKind.malformed, 'diagnostic mismatch');
      }
      diagnosticSucceeded = true;
    } catch (e) {
      if (_current(epoch, uid)) diagnosticError = _failure(e);
    } finally {
      if (_current(epoch, uid)) {
        diagnosticLoading = false;
        notifyListeners();
      }
    }
  }

  // --- Helpers ---------------------------------------------------------------

  AiContext? _context(AnalysisPeriod period) {
    final BehaviorAnalysis? a = _insights.analysisFor(period);
    return a == null ? null : _build(a);
  }

  /// Contexts are cached per analysis object (and dropped when feedback or
  /// preferences change) so rebuilding widgets never re-encodes them.
  AiContext _build(BehaviorAnalysis a) {
    final bool? tracking = _trackingEnabled?.call();
    if (!identical(_ctxRecs, _recommendations) ||
        !identical(_ctxPrefs, _preferences) ||
        tracking != _ctxTracking ||
        _ctxCache.length > 8) {
      _ctxCache.clear();
      _ctxRecs = _recommendations;
      _ctxPrefs = _preferences;
      _ctxTracking = tracking;
    }
    return _ctxCache.putIfAbsent(
      a,
      () => builder.build(
        a,
        feedback: _recommendations,
        preferences: _preferences,
        trackingEnabled: tracking,
      ),
    );
  }

  /// The Module 3 analysis a summary is about (for the "Recorded" facts).
  BehaviorAnalysis? analysisForSummary(SummaryKind kind) {
    if (kind == SummaryKind.weekly) {
      return _insights.analysisFor(AnalysisPeriod.week);
    }
    final DateTime now = _clock();
    final DateTime day = summaryDay == SummaryDay.today
        ? now
        : DateTime(now.year, now.month, now.day - 1);
    final String key = _dayKey(day);
    return _dayCache[key] ??= _insights.analysisForDay(day);
  }

  AiContext? _summaryContext(SummaryKind kind) {
    final BehaviorAnalysis? a = analysisForSummary(kind);
    return a == null ? null : _build(a);
  }

  String _periodKey(SummaryKind kind) {
    final DateTime now = _clock();
    return _dayKey(
      kind == SummaryKind.daily && summaryDay == SummaryDay.yesterday
          ? DateTime(now.year, now.month, now.day - 1)
          : now,
    );
  }

  Future<AiContext> _requireContext(AnalysisPeriod period) async {
    await _insights.ensureAnalyses();
    final AiContext? ctx = _context(period);
    if (ctx == null || !ctx.hasData) {
      throw const AiFailure(AiFailureKind.notEnoughData);
    }
    return ctx;
  }

  static String _summaryKey(SummaryKind kind, String periodKey) =>
      '${kind.name}_$periodKey';

  static String _dayKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  static AiFailure _failure(Object e) => e is AiFailure
      ? e
      : AiFailure(AiFailureKind.unknown, e.runtimeType.toString());

  /// Storage is best effort: results stay on screen even if saving fails.
  static Future<void> _quietly(Future<void> f) async {
    try {
      await f;
    } catch (e) {
      debugPrint('AI store: ${e.runtimeType}');
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    _insights.changes.removeListener(_onInsightsChanged);
    _trackingChanges?.removeListener(_onInsightsChanged);
    super.dispose();
  }
}
