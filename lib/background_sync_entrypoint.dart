import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'features/activity_monitoring/data/models/activity_sync_state.dart';
import 'features/activity_monitoring/data/services/activity_sync_service.dart';
import 'features/activity_monitoring/data/services/activity_tracking_controller.dart';
import 'firebase_options.dart';

/// One background sync, run by `BackgroundSyncWorker.kt` in a short-lived
/// headless engine. It reuses exactly the foreground pipeline
/// ([ActivitySyncService]): the same Android capture, categories, daily record
/// and idempotent Firestore write. Only the user that Firebase Auth has
/// restored on this phone is synced; nothing runs when signed out.
///
/// Reports `true` to the worker when there was nothing to do or the sync
/// worked, `false` to let WorkManager retry later with backoff.
Future<void> runBackgroundSync() async {
  WidgetsFlutterBinding.ensureInitialized();
  const MethodChannel channel = MethodChannel('vivora/background_sync');
  bool ok = false;
  try {
    if (Firebase.apps.isEmpty) {
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
    }
    final User? user = await FirebaseAuth.instance
        .authStateChanges()
        .first
        .timeout(const Duration(seconds: 10));
    if (user == null) {
      ok = true;
    } else {
      // Second, independent check of the switch (the worker already checked
      // the native flag): this account's own stored choice.
      final ActivityTrackingController tracking =
          ActivityTrackingController.instance;
      await tracking.resolveForUser(user.uid);
      if (!tracking.allows(user.uid)) {
        await channel.invokeMethod<void>('done', true);
        return;
      }
      final ActivitySyncService service = ActivitySyncService.instance;
      service.onUserChanged(user.uid);
      final result = await service
          .syncNow(force: true)
          .timeout(const Duration(seconds: 60));
      ok =
          result.state != ActivitySyncState.failed &&
          result.state != ActivitySyncState.syncing;
    }
  } catch (error) {
    debugPrint('Background sync failed: $error');
  }
  try {
    await channel.invokeMethod<void>('done', ok);
  } catch (_) {}
}
