import 'package:cloud_firestore/cloud_firestore.dart';

DateTime? adminDate(Object? value) => value is Timestamp
    ? value.toDate()
    : value is DateTime
    ? value
    : value is String
    ? DateTime.tryParse(value)
    : null;
double? adminNumber(Object? value, {double max = double.infinity}) =>
    value is num && value.isFinite && value >= 0 && value <= max
    ? value.toDouble()
    : null;
String adminText(Object? value) =>
    value is String && value.trim().isNotEmpty ? value : 'Not recorded';
Map<String, dynamic> adminMap(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : {};

class AdminUser {
  const AdminUser(
    this.uid,
    this.profile, {
    this.tracking,
    this.lastActivity,
    this.studyHours,
    this.focusSeconds,
    this.focusCount,
    this.scoreSum,
    this.scoreCount,
    this.loadError,
  });
  final String uid;
  final Map<String, dynamic> profile;
  final bool? tracking;
  final DateTime? lastActivity;
  final double? studyHours, focusSeconds, scoreSum;
  final int? focusCount, scoreCount;
  final String? loadError;
  String get name => adminText(profile['fullName']);
  String get email => adminText(profile['email']);
  DateTime? get createdAt => adminDate(profile['createdAt']);
  double? get score =>
      adminNumber(profile['latestProductivityScore'], max: 100);
  bool activeAt(DateTime now) =>
      lastActivity != null &&
      !lastActivity!.isAfter(now) &&
      !lastActivity!.isBefore(now.subtract(const Duration(days: 7)));
}

class AdminTotals {
  AdminTotals(List<AdminUser> users, DateTime now) {
    for (final u in users) {
      if (u.activeAt(now)) active++;
      if (u.tracking == true) tracking++;
      if (u.loadError != null) incomplete++;
      studyHours += u.studyHours ?? 0;
      focusSeconds += u.focusSeconds ?? 0;
      sessions += u.focusCount ?? 0;
      scoreSum += u.scoreSum ?? 0;
      scoreCount += u.scoreCount ?? 0;
    }
  }
  int active = 0, tracking = 0, sessions = 0, scoreCount = 0, incomplete = 0;
  double studyHours = 0, focusSeconds = 0, scoreSum = 0;
  double? get averageScore => scoreCount == 0 ? null : scoreSum / scoreCount;
}
