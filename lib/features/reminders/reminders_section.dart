import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme/vivora_palette.dart';
import '../../core/widgets/ui_kit.dart';
import 'reminder_service.dart';

/// Settings section for local reminders. Every reminder is off until the
/// student turns it on; turning one on asks for notification permission.
class RemindersSection extends StatefulWidget {
  const RemindersSection({super.key, this.service});

  final ReminderService? service;

  @override
  State<RemindersSection> createState() => _RemindersSectionState();
}

class _RemindersSectionState extends State<RemindersSection> {
  late final ReminderService _service =
      widget.service ?? ReminderService.instance;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_service.load());
  }

  Future<void> _update(ReminderSettings next) async {
    if (_busy) return;
    setState(() => _busy = true);
    final bool ok = await _service.update(next);
    if (!mounted) return;
    setState(() => _busy = false);
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Notifications are turned off for Personal Digital Twin. Allow them in Android settings to use reminders.',
          ),
        ),
      );
    }
  }

  Future<void> _pickTime(
    TimeOfDay initial,
    ReminderSettings Function(TimeOfDay) apply,
  ) async {
    final TimeOfDay? t = await showTimePicker(
      context: context,
      initialTime: initial,
    );
    if (t != null) await _update(apply(t));
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ReminderSettings>(
      valueListenable: _service.settings,
      builder: (context, s, _) => SectionCard(
        title: 'REMINDERS',
        children: <Widget>[
          _toggle(
            icon: Icons.edit_note_rounded,
            title: 'Daily log reminder',
            value: 'Skipped on days you have already logged',
            on: s.dailyLog,
            onChanged: (v) => _update(s.copyWith(dailyLog: v)),
          ),
          if (s.dailyLog)
            InfoRow(
              icon: Icons.schedule_rounded,
              title: 'Log reminder time',
              value: s.dailyLogTime.format(context),
              onTap: () =>
                  _pickTime(s.dailyLogTime, (t) => s.copyWith(dailyLogTime: t)),
            ),
          _toggle(
            icon: Icons.auto_stories_rounded,
            title: 'Study session reminder',
            value: 'Once a day at a time you choose',
            on: s.study,
            onChanged: (v) => _update(s.copyWith(study: v)),
          ),
          if (s.study)
            InfoRow(
              icon: Icons.schedule_rounded,
              title: 'Study reminder time',
              value: s.studyTime.format(context),
              onTap: () =>
                  _pickTime(s.studyTime, (t) => s.copyWith(studyTime: t)),
            ),
          _toggle(
            icon: Icons.free_breakfast_rounded,
            title: 'Focus break alert',
            value: 'When a Focus Mode session ends, even if Personal Digital Twin is closed',
            on: s.focusEnd,
            onChanged: (v) => _update(s.copyWith(focusEnd: v)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Space.lg,
              Space.sm,
              Space.lg,
              Space.md,
            ),
            child: Text(
              'Reminders are set on this phone only. To save battery, Android may deliver them a few minutes late.',
              style: TextStyle(
                color: context.palette.textSecondary,
                fontSize: 12.5,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _toggle({
    required IconData icon,
    required String title,
    required String value,
    required bool on,
    required ValueChanged<bool> onChanged,
  }) {
    return InfoRow(
      icon: icon,
      title: title,
      value: value,
      onTap: _busy ? null : () => onChanged(!on),
      trailing: Switch(value: on, onChanged: _busy ? null : onChanged),
    );
  }
}
