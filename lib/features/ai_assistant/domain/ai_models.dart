/// Typed results of Module 6 (AI recommendations and smart assistance).
///
/// Everything the model returns is parsed into these classes by
/// `AiResponseValidator` before it reaches a widget; nothing here is built
/// from unchecked model output.
library;

import '../../behavior_analysis/domain/behavior_models.dart';

enum RecommendationCategory {
  study('Study'),
  focus('Focus'),
  sleep('Sleep'),
  screenTime('Screen Time'),
  distractions('Distractions'),
  goals('Goals'),
  routine('Routine'),
  general('General Productivity');

  const RecommendationCategory(this.label);
  final String label;

  static RecommendationCategory? tryParse(Object? value) {
    if (value is! String) return null;
    final String v = value.trim().toLowerCase().replaceAll(
      RegExp(r'[\s_-]'),
      '',
    );
    for (final RecommendationCategory c in values) {
      if (c.name.toLowerCase() == v ||
          c.label.toLowerCase().replaceAll(' ', '') == v) {
        return c;
      }
    }
    if (v == 'generalproductivity' || v == 'productivity') return general;
    return null;
  }
}

enum RecommendationPriority {
  high(3),
  medium(2),
  low(1);

  const RecommendationPriority(this.rank);
  final int rank;

  static RecommendationPriority? tryParse(Object? value) {
    if (value is! String) return null;
    final String v = value.trim().toLowerCase();
    for (final RecommendationPriority p in values) {
      if (p.name == v) return p;
    }
    return null;
  }
}

/// Lifecycle of a recommendation after the student has seen it.
enum RecommendationStatus {
  active,
  helpful,
  notHelpful,
  completed,
  dismissed;

  static RecommendationStatus parse(Object? value) {
    for (final RecommendationStatus s in values) {
      if (s.name == value) return s;
    }
    return active;
  }

  /// Still shown in "For you".
  bool get isVisible => this == active || this == helpful || this == notHelpful;
}

class AiRecommendation {
  const AiRecommendation({
    required this.id,
    required this.title,
    required this.description,
    required this.category,
    required this.priority,
    required this.reason,
    required this.sourceMetrics,
    required this.period,
    required this.suggestion,
    required this.generatedAt,
    this.status = RecommendationStatus.active,
    this.statusChangedAt,
  });

  final String id;
  final String title;
  final String description;
  final RecommendationCategory category;
  final RecommendationPriority priority;

  /// Why it was suggested (refers to the student's recorded data).
  final String reason;

  /// Module 3 metric ids the advice rests on (all had data when generated).
  final List<String> sourceMetrics;
  final AnalysisPeriod period;

  /// The concrete next action.
  final String suggestion;
  final DateTime generatedAt;
  final RecommendationStatus status;
  final DateTime? statusChangedAt;

  AiRecommendation copyWith({
    RecommendationStatus? status,
    DateTime? statusChangedAt,
  }) => AiRecommendation(
    id: id,
    title: title,
    description: description,
    category: category,
    priority: priority,
    reason: reason,
    sourceMetrics: sourceMetrics,
    period: period,
    suggestion: suggestion,
    generatedAt: generatedAt,
    status: status ?? this.status,
    statusChangedAt: statusChangedAt ?? this.statusChangedAt,
  );

  Map<String, dynamic> toMap() => <String, dynamic>{
    'id': id,
    'title': title,
    'description': description,
    'category': category.name,
    'priority': priority.name,
    'reason': reason,
    'sourceMetrics': sourceMetrics,
    'period': period.name,
    'suggestion': suggestion,
    'generatedAt': generatedAt.toIso8601String(),
    'status': status.name,
    'statusChangedAt': statusChangedAt?.toIso8601String(),
  };

