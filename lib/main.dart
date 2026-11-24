import 'dart:async';

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

import 'core/routes/app_routes.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/theme_controller.dart';
import 'background_sync_entrypoint.dart';
import 'features/activity_monitoring/data/services/auto_sync_coordinator.dart';
import 'firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // The saved appearance is read before the first frame so the app never
  // starts in the wrong theme.
  await Future.wait<void>(<Future<void>>[
    ThemeController.init(),
    Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    ).then(
      (_) => debugPrint('Firebase initialized successfully'),
      onError: (Object e) => debugPrint('Error initializing Firebase: $e'),
    ),
  ]);
  if (Firebase.apps.isEmpty) {
    runApp(
      MaterialApp(
        theme: AppTheme.lightTheme,
        darkTheme: AppTheme.darkTheme,
        themeMode: ThemeController.instance.value,
        home: Scaffold(
          body: SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    const Text(
                      'Personal Digital Twin could not initialize Firebase. Check your connection and app configuration, then retry.',
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: main,
                      child: const Text('Retry startup'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return;
  }
  await _activateAppCheck();
  runApp(const VivoraApp());
}

/// App Check remains enabled for existing Firebase services. Direct Gemini
/// requests use their own API key. Debug builds use the debug provider and print a debug
/// token in logcat ("Enter this debug secret into the allow list ...") that
/// must be registered in Firebase console > App Check > Manage debug tokens.
/// Release builds use Play Integrity (requires the app's SHA-256 fingerprint
/// in the Firebase project). It only affects services where App Check is
/// enforced in the console.
Future<void> _activateAppCheck() async {
  if (Firebase.apps.isEmpty) return;
  try {
    await FirebaseAppCheck.instance.activate(
      providerAndroid: kDebugMode
          ? const AndroidDebugProvider()
          : const AndroidPlayIntegrityProvider(),
    );
  } catch (e) {
    debugPrint('App Check not active: $e');
  }
}

class VivoraApp extends StatefulWidget {
  const VivoraApp({super.key});

  @override
  State<VivoraApp> createState() => _VivoraAppState();
}

class _VivoraAppState extends State<VivoraApp> with WidgetsBindingObserver {
  final AutoSyncCoordinator _autoSync = AutoSyncCoordinator.instance;
  StreamSubscription<User?>? _authSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (Firebase.apps.isNotEmpty) {
      // Automatic activity sync follows the signed-in account: it starts on
      // sign-in (every 5 minutes while the app is open, WorkManager in the
      // background) and stops on sign-out, dropping the previous user's data.
      _authSubscription = FirebaseAuth.instance.authStateChanges().listen(
        (User? user) => unawaited(_autoSync.handleUser(user?.uid)),
      );
    }
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Pauses the 5-minute timer in the background and catches up on resume
    // (also right after Usage Access is granted in Android settings).
    if (Firebase.apps.isNotEmpty) _autoSync.handleLifecycle(state);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: ThemeController.instance,
      builder: (BuildContext context, ThemeMode mode, Widget? child) {
        // Read from the platform: there is no MediaQuery above MaterialApp.
        final bool reduceMotion = WidgetsBinding
            .instance
            .platformDispatcher
            .accessibilityFeatures
            .disableAnimations;
        return MaterialApp(
          title: 'Personal Digital Twin',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.lightTheme,
          darkTheme: AppTheme.darkTheme,
          themeMode: mode,
          // Short cross-fade between themes; none when the device asks for
          // reduced motion.
          themeAnimationDuration: reduceMotion
              ? Duration.zero
              : const Duration(milliseconds: 250),
          initialRoute: AppRoutes.splash,
          onGenerateRoute: AppRoutes.onGenerateRoute,
        );
      },
    );
  }
}

/// Entry point run by Android's WorkManager job (`BackgroundSyncWorker.kt`)
/// in a headless Flutter engine while the app is in the background.
@pragma('vm:entry-point')
Future<void> backgroundSyncMain() => runBackgroundSync();
