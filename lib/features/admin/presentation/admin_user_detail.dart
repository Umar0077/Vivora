import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import '../../activity_monitoring/data/models/app_usage_entry.dart';
import '../../activity_monitoring/data/models/daily_activity_log.dart';
import '../../behavior_analysis/domain/behavior_analysis_engine.dart';
import '../../behavior_analysis/domain/behavior_models.dart';
import '../../behavior_analysis/presentation/behavior_insights_section.dart';
import '../../insights/data/history_data.dart';
import '../../productivity_scoring/data/services/productivity_score_service.dart';
import '../data/admin_models.dart';
import '../data/admin_repository.dart';
import '../data/admin_session.dart';
import 'admin_widgets.dart';

class AdminUserDetail extends StatefulWidget {
  const AdminUserDetail({
    super.key,
    required this.user,
    required this.repository,
    required this.onBack,
    this.initialSection = 0,
  });
  final AdminUser user;
  final AdminRepository repository;
  final VoidCallback onBack;
  final int initialSection;
  @override
  State<AdminUserDetail> createState() => _AdminUserDetailState();
}

class _AdminUserDetailState extends State<AdminUserDetail> {
  late int _section = widget.initialSection;
  HistoryData? _history;
  Map<AnalysisPeriod, BehaviorAnalysis>? _analyses;
  List<Map<String, dynamic>>? _ai;
  String? _error;
  bool _busy = false;
  AnalysisPeriod _period = AnalysisPeriod.week;
  static const tabs = [
    'Overview',
    'Activity',
    'Behavior',
    'Productivity',
    'Reports',
    'AI Insights',
  ];
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_section == 5) {
        final data = await widget.repository.savedAi(widget.user.uid);
        if (mounted) setState(() => _ai = data);
      } else if (_section != 0) {
        final history = await widget.repository.history(widget.user);
        final analyses = const BehaviorAnalysisEngine().analyzeAll(history);
        if (mounted) {
          setState(() {
            _history = history;
            _analyses = analyses;
          });
        }
      }
    } catch (e) {
      if (mounted) setState(() => _error = adminError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _change(int i) {
    setState(() {
      _section = i;
      _error = null;
    });
    if (i == 5 && _ai == null || i > 0 && i != 5 && _history == null) _load();
  }

  @override
  Widget build(BuildContext context) => RefreshIndicator(
    onRefresh: _load,
    child: ListView(
      padding: const EdgeInsets.all(20),
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: widget.onBack,
            icon: const Icon(Icons.arrow_back),
            label: const Text('Back to users'),
          ),
        ),
        Text(
          widget.user.name,
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        Text(widget.user.email),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (var i = 0; i < tabs.length; i++)
              ChoiceChip(
                label: Text(tabs[i]),
                selected: _section == i,
                onSelected: _busy ? null : (_) => _change(i),
              ),
          ],
        ),
        const SizedBox(height: 20),
        if (_error != null) AdminMessage(_error!, retry: _load, error: true),
        if (_busy)
          const AdminLoading()
        else if (_section == 0)
          ..._overview()
        else if (_section == 5)
          ..._savedAi()
        else if (_history != null) ...[
          const Text(
            'Last 60 calendar days loaded for comparison. Missing, malformed and future records are not evidence. Older history is outside this view.',
          ),
          const SizedBox(height: 12),
          if (_section == 2)
            BehaviorInsightsSection(analyses: _analyses)
          else ...[
            Wrap(
              spacing: 8,
              children: [
                for (final p in AnalysisPeriod.values)
                  ChoiceChip(
                    label: Text(p.label),
                    selected: p == _period,
                    onSelected: (_) => setState(() => _period = p),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            if (_section == 1) ..._activity() else ..._productivity(),
          ],
        ],
      ],
    ),
  );

  List<Widget> _overview() {
    final p = widget.user.profile;
    final goals = adminMap(p['goals']);
    final prefs = adminMap(p['preferences']);
    return [
      AdminPanel(
        title: 'Account overview',
        child: AdminFields({
          'Full name': p['fullName'],
          'Email': p['email'],
          'Created': adminDay(widget.user.createdAt),
          'Last recorded activity': adminDay(widget.user.lastActivity),
          'Academic level': p['academicLevel'],
          'Institution': p['institution'],
          'Field of study': p['fieldOfStudy'],
          'Setup completed': p['setupCompleted'],
          'Tracking enabled': widget.user.tracking,
          'Latest saved score': widget.user.score,
        }),
      ),
      AdminPanel(
        title: 'Current goals',
        child: AdminFields({
          'Sleep': goals['targetSleepHours'],
          'Study': goals['targetStudyHours'],
          'Focus': goals['targetFocusHours'],
          'Screen time limit': goals['targetScreenTimeLimit'],
          'Goal type': goals['productivityGoalType'],
        }),
      ),
      AdminPanel(
        title: 'Preferences',
        child: AdminFields({
          'Smart reminders': prefs['smartReminders'],
          'Motivational tips': prefs['motivationalTips'],
          'Daily summary': prefs['dailySummary'],
          'Analytics suggestions': prefs['analyticsSuggestions'],
        }),
      ),
      const Text(
        'Profile pictures are not stored by the existing profile schema; a neutral avatar is used. No authentication secrets are retrieved.',
      ),
    ];
  }

  bool _inPeriod(DateTime date) {
    final now = _history!.today;
    final start = DateTime(now.year, now.month, now.day - _period.days + 1);
    return !date.isBefore(start) && !date.isAfter(now);
  }

  List<Widget> _activity() {
    final history = _history!;
    final logs = history.activityLogs.where((l) => _inPeriod(l.date)).toList()
      ..sort((a, b) => b.date.compareTo(a.date));
    final manual = history.scores.where((s) => _inPeriod(s.date)).toList()
      ..sort((a, b) => b.date.compareTo(a.date));
    final sessions = history.focusSessions
        .where((s) => _inPeriod(s.startedAt))
        .toList();
    return [
      if (logs.isEmpty && manual.isEmpty && sessions.isEmpty)
        const AdminMessage('No activity recorded in this period.'),
      for (final l in logs)
        AdminPanel(
          title: 'Device activity · ${adminDay(l.date)}',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AdminFields({
                'App usage (minutes)': l.appUsageMinutes,
                'Screen unlocked (minutes)': l.screenTimeMinutes,
                'Phone unlocks': l.phoneUnlockCount,
                'Tracked minutes': l.trackedMinutes,
                'Complete tracking coverage': l.trackingComplete,
                'Walking minutes': l.walkingMinutes,
                'Running minutes': l.runningMinutes,
                'Productive app minutes': l.productiveAppMinutes,
                'Distracting app minutes': l.distractingAppMinutes,
              }),
              AdminAppUsage(
                repository: widget.repository,
                uid: widget.user.uid,
                log: l,
                overrides: history.categoryOverrides,
              ),
            ],
          ),
        ),
      for (final s in manual)
        AdminPanel(
          title: 'Daily log · ${adminDay(s.date)}',
          child: AdminFields({
            'Study hours': s.log.actualStudyHours,
            'Manual focus hours': s.log.actualFocusHours,
            'Sleep hours': s.log.actualSleepHours,
            'Screen hours': s.log.actualScreenTimeHours,
            'Screen time source': s.log.screenTimeFromDevice
                ? 'Device prefill'
                : 'User entry',
            'Routine self-rating': s.log.consistencyScore,
            'Activity self-rating': s.log.activityScore,
          }),
        ),
      AdminPanel(
        title: 'Focus sessions',
        child: Column(
          children: [
            if (sessions.isEmpty)
              const Text('No timed focus sessions recorded.'),
            for (final s in sessions)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.timer_outlined),
                title: Text(
                  '${adminDay(s.startedAt)} · ${s.focusedMinutes} minutes',
                ),
                subtitle: Text(
                  '${s.completed ? 'Completed' : 'Ended early'} · planned ${s.plannedMinutes} minutes',
                ),
              ),
          ],
        ),
      ),
    ];
  }

  List<Widget> _productivity() {
    final a = _analyses![_period]!;
    final scores =
        _history!.scores
            .where(
              (s) =>
                  _inPeriod(s.date) &&
                  adminNumber(s.overallScore, max: 100) != null,
            )
            .toList()
          ..sort((a, b) => a.date.compareTo(b.date));
    return [
      AdminPanel(
        title: 'Recorded productivity scores',
        subtitle:
            'Saved historical scores are preserved. Missing dates are not zero.',
        child: scores.isEmpty
            ? const AdminMessage('No valid productivity scores in this period.')
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    height: 200,
                    child: LineChart(
                      LineChartData(
                        minY: 0,
                        maxY: 100,
                        titlesData: const FlTitlesData(show: false),
                        borderData: FlBorderData(show: false),
                        lineBarsData: [
                          LineChartBarData(
                            isCurved: false,
                            color: Theme.of(context).colorScheme.primary,
                            barWidth: 3,
                            spots: [
                              for (final s in scores)
                                FlSpot(
                                  s.date
                                      .difference(
                                        _history!.today.subtract(
                                          Duration(days: _period.days),
                                        ),
                                      )
                                      .inDays
                                      .toDouble(),
                                  s.overallScore!,
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  for (final s in scores)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Text(
                        '${adminDay(s.date)}: ${s.overallScore!.toStringAsFixed(1)} / 100',
                      ),
                    ),
                ],
              ),
      ),
      AdminPanel(
        title: 'Period statistics',
        child: AdminFields({
          'Average saved productivity': a.metrics['score']?.mean,
          'Average study hours': a.metrics['studyHours']?.mean,
          'Average sleep hours': a.metrics['sleepHours']?.mean,
          'Days with manual logs': a.dataQuality.loggedDays,
          'Days measured': a.dataQuality.measuredDays,
        }),
      ),
      AdminPanel(
        title: 'Goal completion',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (a.goals.isEmpty)
              const Text('Insufficient records or no configured goals.'),
            for (final g in a.goals)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(
                  '${g.goal}: ${g.metDays} of ${g.observedDays} observed days met the ${g.target} ${g.unit} ${g.isLimit ? 'limit' : 'target'}.',
                ),
              ),
          ],
        ),
      ),
      if (scores.isNotEmpty && _history!.goals != null)
        Builder(
          builder: (context) {
            final result = ProductivityScoreService().calculate(
              log: scores.last.log,
              goals: _history!.goals!,
            );
            return AdminPanel(
              title: 'Score components · latest recorded day',
              subtitle:
                  'Recalculated locally with current goals; the original historical score above is unchanged.',
              child: AdminFields({
                for (final c in result.components)
                  '${c.label} (${(c.weight * 100).round()}%)': c.score,
                'Data coverage': '${(result.coverage * 100).round()}%',
              }),
            );
          },
        ),
      AdminPanel(
        title: 'Historical comparisons',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final t in a.trends.values)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(
                  '${t.metric}: ${t.direction.name} · ${t.basis}\nCurrent ${t.currentMean?.toStringAsFixed(1) ?? 'unknown'} / previous ${t.previousMean?.toStringAsFixed(1) ?? 'unknown'} ${t.unit}',
                ),
              ),
          ],
        ),
      ),
    ];
  }

  List<Widget> _savedAi() => [
    const AdminPanel(
      title: 'Saved AI insights only',
      child: Text(
        'Private conversations and chatbot explanations are not accessible. This view loads up to 40 recent recommendations and 30 summaries, plus the current goals and study plan. No Gemini request is made.',
      ),
    ),
    if (_ai != null && _ai!.isEmpty)
      const AdminMessage('No saved AI insights available.'),
    for (final record in _ai ?? <Map<String, dynamic>>[])
      AdminPanel(
        title: adminText(
          record['title'] ?? record['headline'] ?? record['_type'],
        ),
        subtitle:
            '${adminText(record['_type'])} · ${adminDay(adminDate(record['generatedAt']))}',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AdminFields({
              for (final key in [
                'kind',
                'periodKey',
                'description',
                'overview',
                'reason',
                'suggestion',
                'status',
                'statusChangedAt',
                'dailyStudyMinutes',
                'sessionsPerDay',
                'sessionMinutes',
                'breakMinutes',
                'goalAlignment',
                'preferredTime',
                'acceptedAt',
              ])
                if (record.containsKey(key)) key: record[key],
            }),
            for (final key in [
              'improvements',
              'nextSteps',
              'priorities',
              'tips',
            ])
              if (record[key] is List) ...[
                Text(key, style: Theme.of(context).textTheme.titleSmall),
                for (final value in record[key] as List)
                  if (value is String)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Text('• $value'),
                    ),
              ],
            if (record['highlights'] is List)
              for (final v in record['highlights'] as List)
                if (v is Map)
                  AdminFields({
                    'Highlight': v['label'],
                    'Explanation': v['text'],
                  }),
            if (record['goalSuggestions'] is List)
              for (final v in record['goalSuggestions'] as List)
                if (v is Map)
                  AdminFields({
                    'Goal': v['goal'],
                    'Suggested hours': v['suggestedHours'],
                    'Current target': v['currentTargetHours'],
                    'Observed average': v['observedAverageHours'],
                    'Reason': v['reason'],
                  }),
          ],
        ),
      ),
  ];
}