  /// Reads a stored recommendation; returns null for damaged documents
  /// instead of throwing.
  static AiRecommendation? fromMap(Map<String, dynamic> map) {
    final RecommendationCategory? category = RecommendationCategory.tryParse(
      map['category'],
    );
    final RecommendationPriority? priority = RecommendationPriority.tryParse(
      map['priority'],
    );
    final DateTime? generatedAt = DateTime.tryParse(
      '${map['generatedAt'] ?? ''}',
    );
    final String? id = map['id'] is String ? map['id'] as String : null;
    final String? title = map['title'] is String
        ? map['title'] as String
        : null;
    if (category == null ||
        priority == null ||
        generatedAt == null ||
        id == null ||
        title == null) {
      return null;
    }
    return AiRecommendation(
      id: id,
      title: title,
      description: '${map['description'] ?? ''}',
      category: category,
      priority: priority,
      reason: '${map['reason'] ?? ''}',
      sourceMetrics: <String>[
        for (final Object? m
            in (map['sourceMetrics'] is List
                ? map['sourceMetrics'] as List
                : const []))
          if (m is String) m,
      ],
      period: AnalysisPeriod.values.firstWhere(
        (p) => p.name == map['period'],
        orElse: () => AnalysisPeriod.week,
      ),
      suggestion: '${map['suggestion'] ?? ''}',
      generatedAt: generatedAt,
      status: RecommendationStatus.parse(map['status']),
      statusChangedAt: DateTime.tryParse('${map['statusChangedAt'] ?? ''}'),
    );
  }
}

/// The goals the existing Goals screen manages (same Firestore fields).
enum SuggestedGoal {
  sleep('Sleep', 'targetSleepHours', 'sleepHours', 6, 10),
  study('Study', 'targetStudyHours', 'studyHours', 0.5, 14),
  focus('Focus', 'targetFocusHours', 'deepFocusHours', 0.5, 10),
  screenLimit(
    'Screen time limit',
    'targetScreenTimeLimit',
    'appUsageMinutes',
    1,
    12,
  );

  const SuggestedGoal(
    this.label,
    this.profileField,
    this.metric,
    this.minHours,
    this.maxHours,
  );

  final String label;

  /// Field in `users/{uid}.goals`.
  final String profileField;

  /// Module 3 metric that measures progress towards it.
  final String metric;
  final double minHours;
  final double maxHours;

  /// Matches the goal id used by Module 3 [GoalAchievement.goal].
  String get achievementId => this == screenLimit ? 'appUsageLimit' : name;

  bool get isLimit => this == screenLimit;

  static SuggestedGoal? tryParse(Object? value) {
    if (value is! String) return null;
    final String v = value.trim().toLowerCase().replaceAll(
      RegExp(r'[\s_-]'),
      '',
    );
    for (final SuggestedGoal g in values) {
      if (g.name.toLowerCase() == v) return g;
    }
    if (v == 'screentime' || v == 'screen' || v == 'appusagelimit') {
      return screenLimit;
    }
    return null;
  }
}

class GoalSuggestion {
  const GoalSuggestion({
    required this.goal,
    required this.suggestedHours,
    required this.reason,
    this.currentTargetHours,
    this.observedAverageHours,
  });

  final SuggestedGoal goal;
  final double suggestedHours;
  final String reason;
  final double? currentTargetHours;

  /// Recorded average over the analysed period, in hours.
  final double? observedAverageHours;

  Map<String, dynamic> toMap() => <String, dynamic>{
    'goal': goal.name,
    'suggestedHours': suggestedHours,
    'reason': reason,
    'currentTargetHours': currentTargetHours,
    'observedAverageHours': observedAverageHours,
  };

