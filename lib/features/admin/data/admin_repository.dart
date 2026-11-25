import 'package:cloud_firestore/cloud_firestore.dart';
import '../../activity_monitoring/data/models/activity_date_utils.dart';
import '../../activity_monitoring/data/models/app_usage_entry.dart';
import '../../activity_monitoring/data/models/daily_activity_log.dart';
import '../../first_time_setup/data/models/user_profile_model.dart';
import '../../focus_mode/data/focus_session_repository.dart';
import '../../insights/data/history_data.dart';
import '../../productivity_scoring/data/models/productivity_models.dart';
import 'admin_models.dart';

class AdminPage {
  const AdminPage(this.users, this.cursor, this.hasMore);
  final List<AdminUser> users;
  final DocumentSnapshot<Map<String, dynamic>>? cursor;
  final bool hasMore;
}

/// Read-only repository; every request uses the isolated administrator client.
/// No collection-group reads, writes, chat retrieval or Gemini calls.
class AdminRepository {
  AdminRepository(this.db);
  final FirebaseFirestore db;
  static const server = GetOptions(source: Source.server);
  static const timeout = Duration(seconds: 18);
  CollectionReference<Map<String, dynamic>> get users => db.collection('users');

  Future<int> userCount() async =>
      (await users.count().get().timeout(timeout)).count ?? 0;
  Future<List<AdminUser>> recentUsers() async =>
      (await users
              .orderBy('createdAt', descending: true)
              .limit(6)
              .get(server)
              .timeout(timeout))
          .docs
          .map((d) => AdminUser(d.id, d.data()))
          .toList();

  Future<AdminPage> page([
    DocumentSnapshot<Map<String, dynamic>>? after,
  ]) async {
    Query<Map<String, dynamic>> query = users
        .orderBy(FieldPath.documentId)
        .limit(20);
    if (after != null) query = query.startAfterDocument(after);
    final snap = await query.get(server).timeout(timeout);
    final result = <AdminUser>[];
    // Four users at a time bounds requests without downloading their history.
    for (var i = 0; i < snap.docs.length; i += 4) {
      result.addAll(await Future.wait(snap.docs.skip(i).take(4).map(_summary)));
    }
    return AdminPage(
      result,
      snap.docs.isEmpty ? after : snap.docs.last,
      snap.docs.length == 20,
    );
  }

  Future<AdminUser> _summary(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) async {
    final ref = doc.reference;
    final daily = ref.collection('dailyLogs');
    Query<Map<String, dynamic>> valid(
      Query<Map<String, dynamic>> q,
      String field,
      double max,
    ) => q
        .where(field, isGreaterThanOrEqualTo: 0)
        .where(field, isLessThanOrEqualTo: max);
    try {
      final results = await Future.wait<Object>([
        ref.collection('settings').doc('activityTracking').get(server),
        ref
            .collection('activityLogs')
            .orderBy('lastSyncAt', descending: true)
            .limit(1)
            .get(server),
        daily.orderBy('updatedAt', descending: true).limit(1).get(server),
        ref
            .collection('focusSessions')
            .orderBy('endedAt', descending: true)
            .limit(1)
            .get(server),
        valid(
          daily,
          'actualStudyHours',
          24,
        ).aggregate(sum('actualStudyHours')).get(),
        valid(
          ref.collection('focusSessions'),
          'focusedSeconds',
          86400,
        ).aggregate(sum('focusedSeconds'), count()).get(),
        valid(
          daily,
          'overallScore',
          100,
        ).aggregate(sum('overallScore'), count()).get(),
      ]).timeout(timeout);
      final tracking = (results[0] as DocumentSnapshot<Map<String, dynamic>>)
          .data()?['enabled'];
      final dates = <DateTime>[
        for (var i = 1; i <= 3; i++)
          for (final d
              in (results[i] as QuerySnapshot<Map<String, dynamic>>).docs)
            if (adminDate(
                  d.data()[['', 'lastSyncAt', 'updatedAt', 'endedAt'][i]],
                )
                case final DateTime at)
              at,
      ]..sort();
      final focus = results[5] as AggregateQuerySnapshot;
      final scores = results[6] as AggregateQuerySnapshot;
      return AdminUser(
        doc.id,
        doc.data(),
        tracking: tracking is bool ? tracking : null,
        lastActivity: dates.isEmpty ? null : dates.last,
        studyHours: (results[4] as AggregateQuerySnapshot).getSum(
          'actualStudyHours',
        ),
        focusSeconds: focus.getSum('focusedSeconds'),
        focusCount: focus.count,
        scoreSum: scores.getSum('overallScore'),
        scoreCount: scores.count,
      );
    } catch (_) {
      // Missing/unreadable data is not presented as a zero or a disabled switch.
      return AdminUser(
        doc.id,
        doc.data(),
        loadError: 'Some statistics could not be loaded. Refresh to retry.',
      );
    }
  }

