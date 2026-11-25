import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

bool isActiveAdministrator(Map<String, dynamic>? data) =>
    data != null &&
    data['role'] == 'admin' &&
    data['isActive'] == true &&
    data.keys.every(const {'email', 'role', 'isActive'}.contains);

/// Separate client: admin sign-in never triggers user tracking or sync.
class AdminSession {
  AdminSession._(this.auth, this.db);
  final FirebaseAuth auth;
  final FirebaseFirestore db;
  static Future<AdminSession>? _instance;
  static Future<AdminSession> instance() => _instance ??= _create();
  static Future<AdminSession> _create() async {
    try {
      final existing = Firebase.apps
          .where((app) => app.name == 'personal-digital-twin-admin')
          .firstOrNull;
      final app =
          existing ??
          await Firebase.initializeApp(
            name: 'personal-digital-twin-admin',
            options: Firebase.app().options,
          );
      await FirebaseAppCheck.instanceFor(app: app).activate(
        providerAndroid: kDebugMode
            ? const AndroidDebugProvider()
            : const AndroidPlayIntegrityProvider(),
      );
      final db = FirebaseFirestore.instanceFor(app: app);
      db.settings = const Settings(persistenceEnabled: false);
      return AdminSession._(FirebaseAuth.instanceFor(app: app), db);
    } catch (_) {
      _instance = null;
      rethrow;
    }
  }

  Future<void> signIn(String email, String password) async {
    try {
      await auth.signInWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
      if (!await authorized()) throw const AdminAccessException();
    } catch (_) {
      await auth.signOut();
      rethrow;
    }
  }

  Future<bool> authorized() async {
    final uid = auth.currentUser?.uid;
    if (uid == null) return false;
    final doc = await db
        .collection('admin')
        .doc(uid)
        .get(const GetOptions(source: Source.server))
        .timeout(const Duration(seconds: 12));
    return auth.currentUser?.uid == uid && isActiveAdministrator(doc.data());
  }

  Stream<bool> authorizationChanges() {
    final uid = auth.currentUser?.uid;
    if (uid == null) return Stream.value(false);
    return db
        .collection('admin')
        .doc(uid)
        .snapshots(includeMetadataChanges: true)
        .map(
          (doc) =>
              !doc.metadata.isFromCache &&
              auth.currentUser?.uid == uid &&
              isActiveAdministrator(doc.data()),
        );
  }

  Future<void> signOut() => auth.signOut();
}

class AdminAccessException implements Exception {
  const AdminAccessException();
}

String adminError(Object error) {
  if (error is AdminAccessException) {
    return 'Administrator access is not enabled for this account. Contact the project administrator.';
  }
  if (error is TimeoutException) {
    return 'The server did not respond. Check your connection and try again.';
  }
  if (error is FirebaseAuthException) {
    return switch (error.code) {
      'invalid-credential' ||
      'wrong-password' ||
      'user-not-found' ||
      'invalid-email' => 'Email or password is incorrect.',
      'too-many-requests' =>
        'Too many attempts. Please wait before trying again.',
      'user-disabled' => 'This authentication account is disabled.',
      'network-request-failed' =>
        'Unable to connect. Check your internet connection.',
      _ => 'Sign-in failed. Check your account configuration and try again.',
    };
  }
  if (error is FirebaseException && error.code == 'permission-denied') {
    return 'Access denied. Verify administrator membership, deployed Firestore rules, and App Check configuration.';
  }
  return 'Unable to load authorized data. Check your connection and Firebase configuration, then retry.';
}
