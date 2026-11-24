import 'dart:convert';

import '../../activity_monitoring/data/models/activity_date_utils.dart';
import '../../behavior_analysis/domain/behavior_models.dart';
import 'ai_models.dart';

/// What the student told Personal Digital Twin during setup that is useful for planning.
/// Only these fields are ever sent (no name, email or institution).
class StudyPreferences {
  const StudyPreferences({
    this.preferredStudyTime = '',
    this.averageStudyHours = '',
    this.mainDailyChallenge = '',
  });

  final String preferredStudyTime;
  final String averageStudyHours;
  final String mainDailyChallenge;

  bool get isEmpty =>
      preferredStudyTime.trim().isEmpty &&
      averageStudyHours.trim().isEmpty &&
      mainDailyChallenge.trim().isEmpty;

  Map<String, dynamic> toMap() => <String, dynamic>{
    if (preferredStudyTime.trim().isNotEmpty)
      'preferredStudyTime': _clip(preferredStudyTime, 40),
    if (averageStudyHours.trim().isNotEmpty)
      'usualStudyHoursStatedAtSetup': _clip(averageStudyHours, 20),
    if (mainDailyChallenge.trim().isNotEmpty)
      'mainChallengeStatedAtSetup': _clip(mainDailyChallenge, 60),
  };
}

/// A compact, privacy-reduced description of one Module 3 analysis, ready to
/// be sent to the model.
class AiContext {
  const AiContext({
    required this.period,
    required this.periodKey,
    required this.data,
    required this.fingerprint,
    required this.metricsWithData,
    required this.goalTargets,
    required this.observedAverageHours,
    required this.hasData,
  });

  final AnalysisPeriod period;

  /// Last day covered (yyyy-MM-dd).
  final String periodKey;

  /// JSON-safe map; see [AiContextBuilder.build].
  final Map<String, dynamic> data;

  /// Changes whenever the underlying numbers change (not when only the
  /// calculation time changes); used to decide whether cached AI output is
  /// still current.
  final String fingerprint;

  /// Metric ids with at least one valid observation in the period.
  final Set<String> metricsWithData;

  /// Current goal targets in hours (only goals the student has set).
  final Map<SuggestedGoal, double> goalTargets;

  /// Recorded averages in hours for the goal metrics that have data.
  final Map<SuggestedGoal, double> observedAverageHours;

  /// False when nothing was recorded in the period: no AI request is made.
  final bool hasData;

  String toJson() => jsonEncode(data);
}

/// Builds [AiContext] from Module 3 output. Pure Dart, no I/O; the same input
/// always gives the same output.
///
/// Measured, tracked (Focus Mode), self-reported and calculated values are
/// kept in separate groups with their units, so the model can tell recorded
/// facts apart and never mistakes a manual entry for a measurement.
class AiContextBuilder {
  const AiContextBuilder({this.maxHabits = 8, this.maxApps = 5});

  final int maxHabits;
  final int maxApps;

