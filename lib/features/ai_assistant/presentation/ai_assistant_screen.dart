import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import '../../../core/routes/app_routes.dart';
import '../../../core/theme/vivora_palette.dart';
import '../../../core/widgets/app_bar_title.dart';
import '../../../core/widgets/gradient_background.dart';
import '../../activity_monitoring/data/models/app_usage_entry.dart';
import '../../insights/services/recommendation_service.dart';
import '../ai_assistant_module.dart';
import '../application/ai_assistant_controller.dart';
import '../domain/ai_failure.dart';
import '../domain/ai_models.dart';
import 'ai_chat_screen.dart';
import 'widgets/ai_widgets.dart';

/// Module 6 home: personalised advice, summaries and a study plan, plus the
/// entry to the chat. Opening it never calls the AI; it shows saved results
/// and the student starts each generation explicitly.
class AiAssistantScreen extends StatefulWidget {
  const AiAssistantScreen({
    super.key,
    this.controller,
    this.showAppBar = false,
  });

  /// Defaults to the app-wide controller; injectable for tests.
  final AiAssistantController? controller;
  final bool showAppBar;

  @override
  State<AiAssistantScreen> createState() => _AiAssistantScreenState();
}

class _AiAssistantScreenState extends State<AiAssistantScreen> {
  late final AiAssistantController _c =
      widget.controller ?? AiAssistantModule.controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_c.open()));
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) =>
          AiAssistantView(controller: _c, showAppBar: widget.showAppBar),
    );
  }
}

class AiAssistantView extends StatelessWidget {
  const AiAssistantView({
    super.key,
    required this.controller,
    this.showAppBar = false,
  });

  final AiAssistantController controller;
  final bool showAppBar;

  void _openChat(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AiChatScreen(controller: controller),
      ),
    );
  }

  void _diagnostics(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => AnimatedBuilder(
        animation: controller,
        builder: (context, _) => AlertDialog(
          scrollable: true,
          title: const Text('AI connection test'),
          content: Text(
            'Provider: Direct Gemini Developer API\n'
            'Model: ${controller.modelName}\n\n'
            'Sends one small request without student records. '
            'Uses the same Gemini key and request budget as the assistant.\n\n'
            '${controller.diagnosticLoading
                ? 'Testing…'
                : controller.diagnosticSucceeded
                ? 'Success: model responded and the response was validated.'
                : controller.diagnosticError != null
                ? '${controller.diagnosticError!.kind.name}: ${controller.diagnosticError!.message}'
                : 'Not tested.'}',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
            FilledButton(
              onPressed: controller.diagnosticLoading
                  ? null
                  : controller.testConnection,
              child: const Text('Test connection'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final VivoraPalette p = context.palette;
    // A compact header keeps the tabs on screen even on small phones with
    // large text; everything else scrolls inside each tab.
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: showAppBar
            ? AppBar(
                title: const AppBarTitle('Personal Digital Twin AI'),
                actions: <Widget>[
                  if (kDebugMode)
                    IconButton(
                      tooltip: 'AI diagnostics',
                      onPressed: () => _diagnostics(context),
                      icon: const Icon(Icons.network_check),
                    ),
                  IconButton(
                    tooltip: 'Ask Personal Digital Twin AI',
                    onPressed: () => _openChat(context),
                    icon: const Icon(Icons.forum_rounded),
                  ),
                ],
              )
            : null,
        body: GradientBackground(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (!showAppBar)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: AppBarTitle(
                          'Personal Digital Twin AI',
                          style: Theme.of(context).textTheme.headlineMedium
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                      ),
                      const SizedBox(width: Space.sm),
                      if (kDebugMode)
                        IconButton(
                          tooltip: 'AI diagnostics',
                          onPressed: () => _diagnostics(context),
                          icon: const Icon(Icons.network_check),
                        ),
                      IconButton.filledTonal(
                        tooltip: 'Ask Personal Digital Twin AI',
                        onPressed: () => _openChat(context),
                        icon: const Icon(Icons.forum_rounded),
                      ),
                    ],
                  ),
                ),
              TabBar(
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                labelPadding: const EdgeInsets.symmetric(horizontal: 12),
                labelStyle: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 14,
                ),
                unselectedLabelStyle: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
                labelColor: p.textPrimary,
                unselectedLabelColor: p.textSecondary,
                indicatorColor: context.brand,
                dividerColor: p.border,
                tabs: const <Widget>[
                  Tab(text: 'For you'),
                  Tab(text: 'Summaries'),
                  Tab(text: 'Study plan'),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: <Widget>[
                    _ForYouTab(
                      controller: controller,
                      onAsk: () => _openChat(context),
                    ),
                    _SummariesTab(controller: controller),
                    _StudyPlanTab(controller: controller),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AskCard extends StatelessWidget {
  const _AskCard({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final VivoraPalette p = context.palette;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Radii.lg),
        child: Ink(
          padding: const EdgeInsets.all(Space.lg),
          decoration: BoxDecoration(
            gradient: p.highlightGradient,
            borderRadius: BorderRadius.circular(Radii.lg),
          ),
          child: Row(
            children: <Widget>[
              Icon(Icons.forum_rounded, color: p.onHighlight, size: 28),
              const SizedBox(width: Space.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'Ask Personal Digital Twin AI',
                      style: TextStyle(
                        color: p.onHighlight,
                        fontWeight: FontWeight.w800,
                        fontSize: 17,
                      ),
                    ),
                    Text(
                      'Questions about your week, habits or study plan',
                      style: TextStyle(color: p.onHighlight, fontSize: 13),
                    ),
                  ],
                ),
              ),
              Icon(Icons.arrow_forward_rounded, color: p.onHighlight),
            ],
          ),
        ),
      ),
    );
  }
}

