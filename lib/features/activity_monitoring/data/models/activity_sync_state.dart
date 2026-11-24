enum ActivitySyncState {
  idle,
  syncing,

  /// Device data collected for today.
  success,
  permissionRequired,

  /// Collected, but some optional source (e.g. movement) is unavailable.
  partialData,
  failed,

  /// The user switched Automatic Activity Tracking off: nothing is measured.
  trackingOff,
}
