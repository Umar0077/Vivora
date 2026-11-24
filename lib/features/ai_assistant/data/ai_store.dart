import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../domain/ai_models.dart';

/// Saved advice metadata: when it was generated, from which data, and the
/// goal suggestions not yet accepted or rejected.
class StoredAdvice {
  const StoredAdvice({
    required this.generatedAt,
    required this.fingerprint,
    required this.goalSuggestions,
    required this.model,
  });

  final DateTime generatedAt;
  final String fingerprint;
  final List<GoalSuggestion> goalSuggestions;
  final String model;
}

/// Persistence for Module 6. Every method is scoped to one user id.
abstract class AiStore {
  /// Most recent first.
  Future<List<AiRecommendation>> loadRecommendations(String uid);
  Future<StoredAdvice?> loadAdvice(String uid);
  Future<void> saveAdvice(
    String uid,
    AdviceBatch batch, {
    required String model,
  });
  Future<void> saveGoalSuggestions(String uid, List<GoalSuggestion> remaining);
  Future<void> updateStatus(
    String uid,
    String id,
    RecommendationStatus status,
    DateTime at,
  );

  Future<AiSummary?> loadSummary(
    String uid,
    SummaryKind kind,
    String periodKey,
  );
  Future<void> saveSummary(String uid, AiSummary summary);

  Future<StudyPlan?> loadStudyPlan(String uid);
  Future<void> saveStudyPlan(String uid, StudyPlan plan);

  /// Oldest first, at most [limit] latest messages.
  Future<List<ChatMessage>> loadChat(String uid, {int limit = 60});
  Future<void> addChatMessage(String uid, ChatMessage message);
  Future<void> clearChat(String uid);
}

/// Firestore layout (all under the user's own document, covered by the
/// existing `users/{uid}/{document=**}` owner-only rule):
///
/// ```
/// users/{uid}/aiRecommendations/{recId}   one recommendation + its status
/// users/{uid}/aiState/advice              generatedAt, fingerprint, model,
///                                         pending goal suggestions
/// users/{uid}/aiState/studyPlan           latest suggested plan
/// users/{uid}/aiSummaries/{kind_yyyy-MM-dd} cached daily / weekly summary
/// users/{uid}/aiChat/{messageId}          role, text, createdAt
/// ```
///
/// Only AI output, the student's own chat text and feedback are stored; the
/// data context sent to the model is never saved.
class FirestoreAiStore implements AiStore {
  FirestoreAiStore({FirebaseFirestore? firestore}) : _db = firestore;

  final FirebaseFirestore? _db;
  FirebaseFirestore get _firestore => _db ?? FirebaseFirestore.instance;

  static const Duration _readTimeout = Duration(seconds: 8);
  static const Duration _writeTimeout = Duration(seconds: 10);

  DocumentReference<Map<String, dynamic>> _user(String uid) =>
      _firestore.collection('users').doc(uid);

  /// Offline-first write: returns once cached locally or after a timeout; the
  /// upload continues in the background.
  Future<void> _write(Future<void> write) async {
    try {
      await write.timeout(_writeTimeout);
    } on TimeoutException {
      unawaited(
        write.catchError(
          (Object e) => debugPrint('AI store upload: ${e.runtimeType}'),
        ),
      );
    }
  }

  @override
  Future<List<AiRecommendation>> loadRecommendations(String uid) async {
    final QuerySnapshot<Map<String, dynamic>> snap = await _user(uid)
        .collection('aiRecommendations')
        .orderBy('generatedAt', descending: true)
        .limit(40)
        .get()
        .timeout(_readTimeout);
    return snap.docs
        .map((d) => AiRecommendation.fromMap(d.data()))
        .whereType<AiRecommendation>()
        .toList();
  }

  @override
  Future<StoredAdvice?> loadAdvice(String uid) async {
    final DocumentSnapshot<Map<String, dynamic>> doc = await _user(
      uid,
    ).collection('aiState').doc('advice').get().timeout(_readTimeout);
    final Map<String, dynamic>? m = doc.data();
    final DateTime? at = DateTime.tryParse('${m?['generatedAt'] ?? ''}');
    if (m == null || at == null) return null;
    return StoredAdvice(
      generatedAt: at,
      fingerprint: '${m['fingerprint'] ?? ''}',
      model: '${m['model'] ?? ''}',
      goalSuggestions: <GoalSuggestion>[
        for (final Object? g
            in (m['goalSuggestions'] is List
                ? m['goalSuggestions'] as List
                : const []))
          if (g is Map<String, dynamic>) ?GoalSuggestion.fromMap(g),
      ],
    );
  }