Widget _tabList(BuildContext context, String key, List<Widget> children) {
  return ListView(
    key: PageStorageKey<String>(key),
    padding: const EdgeInsets.only(top: Space.lg, bottom: Space.xxxl),
    children: children,
  );
}

// --- For you -----------------------------------------------------------------

class _ForYouTab extends StatefulWidget {
  const _ForYouTab({required this.controller, required this.onAsk});
  final AiAssistantController controller;
  final VoidCallback onAsk;

  @override
  State<_ForYouTab> createState() => _ForYouTabState();
}

class _ForYouTabState extends State<_ForYouTab> {
  bool _goalBusy = false;

  AiAssistantController get c => widget.controller;

  Future<void> _accept(GoalSuggestion s) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: Text('Change your ${s.goal.label.toLowerCase()} goal?'),
        content: Text(
          '${s.currentTargetHours == null ? 'Set' : 'Change'} your ${s.goal.label.toLowerCase()} '
          '${s.goal.isLimit ? 'limit' : 'goal'} to ${formatHours(s.suggestedHours)} per day. '
          'You can change it again on the Goals screen.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Apply'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _goalBusy = true);
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      await c.acceptGoalSuggestion(s);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            '${s.goal.label} goal set to ${formatHours(s.suggestedHours)}',
          ),
        ),
      );
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Could not save the goal. Please try again.'),
        ),
      );
    } finally {
      if (mounted) setState(() => _goalBusy = false);
    }
  }

  Future<void> _feedback(AiRecommendation r, RecommendationStatus s) async {
    try {
      await c.setStatus(r, s);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not save feedback. Please try again.'),
          ),
        );
      }
      return;
    }
    if (!mounted) return;
    final String text = switch (s) {
      RecommendationStatus.helpful => 'Thanks, marked as helpful.',
      RecommendationStatus.notHelpful =>
        'Thanks. Similar advice will be avoided next time.',
      RecommendationStatus.completed => 'Nice work! Moved to Recent advice.',
      RecommendationStatus.dismissed =>
        'Dismissed. It will not be suggested again.',
      RecommendationStatus.active => '',
    };
    if (text.isNotEmpty) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text(text)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final List<AiRecommendation> recs = c.currentRecommendations;
    final List<Widget> children = <Widget>[
      Text(
        'On request, Personal Digital Twin sends a compact activity summary to Google Gemini. Free-tier inputs and replies may be used to improve Google products. Avoid sensitive information. AI can make mistakes; check the recorded facts.',
        style: TextStyle(color: context.palette.textSecondary),
      ),
      const SizedBox(height: Space.md),
      _AskCard(onTap: widget.onAsk),
      const SizedBox(height: Space.lg),
    ];

    if (c.isOpening && c.advice == null) {
      children.add(const AiLoading(message: 'Loading your saved advice…'));
    } else if (c.advice == null || c.adviceLoading) {
      children.add(
        AiActionCard(
          icon: Icons.auto_awesome_rounded,
          title: 'Personalised recommendations',
          message:
              'Personal Digital Twin AI reviews your last 7 days (measured phone use, Focus Mode and your daily logs) and suggests a few practical changes.',
          actionLabel: 'Generate recommendations',
          loading: c.adviceLoading,
          onAction: c.generateAdvice,
        ),
      );
    } else {
      children.addAll(<Widget>[
        AiSectionTitle(
          'Recommendations',
          subtitle: 'Last 7 days',
          trailing: TextButton.icon(
            onPressed: c.adviceLoading ? null : c.generateAdvice,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Refresh'),
          ),
        ),
        AiMetaLine(generatedAt: c.advice!.generatedAt, stale: c.adviceIsStale),
        const SizedBox(height: Space.md),
        if (recs.isEmpty)
          Text(
            'No open recommendations. Refresh after recording more data for new advice.',
            style: TextStyle(color: context.palette.textSecondary),
          ),
        for (final AiRecommendation r in recs) ...<Widget>[
          AiRecommendationCard(
            recommendation: r,
            onFeedback: (s) => _feedback(r, s),
          ),
          const SizedBox(height: Space.md),
        ],
      ]);
    }

    final AiFailure? error = c.adviceError;
    if (error != null) {
      children.addAll(<Widget>[
        const SizedBox(height: Space.md),
        AiErrorBanner(failure: error, onRetry: c.generateAdvice),
      ]);
    }

    children.addAll(<Widget>[
      const SizedBox(height: Space.md),
      AiActionCard(
        icon: Icons.flag_outlined,
        title: 'Adaptive goals',
        message:
            'Suggest gradual targets from your recorded data. This works independently of recommendations; nothing is applied automatically.',
        actionLabel: 'Suggest goals',
        loading: c.goalsLoading,
        onAction: c.generateGoals,
      ),
      if (c.goalsError != null)
        AiErrorBanner(failure: c.goalsError!, onRetry: c.generateGoals),
      const SizedBox(height: Space.md),
    ]);
    if (c.goalSuggestions.isNotEmpty) {
      children.addAll(<Widget>[
        const AiSectionTitle(
          'Suggested goals',
          subtitle:
              'Based on what you actually recorded. Nothing changes unless you apply it.',
        ),
        for (final GoalSuggestion s in c.goalSuggestions) ...<Widget>[
          GoalSuggestionCard(
            suggestion: s,
            busy: _goalBusy,
            onAccept: () => _accept(s),
            onReject: () => unawaited(c.rejectGoalSuggestion(s)),
          ),
          const SizedBox(height: Space.md),
        ],
      ]);
    }

    // Deterministic Module 3 suggestions: always available, clearly labelled.
    final List<Recommendation> rules = c.behaviorInsights;
    if (rules.isNotEmpty && (error != null || c.advice == null)) {
      children.addAll(<Widget>[
        const AiSectionTitle(
          'Behaviour insights',
          subtitle: 'Rule-based from your data, not generated by AI',
        ),
        for (final Recommendation r in rules) ...<Widget>[
          AiCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  r.title,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: Space.xs),
                Text(r.action),
                const SizedBox(height: Space.xs),
                Text(
                  'Why: ${r.evidence}',
                  style: TextStyle(
                    color: context.palette.textSecondary,
                    fontSize: 12.5,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: Space.md),
        ],
      ]);
    }

    final List<AiRecommendation> recent = c.recentAdvice;
    if (recent.isNotEmpty) {
      children.addAll(<Widget>[
        const AiSectionTitle('Recent advice'),
        AiCard(
          child: Column(
            children: <Widget>[
              for (final AiRecommendation r in recent)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(categoryIcon(r.category)),
                  title: Text(r.title),
                  subtitle: Text(
                    '${_statusLabel(r.status)} · ${formatWhen(context, r.generatedAt)}',
                  ),
                ),
            ],
          ),
        ),
      ]);
    }
    return _tabList(context, 'forYou', children);
  }

  static String _statusLabel(RecommendationStatus s) => switch (s) {
    RecommendationStatus.active => 'Earlier advice',
    RecommendationStatus.helpful => 'Marked helpful',
    RecommendationStatus.notHelpful => 'Marked not helpful',
    RecommendationStatus.completed => 'Completed',
    RecommendationStatus.dismissed => 'Dismissed',
  };
}

