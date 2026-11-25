import 'dart:async';
import 'package:flutter/material.dart';
import '../../../core/routes/app_routes.dart';
import '../../../core/theme/theme_controller.dart';
import '../data/admin_models.dart';
import '../data/admin_repository.dart';
import '../data/admin_session.dart';
import 'admin_widgets.dart';
import 'admin_user_detail.dart';

class AdminPortalScreen extends StatefulWidget {
  const AdminPortalScreen({super.key});
  @override
  State<AdminPortalScreen> createState() => _AdminPortalScreenState();
}

class _AdminPortalScreenState extends State<AdminPortalScreen>
    with WidgetsBindingObserver {
  AdminSession? _session;
  AdminRepository? _repo;
  StreamSubscription<bool>? _authorization;
  Timer? _timer;
  bool _allowed = false;
  bool _foreground = true;
  bool _signingOut = false;
  int _epoch = 0;
  String? _error;
  int _section = 0;
  AdminUser? _selected;
  static const sections = [
    'Dashboard',
    'All Users',
    'Activity Monitoring',
    'Behavior Analysis',
    'Productivity Analytics',
    'AI Insights',
    'Settings',
  ];
  static const icons = [
    Icons.space_dashboard_outlined,
    Icons.people_outline,
    Icons.phonelink_ring_outlined,
    Icons.psychology_outlined,
    Icons.insights_outlined,
    Icons.auto_awesome_outlined,
    Icons.settings_outlined,
  ];
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _open();
  }

  Future<void> _open() async {
    final epoch = ++_epoch;
    try {
      final session = await AdminSession.instance();
      if (!mounted || epoch != _epoch || _signingOut) return;
      _session = session;
      if (!await session.authorized()) throw const AdminAccessException();
      if (!mounted || epoch != _epoch || !_foreground || _signingOut) return;
      setState(() {
        _session = session;
        _repo = AdminRepository(session.db);
        _allowed = true;
        _error = null;
      });
      await _authorization?.cancel();
      if (!mounted || epoch != _epoch) return;
      _authorization = session.authorizationChanges().listen(
        (ok) {
          if (!mounted || epoch != _epoch || !_foreground || _signingOut) {
            return;
          }
          if (ok) {
            setState(() {
              _allowed = true;
              _error = null;
            });
          } else {
            _lock(
              'Authorization could not be confirmed. Reconnect and verify access.',
            );
          }
        },
        onError: (_) {
          if (epoch == _epoch) {
            _lock(
              'Administrator access was revoked or the server is unavailable.',
            );
          }
        },
      );
      _timer?.cancel();
      _timer = Timer.periodic(const Duration(seconds: 30), (_) => _verify());
    } catch (e) {
      if (epoch == _epoch) _lock(adminError(e));
    }
  }

  void _lock(String message) {
    if (mounted) {
      setState(() {
        _allowed = false;
        _selected = null;
        _error = message;
      });
    }
  }

  Future<void> _verify() async {
    if (!_foreground || _signingOut) return;
    final epoch = _epoch;
    try {
      final ok = await _session!.authorized();
      if (epoch == _epoch && !ok) {
        _lock('Administrator access is no longer active.');
      }
    } catch (_) {
      if (epoch == _epoch) {
        _lock(
          'A server connection is required to verify administrator access.',
        );
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _foreground = true;
      if (_session != null && !_signingOut) {
        _lock('Verifying access…');
        _open();
      }
    }
    if (state == AppLifecycleState.paused) {
      _foreground = false;
      _epoch++;
      _lock('Administrator data is hidden while the app is in the background.');
    }
  }

  Future<void> _logout() async {
    _signingOut = true;
    _epoch++;
    _lock('Signing out…');
    await _authorization?.cancel();
    _timer?.cancel();
    await _session?.signOut();
    if (mounted) {
      Navigator.of(
        context,
      ).pushNamedAndRemoveUntil(AppRoutes.auth, (_) => false);
    }
  }

  @override
  void dispose() {
    _epoch++;
    WidgetsBinding.instance.removeObserver(this);
    _authorization?.cancel();
    _timer?.cancel();
    super.dispose();
  }

  void _select(int index) {
    setState(() {
      _section = index;
      _selected = null;
    });
  }

  Widget _navigation() => ListView(
    children: [
      const Padding(
        padding: EdgeInsets.all(20),
        child: Text('Personal Digital Twin\nAdmin Portal'),
      ),
      for (var i = 0; i < sections.length; i++)
        ListTile(
          leading: Icon(icons[i]),
          title: Text(sections[i]),
          selected: _section == i,
          onTap: () => _select(i),
        ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    if (!_allowed) {
      return Scaffold(
        appBar: AppBar(title: const Text('Admin Portal')),
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_error == null)
                    const CircularProgressIndicator()
                  else
                    AdminMessage(_error!, retry: _open, error: true),
                  TextButton(
                    onPressed: _logout,
                    child: const Text('Back to User Login'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 1000;
        final content = _selected != null
            ? AdminUserDetail(
                key: ValueKey(_selected!.uid),
                user: _selected!,
                repository: _repo!,
                initialSection: switch (_section) {
                  2 => 1,
                  3 => 2,
                  4 => 3,
                  5 => 5,
                  _ => 0,
                },
                onBack: () => setState(() => _selected = null),
              )
            : _section == 6
            ? _settings()
            : AdminDirectory(
                key: ValueKey(_section),
                repository: _repo!,
                dashboard: _section == 0,
                heading: sections[_section],
                onSelect: (u) => setState(() => _selected = u),
              );
        return Scaffold(
          appBar: AppBar(
            title: Text(
              _selected?.name ?? sections[_section],
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            actions: [
              IconButton(
                tooltip: 'Secure logout',
                onPressed: _logout,
                icon: const Icon(Icons.logout),
              ),
            ],
          ),
          drawer: wide
              ? null
              : Drawer(
                  child: Builder(
                    builder: (drawerContext) => ListView(
                      children: [
                        const DrawerHeader(
                          child: Text('Personal Digital Twin\nAdmin Portal'),
                        ),
                        for (var i = 0; i < sections.length; i++)
                          ListTile(
                            leading: Icon(icons[i]),
                            title: Text(sections[i]),
                            selected: i == _section,
                            onTap: () {
                              Navigator.pop(drawerContext);
                              _select(i);
                            },
                          ),
                      ],
                    ),
                  ),
                ),
          body: SafeArea(
            child: Row(
              children: [
                if (wide) SizedBox(width: 250, child: _navigation()),
                if (wide) const VerticalDivider(width: 1),
                Expanded(child: content),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _settings() => ListView(
    padding: const EdgeInsets.all(20),
    children: [
      AdminPanel(
        title: 'Administrator profile',
        child: AdminFields({
          'Email': _session?.auth.currentUser?.email,
          'Role': 'Admin',
          'Access': 'Read only · verified by Firestore rules',
        }),
      ),
      AdminPanel(
        title: 'Appearance',
        child: Wrap(
          spacing: 8,
          children: [
            for (final m in ThemeMode.values)
              ChoiceChip(
                label: Text(m.name),
                selected: ThemeController.instance.value == m,
                onSelected: (_) => ThemeController.instance.setMode(m),
              ),
          ],
        ),
      ),
      const AdminPanel(
        title: 'Privacy & access',
        child: Text(
          'Private AI conversations are excluded. Saved AI output is read only; opening this portal does not call Gemini. Administrator records are not cached to disk. Revocation is enforced by Firestore and rechecked when resuming the app.',
        ),
      ),
      FilledButton.icon(
        onPressed: _logout,
        icon: const Icon(Icons.logout),
        label: const Text('Log out of Admin Portal'),
      ),
    ],
  );
}

class AdminDirectory extends StatefulWidget {
  const AdminDirectory({
    super.key,
    required this.repository,
    required this.dashboard,
    required this.heading,
    required this.onSelect,
  });
  final AdminRepository repository;
  final bool dashboard;
  final String heading;
  final ValueChanged<AdminUser> onSelect;
  @override
  State<AdminDirectory> createState() => _AdminDirectoryState();
}

class _AdminDirectoryState extends State<AdminDirectory> {
  List<AdminUser> _users = [], _recent = [];
  AdminPage? _page;
  int? _total;
  bool _busy = false;
  String? _error;
  String _query = '', _filter = 'All', _sort = 'Name';
  @override
  void initState() {
    super.initState();
    _load(reset: true);
  }

  Future<void> _load({bool reset = false}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (reset) {
        final total = await widget.repository.userCount();
        final recent = await widget.repository.recentUsers();
        if (!mounted) return;
        setState(() {
          _total = total;
          _recent = recent;
          _users = [];
          _page = null;
        });
      }
      final page = await widget.repository.page(_page?.cursor);
      if (!mounted) return;
      setState(() {
        _users = [..._users, ...page.users];
        _page = page;
      });
    } catch (e) {
      if (mounted) setState(() => _error = adminError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final totals = AdminTotals(_users, DateTime.now());
    final filtered =
        _users
            .where(
              (u) =>
                  '${u.name} ${u.email}'.toLowerCase().contains(
                    _query.toLowerCase(),
                  ) &&
                  switch (_filter) {
                    'Tracking on' => u.tracking == true,
                    'Tracking off' => u.tracking == false,
                    'Active' => u.activeAt(DateTime.now()),
                    'Missing data' =>
                      u.loadError != null || u.lastActivity == null,
                    _ => true,
                  },
            )
            .toList()
          ..sort(
            (a, b) => switch (_sort) {
              'Newest' => (b.createdAt ?? DateTime(0)).compareTo(
                a.createdAt ?? DateTime(0),
              ),
              'Score' => (b.score ?? -1).compareTo(a.score ?? -1),
              _ => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
            },
          );
    return RefreshIndicator(
      onRefresh: () => _load(reset: true),
      child: ListView(
        padding: const EdgeInsets.all(20),
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          Text(
            widget.dashboard
                ? 'Student wellbeing at a glance'
                : 'Explore student records',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          Text(
            widget.dashboard
                ? 'Real Firestore records · read-only overview'
                : '${widget.heading}: select a student to view authorized records.',
          ),
          const SizedBox(height: 20),
          if (_error != null)
            AdminMessage(_error!, retry: () => _load(reset: true), error: true),
          if (widget.dashboard && _total != null) ...[
            AdminMetricGrid([
              ('Registered user profiles', '$_total', Icons.people_outline),
              (
                'Active in last 7 days',
                '${totals.active}',
                Icons.person_outline,
              ),
              ('Tracking enabled', '${totals.tracking}', Icons.track_changes),
              (
                'Recorded study duration',
                adminHours(totals.studyHours),
                Icons.school_outlined,
              ),
              (
                'Timed focus duration',
                adminHours(totals.focusSeconds / 3600),
                Icons.timer_outlined,
              ),
              (
                'Average recorded score',
                totals.averageScore?.toStringAsFixed(1) ?? 'Not recorded',
                Icons.insights,
              ),
              (
                'Recorded focus sessions',
                '${totals.sessions}',
                Icons.check_circle_outline,
              ),
              (
                'Profiles summarized',
                '${_users.length} / $_total',
                Icons.dataset_outlined,
              ),
            ]),
            const SizedBox(height: 16),
            AdminPanel(
              title: 'How these numbers are calculated',
              child: Text(
                'Profile count covers users documents, not Firebase Auth accounts without a profile. Other metrics cover ${_users.length} loaded profiles${_page?.hasMore == true ? ' — load more to complete totals' : ''}. '
                'Active means a synced activity log, updated daily log, or ended focus session in the last 7 days. '
                'Study is the sum of valid manual study hours; focus sums valid timer seconds, without adding manual focus twice. '
                'Average score is weighted by the number of valid saved daily scores across all dates. Tracking reflects the saved cloud preference. '
                '${totals.incomplete} profiles have unavailable statistics and are excluded from those totals.',
              ),
            ),
            AdminPanel(
              title: 'Recently registered',
              subtitle: 'Most recent profiles with a recorded creation date.',
              child: Column(
                children: [
                  if (_recent.isEmpty)
                    const Text('No registration dates recorded.'),
                  for (final u in _recent)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const CircleAvatar(
                        child: Icon(Icons.person_outline),
                      ),
                      title: Text(u.name),
                      subtitle: Text(adminDay(u.createdAt)),
                      onTap: () => widget.onSelect(
                        _users.where((x) => x.uid == u.uid).firstOrNull ?? u,
                      ),
                    ),
                ],
              ),
            ),
          ],
          TextField(
            decoration: const InputDecoration(
              labelText: 'Search loaded users by name or email',
              prefixIcon: Icon(Icons.search),
            ),
            onChanged: (v) => setState(() => _query = v),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              DropdownButton<String>(
                value: _filter,
                items:
                    [
                          'All',
                          'Tracking on',
                          'Tracking off',
                          'Active',
                          'Missing data',
                        ]
                        .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                        .toList(),
                onChanged: (v) => setState(() => _filter = v!),
              ),
              DropdownButton<String>(
                value: _sort,
                items: ['Name', 'Newest', 'Score']
                    .map(
                      (s) =>
                          DropdownMenuItem(value: s, child: Text('Sort: $s')),
                    )
                    .toList(),
                onChanged: (v) => setState(() => _sort = v!),
              ),
            ],
          ),
          Text(
            'Search, filters and sorting apply to ${_users.length} loaded profiles. Load more to search additional users.',
          ),
          const SizedBox(height: 12),
          if (!_busy && filtered.isEmpty)
            const AdminMessage('No matching profiles in the loaded results.'),
          for (final u in filtered)
            AdminPanel(
              title: u.name,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: CircleAvatar(child: Icon(Icons.person_outline)),
                  ),
                  const SizedBox(height: 8),
                  Text(u.email),
                  Text(
                    'Joined: ${adminDay(u.createdAt)} · Last activity: ${adminDay(u.lastActivity)}',
                  ),
                  Text(
                    'Tracking: ${u.tracking == null
                        ? 'Unknown'
                        : u.tracking!
                        ? 'On'
                        : 'Off'} · Latest score: ${u.score?.toStringAsFixed(1) ?? 'Not recorded'}',
                  ),
                  if (u.loadError != null) Text(u.loadError!),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: () => widget.onSelect(u),
                      icon: const Icon(Icons.arrow_forward),
                      label: const Text('View Details'),
                    ),
                  ),
                ],
              ),
            ),
          if (_busy) const AdminLoading(),
          if (!_busy && _page?.hasMore == true)
            OutlinedButton(
              onPressed: _load,
              child: const Text('Load next 20 users'),
            ),
          if (!_busy)
            TextButton.icon(
              onPressed: () => _load(reset: true),
              icon: const Icon(Icons.refresh),
              label: const Text('Refresh data'),
            ),
        ],
      ),
    );
  }
}