  @override
  Future<void> saveAdvice(
    String uid,
    AdviceBatch batch, {
    required String model,
  }) async {
    final WriteBatch b = _firestore.batch();
    for (final AiRecommendation r in batch.recommendations) {
      b.set(
        _user(uid).collection('aiRecommendations').doc(r.id),
        <String, dynamic>{...r.toMap(), 'model': model},
      );
    }
    b.set(_user(uid).collection('aiState').doc('advice'), <String, dynamic>{
      'generatedAt': batch.generatedAt.toIso8601String(),
      'fingerprint': batch.fingerprint,
      'period': batch.period.name,
      'model': model,
      'goalSuggestions': batch.goalSuggestions.map((g) => g.toMap()).toList(),
    });
    await _write(b.commit());
  }

  @override
  Future<void> saveGoalSuggestions(
    String uid,
    List<GoalSuggestion> remaining,
  ) => _write(
    _user(uid).collection('aiState').doc('advice').set(<String, dynamic>{
      'goalSuggestions': remaining.map((g) => g.toMap()).toList(),
    }, SetOptions(merge: true)),
  );

  @override
  Future<void> updateStatus(
    String uid,
    String id,
    RecommendationStatus status,
    DateTime at,
  ) => _write(
    _user(uid).collection('aiRecommendations').doc(id).set(<String, dynamic>{
      'status': status.name,
      'statusChangedAt': at.toIso8601String(),
    }, SetOptions(merge: true)),
  );

  static String _summaryId(SummaryKind kind, String periodKey) =>
      '${kind.name}_$periodKey';

  @override
  Future<AiSummary?> loadSummary(
    String uid,
    SummaryKind kind,
    String periodKey,
  ) async {
    final DocumentSnapshot<Map<String, dynamic>> doc = await _user(uid)
        .collection('aiSummaries')
        .doc(_summaryId(kind, periodKey))
        .get()
        .timeout(_readTimeout);
    final Map<String, dynamic>? m = doc.data();
    return m == null ? null : AiSummary.fromMap(m);
  }

  @override
  Future<void> saveSummary(String uid, AiSummary summary) => _write(
    _user(uid)
        .collection('aiSummaries')
        .doc(_summaryId(summary.kind, summary.periodKey))
        .set(summary.toMap()),
  );

  @override
  Future<StudyPlan?> loadStudyPlan(String uid) async {
    final DocumentSnapshot<Map<String, dynamic>> doc = await _user(
      uid,
    ).collection('aiState').doc('studyPlan').get().timeout(_readTimeout);
    final Map<String, dynamic>? m = doc.data();
    return m == null ? null : StudyPlan.fromMap(m);
  }

  @override
  Future<void> saveStudyPlan(String uid, StudyPlan plan) => _write(
    _user(uid).collection('aiState').doc('studyPlan').set(plan.toMap()),
  );

  @override
  Future<List<ChatMessage>> loadChat(String uid, {int limit = 60}) async {
    final QuerySnapshot<Map<String, dynamic>> snap = await _user(uid)
        .collection('aiChat')
        .orderBy('createdAt', descending: true)
        .limit(limit)
        .get()
        .timeout(_readTimeout);
    return snap.docs
        .map((d) => ChatMessage.fromMap(d.id, d.data()))
        .whereType<ChatMessage>()
        .toList()
        .reversed
        .toList();
  }

  @override
  Future<void> addChatMessage(String uid, ChatMessage message) => _write(
    _user(uid).collection('aiChat').doc(message.id).set(message.toMap()),
  );

  @override
  Future<void> clearChat(String uid) async {
    // Deletes only this user's own chat messages, in pages of 200.
    while (true) {
      final QuerySnapshot<Map<String, dynamic>> snap = await _user(
        uid,
      ).collection('aiChat').limit(200).get().timeout(_readTimeout);
      if (snap.docs.isEmpty) return;
      final WriteBatch b = _firestore.batch();
      for (final QueryDocumentSnapshot<Map<String, dynamic>> d in snap.docs) {
        b.delete(d.reference);
      }
      await _write(b.commit());
      if (snap.docs.length < 200) return;
    }
  }
}
