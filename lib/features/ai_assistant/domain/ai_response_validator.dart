import 'dart:convert';

import 'ai_context_builder.dart';
import 'ai_failure.dart';
import 'ai_models.dart';

/// Turns raw model output into typed, bounded values. Model output is treated
/// as untrusted input: unknown fields are ignored, unsupported values dropped,
/// long text shortened, and anything unusable reported as
/// [AiFailureKind.malformed] rather than shown.
class AiResponseValidator {
  const AiResponseValidator();

  static const int maxRecommendations = 5;
  static const int maxGoalSuggestions = 3;
  static const int maxChatChars = 2000;

  /// Fields the model may cite besides metric ids.
  static const Set<String> _extraSources = <String>{
    'loggingStreakDays',
    'goals',
    'trends',
    'detectedPatterns',
    'topApps',
  };

  Map<String, dynamic> decodeObject(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      throw const AiFailure(AiFailureKind.malformed, 'empty response');
    }
    if (raw.length > 64000) {
      throw const AiFailure(AiFailureKind.malformed, 'response too large');
    }
    String text = raw.trim();
    // Some models wrap JSON in a Markdown fence even in JSON mode.
    final RegExpMatch? fence = RegExp(
      r'^```(?:json)?\s*([\s\S]*?)\s*```$',
    ).firstMatch(text);
    if (fence != null) text = fence.group(1)!;
    try {
      final Object? decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) return decoded;
    } on FormatException catch (e) {
      throw AiFailure(AiFailureKind.malformed, 'invalid JSON: ${e.message}');
    }
    throw const AiFailure(AiFailureKind.malformed, 'not a JSON object');
  }

  // --- Recommendations and goal suggestions ---------------------------------

  AdviceBatch advice(
    String? raw,
    AiContext context, {
    required DateTime now,
    Iterable<String> suppressedTitles = const <String>[],
  }) {
    final Map<String, dynamic> json = decodeObject(raw);
    final Object? recs = json['recommendations'];
    if (recs is! List) {
      throw const AiFailure(AiFailureKind.malformed, 'recommendations missing');
    }
    final Set<String> suppressed = suppressedTitles.map(_norm).toSet();
    final Set<String> seen = <String>{};
    final List<AiRecommendation> out = <AiRecommendation>[];
    int index = 0;
    for (final Object? item in recs) {
      if (item is! Map<String, dynamic>) continue;
      final AiRecommendation? r = _recommendation(item, context, now, index++);
      if (r == null) continue;
      final String key = _norm(r.title);
      if (suppressed.contains(key) || !seen.add(key)) continue;
      out.add(r);
    }
    out.sort((a, b) => b.priority.rank.compareTo(a.priority.rank));

    final List<GoalSuggestion> goals = <GoalSuggestion>[];
    final Object? rawGoals = json['goalSuggestions'];
    if (rawGoals is List) {
      final Set<SuggestedGoal> used = <SuggestedGoal>{};
      for (final Object? g in rawGoals) {
        if (g is! Map<String, dynamic>) continue;
        final GoalSuggestion? s = goalSuggestion(g, context);
        if (s != null && used.add(s.goal)) goals.add(s);
        if (goals.length == maxGoalSuggestions) break;
      }
    }

    return AdviceBatch(
      recommendations: out.take(maxRecommendations).toList(),
      goalSuggestions: goals,
      generatedAt: now,
      fingerprint: context.fingerprint,
      period: context.period,
    );
  }

  AiRecommendation? _recommendation(
    Map<String, dynamic> m,
    AiContext context,
    DateTime now,
    int index,
  ) {
    final RecommendationCategory? category = RecommendationCategory.tryParse(
      m['category'],
    );
    final String? title = _text(m['title'], 80);
    final String? description = _text(m['description'], 320);
    final String? suggestion = _text(m['suggestion'], 240);
    final String? reason = _text(m['reason'], 280);
    if (category == null ||
        title == null ||
        description == null ||
        suggestion == null ||
        reason == null) {
      return null;
    }
    // Advice must rest on data that was actually recorded.
    final List<String> sources = <String>{
      for (final Object? s
          in (m['sourceMetrics'] is List
              ? m['sourceMetrics'] as List
              : const []))
        if (s is String &&
            (context.metricsWithData.contains(s.trim()) ||
                _extraSources.contains(s.trim())))
          s.trim(),
    }.toList();
    if (!sources.any(context.metricsWithData.contains)) return null;
    return AiRecommendation(
      id: 'rec_${now.millisecondsSinceEpoch}_$index',
      title: title,
      description: description,
      category: category,
      priority:
          RecommendationPriority.tryParse(m['priority']) ??
          RecommendationPriority.medium,
      // Supporting numerical evidence is rendered from recorded metrics,
      // never copied from the model's claimed statistics.
      reason: sources
          .where(context.metricsWithData.contains)
          .take(3)
          .map((id) {
            final Map<String, dynamic>? metric = _metric(context, id);
            final String label = id
                .replaceAllMapped(
                  RegExp(r'([a-z])([A-Z])'),
                  (m) => '${m[1]} ${m[2]}',
                )
                .toLowerCase();
            return '$label: recorded average ${metric?['average']} ${metric?['unit']} '
                '(${metric?['daysWithData']} recorded days).';
          })
          .join(' '),
      sourceMetrics: sources,
      period: context.period,
      suggestion: suggestion,
      generatedAt: now,
    );
  }

  /// Accepts a suggested goal only when it is gradual and grounded in data:
  /// at least 3 recorded days, within the Goals screen's range, a real
  /// change from the current target, and no more than about one hour away
  /// from what the student actually recorded.
  GoalSuggestion? goalSuggestion(Map<String, dynamic> m, AiContext context) {
    final SuggestedGoal? goal = SuggestedGoal.tryParse(m['goal']);
    final num? raw = m['suggestedHours'] is num
        ? m['suggestedHours'] as num
        : num.tryParse('${m['suggestedHours']}');
    final String? reason = _text(m['reason'], 240);
    if (goal == null || raw == null || reason == null) return null;
    if (raw.isNaN || raw.isInfinite) return null;
    final Map<String, dynamic>? metric = _metric(context, goal.metric);
    final double? observed = context.observedAverageHours[goal];
    if (metric == null ||
        observed == null ||
        ((metric['daysWithData'] as num?) ?? 0) < 3) {
      return null;
    }
    final double hours = (raw * 2).round() / 2;
    if (hours < goal.minHours || hours > goal.maxHours) return null;
    final double? current = context.goalTargets[goal];
    if (current != null && (hours - current).abs() < 0.5) return null;

    final bool gradual = goal.isLimit
        // Reduce screen time gradually: not below ~70% of current use.
        ? hours >= observed * 0.7 - 0.25 && hours <= observed + 0.5
        : hours >= observed - 1.0 && hours <= observed + 1.0;
    if (!gradual) return null;
    return GoalSuggestion(
      goal: goal,
      suggestedHours: hours,
      reason: reason,
      currentTargetHours: current,
      // Preserve the recorded mean; round only when formatting minutes in UI.
      observedAverageHours: observed,
    );
  }

  static Map<String, dynamic>? _metric(AiContext c, String id) {
    for (final String group in const <String>[
      'measuredByPhone',
      'trackedByFocusMode',
      'loggedManually',
      'calculated',
    ]) {
      final Object? g = c.data[group];
      if (g is Map<String, dynamic> && g[id] is Map<String, dynamic>) {
        return g[id] as Map<String, dynamic>;
      }
    }
    return null;
  }

  // --- Summaries -------------------------------------------------------------

  AiSummary summary(
    String? raw,
    SummaryKind kind,
    AiContext context, {
    required DateTime now,
  }) {
    final Map<String, dynamic> json = decodeObject(raw);
    final String? headline = _text(json['headline'], 110);
    final String? overview = _text(json['overview'], 700);
    if (headline == null || overview == null) {
      throw const AiFailure(AiFailureKind.malformed, 'summary text missing');
    }
    if (kind == SummaryKind.weekly) {
      // Reject incomplete structures instead of silently presenting a partial
      // weekly response as successfully validated. Optional content uses [].
      for (final field in ['highlights', 'improvements', 'nextSteps']) {
        final items = json[field];
        if (items is! List ||
            items.any(
              (item) => field == 'highlights'
                  ? item is! Map<String, dynamic> ||
                        _text(item['label'], 32) == null ||
                        _text(item['text'], 260) == null
                  : item is! String || item.trim().isEmpty,
            )) {
          throw AiFailure(AiFailureKind.malformed, 'weekly_structure_$field');
        }
      }
    }
    final List<SummaryPoint> highlights = <SummaryPoint>[
      for (final Object? h
          in (json['highlights'] is List
              ? json['highlights'] as List
              : const []))
        if (h is Map<String, dynamic> &&
            _text(h['label'], 32) != null &&
            _text(h['text'], 260) != null)
          SummaryPoint(
            label: _text(h['label'], 32)!,
            text: _text(h['text'], 260)!,
          ),
    ].take(kind == SummaryKind.weekly ? 7 : 4).toList();
    final List<String> improvements = _strings(json['improvements'], 3, 220);
    // Facts are rendered by the UI from Module 3/4. Keep generated prose
    // qualitative rather than accepting model-authored numerical statistics.
    final factualFields = <String, String>{
      'headline': headline,
      'overview': overview,
      'highlights': highlights.expand((h) => [h.label, h.text]).join(' '),
      'improvements': improvements.join(' '),
    };
    final numericalClaim = RegExp(
      r'\d|\b(?:zero|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred|thousand|half|quarter)\s+(?:hours?|minutes?|percent|points?|days?|sessions?)\b',
      caseSensitive: false,
    );
    for (final field in factualFields.entries) {
      if (numericalClaim.hasMatch(field.value)) {
        throw AiFailure(
          AiFailureKind.malformed,
          'summary_numeric_${field.key}',
        );
      }
    }
    return AiSummary(
      kind: kind,
      periodKey: context.periodKey,
      headline: headline,
      overview: overview,
      highlights: highlights,
      improvements: improvements,
      nextSteps: _strings(
        json['nextSteps'],
        kind == SummaryKind.daily ? 2 : 3,
        220,
      ),
      generatedAt: now,
      fingerprint: context.fingerprint,
    );
  }

  // --- Study plan ------------------------------------------------------------

  StudyPlan studyPlan(
    String? raw,
    AiContext context, {
    required DateTime now,
    StudyPreferences? preferences,
  }) {
    final Map<String, dynamic> json = decodeObject(raw);
    int? i(String k) {
      final Object? v = json[k];
      if (v is num && !v.isNaN && !v.isInfinite) return v.round();
      return int.tryParse('$v');
    }

    final int? daily = i('dailyStudyMinutes');
    final int? sessions = i('sessionsPerDay');
    final int? length = i('sessionMinutes');
    final int? breaks = i('breakMinutes');
    final String? overview = _text(json['overview'], 500);
    if (daily == null ||
        sessions == null ||
        length == null ||
        breaks == null ||
        overview == null) {
      throw const AiFailure(AiFailureKind.malformed, 'plan fields missing');
    }
    // Realistic bounds: sessions Focus Mode supports, short breaks, and a
    // daily amount close to what the student already does or aims for.
    final double observedStudy =
        context.observedAverageHours[SuggestedGoal.study] ?? 0;
    final double target = context.goalTargets[SuggestedGoal.study] ?? 0;
    final int ceiling =
        ((observedStudy > target ? observedStudy : target) * 60 + 90)
            .clamp(120, 600)
            .round();
    final bool valid =
        daily >= 15 &&
        daily <= ceiling &&
        sessions >= 1 &&
        sessions <= 8 &&
        length >= 10 &&
        length <= 90 &&
        breaks >= 3 &&
        breaks <= 30 &&
        sessions * length == daily;
    if (!valid) {
      throw const AiFailure(AiFailureKind.malformed, 'unrealistic plan');
    }
    final String preferred = preferences?.preferredStudyTime.trim() ?? '';
    return StudyPlan(
      overview: overview,
      dailyStudyMinutes: daily,
      sessionsPerDay: sessions,
      sessionMinutes: length,
      breakMinutes: breaks,
      priorities: _strings(json['priorities'], 4, 160),
      goalAlignment: _text(json['goalAlignment'], 300) ?? '',
      tips: _strings(json['tips'], 3, 200),
      // Never taken from the model: only what the student said at setup.
      preferredTime: preferred.isEmpty ? null : preferred,
      generatedAt: now,
      fingerprint: context.fingerprint,
    );
  }

  // --- Chat -------------------------------------------------------------------

  String chatReply(String? raw) {
    final String text = _clean(raw ?? '');
    if (text.isEmpty) {
      throw const AiFailure(AiFailureKind.malformed, 'empty reply');
    }
    return text.length <= maxChatChars
        ? text
        : '${_cutAtWord(text, maxChatChars)}…';
  }

  // --- Helpers ---------------------------------------------------------------

  /// Cleans a string field; null when missing/empty or absurdly long (a sign
  /// of a broken response). Moderately long text is shortened at a word.
  static String? _text(Object? value, int max) {
    if (value is! String) return null;
    final String t = _clean(value);
    if (t.isEmpty || t.length > max * 4) return null;
    return t.length <= max ? t : '${_cutAtWord(t, max - 1)}…';
  }

  static List<String> _strings(Object? value, int maxItems, int maxChars) =>
      <String>[
        for (final Object? s in (value is List ? value : const <Object?>[]))
          if (_text(s, maxChars) != null) _text(s, maxChars)!,
      ].take(maxItems).toList();

  /// Removes control characters and Markdown emphasis; keeps line breaks.
  static String _clean(String s) => s
      .replaceAll(RegExp(r'[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]'), '')
      .replaceAll(RegExp(r'\*\*|__'), '')
      .replaceAll(RegExp(r'[ \t]+'), ' ')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();

  static String _cutAtWord(String s, int max) {
    final String cut = s.substring(0, max);
    final int space = cut.lastIndexOf(' ');
    return (space > max * 0.6 ? cut.substring(0, space) : cut).trimRight();
  }

  static String _norm(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
}
