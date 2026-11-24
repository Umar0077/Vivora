import 'package:shared_preferences/shared_preferences.dart';

import '../../activity_monitoring/data/models/activity_date_utils.dart';
import '../domain/ai_failure.dart';

/// Per-user, per-day request budget on this phone, plus a short cool-down
/// between requests.
///
/// This keeps normal use cheap and stops accidental bursts (double taps,
/// retry loops). It is NOT a security control: a modified client could skip
/// it. Google enforces the API project's quota; this local limiter does not
/// protect a key embedded in a temporary testing build.
class AiUsageLimiter {
  AiUsageLimiter({
    this.dailyLimit = 40,
    this.minInterval = const Duration(seconds: 3),
    DateTime Function()? clock,
    Future<SharedPreferences> Function()? prefs,
  }) : _clock = clock ?? DateTime.now,
       _prefs = prefs ?? SharedPreferences.getInstance;

  final int dailyLimit;
  final Duration minInterval;
  final DateTime Function() _clock;
  final Future<SharedPreferences> Function() _prefs;
  final Map<String, DateTime> _last = <String, DateTime>{};
  final Set<String> _reserving = <String>{};

  static String _key(String uid) => 'vivora_ai_usage_$uid';

  /// Requests left today for [uid].
  Future<int> remaining(String uid) async {
    final (String day, int used) = await _read(uid);
    return day == ActivityDateUtils.dayKey(_clock())
        ? (dailyLimit - used).clamp(0, dailyLimit)
        : dailyLimit;
  }

  /// Reserves one request or throws [AiFailureKind.localLimit] /
  /// [AiFailureKind.rateLimited].
  Future<void> acquire(String uid) async {
    if (!_reserving.add(uid)) {
      throw const AiFailure(AiFailureKind.rateLimited, 'reservation pending');
    }
    try {
      await _reserve(uid);
    } finally {
      _reserving.remove(uid);
    }
  }

  Future<void> _reserve(String uid) async {
    final DateTime now = _clock();
    final DateTime? last = _last[uid];
    if (last != null && now.difference(last) < minInterval) {
      throw const AiFailure(AiFailureKind.rateLimited, 'local cool-down');
    }
    final String today = ActivityDateUtils.dayKey(now);
    final (String day, int used) = await _read(uid);
    final int count = day == today ? used : 0;
    if (count >= dailyLimit) {
      throw const AiFailure(AiFailureKind.localLimit);
    }
    _last[uid] = now;
    try {
      final SharedPreferences p = await _prefs();
      await p.setString(_key(uid), '$today:${count + 1}');
    } catch (_) {
      // Storage unavailable: the cool-down still applies.
    }
  }

  Future<(String, int)> _read(String uid) async {
    try {
      final SharedPreferences p = await _prefs();
      final String? raw = p.getString(_key(uid));
      final List<String> parts = (raw ?? '').split(':');
      if (parts.length == 2) {
        return (parts[0], int.tryParse(parts[1]) ?? 0);
      }
    } catch (_) {}
    return ('', 0);
  }
}
