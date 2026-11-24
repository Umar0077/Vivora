import 'package:flutter/material.dart';
import 'package:vivora/core/theme/vivora_palette.dart';

import '../../../../core/widgets/info_card.dart';
import '../../../../core/widgets/primary_button.dart';
import '../../../../core/widgets/secondary_button.dart';
import '../../data/models/activity_sync_snapshot.dart';
import '../../data/models/activity_sync_state.dart';
import '../../data/models/app_usage_entry.dart';
import '../../data/models/daily_activity_log.dart';
import '../../data/services/activity_sync_service.dart';
import '../../data/services/activity_tracking_controller.dart';

/// Tracking status, today's device metrics and sync/cloud state.
///
/// Reads everything from [ActivitySyncService] notifiers so every screen that
/// embeds it shows the same snapshot.
class TrackingStatusCard extends StatelessWidget {
  TrackingStatusCard({
    super.key,
    ActivitySyncService? service,
    ActivityTrackingController? tracking,
    this.now,
  }) : service = service ?? ActivitySyncService.instance,
       tracking = tracking ?? ActivityTrackingController.instance;

  final ActivitySyncService service;

  /// The Settings switch; when OFF the card shows paused, last recorded data.
  final ActivityTrackingController tracking;

  /// Clock for the "x min ago" text; injectable for tests.
  final DateTime Function()? now;