  static GoalSuggestion? fromMap(Map<String, dynamic> map) {
    final SuggestedGoal? goal = SuggestedGoal.tryParse(map['goal']);
    final num? hours = map['suggestedHours'] is num
        ? map['suggestedHours'] as num
        : null;
    if (goal == null ||
        hours == null ||
        !hours.isFinite ||
        hours < goal.minHours ||
        hours > goal.maxHours) {
      return null;
    }
    return GoalSuggestion(
      goal: goal,
      suggestedHours: hours.toDouble(),
      reason: '${map['reason'] ?? ''}',
      currentTargetHours: map['currentTargetHours'] is num
          ? (map['currentTargetHours'] as num).toDouble()
          : null,
      observedAverageHours: map['observedAverageHours'] is num
          ? (map['observedAverageHours'] as num).toDouble()
          : null,
    );
  }
}

/// One "For you" generation: recommendations and goal suggestions from the
/// same request, so they share one context and one API call.
class AdviceBatch {
  const AdviceBatch({
    required this.recommendations,
    required this.goalSuggestions,
    required this.generatedAt,
    required this.fingerprint,
    required this.period,
  });

  final List<AiRecommendation> recommendations;
  final List<GoalSuggestion> goalSuggestions;
  final DateTime generatedAt;

  /// Fingerprint of the data the advice was based on (see AiContext).
  final String fingerprint;
  final AnalysisPeriod period;
}

enum SummaryKind {
  daily('Daily summary'),
  weekly('Weekly summary');

  const SummaryKind(this.label);
  final String label;
}

class SummaryPoint {
  const SummaryPoint({required this.label, required this.text});
  final String label;
  final String text;

  Map<String, dynamic> toMap() => <String, dynamic>{
    'label': label,
    'text': text,
  };
}

class AiSummary {
  const AiSummary({
    required this.kind,
    required this.periodKey,
    required this.headline,
    required this.overview,
    required this.highlights,
    required this.improvements,
    required this.nextSteps,
    required this.generatedAt,
    required this.fingerprint,
  });

  final SummaryKind kind;

  /// The day (yyyy-MM-dd) or the last day of the week the summary covers.
  final String periodKey;
  final String headline;
  final String overview;
  final List<SummaryPoint> highlights;
  final List<String> improvements;
  final List<String> nextSteps;
  final DateTime generatedAt;
  final String fingerprint;

  Map<String, dynamic> toMap() => <String, dynamic>{
    'kind': kind.name,
    'periodKey': periodKey,
    'headline': headline,
    'overview': overview,
    'highlights': highlights.map((h) => h.toMap()).toList(),
    'improvements': improvements,
    'nextSteps': nextSteps,
    'generatedAt': generatedAt.toIso8601String(),
    'fingerprint': fingerprint,
  };

  static AiSummary? fromMap(Map<String, dynamic> map) {
    final DateTime? at = DateTime.tryParse('${map['generatedAt'] ?? ''}');
    final SummaryKind? kind = SummaryKind.values
        .where((k) => k.name == map['kind'])
        .firstOrNull;
    if (at == null || kind == null || map['headline'] is! String) return null;
    List<String> strings(Object? v) => <String>[
      for (final Object? s in (v is List ? v : const <Object?>[]))
        if (s is String) s,
    ];
    return AiSummary(
      kind: kind,
      periodKey: '${map['periodKey'] ?? ''}',
      headline: map['headline'] as String,
      overview: '${map['overview'] ?? ''}',
      highlights: <SummaryPoint>[
        for (final Object? h
            in (map['highlights'] is List
                ? map['highlights'] as List
                : const []))
          if (h is Map && h['label'] is String && h['text'] is String)
            SummaryPoint(
              label: h['label'] as String,
              text: h['text'] as String,
            ),
      ],
      improvements: strings(map['improvements']),
      nextSteps: strings(map['nextSteps']),
      generatedAt: at,
      fingerprint: '${map['fingerprint'] ?? ''}',
    );
  }
}

class StudyPlan {
  const StudyPlan({
    required this.overview,
    required this.dailyStudyMinutes,
    required this.sessionsPerDay,
    required this.sessionMinutes,
    required this.breakMinutes,
    required this.priorities,
    required this.goalAlignment,
    required this.tips,
    required this.generatedAt,
    required this.fingerprint,
    this.preferredTime,
    this.acceptedAt,
  });