class AdminAppUsage extends StatefulWidget {
  const AdminAppUsage({
    super.key,
    required this.repository,
    required this.uid,
    required this.log,
    required this.overrides,
  });
  final AdminRepository repository;
  final String uid;
  final DailyActivityLog log;
  final Map<String, AppCategory> overrides;
  @override
  State<AdminAppUsage> createState() => _AdminAppUsageState();
}

class _AdminAppUsageState extends State<AdminAppUsage> {
  Future<List<AppUsageEntry>>? _apps;
  @override
  Widget build(BuildContext context) => ExpansionTile(
    tilePadding: EdgeInsets.zero,
    title: const Text('Individual application usage'),
    onExpansionChanged: (open) {
      if (open && _apps == null) {
        setState(() => _apps = widget.repository.apps(widget.uid, widget.log));
      }
    },
    children: [
      if (_apps != null)
        FutureBuilder<List<AppUsageEntry>>(
          future: _apps,
          builder: (context, snap) {
            if (snap.hasError) {
              return AdminMessage(
                adminError(snap.error!),
                error: true,
                retry: () => setState(
                  () => _apps = widget.repository.apps(widget.uid, widget.log),
                ),
              );
            }
            if (!snap.hasData) return const LinearProgressIndicator();
            return Column(
              children: [
                if (snap.data!.isEmpty)
                  const Text('No app usage details available.'),
                for (final app in snap.data!)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(app.displayName),
                    subtitle: Text(
                      '${(widget.overrides[app.packageName] ?? app.category).name} · ${app.durationLabel}',
                    ),
                  ),
              ],
            );
          },
        ),
    ],
  );
}