  AiContext build(
    BehaviorAnalysis analysis, {
    List<AiRecommendation> feedback = const <AiRecommendation>[],
    StudyPreferences? preferences,
    bool? trackingEnabled,
  }) {
    final Map<String, Map<String, dynamic>> groups =
        <String, Map<String, dynamic>>{
          'measuredByPhone': <String, dynamic>{},
          'trackedByFocusMode': <String, dynamic>{},
          'loggedManually': <String, dynamic>{},
          'calculated': <String, dynamic>{},
        };
    final Set<String> withData = <String>{};
    final List<String> unavailable = <String>[];

    final List<String> metricIds = analysis.metrics.keys.toList()..sort();
    for (final String id in metricIds) {
      final MetricStats m = analysis.metrics[id]!;
      if (!m.hasData) {
        unavailable.add(id);
        continue;
      }
      withData.add(id);
      groups[_group(m.source)]![id] = <String, dynamic>{
        'unit': m.unit,
        'average': _round(m.mean),
        if (analysis.period != AnalysisPeriod.day) 'total': _round(m.total),
        if (analysis.period != AnalysisPeriod.day && m.count > 1) ...{
          'lowest': _round(m.min?.value),
          'highest': _round(m.max?.value),
        },
        'daysWithData': m.count,
      };
    }
    groups.removeWhere((_, v) => v.isEmpty);

    final Map<SuggestedGoal, double> targets = <SuggestedGoal, double>{};
    final List<Map<String, dynamic>> goals = <Map<String, dynamic>>[];
    for (final GoalAchievement g in analysis.goals) {
      final SuggestedGoal? kind = _goalFor(g.goal);
      if (kind != null) targets[kind] = g.target;
      goals.add(<String, dynamic>{
        'goal': g.goal,
        'targetHours': _round(g.target),
        'type': g.isLimit ? 'limit (stay at or below)' : 'target (reach)',
        'source': g.source.name,
        'daysMet': g.metDays,
        'daysObserved': g.observedDays,
      });
    }

    final Map<SuggestedGoal, double> observed = <SuggestedGoal, double>{};
    for (final SuggestedGoal goal in SuggestedGoal.values) {
      final MetricStats? m = analysis.metrics[goal.metric];
      if (m == null || !m.hasData || m.mean == null) continue;
      observed[goal] = m.unit == 'minutes' ? m.mean! / 60 : m.mean!;
    }

    final List<Map<String, dynamic>> trends = <Map<String, dynamic>>[
      for (final TrendResult t in analysis.trends.values)
        if (t.direction != TrendDirection.insufficientData)
          <String, dynamic>{
            'metric': t.metric,
            'unit': t.unit,
            'direction': t.direction.name,
            'currentAverage': _round(t.currentMean),
            'previousAverage': _round(t.previousMean),
            if (t.changeRatio != null)
              'changePercent': (t.changeRatio! * 100).round(),
            'comparedWith': t.basis,
          },
    ]..sort((a, b) => '${a['metric']}'.compareTo('${b['metric']}'));

    final List<Map<String, dynamic>> habits = <Map<String, dynamic>>[
      for (final DetectedHabit h in analysis.habits.take(maxHabits))
        <String, dynamic>{
          'id': h.id,
          'title': _clip(h.title, 80),
          'description': _clip(h.description, 220),
          'type': h.polarity.name,
          'evidenceQuality': h.quality.name,
          'source': h.source.name,
          if (h.isSingleDayObservation) 'singleDayObservation': true,
        },
    ];

    final List<Map<String, dynamic>> apps = <Map<String, dynamic>>[
      for (final AppUsagePattern a in analysis.apps.take(maxApps))
        <String, dynamic>{
          'app': _clip(a.appName, 40),
          'category': a.category,
          'averageMinutesPerObservedDay': _round(a.averagePerObservedDay),
          'daysUsed': a.daysUsed,
          'observedDays': a.observedDays,
        },
    ];

    final List<Map<String, dynamic>> relationships = <Map<String, dynamic>>[
      for (final BehaviorRelationship r in analysis.relationships)
        if (r.isConclusive)
          <String, dynamic>{
            'metric': r.metric,
            'statement': _clip(r.statement, 200),
            'note': 'association only, not cause and effect',
          },
    ];

    final DataQualityReport q = analysis.dataQuality;
    final Map<String, dynamic> data = <String, dynamic>{
      'period': <String, dynamic>{
        'name': analysis.period.name,
        'label': analysis.period.label,
        'firstDay': ActivityDateUtils.dayKey(analysis.start),
        'lastDay': ActivityDateUtils.dayKey(analysis.end),
        'days': analysis.period.days,
      },
      'dataQuality': <String, dynamic>{
        'automaticTracking': trackingEnabled == null
            ? 'unknown'
            : trackingEnabled
            ? 'on'
            : 'off',
        'phoneCoverage':
            'Recorded intervals only; current-day measurements are partial. Missing intervals are unknown, never zero.',
        'daysWithDailyLog': q.loggedDays,
        'daysWithPhoneMeasurement': q.measuredDays,
        'periodDays': q.periodDays,
        'overallEvidence': _overallEvidence(analysis),
        if (q.warnings.isNotEmpty)
          'warnings': q.warnings.take(8).map((w) => _clip(w, 200)).toList(),
        if (q.excludedRecords.isNotEmpty) 'excludedRecords': q.excludedRecords,
        if (q.missing.isNotEmpty)
          'missing': q.missing.map((k, v) => MapEntry(k, _clip(v, 160))),
      },
      ...groups,
      if (unavailable.isNotEmpty) 'noDataFor': unavailable,
      'loggingStreakDays': analysis.loggingStreak,
      'bestLoggingStreakDays': analysis.bestLoggingStreak,
      if (goals.isNotEmpty) 'goals': goals else 'goals': 'none set',
      if (trends.isNotEmpty) 'trends': trends,
      if (habits.isNotEmpty) 'detectedPatterns': habits,
      if (apps.isNotEmpty) 'topApps': apps,
      if (relationships.isNotEmpty) 'scoreAssociations': relationships,
      if (preferences != null && !preferences.isEmpty)
        'statedPreferences': preferences.toMap(),
      ..._feedback(feedback),
    };

    // The fingerprint ignores feedback and calculation time so cached advice
    // is only marked out of date when the student's records change.
    final Map<String, dynamic> stable = Map<String, dynamic>.of(data)
      ..remove('previousAdviceFeedback');
    return AiContext(
      period: analysis.period,
      periodKey: ActivityDateUtils.dayKey(analysis.end),
      data: data,
      fingerprint: fingerprintOf(jsonEncode(stable)),
      metricsWithData: withData,
      goalTargets: targets,
      observedAverageHours: observed,
      hasData: analysis.hasAnyData && withData.isNotEmpty,
    );
  }

