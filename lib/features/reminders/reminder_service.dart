import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The reminders the student chose. All are off until turned on.
@immutable
class ReminderSettings {
  const ReminderSettings({
    this.dailyLog = false,
    this.dailyLogTime = const TimeOfDay(hour: 21, minute: 0),
    this.study = false,
    this.studyTime = const TimeOfDay(hour: 18, minute: 0),
    this.focusEnd = false,
  });

  /// "Log today's progress" once a day (skipped on days already logged).
  final bool dailyLog;
  final TimeOfDay dailyLogTime;

  /// "Time for your study session" once a day, at a time the student picks.
  final bool study;
  final TimeOfDay studyTime;

  /// A notification when a running Focus Mode session ends (break time).
  final bool focusEnd;

  ReminderSettings copyWith({
    bool? dailyLog,
    TimeOfDay? dailyLogTime,
    bool? study,
    TimeOfDay? studyTime,
    bool? focusEnd,
  }) => ReminderSettings(
    dailyLog: dailyLog ?? this.dailyLog,
    dailyLogTime: dailyLogTime ?? this.dailyLogTime,
    study: study ?? this.study,
    studyTime: studyTime ?? this.studyTime,
    focusEnd: focusEnd ?? this.focusEnd,
  );

  bool get anyEnabled => dailyLog || study || focusEnd;

  @override
  bool operator ==(Object other) =>
      other is ReminderSettings &&
      other.dailyLog == dailyLog &&
      other.dailyLogTime == dailyLogTime &&
      other.study == study &&
      other.studyTime == studyTime &&
      other.focusEnd == focusEnd;

  @override
  int get hashCode =>
      Object.hash(dailyLog, dailyLogTime, study, studyTime, focusEnd);
}

/// Native side of reminders (`ReminderScheduler.kt`). Replaceable in tests.
abstract class ReminderPlatform {
  Future<bool> notificationsAllowed();
  Future<bool> requestPermission();
  Future<void> scheduleDaily({
    required int id,
    required TimeOfDay time,
    required String title,
    required String body,
    DateTime? notBefore,
  });
  Future<void> scheduleOnce({
    required int id,
    required DateTime at,
    required String title,
    required String body,
  });
  Future<void> cancel(int id);
}

class MethodChannelReminderPlatform implements ReminderPlatform {
  const MethodChannelReminderPlatform();

  static const MethodChannel _channel = MethodChannel('vivora/reminders');

  @override
  Future<bool> notificationsAllowed() async =>
      await _channel.invokeMethod<bool>('notificationsAllowed') ?? false;

  @override
  Future<bool> requestPermission() async =>
      await _channel.invokeMethod<bool>('requestNotificationPermission') ??
      false;

  @override
  Future<void> scheduleDaily({
    required int id,
    required TimeOfDay time,
    required String title,
    required String body,
    DateTime? notBefore,
  }) => _channel.invokeMethod<void>('scheduleDaily', <String, Object?>{
    'id': id,
    'hour': time.hour,
    'minute': time.minute,
    'title': title,
    'body': body,
    'notBeforeMillis': notBefore?.millisecondsSinceEpoch ?? 0,
  });

  @override
  Future<void> scheduleOnce({
    required int id,
    required DateTime at,
    required String title,
    required String body,
  }) => _channel.invokeMethod<void>('scheduleOnce', <String, Object?>{
    'id': id,
    'atMillis': at.millisecondsSinceEpoch,
    'title': title,
    'body': body,
  });

  @override
  Future<void> cancel(int id) =>
      _channel.invokeMethod<void>('cancel', <String, Object?>{'id': id});
}

/// Local Android reminders. Settings are stored on this phone (alarms are
/// per device), each reminder has a fixed id so re-scheduling replaces it,
/// and nothing is scheduled without notification permission.
class ReminderService {
  ReminderService({
    ReminderPlatform platform = const MethodChannelReminderPlatform(),
    Future<SharedPreferences> Function()? prefs,
    DateTime Function()? clock,
  }) : _platform = platform,
       _prefs = prefs ?? SharedPreferences.getInstance,
       _clock = clock ?? DateTime.now;

  static final ReminderService instance = ReminderService();

  static const int dailyLogId = 1001;
  static const int studyId = 1002;
  static const int focusEndId = 1003;

  final ReminderPlatform _platform;
  final Future<SharedPreferences> Function() _prefs;
  final DateTime Function() _clock;

  final ValueNotifier<ReminderSettings> settings =
      ValueNotifier<ReminderSettings>(const ReminderSettings());
  bool _loaded = false;

