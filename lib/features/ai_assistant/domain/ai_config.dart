import 'ai_failure.dart';
import '../../../core/config/gemini_config.dart';

/// Shared limits; local model and key live in GeminiConfig.
class AiConfig {
  const AiConfig._();

  static const bool enabled = bool.fromEnvironment(
    'VIVORA_AI_ENABLED',
    defaultValue: true,
  );
  static const String model = GeminiConfig.model;
  static const Duration timeout = Duration(seconds: 40);

  static void validate(String modelName, {bool isEnabled = enabled}) {
    if (!isEnabled) throw const AiFailure(AiFailureKind.notConfigured);
    // Validate syntax locally; availability is established only by a request.
    if (!RegExp(r'^gemini-[a-z0-9][a-z0-9.-]{0,100}$').hasMatch(modelName)) {
      throw const AiFailure(AiFailureKind.modelUnavailable, 'invalid model id');
    }
  }
}