  /// Previous feedback, so the model avoids repeating dismissed or unhelpful
  /// advice. Titles only; capped.
  Map<String, dynamic> _feedback(List<AiRecommendation> feedback) {
    List<String> titles(RecommendationStatus s) => feedback
        .where((r) => r.status == s)
        .take(6)
        .map((r) => _clip(r.title, 80))
        .toList();
    final Map<String, dynamic> out = <String, dynamic>{
      if (titles(RecommendationStatus.dismissed).isNotEmpty)
        'dismissed': titles(RecommendationStatus.dismissed),
      if (titles(RecommendationStatus.notHelpful).isNotEmpty)
        'markedNotHelpful': titles(RecommendationStatus.notHelpful),
      if (titles(RecommendationStatus.completed).isNotEmpty)
        'alreadyCompleted': titles(RecommendationStatus.completed),
      if (titles(RecommendationStatus.helpful).isNotEmpty)
        'markedHelpful': titles(RecommendationStatus.helpful),
    };
    return out.isEmpty
        ? const <String, dynamic>{}
        : <String, dynamic>{'previousAdviceFeedback': out};
  }

  static String _group(DataSource s) => switch (s) {
    DataSource.measured => 'measuredByPhone',
    DataSource.tracked => 'trackedByFocusMode',
    DataSource.selfReported => 'loggedManually',
    DataSource.mixed => 'calculated',
  };

  static SuggestedGoal? _goalFor(String id) {
    for (final SuggestedGoal g in SuggestedGoal.values) {
      if (g.achievementId == id) return g;
    }
    return null;
  }

  static String _overallEvidence(BehaviorAnalysis a) {
    final int days = a.dataQuality.loggedDays > a.dataQuality.measuredDays
        ? a.dataQuality.loggedDays
        : a.dataQuality.measuredDays;
    if (days == 0) return 'none';
    if (a.period == AnalysisPeriod.day) return 'single day';
    final double share = days / a.period.days;
    if (share >= 0.7) return 'strong';
    if (share >= 0.4) return 'moderate';
    return 'limited';
  }

  static num? _round(double? v) {
    if (v == null || v.isNaN || v.isInfinite) return null;
    final double r = (v * 10).roundToDouble() / 10;
    return r == r.roundToDouble() ? r.round() : r;
  }
}

String _clip(String s, int max) {
  final String t = s.trim();
  return t.length <= max ? t : '${t.substring(0, max - 1)}…';
}

/// 64-bit FNV-1a as hex; stable across runs and platforms (not for security).
String fingerprintOf(String input) {
  BigInt hash = BigInt.parse('cbf29ce484222325', radix: 16);
  final BigInt prime = BigInt.parse('100000001b3', radix: 16);
  final BigInt mask = (BigInt.one << 64) - BigInt.one;
  for (final int byte in utf8.encode(input)) {
    hash = ((hash ^ BigInt.from(byte)) * prime) & mask;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}