  final String overview;
  final int dailyStudyMinutes;
  final int sessionsPerDay;
  final int sessionMinutes;
  final int breakMinutes;
  final List<String> priorities;
  final String goalAlignment;
  final List<String> tips;

  /// Only the student's own stated preference (from setup), never invented.
  final String? preferredTime;
  final DateTime? acceptedAt;

  StudyPlan accept(DateTime at) => StudyPlan(
    overview: overview,
    dailyStudyMinutes: dailyStudyMinutes,
    sessionsPerDay: sessionsPerDay,
    sessionMinutes: sessionMinutes,
    breakMinutes: breakMinutes,
    priorities: priorities,
    goalAlignment: goalAlignment,
    tips: tips,
    generatedAt: generatedAt,
    fingerprint: fingerprint,
    preferredTime: preferredTime,
    acceptedAt: at,
  );
  final DateTime generatedAt;
  final String fingerprint;

  Map<String, dynamic> toMap() => <String, dynamic>{
    'acceptedAt': acceptedAt?.toIso8601String(),
    'overview': overview,
    'dailyStudyMinutes': dailyStudyMinutes,
    'sessionsPerDay': sessionsPerDay,
    'sessionMinutes': sessionMinutes,
    'breakMinutes': breakMinutes,
    'priorities': priorities,
    'goalAlignment': goalAlignment,
    'tips': tips,
    'preferredTime': preferredTime,
    'generatedAt': generatedAt.toIso8601String(),
    'fingerprint': fingerprint,
  };

  static StudyPlan? fromMap(Map<String, dynamic> map) {
    final DateTime? at = DateTime.tryParse('${map['generatedAt'] ?? ''}');
    int? i(String k) => map[k] is num && (map[k] as num).isFinite
        ? (map[k] as num).toInt()
        : null;
    if (at == null ||
        i('dailyStudyMinutes') == null ||
        i('sessionsPerDay') == null ||
        i('sessionMinutes') == null ||
        i('breakMinutes') == null) {
      return null;
    }
    List<String> strings(Object? v) => <String>[
      for (final Object? s in (v is List ? v : const <Object?>[]))
        if (s is String) s,
    ];
    return StudyPlan(
      acceptedAt: DateTime.tryParse('${map['acceptedAt'] ?? ''}'),
      overview: '${map['overview'] ?? ''}',
      dailyStudyMinutes: i('dailyStudyMinutes')!,
      sessionsPerDay: i('sessionsPerDay')!,
      sessionMinutes: i('sessionMinutes')!,
      breakMinutes: i('breakMinutes')!,
      priorities: strings(map['priorities']),
      goalAlignment: '${map['goalAlignment'] ?? ''}',
      tips: strings(map['tips']),
      preferredTime: map['preferredTime'] is String
          ? map['preferredTime'] as String
          : null,
      generatedAt: at,
      fingerprint: '${map['fingerprint'] ?? ''}',
    );
  }
}

enum ChatRole { user, assistant }

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.role,
    required this.text,
    required this.createdAt,
  });

  final String id;
  final ChatRole role;
  final String text;
  final DateTime createdAt;

  Map<String, dynamic> toMap() => <String, dynamic>{
    'role': role.name,
    'text': text,
    'createdAt': createdAt.toIso8601String(),
  };

  static ChatMessage? fromMap(String id, Map<String, dynamic> map) {
    final DateTime? at = DateTime.tryParse('${map['createdAt'] ?? ''}');
    final ChatRole? role = ChatRole.values
        .where((r) => r.name == map['role'])
        .firstOrNull;
    if (at == null || role == null || map['text'] is! String) return null;
    return ChatMessage(
      id: id,
      role: role,
      text: map['text'] as String,
      createdAt: at,
    );
  }
}
