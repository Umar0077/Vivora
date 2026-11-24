// Explicit opt-in live test: flutter test tool/gemini_live_check.dart
// Real Gemini responses; synthetic records and in-memory persistence only.
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import 'package:vivora/core/config/gemini_config.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vivora/features/ai_assistant/application/ai_assistant_controller.dart';
import 'package:vivora/features/ai_assistant/data/ai_provider.dart';
import 'package:vivora/features/ai_assistant/data/ai_usage_limiter.dart';
import 'package:vivora/features/ai_assistant/data/gemini_ai_provider.dart';
import 'package:vivora/features/ai_assistant/domain/ai_context_builder.dart';
import 'package:vivora/features/ai_assistant/domain/ai_failure.dart';
import 'package:vivora/features/ai_assistant/domain/ai_models.dart';
import '../test/support/ai_fakes.dart'
    show FakeInsightsProvider, InMemoryAiStore, richHistory;
import '../test/support/behavior_builders.dart' show bNow;

class LiveProvider implements AiProvider {
  late final delegate = GeminiAiProvider(
    isSignedIn: () => true,
    clientFactory: () => ObservedClient(transport),
  );
  final List<Map<String, Object?>> transport = [];
  final List<Map<String, Object?>> calls = [];
  String feature = '';
  @override
  String get modelName => delegate.modelName;
  @override
  Future<String> generate(AiRequest request) async {
    final timer = Stopwatch()..start();
    final result = <String, Object?>{
      'feature': feature,
      'format': request.format.name,
      'promptCharacters': request.prompt.length,
      'hasProductivityData':
          request.prompt.contains('loggedManually') &&
          request.prompt.contains('studyHours') &&
          request.prompt.contains('daysWithData'),
      'hasBehaviorData': request.prompt.contains('detectedPatterns'),
      'hasPreferences': request.prompt.contains('statedPreferences'),
      'historyTurns': request.history.length,
    };
    try {
      final text = await delegate.generate(request);
      result['status'] = 'success';
      result['responseCharacters'] = text.length;
      result['jsonObject'] =
          (request.format == AiOutputFormat.text ||
              request.format == AiOutputFormat.diagnostic)
          ? null
          : jsonDecode(text) is Map;
      return text;
    } catch (error) {
      result['status'] = error is AiFailure ? error.kind.name : 'unexpected';
      rethrow;
    } finally {
      result['elapsedMs'] = timer.elapsedMilliseconds;
      calls.add(result);
      result['httpAttempts'] = List.of(transport);
      transport.clear();
      await File('build/gemini-live-progress.json').writeAsString(
        const JsonEncoder.withIndent(
          '  ',
        ).convert({'model': modelName, 'calls': calls}),
      );
    }
  }
}

class ObservedClient extends http.BaseClient {
  ObservedClient(this.events);
  final List<Map<String, Object?>> events;
  final inner = http.Client();
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await inner.send(request);
    final bytes = await response.stream.toBytes();
    final event = <String, Object?>{
      'status': response.statusCode,
      'requestBytes': request.contentLength,
    };
    if (response.statusCode == 200) {
      final data = jsonDecode(utf8.decode(bytes)) as Map;
      event['usage'] = data['usageMetadata'];
      event['modelVersion'] = data['modelVersion'];
    }
    if (response.statusCode != 200) {
      try {
        final error = jsonDecode(utf8.decode(bytes))['error'];
        event['message'] = error['message']
            .toString()
            .replaceAll(GeminiConfig.apiKey.trim(), '[REDACTED]')
            .replaceAll(RegExp(r'AIza[\w-]+'), '[REDACTED]');
      } catch (_) {
        event['message'] = 'Non-JSON API error';
      }
    }
    events.add(event);
    return http.StreamedResponse(
      Stream.value(bytes),
      response.statusCode,
      headers: response.headers,
    );
  }

  @override
  void close() => inner.close();
}

