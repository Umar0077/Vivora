import 'dart:async';

import 'package:vivora/features/activity_monitoring/data/services/activity_tracking_controller.dart';
import 'package:vivora/features/activity_monitoring/data/services/auto_sync_coordinator.dart';

/// Deterministic timers: nothing fires until the test says so.
class FakeTimer implements Timer {
  FakeTimer(this.delay, this.callback);
  final Duration delay;
  final void Function() callback;
  bool _active = true;

  @override
  void cancel() => _active = false;

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;

  void fire() {
    if (!_active) return;
    _active = false;
    callback();
  }
}

class FakeBackground implements BackgroundSyncScheduler {
  int scheduled = 0;
  int cancelled = 0;

  @override
  Future<void> schedule() async => scheduled++;

  @override
  Future<void> cancel() async => cancelled++;
}

/// Per-account preferences on "this phone"; survives a simulated restart
/// when the same instance is passed to a new controller.
class MemoryTrackingStore implements LocalTrackingStore {
  final Map<String, TrackingPreference> prefs = <String, TrackingPreference>{};

  @override
  Future<TrackingPreference?> read(String uid) async => prefs[uid];

  @override
  Future<void> write(String uid, TrackingPreference preference) async =>
      prefs[uid] = preference;
}

/// The account's Firestore copy; [gate] simulates a slow network.
class FakeRemoteTrackingStore implements RemoteTrackingStore {
  final Map<String, TrackingPreference> prefs = <String, TrackingPreference>{};
  Completer<void>? gate;
  bool offline = false;
  int writes = 0;

  @override
  Future<TrackingPreference?> read(String uid) async {
    if (gate != null) await gate!.future;
    if (offline) throw TimeoutException('offline');
    return prefs[uid];
  }

  @override
  Future<void> write(String uid, TrackingPreference preference) async {
    writes++;
    if (offline) throw TimeoutException('offline');
    prefs[uid] = TrackingPreference(
      enabled: preference.enabled,
      changedAt: preference.changedAt,
    );
  }
}

/// What native Android code would see.
class FakeNativeFlag implements NativeTrackingFlag {
  bool enabled = false;
  String? uid;
  final List<bool> history = <bool>[];

  @override
  Future<void> set({required bool enabled, required String? uid}) async {
    this.enabled = enabled;
    this.uid = uid;
    history.add(enabled);
  }
}