// --- Summaries ------------------------------------------------------------------

class _SummariesTab extends StatefulWidget {
  const _SummariesTab({required this.controller});
  final AiAssistantController controller;

  @override
  State<_SummariesTab> createState() => _SummariesTabState();
}

class _SummariesTabState extends State<_SummariesTab> {
  SummaryKind _kind = SummaryKind.daily;

  @override
  Widget build(BuildContext context) {
    final AiAssistantController c = widget.controller;
    final AiSummary? s = c.summary(_kind);
    final AiFailure? error = c.summaryError(_kind);
    final bool loading = c.summaryLoading(_kind);
    final facts = c.analysisForSummary(_kind);
    final VivoraPalette p = context.palette;

    final List<Widget> children = <Widget>[
      SegmentedButton<SummaryKind>(
        segments: const <ButtonSegment<SummaryKind>>[
          ButtonSegment<SummaryKind>(
            value: SummaryKind.daily,
            label: Text('Daily'),
            icon: Icon(Icons.today_rounded),
          ),
          ButtonSegment<SummaryKind>(
            value: SummaryKind.weekly,
            label: Text('Weekly'),
            icon: Icon(Icons.date_range_rounded),
          ),
        ],
        selected: <SummaryKind>{_kind},
        onSelectionChanged: (v) => setState(() => _kind = v.first),
      ),
      if (_kind == SummaryKind.daily) ...<Widget>[
        const SizedBox(height: Space.md),
        Wrap(
          spacing: Space.sm,
          children: <Widget>[
            for (final SummaryDay d in SummaryDay.values)
              ChoiceChip(
                label: Text(
                  d == SummaryDay.today ? 'Today (so far)' : 'Yesterday',
                ),
                selected: c.summaryDay == d,
                onSelected: (_) => unawaited(c.selectSummaryDay(d)),
              ),
          ],
        ),
      ],
      const SizedBox(height: Space.lg),
      if (facts != null && recordedFacts(facts).isNotEmpty)
        AiCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(
                    Icons.fact_check_rounded,
                    color: context.brand,
                    size: 20,
                  ),
                  const SizedBox(width: Space.sm),
                  Expanded(
                    child: Text(
                      _kind == SummaryKind.weekly
                          ? 'Local statistical weekly summary — not AI-generated'
                          : 'Recorded (${facts.period.label.toLowerCase()})',
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: Space.sm),
              if (_kind == SummaryKind.weekly) ...[
                Text(
                  '${facts.start.year}-${facts.start.month.toString().padLeft(2, '0')}-${facts.start.day.toString().padLeft(2, '0')} to '
                  '${facts.end.year}-${facts.end.month.toString().padLeft(2, '0')}-${facts.end.day.toString().padLeft(2, '0')}',
                ),
                Text(
                  error != null
                      ? 'AI commentary is unavailable. These statistics are calculated locally from recorded data; missing days are not counted as zero.'
                      : 'Calculated from recorded data only. Missing days are not counted as zero.',
                ),
                const SizedBox(height: Space.sm),
              ],
              for (final (String label, String value) in recordedFacts(facts))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          label,
                          style: TextStyle(color: p.textSecondary),
                        ),
                      ),
                      const SizedBox(width: Space.sm),
                      Flexible(
                        child: Text(
                          value,
                          textAlign: TextAlign.end,
                          style: TextStyle(
                            color: p.textPrimary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              Text(
                'Facts calculated by Personal Digital Twin, not by AI.',
                style: TextStyle(color: p.textSecondary, fontSize: 12),
              ),
            ],
          ),
        ),
      const SizedBox(height: Space.md),
      if (s == null || loading)
        AiActionCard(
          icon: Icons.summarize_rounded,
          title: _kind.label,
          message: _kind == SummaryKind.daily
              ? 'A short explanation of the selected day, what went well, and one or two next steps.'
              : 'Your last 7 days: productivity, study consistency, focus, sleep, screen time, goals and priorities for next week.',
          actionLabel: 'Generate ${_kind.label.toLowerCase()}',
          loading: loading,
          onAction: () => c.generateSummary(_kind),
        )
      else
        _SummaryCard(
          summary: s,
          stale: c.summaryIsStale(_kind),
          onRegenerate: () => c.generateSummary(_kind),
        ),
      if (error != null) ...<Widget>[
        const SizedBox(height: Space.md),
        AiErrorBanner(failure: error, onRetry: () => c.generateSummary(_kind)),
      ],
    ];
    return _tabList(context, 'summaries', children);
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
    required this.summary,
    required this.stale,
    required this.onRegenerate,
  });

  final AiSummary summary;
  final bool stale;
  final VoidCallback onRegenerate;

  @override
  Widget build(BuildContext context) {
    final VivoraPalette p = context.palette;
    Widget bullets(String title, List<String> items) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const SizedBox(height: Space.md),
        Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
        for (final String i in items)
          Padding(
            padding: const EdgeInsets.only(top: Space.xs),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('•  ', style: TextStyle(color: p.textPrimary)),
                Expanded(
                  child: Text(i, style: TextStyle(color: p.textPrimary)),
                ),
              ],
            ),
          ),
      ],
    );

    return AiCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          AiMetaLine(generatedAt: summary.generatedAt, stale: stale),
          const SizedBox(height: Space.md),
          Text(
            summary.headline,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: Space.sm),
          Text(summary.overview, style: TextStyle(color: p.textPrimary)),
          for (final SummaryPoint h in summary.highlights)
            Padding(
              padding: const EdgeInsets.only(top: Space.sm),
              child: Text.rich(
                TextSpan(
                  children: <InlineSpan>[
                    TextSpan(
                      text: '${h.label}: ',
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    TextSpan(text: h.text),
                  ],
                ),
                style: TextStyle(color: p.textPrimary),
              ),
            ),
          if (summary.improvements.isNotEmpty)
            bullets('Could improve', summary.improvements),
          if (summary.nextSteps.isNotEmpty)
            bullets('Next steps', summary.nextSteps),
          const SizedBox(height: Space.sm),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: onRegenerate,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Regenerate'),
            ),
          ),
        ],
      ),
    );
  }
}