void main() {
  test(
    'live Gemini feature checks with synthetic productivity records',
    () async {
      // Explicit opt-in test kept outside test/ to prevent automatic API calls.
      // ignore: invalid_use_of_visible_for_testing_member
      SharedPreferences.setMockInitialValues({});
      final live = LiveProvider();
      final store = InMemoryAiStore();
      final insights = FakeInsightsProvider(richHistory());
      var clockTicks = 0;
      AiAssistantController make() => AiAssistantController(
        insights: insights,
        provider: live,
        store: store,
        currentUserId: () => 'local-live-sample',
        trackingEnabled: () => true,
        limiter: AiUsageLimiter(minInterval: Duration.zero),
        clock: () => bNow.add(Duration(seconds: clockTicks++)),
        loadPreferences: (_) async =>
            const StudyPreferences(preferredStudyTime: 'Evening'),
      );
      final controller = make();
      final checks = <Map<String, Object?>>[];
      Future<void> check(
        String name,
        Future<void> Function() action,
        bool Function() valid,
        AiFailure? Function() error,
      ) async {
        live.feature = name;
        await action();
        checks.add({
          'feature': name,
          'passed': valid(),
          'failure': error()?.kind.name,
        });
      }

      await controller.open();
      await check(
        'connection',
        controller.testConnection,
        () => controller.diagnosticSucceeded,
        () => controller.diagnosticError,
      );
      await check(
        'chatbot',
        () => controller.sendChat(
          'What does my recorded study time suggest I should improve?',
        ),
        () =>
            controller.chatError == null &&
            controller.chat.last.role == ChatRole.assistant,
        () => controller.chatError,
      );
      await check(
        'behavior_explanation',
        () => controller.sendChat(
          'Explain the relationship between my focus and screen use, without claiming causation.',
        ),
        () =>
            controller.chatError == null &&
            controller.chat.last.role == ChatRole.assistant,
        () => controller.chatError,
      );
      await check(
        'recommendations',
        controller.generateAdvice,
        () =>
            controller.adviceError == null &&
            controller.currentRecommendations.isNotEmpty,
        () => controller.adviceError,
      );
      await check(
        'adaptive_goals',
        controller.generateGoals,
        () =>
            controller.goalsError == null &&
            controller.goalSuggestions.isNotEmpty,
        () => controller.goalsError,
      );
      for (final kind in SummaryKind.values) {
        await check(
          '${kind.name}_summary',
          () => controller.generateSummary(kind),
          () => controller.summary(kind) != null,
          () => controller.summaryError(kind),
        );
      }
      await check(
        'study_plan',
        controller.generateStudyPlan,
        () => controller.studyPlan != null,
        () => controller.planError,
      );
      final before = live.calls.length;
      final reopened = make();
      await reopened.open();
      checks.add({
        'feature': 'cache_reopen',
        'passed':
            live.calls.length == before &&
            reopened.summary(SummaryKind.daily) != null &&
            reopened.summary(SummaryKind.weekly) != null &&
            reopened.studyPlan != null &&
            reopened.currentRecommendations.isNotEmpty,
      });
      live.feature = 'invalid_key_error';
      final watch = Stopwatch()..start();
      try {
        await GeminiAiProvider(
          apiKey: 'invalid-local-test-key',
          isSignedIn: () => true,
        ).generate(
          const AiRequest(
            format: AiOutputFormat.text,
            prompt: 'Connection check',
          ),
        );
        checks.add({'feature': 'invalid_key_error', 'passed': false});
      } catch (error) {
        checks.add({
          'feature': 'invalid_key_error',
          'passed':
              error is AiFailure && error.kind == AiFailureKind.notConfigured,
          'elapsedMs': watch.elapsedMilliseconds,
          'failure': error is AiFailure ? error.kind.name : 'unexpected',
        });
      }
      final report = {
        'model': live.modelName,
        'dataSource': 'synthetic test records, not actual user data',
        'persistence': 'in memory, not live Firestore',
        'calls': live.calls,
        'checks': checks,
      };
      final file = File('build/gemini-live-results.json');
      await file.parent.create(recursive: true);
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(report),
      );
      controller.dispose();
      reopened.dispose();
      expect(
        checks
            .where((c) => c['passed'] != true)
            .map((c) => c['feature'])
            .toList(),
        isEmpty,
        reason: 'See credential-free build/gemini-live-results.json',
      );
    },
    timeout: const Timeout(Duration(minutes: 12)),
  );
}
