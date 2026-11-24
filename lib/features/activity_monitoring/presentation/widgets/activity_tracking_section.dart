import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../core/theme/vivora_palette.dart';
import '../../../../core/widgets/ui_kit.dart';
import '../../data/models/activity_sync_snapshot.dart';
import '../../data/services/activity_sync_service.dart';
import '../../data/services/activity_tracking_controller.dart';

/// Settings > ACTIVITY TRACKING: the master switch for automatic phone
/// activity measurement and synchronisation.
///
/// The switch shows the user's choice; the status below it says whether
/// tracking is actually running (it waits for Usage Access when needed).
class ActivityTrackingSection extends StatefulWidget {
  const ActivityTrackingSection({super.key, this.tracking, this.service});

  final ActivityTrackingController? tracking;
  final ActivitySyncService? service;

  static const String title = 'Automatic Activity Tracking';
  static const String onDescription =
      'Automatically measures app usage and updates your activity data every 5 minutes while Personal Digital Twin is open.';
  static const String offDescription =
      'Activity tracking is paused. Personal Digital Twin will not collect or sync new app usage data.';

  @override
  State<ActivityTrackingSection> createState() =>
      _ActivityTrackingSectionState();
}

class _ActivityTrackingSectionState extends State<ActivityTrackingSection> {
  late final ActivityTrackingController _tracking =
      widget.tracking ?? ActivityTrackingController.instance;
  late final ActivitySyncService _service =
      widget.service ?? ActivitySyncService.instance;

  @override
  void initState() {
    super.initState();
    // Only checks whether Usage Access is granted; reads no usage data.
    unawaited(_refreshPermissions());
  }

  Future<void> _refreshPermissions() async {
    try {
      await _service.refreshPermissions();
    } catch (_) {}
  }

  Future<void> _toggle(bool value) async {
    final bool changed = await _tracking.setEnabled(value);
    if (!mounted) return;
    if (!changed) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Could not change tracking right now. Please try again.',
          ),
        ),
      );
      return;
    }
    if (value) await _refreshPermissions();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge(<Listenable>[
        _tracking,
        _service.permissions,
      ]),
      builder: (context, _) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
    final VivoraPalette p = context.palette;
    final bool resolved = _tracking.isResolved;
    final bool on = _tracking.isEnabled;
    final bool saving = _tracking.isSaving;
    final ActivityPermissionSnapshot permissions = _service.permissions.value;
    final bool waitingForPermission = on && !permissions.usageAccessGranted;

    final String status = !resolved
        ? 'Loading your tracking setting…'
        : !on
        ? 'Activity tracking is paused.'
        : waitingForPermission
        ? 'Tracking is on but waiting for Usage Access.'
        : 'Automatic activity tracking is on.';
    final String detail = !resolved
        ? 'Sign in to choose whether Personal Digital Twin tracks your phone activity.'
        : !on
        ? 'No new phone usage data is being collected or synchronized.'
        : waitingForPermission
        ? 'Nothing is measured until Usage Access is allowed for Personal Digital Twin in Android settings.'
        : 'Updates approximately every 5 minutes while the app is open.';
    final Color statusColor = !on
        ? p.textSecondary
        : waitingForPermission
        ? p.warning
        : p.success;

    return SectionCard(
      title: 'ACTIVITY TRACKING',
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(
            Space.lg,
            Space.md,
            Space.sm,
            Space.sm,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      ActivityTrackingSection.title,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: p.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      on
                          ? ActivityTrackingSection.onDescription
                          : ActivityTrackingSection.offDescription,
                      style: TextStyle(color: p.textSecondary),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: Space.sm),
              SizedBox(
                width: 60,
                height: 48,
                child: Center(
                  child: saving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Switch(value: on, onChanged: resolved ? _toggle : null),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.lg, 0, Space.lg, Space.md),
          child: Semantics(
            liveRegion: true,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(
                  on && !waitingForPermission
                      ? Icons.check_circle_rounded
                      : on
                      ? Icons.hourglass_top_rounded
                      : Icons.pause_circle_rounded,
                  size: 18,
                  color: statusColor,
                ),
                const SizedBox(width: Space.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        status,
                        style: TextStyle(
                          color: p.textPrimary,
                          fontWeight: FontWeight.w700,
                          fontSize: 13.5,
                        ),
                      ),
                      Text(
                        detail,
                        style: TextStyle(color: p.textSecondary, fontSize: 13),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        if (waitingForPermission)
          Padding(
            padding: const EdgeInsets.fromLTRB(Space.sm, 0, Space.sm, Space.sm),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                onPressed: _service.openUsageAccessSettings,
                icon: const Icon(Icons.security_rounded),
                label: const Text('Open Usage Access settings'),
              ),
            ),
          ),
      ],
    );
  }
}
