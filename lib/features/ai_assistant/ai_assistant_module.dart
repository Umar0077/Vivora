import 'dart:async';

import '../../core/services/session.dart';
import '../activity_monitoring/data/services/activity_tracking_controller.dart';
import '../first_time_setup/data/models/user_profile_model.dart';
import '../first_time_setup/data/services/user_profile_service.dart';
import '../goals/presentation/goals_screen.dart' show GoalKind;
import '../insights/services/insights_service.dart';
import 'application/ai_assistant_controller.dart';
import 'data/ai_store.dart';
import 'data/gemini_ai_provider.dart';
import 'domain/ai_context_builder.dart';
import 'domain/ai_models.dart';
import 'domain/ai_failure.dart';

/// Production wiring of Module 6: direct Gemini API, Firestore, the shared
/// Module 3 [InsightsService] and the existing goal storage. Created on first
/// use so tests never touch Firebase.
class AiAssistantModule {
  const AiAssistantModule._();

  static AiAssistantController? _controller;

  static AiAssistantController get controller =>
      _controller ??= AiAssistantController(
        insights: InsightsService.instance,
        provider: GeminiAiProvider(),
        store: FirestoreAiStore(),
        currentUserId: () => Session.currentUserId(),
        trackingEnabled: () => ActivityTrackingController.instance.isResolved
            ? ActivityTrackingController.instance.isEnabled
            : null,
        trackingChanges: ActivityTrackingController.instance,
        loadPreferences: _preferences,
        applyGoal: applyGoal,
        behaviorInsights: () =>
            InsightsService.instance.snapshot.value?.recommendations ??
            const [],
      );

  static Future<StudyPreferences?> _preferences(String uid) async {
    final UserProfile? p = await UserProfileService()
        .getUserProfile(uid)
        .timeout(const Duration(seconds: 8));
    if (p == null) return null;
    return StudyPreferences(
      preferredStudyTime: p.routineProfile.preferredStudyTime,
      averageStudyHours: p.routineProfile.averageStudyHours,
      mainDailyChallenge: p.routineProfile.mainDailyChallenge,
    );
  }

  /// Writes one goal exactly like the Goals screen does (same field and
  /// "Nh" format), then refreshes the analysis.
  static Future<void> applyGoal(
    String uid,
    SuggestedGoal goal,
    double hours,
  ) async {
    final UserProfileService profiles = UserProfileService();
    final UserProfile? profile = await profiles
        .getUserProfile(uid)
        .timeout(const Duration(seconds: 10));
    if (Session.currentUserId() != uid) {
      throw const AiFailure(AiFailureKind.signedOut);
    }
    if (!hours.isFinite || hours < goal.minHours || hours > goal.maxHours) {
      throw const AiFailure(AiFailureKind.malformed, 'goal bounds');
    }
    final UserGoals current = profile?.goals ?? UserGoals();
    final String text = hours % 1 == 0 ? '${hours.toInt()}h' : '${hours}h';
    await profiles.updateGoals(uid, goalKindFor(goal).write(current, text));
    unawaited(InsightsService.instance.reload());
  }

  static GoalKind goalKindFor(SuggestedGoal goal) => switch (goal) {
    SuggestedGoal.sleep => GoalKind.sleep,
    SuggestedGoal.study => GoalKind.study,
    SuggestedGoal.focus => GoalKind.focus,
    SuggestedGoal.screenLimit => GoalKind.screen,
  };
}
