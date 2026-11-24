import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/vivora_palette.dart';
import '../../../activity_monitoring/data/models/app_usage_entry.dart';
import '../../../behavior_analysis/domain/behavior_models.dart';
import '../../domain/ai_failure.dart';
import '../../domain/ai_models.dart';

/// Friendly names for Module 3 metric ids, with where the value comes from.
String metricLabel(String id) => switch (id) {
  'appUsageMinutes' => 'App usage (measured)',
  'screenUnlockedMinutes' => 'Screen unlocked (measured)',
  'unlocks' => 'Phone unlocks (measured)',
  'productiveAppMinutes' => 'Productive apps (measured)',
  'distractingAppMinutes' => 'Distracting apps (measured)',
  'neutralAppMinutes' => 'Neutral apps (measured)',
  'uncategorizedAppMinutes' => 'Uncategorised apps (measured)',
  'sensorActiveMinutes' => 'Walking/running (measured)',
  'loggedScreenHours' => 'Screen time (logged)',
  'studyHours' => 'Study (logged)',
  'deepFocusHours' => 'Deep focus (logged)',
  'focusSessionMinutes' => 'Focus Mode sessions',
  'sleepHours' => 'Sleep (logged)',
  'routineRating' => 'Routine rating (logged)',
  'activityRating' => 'Activity rating (logged)',
  'score' => 'Productivity score',
  _ => id,
};

String formatHours(double hours) => formatMinutes((hours * 60).round());

/// "Today, 14:05" / "Yesterday, 09:30" / "12 Oct, 18:00".
String formatWhen(BuildContext context, DateTime at, {DateTime? now}) {
  final DateTime n = now ?? DateTime.now();
  final String time = TimeOfDay.fromDateTime(at).format(context);
  final DateTime d = DateTime(at.year, at.month, at.day);
  final DateTime today = DateTime(n.year, n.month, n.day);
  final int days = today.difference(d).inDays;
  if (days == 0) return 'Today, $time';
  if (days == 1) return 'Yesterday, $time';
  const List<String> months = <String>[
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${at.day} ${months[at.month - 1]}, $time';
}

/// Deterministic facts straight from Module 3 (no AI), so the student can
/// compare the AI's wording with the recorded numbers.
List<(String, String)> recordedFacts(BehaviorAnalysis a) {
  final List<(String, String)> out = <(String, String)>[];
  void add(String id, String label, String Function(double) fmt) {
    final MetricStats? m = a.metrics[id];
    if (m == null || !m.hasData || m.mean == null) return;
    final String days = a.period == AnalysisPeriod.day
        ? ''
        : ' (avg of ${m.count} ${m.count == 1 ? 'day' : 'days'})';
    out.add((label, '${fmt(m.mean!)}$days'));
  }

  String mins(double v) => formatMinutes(v.round());
  add('score', 'Productivity score', (v) => '${v.round()}/100');
  add('studyHours', 'Study (logged)', formatHours);
  add('deepFocusHours', 'Deep focus (logged)', formatHours);
  add('focusSessionMinutes', 'Focus Mode', mins);
  add('sleepHours', 'Sleep (logged)', formatHours);
  add('appUsageMinutes', 'App usage (measured)', mins);
  add('distractingAppMinutes', 'Distracting apps (measured)', mins);
  if (a.period != AnalysisPeriod.day) {
    out.add((
      'Days logged',
      '${a.dataQuality.loggedDays} of ${a.dataQuality.periodDays}',
    ));
  }
  return out;
}

/// Small rounded label.
class AiTag extends StatelessWidget {
  const AiTag({super.key, required this.text, this.icon, this.color});

  final String text;
  final IconData? icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final Color c = color ?? context.brand;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: 14, color: c),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: context.palette.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A plain surface card used throughout Module 6.
class AiCard extends StatelessWidget {
  const AiCard({super.key, required this.child, this.highlight = false});

  final Widget child;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final VivoraPalette p = context.palette;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(Space.lg),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(Radii.lg),
        border: Border.all(
          color: highlight ? context.brand.withValues(alpha: 0.5) : p.border,
        ),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: p.shadow,
            blurRadius: 18,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: child,
    );
  }
}

/// Generate / refresh call to action with an explanation.
class AiActionCard extends StatelessWidget {
  const AiActionCard({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    required this.actionLabel,
    required this.onAction,
    this.loading = false,
  });