  static const String _k = 'vivora_reminders_v1';

  Future<ReminderSettings> load() async {
    if (_loaded) return settings.value;
    try {
      final SharedPreferences p = await _prefs();
      final List<String>? v = p.getStringList(_k);
      if (v != null && v.length == 5) {
        TimeOfDay t(String s) {
          final List<String> hm = s.split(':');
          return TimeOfDay(
            hour: (int.tryParse(hm.first) ?? 0).clamp(0, 23),
            minute: (int.tryParse(hm.last) ?? 0).clamp(0, 59),
          );
        }

        settings.value = ReminderSettings(
          dailyLog: v[0] == '1',
          dailyLogTime: t(v[1]),
          study: v[2] == '1',
          studyTime: t(v[3]),
          focusEnd: v[4] == '1',
        );
      }
    } catch (e) {
      debugPrint('Reminder settings unavailable: $e');
    }
    _loaded = true;
    return settings.value;
  }

  Future<bool> notificationsAllowed() async {
    try {
      return await _platform.notificationsAllowed();
    } catch (_) {
      return false;
    }
  }

  /// Saves [next] and updates the alarms. Turning a reminder on asks for
  /// notification permission first; returns false (and keeps it off) when
  /// permission is refused.
  Future<bool> update(ReminderSettings next) async {
    final ReminderSettings previous = settings.value;
    final bool enabling =
        (next.dailyLog && !previous.dailyLog) ||
        (next.study && !previous.study) ||
        (next.focusEnd && !previous.focusEnd);
    if (enabling) {
      bool allowed = await notificationsAllowed();
      if (!allowed) {
        try {
          allowed = await _platform.requestPermission();
        } catch (_) {
          allowed = false;
        }
      }
      if (!allowed) return false;
    }
    settings.value = next;
    await _save(next);
    await _apply(next);
    return true;
  }

  Future<void> _apply(ReminderSettings s) async {
    try {
      if (s.dailyLog) {
        await _platform.scheduleDaily(
          id: dailyLogId,
          time: s.dailyLogTime,
          title: 'Log today\'s progress',
          body:
              'Add your sleep, study and focus time so Personal Digital Twin can score your day.',
        );
      } else {
        await _platform.cancel(dailyLogId);
      }
      if (s.study) {
        await _platform.scheduleDaily(
          id: studyId,
          time: s.studyTime,
          title: 'Study session time',
          body: 'Start a Focus Mode session for your planned study block.',
        );
      } else {
        await _platform.cancel(studyId);
      }
      if (!s.focusEnd) await _platform.cancel(focusEndId);
    } catch (e) {
      debugPrint('Reminders not scheduled: $e');
    }
  }

  /// Today's log was saved: skip today's log reminder (next one tomorrow).
  Future<void> onLoggedToday() async {
    final ReminderSettings s = await load();
    if (!s.dailyLog) return;
    final DateTime now = _clock();
    try {
      await _platform.scheduleDaily(
        id: dailyLogId,
        time: s.dailyLogTime,
        title: 'Log today\'s progress',
        body:
            'Add your sleep, study and focus time so Personal Digital Twin can score your day.',
        notBefore: DateTime(now.year, now.month, now.day + 1),
      );
    } catch (e) {
      debugPrint('Log reminder not moved: $e');
    }
  }

  /// A Focus Mode session started (or resumed) and will end at [end].
  Future<void> onFocusRunning(DateTime end) async {
    final ReminderSettings s = await load();
    if (!s.focusEnd) return;
    try {
      await _platform.scheduleOnce(
        id: focusEndId,
        at: end,
        title: 'Focus session complete',
        body: 'Nice work. Take a short break before your next session.',
      );
    } catch (e) {
      debugPrint('Focus reminder not scheduled: $e');
    }
  }

  /// The session was paused, stopped or finished inside the app.
  Future<void> onFocusStopped() async {
    try {
      await _platform.cancel(focusEndId);
    } catch (_) {}
  }

  Future<void> _save(ReminderSettings s) async {
    String t(TimeOfDay x) => '${x.hour}:${x.minute}';
    try {
      final SharedPreferences p = await _prefs();
      await p.setStringList(_k, <String>[
        s.dailyLog ? '1' : '0',
        t(s.dailyLogTime),
        s.study ? '1' : '0',
        t(s.studyTime),
        s.focusEnd ? '1' : '0',
      ]);
    } catch (e) {
      debugPrint('Reminder settings not saved: $e');
    }
  }
}