  Future<HistoryData> history(AdminUser user) async {
    final now = DateTime.now();
    final from = ActivityDateUtils.lastDays(now, 60).first;
    final ref = users.doc(user.uid);
    final result = await Future.wait<Object>([
      ref
          .collection('dailyLogs')
          .where(
            FieldPath.documentId,
            isGreaterThanOrEqualTo: ActivityDateUtils.dayKey(from),
          )
          .where(
            FieldPath.documentId,
            isLessThanOrEqualTo: ActivityDateUtils.dayKey(now),
          )
          .get(server),
      ref
          .collection('activityLogs')
          .where(
            FieldPath.documentId,
            isGreaterThanOrEqualTo: ActivityDateUtils.documentIdFor(from),
          )
          .where(
            FieldPath.documentId,
            isLessThanOrEqualTo: ActivityDateUtils.documentIdFor(now),
          )
          .get(server),
      ref
          .collection('focusSessions')
          .where(
            'dateKey',
            isGreaterThanOrEqualTo: ActivityDateUtils.dayKey(from),
          )
          .where('dateKey', isLessThanOrEqualTo: ActivityDateUtils.dayKey(now))
          .get(server),
      ref.collection('settings').doc('appCategories').get(server),
    ]).timeout(timeout);
    final scores = <SavedDailyScore>[];
    final activity = <DailyActivityLog>[];
    final focus = <FocusSession>[];
    for (final d in (result[0] as QuerySnapshot<Map<String, dynamic>>).docs) {
      try {
        scores.add(SavedDailyScore.fromMap(d.data(), documentId: d.id));
      } catch (_) {
        /* Invalid legacy record omitted. */
      }
    }
    for (final d in (result[1] as QuerySnapshot<Map<String, dynamic>>).docs) {
      try {
        activity.add(DailyActivityLog.fromMap(d.data(), documentId: d.id));
      } catch (_) {
        /* Invalid legacy record omitted. */
      }
    }
    for (final d in (result[2] as QuerySnapshot<Map<String, dynamic>>).docs) {
      try {
        focus.add(FocusSession.fromMap(d.data(), id: d.id));
      } catch (_) {
        /* Invalid legacy record omitted. */
      }
    }
    final goals = adminMap(user.profile['goals']);
    return HistoryData(
      today: now,
      activityLogs: activity,
      appUsageByDay: const {},
      scores: scores,
      focusSessions: focus,
      goals: UserGoals(
        targetSleepHours: goals['targetSleepHours'] is String
            ? goals['targetSleepHours']
            : '',
        targetStudyHours: goals['targetStudyHours'] is String
            ? goals['targetStudyHours']
            : '',
        targetFocusHours: goals['targetFocusHours'] is String
            ? goals['targetFocusHours']
            : '',
        targetScreenTimeLimit: goals['targetScreenTimeLimit'] is String
            ? goals['targetScreenTimeLimit']
            : '',
      ),
      categoryOverrides: {
        for (final e
            in ((result[3] as DocumentSnapshot<Map<String, dynamic>>).data() ??
                    {})
                .entries)
          if (e.key != 'updatedAt')
            e.key: AppCategoryX.fromValue(e.value is String ? e.value : null),
      },
    );
  }

  Future<List<AppUsageEntry>> apps(String uid, DailyActivityLog log) async {
    if (log.appSummary != null) return log.appSummary!;
    final snap = await users
        .doc(uid)
        .collection('activityLogs')
        .doc(log.documentId)
        .collection('appUsage')
        .get(server)
        .timeout(timeout);
    final result = <AppUsageEntry>[];
    for (final d in snap.docs) {
      try {
        final app = AppUsageEntry.fromMap(d.data());
        if (log.captureId == null || app.captureId == log.captureId) {
          result.add(app);
        }
      } catch (_) {
        /* Invalid legacy app omitted. */
      }
    }
    return result;
  }

  Future<List<Map<String, dynamic>>> savedAi(String uid) async {
    final ref = users.doc(uid);
    final result = await Future.wait<Object>([
      ref
          .collection('aiRecommendations')
          .orderBy('generatedAt', descending: true)
          .limit(40)
          .get(server),
      ref
          .collection('aiSummaries')
          .orderBy('generatedAt', descending: true)
          .limit(30)
          .get(server),
      ref.collection('aiState').doc('advice').get(server),
      ref.collection('aiState').doc('studyPlan').get(server),
    ]).timeout(timeout);
    return [
      for (var i = 0; i < 2; i++)
        for (final d in (result[i] as QuerySnapshot<Map<String, dynamic>>).docs)
          {
            ...d.data(),
            '_type': i == 0 ? 'Recommendation & feedback' : 'Saved summary',
          },
      for (var i = 2; i < 4; i++)
        if ((result[i] as DocumentSnapshot<Map<String, dynamic>>).exists)
          {
            ...(result[i] as DocumentSnapshot<Map<String, dynamic>>).data()!,
            '_type': i == 2 ? 'Adaptive goals' : 'Study plan',
          },
    ];
  }
}