  final IconData icon;
  final String title;
  final String message;
  final String actionLabel;
  final VoidCallback? onAction;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return AiCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(icon, color: context.brand),
              const SizedBox(width: Space.sm),
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: Space.sm),
          Text(message, style: TextStyle(color: context.palette.textSecondary)),
          const SizedBox(height: Space.md),
          if (loading)
            const AiLoading(
              message:
                  'Personal Digital Twin AI is reading your recorded data…',
            )
          else
            FilledButton.icon(
              onPressed: onAction,
              icon: const Icon(Icons.auto_awesome_rounded),
              label: Text(actionLabel),
            ),
        ],
      ),
    );
  }
}

class AiLoading extends StatelessWidget {
  const AiLoading({super.key, required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      label: message,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const LinearProgressIndicator(),
          const SizedBox(height: Space.sm),
          Text(
            message,
            style: TextStyle(
              color: context.palette.textSecondary,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}

/// Friendly failure with Retry where retrying can help.
class AiErrorBanner extends StatelessWidget {
  const AiErrorBanner({super.key, required this.failure, this.onRetry});

  final AiFailure failure;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final VivoraPalette p = context.palette;
    final bool data = failure.kind == AiFailureKind.notEnoughData;
    final Color accent = data ? p.warning : p.danger;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(Space.md),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: accent.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            data ? Icons.info_outline_rounded : Icons.cloud_off_rounded,
            color: accent,
          ),
          const SizedBox(width: Space.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(failure.message, style: TextStyle(color: p.textPrimary)),
                if (failure.canRetry && onRetry != null)
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: TextButton.icon(
                      onPressed: onRetry,
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('Retry'),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// "Generated … · AI" line, with an out-of-date notice when the student's
/// records changed after generation.
class AiMetaLine extends StatelessWidget {
  const AiMetaLine({
    super.key,
    required this.generatedAt,
    required this.stale,
    this.extra,
  });

  final DateTime generatedAt;
  final bool stale;
  final String? extra;

  @override
  Widget build(BuildContext context) {
    final VivoraPalette p = context.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Wrap(
          spacing: Space.sm,
          runSpacing: Space.xs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            const AiTag(text: 'AI-generated', icon: Icons.auto_awesome_rounded),
            Text(
              'Generated ${formatWhen(context, generatedAt)}${extra == null ? '' : ' · $extra'}',
              style: TextStyle(color: p.textSecondary, fontSize: 12.5),
            ),
          ],
        ),
        if (stale) ...<Widget>[
          const SizedBox(height: Space.sm),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(Icons.update_rounded, size: 18, color: p.warning),
              const SizedBox(width: Space.xs),
              Expanded(
                child: Text(
                  'New data has been recorded since this was generated. Refresh to include it.',
                  style: TextStyle(color: p.textPrimary, fontSize: 12.5),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

Color categoryColor(RecommendationCategory c) => switch (c) {
  RecommendationCategory.study => AppColors.secondaryCyan,
  RecommendationCategory.focus => AppColors.accentGreen,
  RecommendationCategory.sleep => AppColors.softPurple,
  RecommendationCategory.screenTime => AppColors.primaryBlue,
  RecommendationCategory.distractions => const Color(0xFFF59E0B),
  RecommendationCategory.goals => AppColors.accentGreen,
  RecommendationCategory.routine => AppColors.secondaryCyan,
  RecommendationCategory.general => AppColors.primaryBlue,
};

IconData categoryIcon(RecommendationCategory c) => switch (c) {
  RecommendationCategory.study => Icons.auto_stories_rounded,
  RecommendationCategory.focus => Icons.center_focus_strong_rounded,
  RecommendationCategory.sleep => Icons.nightlight_round,
  RecommendationCategory.screenTime => Icons.phone_android_rounded,
  RecommendationCategory.distractions => Icons.notifications_off_rounded,
  RecommendationCategory.goals => Icons.flag_rounded,
  RecommendationCategory.routine => Icons.event_repeat_rounded,
  RecommendationCategory.general => Icons.trending_up_rounded,
};

/// One AI recommendation with its evidence and feedback actions.
class AiRecommendationCard extends StatelessWidget {
  const AiRecommendationCard({
    super.key,
    required this.recommendation,
    required this.onFeedback,
  });

  final AiRecommendation recommendation;
  final void Function(RecommendationStatus status) onFeedback;

  @override
  Widget build(BuildContext context) {
    final AiRecommendation r = recommendation;
    final VivoraPalette p = context.palette;
    final Color c = categoryColor(r.category);
    TextStyle label = TextStyle(
      color: p.textPrimary,
      fontWeight: FontWeight.w700,
    );
    return AiCard(
      highlight: r.priority == RecommendationPriority.high,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Wrap(
            spacing: Space.sm,
            runSpacing: Space.xs,
            children: <Widget>[
              AiTag(
                text: r.category.label,
                icon: categoryIcon(r.category),
                color: c,
              ),
              AiTag(
                text:
                    '${r.priority.name[0].toUpperCase()}${r.priority.name.substring(1)} priority',
                color: r.priority == RecommendationPriority.high
                    ? p.warning
                    : p.textSecondary,
              ),
            ],
          ),
          const SizedBox(height: Space.sm),
          Text(
            r.title,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: Space.xs),
          Text(r.description, style: TextStyle(color: p.textPrimary)),
          const SizedBox(height: Space.sm),
          Text.rich(
            TextSpan(
              children: <InlineSpan>[
                TextSpan(text: 'Try: ', style: label),
                TextSpan(text: r.suggestion),
              ],
            ),
            style: TextStyle(color: p.textPrimary),
          ),
          const SizedBox(height: Space.xs),
          Text.rich(
            TextSpan(
              children: <InlineSpan>[
                TextSpan(text: 'Why: ', style: label),
                TextSpan(text: r.reason),
              ],
            ),
            style: TextStyle(color: p.textSecondary),
          ),
          const SizedBox(height: Space.xs),
          Text(
            'Based on: ${r.sourceMetrics.map(metricLabel).join(', ')} · ${r.period.label}',
            style: TextStyle(color: p.textSecondary, fontSize: 12),
          ),
          const SizedBox(height: Space.sm),
          Wrap(
            spacing: Space.xs,
            runSpacing: Space.xs,
            children: <Widget>[
              _FeedbackChip(
                icon: Icons.thumb_up_alt_outlined,
                label: 'Helpful',
                selected: r.status == RecommendationStatus.helpful,
                onTap: () => onFeedback(RecommendationStatus.helpful),
              ),
              _FeedbackChip(
                icon: Icons.thumb_down_alt_outlined,
                label: 'Not helpful',
                selected: r.status == RecommendationStatus.notHelpful,
                onTap: () => onFeedback(RecommendationStatus.notHelpful),
              ),
              _FeedbackChip(
                icon: Icons.check_circle_outline_rounded,
                label: 'Done',
                selected: false,
                onTap: () => onFeedback(RecommendationStatus.completed),
              ),
              _FeedbackChip(
                icon: Icons.close_rounded,
                label: 'Dismiss',
                selected: false,
                onTap: () => onFeedback(RecommendationStatus.dismissed),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _FeedbackChip extends StatelessWidget {
  const _FeedbackChip({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      selected: selected,
      button: true,
      child: FilterChip(
        avatar: Icon(icon, size: 18),
        label: Text(label),
        selected: selected,
        showCheckmark: false,
        onSelected: (_) => onTap(),
      ),
    );
  }
}

/// A suggested goal change with Apply / Not now.
class GoalSuggestionCard extends StatelessWidget {
  const GoalSuggestionCard({
    super.key,
    required this.suggestion,
    required this.onAccept,
    required this.onReject,
    this.busy = false,
  });

  final GoalSuggestion suggestion;
  final VoidCallback onAccept;
  final VoidCallback onReject;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final GoalSuggestion s = suggestion;
    final VivoraPalette p = context.palette;
    final String from = s.currentTargetHours == null
        ? 'not set'
        : formatHours(s.currentTargetHours!);
    return AiCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '${s.goal.label} goal',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: Space.xs),
          Text(
            'Current: $from  →  Suggested: ${formatHours(s.suggestedHours)}${s.goal.isLimit ? ' limit' : ''}',
            style: TextStyle(color: p.textPrimary, fontWeight: FontWeight.w600),
          ),
          if (s.observedAverageHours != null)
            Text(
              'Your recorded average: ${formatHours(s.observedAverageHours!)} per day',
              style: TextStyle(color: p.textSecondary, fontSize: 12.5),
            ),
          const SizedBox(height: Space.sm),
          Text(s.reason, style: TextStyle(color: p.textPrimary)),
          const SizedBox(height: Space.sm),
          Wrap(
            spacing: Space.sm,
            runSpacing: Space.xs,
            children: <Widget>[
              FilledButton(
                onPressed: busy ? null : onAccept,
                child: const Text('Apply goal'),
              ),
              TextButton(
                onPressed: busy ? null : onReject,
                child: const Text('Not now'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Section title used inside the assistant tabs.
class AiSectionTitle extends StatelessWidget {
  const AiSectionTitle(this.title, {super.key, this.subtitle, this.trailing});

  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: Space.xl, bottom: Space.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(title, style: Theme.of(context).textTheme.titleLarge),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    style: TextStyle(
                      color: context.palette.textSecondary,
                      fontSize: 13,
                    ),
                  ),
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}