  Listenable get _listenable => Listenable.merge(<Listenable>[
    tracking,
    service.syncState,
    service.permissions,
    service.today,
    service.cloudStatus,
    service.latestResult,
  ]);

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _listenable,
      builder: (BuildContext context, Widget? child) => _build(context),
    );
  }

  Future<void> _enableTracking(BuildContext context) async {
    final ActivityPermissionSnapshot snapshot = await service
        .refreshPermissions();
    if (!snapshot.usageAccessGranted) {
      await service.openUsageAccessSettings();
      return;
    }
    if (!snapshot.activityPermissionGranted) {
      final bool granted = await service.requestActivityPermission();
      if (!granted && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Physical activity permission was denied. Movement will show as unavailable.',
            ),
          ),
        );
      }
    }
    await service.syncNow(force: true);
  }

  Widget _build(BuildContext context) {
    final ActivitySyncState syncState = service.syncState.value;
    final ActivityPermissionSnapshot permissions = service.permissions.value;
    final TodayActivity? today = service.today.value;
    final DailyActivityLog? log = today?.log;
    final CloudSyncStatus cloud = service.cloudStatus.value;
    final bool trackingOff = !tracking.isEnabled;
    // Permission prompts only matter while tracking is on.
    final bool needsUsage = !trackingOff && !permissions.usageAccessGranted;
    final bool needsActivity =
        !trackingOff && !permissions.activityPermissionGranted;
    final bool isSyncing = syncState == ActivitySyncState.syncing;
    final String? error = syncState == ActivitySyncState.failed
        ? service.latestResult.value?.message
        : null;

    final Color accent = trackingOff
        ? context.palette.textSecondary
        : needsUsage
        ? Colors.orange
        : syncState == ActivitySyncState.failed
        ? context.palette.danger
        : context.brand;

    return InfoCard(
      gradient: context.palette.cardGradient,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: accent,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Automatic Tracking',
                  softWrap: true,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: context.palette.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Own line: sharing the title's row squeezed the title until it
          // broke between letters ("Automati c Tracki…").
          _StatusChip(
            label: trackingOff ? 'Paused' : _statusLabel(syncState, needsUsage),
          ),
          if (trackingOff && log != null) ...<Widget>[
            const SizedBox(height: 10),
            Text(
              'Showing the last recorded values. Nothing new is measured while tracking is off.',
              style: TextStyle(
                color: context.palette.textSecondary,
                fontSize: 13,
              ),
            ),
          ] else if (!trackingOff &&
              log != null &&
              log.isPartiallyTracked) ...<Widget>[
            const SizedBox(height: 10),
            Text(
              'Today is only partly measured: tracking was off for part of the day.',
              style: TextStyle(
                color: context.palette.textSecondary,
                fontSize: 13,
              ),
            ),
          ],
          const SizedBox(height: 16),
          if (needsUsage) ...<Widget>[
            Text(
              'Allow Usage Access so Personal Digital Twin can measure screen time and app usage on this phone.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: context.palette.textSecondary,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 14),
          ],
          _TrackingRow(
            label: 'Usage Access',
            value: permissions.usageAccessGranted
                ? 'Enabled'
                : trackingOff
                ? 'Not allowed'
                : 'Required',
          ),
          const SizedBox(height: 10),
          _TrackingRow(
            label: 'Physical Activity',
            value: !permissions.activityPermissionGranted
                ? 'Not allowed'
                : permissions.backgroundSyncEnabled
                ? 'Enabled'
                : 'Allowed, not registered',
          ),
          const SizedBox(height: 10),
          _TrackingRow(
            label: 'App usage today',
            value: log?.appUsageMinutes == null
                ? 'No data yet'
                : formatMinutes(log!.appUsageMinutes!),
          ),
          const SizedBox(height: 10),
          _TrackingRow(
            label: 'Screen unlocked',
            value: log == null
                ? 'No data yet'
                : log.screenTimeMinutes == null
                ? 'Not reported by this phone'
                : formatMinutes(log.screenTimeMinutes!),
          ),
          const SizedBox(height: 10),
          _TrackingRow(
            label: 'Unlocks',
            value: log?.phoneUnlockCount?.toString() ?? 'No data yet',
          ),
          const SizedBox(height: 10),
          _TrackingRow(label: 'Top app', value: _topApp(today)),
          const SizedBox(height: 10),
          _TrackingRow(label: 'Movement', value: movementLabel(log)),
          const SizedBox(height: 10),
          _TrackingRow(
            label: trackingOff ? 'Last recorded' : 'Last device sync',
            value: _formatTime(log?.lastSyncAt),
          ),
          const SizedBox(height: 10),
          _TrackingRow(label: 'Cloud', value: cloud.label),
          if (error != null) ...<Widget>[
            const SizedBox(height: 12),
            Text(
              error,
              style: TextStyle(color: context.palette.danger, fontSize: 13),
            ),
          ],
          const SizedBox(height: 18),
          _AutoSyncLine(
            text: autoSyncStatus(
              trackingOff: trackingOff,
              syncState: syncState,
              needsUsage: needsUsage,
              cloud: cloud.state,
              lastSyncAt: log?.lastSyncAt,
              now: (now ?? DateTime.now)(),
              use24h: MediaQuery.alwaysUse24HourFormatOf(context),
            ),
            busy: isSyncing,
          ),
          if (needsUsage) ...<Widget>[
            const SizedBox(height: 14),
            PrimaryButton(
              label: 'Enable Usage Access',
              onPressed: () => _enableTracking(context),
              icon: Icons.security_rounded,
              isLoading: isSyncing,
            ),
          ] else if (needsActivity) ...<Widget>[
            const SizedBox(height: 14),
            SecondaryButton(
              label: 'Allow Activity',
              onPressed: () => _enableTracking(context),
            ),
          ],
        ],
      ),
    );
  }

  /// Human-readable movement state; never shows a guessed duration.
  static String movementLabel(DailyActivityLog? log) {
    if (log == null) {
      return 'No data yet';
    }
    switch (log.movementStatus) {
      case 'permissionDenied':
        return 'Permission not granted';
      case 'notRegistered':
        return 'Not started';
      case 'noSamples':
        return 'No readings yet today';
      case 'available':
        final int active = log.activeMinutes ?? 0;
        return active > 0
            ? '${formatMinutes(active)} walking/running'
            : 'No walking detected';
      default:
        return 'Unavailable';
    }
  }

  String _topApp(TodayActivity? today) {
    if (today == null || today.apps.isEmpty) {
      return 'No app data yet';
    }
    final AppUsageEntry top = today.apps.first;
    return '${top.displayName} (${top.durationLabel})';
  }

  String _formatTime(DateTime? time) {
    if (time == null) {
      return 'Never';
    }
    final DateTime local = time.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }

  String _statusLabel(ActivitySyncState state, bool needsUsage) {
    if (needsUsage) {
      return 'Permission required';
    }
    switch (state) {
      case ActivitySyncState.syncing:
        return 'Syncing';
      case ActivitySyncState.failed:
        return 'Error';
      case ActivitySyncState.permissionRequired:
        return 'Permission required';
      case ActivitySyncState.trackingOff:
        return 'Paused';
      case ActivitySyncState.idle:
        return 'Waiting';
      case ActivitySyncState.success:
      case ActivitySyncState.partialData:
        return 'Active';
    }
  }
}