// --- Study plan -----------------------------------------------------------------

class _StudyPlanTab extends StatefulWidget {
  const _StudyPlanTab({required this.controller});
  final AiAssistantController controller;

  @override
  State<_StudyPlanTab> createState() => _StudyPlanTabState();
}

class _StudyPlanTabState extends State<_StudyPlanTab> {
  bool _saving = false;

  Future<void> _acceptPlan(StudyPlan plan) async {
    setState(() => _saving = true);
    try {
      await widget.controller.acceptStudyPlan(plan);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not save the plan. Please try again.'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _useAsGoal(StudyPlan plan, double hours) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('Update your study goal?'),
        content: Text(
          'Set your daily study goal to ${formatHours(hours)}. Your other goals stay the same.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Update goal'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _saving = true);
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      await widget.controller.applyPlanAsStudyGoal(plan);
      messenger.showSnackBar(
        SnackBar(content: Text('Study goal set to ${formatHours(hours)}')),
      );
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text('Could not save the goal. Please try again.'),
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AiAssistantController c = widget.controller;
    final StudyPlan? plan = c.studyPlan;
    final VivoraPalette p = context.palette;
    final List<Widget> children = <Widget>[];

    if (plan == null || c.planLoading) {
      children.add(
        AiActionCard(
          icon: Icons.event_note_rounded,
          title: 'Personalised study plan',
          message:
              'A realistic daily plan built from your recorded study and focus time and your goals. It is a suggestion to review; nothing is scheduled automatically.',
          actionLabel: 'Suggest a study plan',
          loading: c.planLoading,
          onAction: c.generateStudyPlan,
        ),
      );
    } else {
      final double? goalHours = c.studyGoalFromPlan(plan);
      children.add(
        AiCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              AiMetaLine(
                generatedAt: plan.generatedAt,
                stale: c.planIsStale,
                extra: 'Suggestion only',
              ),
              const SizedBox(height: Space.md),
              Text(plan.overview, style: TextStyle(color: p.textPrimary)),
              const SizedBox(height: Space.md),
              Wrap(
                spacing: Space.sm,
                runSpacing: Space.sm,
                children: <Widget>[
                  AiTag(
                    text:
                        '${formatMinutes(plan.dailyStudyMinutes)} study per day',
                    icon: Icons.auto_stories_rounded,
                  ),
                  AiTag(
                    text:
                        '${plan.sessionsPerDay} × ${plan.sessionMinutes} min sessions',
                    icon: Icons.timer_rounded,
                  ),
                  AiTag(
                    text: '${plan.breakMinutes} min breaks',
                    icon: Icons.free_breakfast_rounded,
                  ),
                  if (plan.preferredTime != null)
                    AiTag(
                      text: 'You prefer: ${plan.preferredTime}',
                      icon: Icons.schedule_rounded,
                    ),
                ],
              ),
              if (plan.priorities.isNotEmpty) ...<Widget>[
                const SizedBox(height: Space.md),
                const Text(
                  'Daily priorities',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
                for (final String s in plan.priorities)
                  Padding(
                    padding: const EdgeInsets.only(top: Space.xs),
                    child: Text(
                      '•  $s',
                      style: TextStyle(color: p.textPrimary),
                    ),
                  ),
              ],
              if (plan.goalAlignment.isNotEmpty) ...<Widget>[
                const SizedBox(height: Space.md),
                Text.rich(
                  TextSpan(
                    children: <InlineSpan>[
                      const TextSpan(
                        text: 'Your goals: ',
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
                      TextSpan(text: plan.goalAlignment),
                    ],
                  ),
                  style: TextStyle(color: p.textPrimary),
                ),
              ],
              if (plan.tips.isNotEmpty) ...<Widget>[
                const SizedBox(height: Space.md),
                const Text(
                  'Tips',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
                for (final String s in plan.tips)
                  Padding(
                    padding: const EdgeInsets.only(top: Space.xs),
                    child: Text(
                      '•  $s',
                      style: TextStyle(color: p.textPrimary),
                    ),
                  ),
              ],
              const SizedBox(height: Space.lg),
              Wrap(
                spacing: Space.sm,
                runSpacing: Space.sm,
                children: <Widget>[
                  FilledButton.icon(
                    onPressed: () =>
                        Navigator.of(context).pushNamed(AppRoutes.focusMode),
                    icon: const Icon(Icons.play_arrow_rounded),
                    label: const Text('Start a focus session'),
                  ),
                  if (goalHours != null)
                    OutlinedButton(
                      onPressed: _saving
                          ? null
                          : () => _useAsGoal(plan, goalHours),
                      child: Text(
                        'Use ${formatHours(goalHours)} as study goal',
                      ),
                    ),
                  OutlinedButton.icon(
                    onPressed: _saving || plan.acceptedAt != null
                        ? null
                        : () => _acceptPlan(plan),
                    icon: const Icon(Icons.check_circle_outline),
                    label: Text(
                      plan.acceptedAt == null
                          ? 'Accept this plan'
                          : 'Plan accepted',
                    ),
                  ),
                  TextButton.icon(
                    onPressed: c.generateStudyPlan,
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('New plan'),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }
    if (c.planError != null) {
      children.addAll(<Widget>[
        const SizedBox(height: Space.md),
        AiErrorBanner(failure: c.planError!, onRetry: c.generateStudyPlan),
      ]);
    }
    return _tabList(context, 'plan', children);
  }
}
