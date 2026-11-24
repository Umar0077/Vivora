/// Why an AI request did not produce usable output. Each kind maps to one
/// plain-language message; technical details are never shown to the student.
enum AiFailureKind {
  offline,
  timeout,
  rateLimited,
  quotaExceeded,
  notConfigured,
  appCheck,
  signedOut,
  modelUnavailable,
  blocked,
  malformed,
  server,
  notEnoughData,
  localLimit,
  unknown,
}

class AiFailure implements Exception {
  const AiFailure(this.kind, [this.detail]);

  final AiFailureKind kind;

  /// Developer-facing detail (logged in debug builds, never displayed).
  final String? detail;

  bool get canRetry => switch (kind) {
    AiFailureKind.notConfigured ||
    AiFailureKind.appCheck ||
    AiFailureKind.signedOut ||
    AiFailureKind.notEnoughData ||
    AiFailureKind.localLimit => false,
    _ => true,
  };

  String get message => switch (kind) {
    AiFailureKind.offline =>
      'You appear to be offline. Connect to the internet and try again.',
    AiFailureKind.timeout =>
      'Personal Digital Twin AI took too long to answer. Please try again.',
    AiFailureKind.rateLimited =>
      'Personal Digital Twin AI is receiving too many requests right now. Please wait a minute and try again.',
    AiFailureKind.quotaExceeded =>
      'The AI usage limit for this project has been reached. Please try again later.',
    AiFailureKind.notConfigured =>
      'Personal Digital Twin AI is not configured. Add a valid Gemini API key to the local configuration and restart the app.',
    AiFailureKind.appCheck =>
      'This copy of Personal Digital Twin could not be verified by Firebase App Check, so AI requests are blocked.',
    AiFailureKind.signedOut =>
      'Please sign in again to use Personal Digital Twin AI.',
    AiFailureKind.modelUnavailable =>
      'The configured AI model is unavailable. Check the model configuration and regional availability.',
    AiFailureKind.blocked =>
      'Personal Digital Twin AI could not answer that. Try asking in a different way.',
    AiFailureKind.malformed =>
      'Personal Digital Twin AI returned an answer that could not be checked, so it was not shown. Please try again.',
    AiFailureKind.server =>
      'Personal Digital Twin AI had a temporary problem. Please try again.',
    AiFailureKind.notEnoughData =>
      'There is not enough recorded data yet. Log your day or let Personal Digital Twin measure your phone use first.',
    AiFailureKind.localLimit =>
      'You have reached today\'s Personal Digital Twin AI limit on this phone. It resets tomorrow.',
    AiFailureKind.unknown =>
      'Personal Digital Twin AI is unavailable right now. Please try again.',
  };

  @override
  String toString() =>
      'AiFailure(${kind.name}${detail == null ? '' : ': $detail'})';
}