class _TrackingRow extends StatelessWidget {
  const _TrackingRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final textTheme = Theme.of(context).textTheme;
        final isCompact = constraints.maxWidth < 340;

        if (isCompact) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                label,
                style: textTheme.bodyMedium?.copyWith(
                  color: context.palette.textSecondary,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                value,
                style: textTheme.titleSmall?.copyWith(
                  color: context.palette.textPrimary,
                  fontWeight: FontWeight.w700,
                ),
                softWrap: true,
              ),
            ],
          );
        }

        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: Text(
                label,
                style: textTheme.bodyMedium?.copyWith(
                  color: context.palette.textSecondary,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Flexible(
              child: Text(
                value,
                textAlign: TextAlign.right,
                style: textTheme.titleSmall?.copyWith(
                  color: context.palette.textPrimary,
                  fontWeight: FontWeight.w700,
                ),
                softWrap: true,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: context.brand.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: context.brand,
          fontWeight: FontWeight.w700,
          fontSize: 12,
        ),
      ),
    );
  }
}

/// One honest sentence about automatic syncing, derived from the real state:
/// never "updated" when the device read or the upload failed.
String autoSyncStatus({
  bool trackingOff = false,
  required ActivitySyncState syncState,
  required bool needsUsage,
  required CloudSyncState cloud,
  required DateTime? lastSyncAt,
  required DateTime now,
  bool use24h = true,
}) {
  if (trackingOff || syncState == ActivitySyncState.trackingOff) {
    return 'Activity tracking is turned off in Settings.';
  }
  if (needsUsage || syncState == ActivitySyncState.permissionRequired) {
    return 'Waiting for Usage Access permission. Updates start automatically once it is allowed.';
  }
  if (syncState == ActivitySyncState.syncing) {
    return 'Updating activity…';
  }
  if (syncState == ActivitySyncState.failed) {
    return 'Could not read activity from this phone. Personal Digital Twin will try again automatically.';
  }
  switch (cloud) {
    case CloudSyncState.pendingOffline:
      return 'Offline. Activity is saved on this phone and uploads when you are back online.';
    case CloudSyncState.permissionDenied:
    case CloudSyncState.unauthenticated:
      return 'Could not upload activity. Please sign in again.';
    case CloudSyncState.failed:
      return 'Upload failed. Personal Digital Twin will try again automatically.';
    case CloudSyncState.idle:
    case CloudSyncState.uploading:
    case CloudSyncState.synced:
      break;
  }
  if (lastSyncAt == null) {
    return 'Activity updates automatically.';
  }
  final DateTime t = lastSyncAt.toLocal();
  final String hhmm = use24h
      ? '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}'
      : '${t.hour % 12 == 0 ? 12 : t.hour % 12}:${t.minute.toString().padLeft(2, '0')} ${t.hour < 12 ? 'AM' : 'PM'}';
  final int minutes = now.difference(lastSyncAt).inMinutes;
  final String ago = minutes < 1
      ? 'just now'
      : minutes < 60
      ? '$minutes min ago'
      : 'at $hhmm';
  final String when = minutes < 60 ? '$hhmm ($ago)' : ago;
  return 'Updates automatically every 5 minutes while Personal Digital Twin is open. Last updated $when.';
}

class _AutoSyncLine extends StatelessWidget {
  const _AutoSyncLine({required this.text, required this.busy});

  final String text;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: busy
                ? SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: context.brand,
                    ),
                  )
                : Icon(Icons.autorenew_rounded, size: 18, color: context.brand),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: context.palette.textSecondary,
                fontSize: 13,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
