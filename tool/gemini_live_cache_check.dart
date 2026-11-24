// Explicit opt-in; real API response, synthetic records, in-memory store.
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vivora/features/ai_assistant/application/ai_assistant_controller.dart';
import 'package:vivora/features/ai_assistant/data/ai_usage_limiter.dart';
import 'package:vivora/features/ai_assistant/domain/ai_models.dart';
import '../test/support/ai_fakes.dart'
    show FakeInsightsProvider, InMemoryAiStore, richHistory;
import '../test/support/behavior_builders.dart' show bNow;
import 'gemini_live_check.dart' show LiveProvider;

void main() {
  test('real chatbot reply survives reopen without another API call', () async {
    // Explicit test entry point outside test/ to prevent automatic API calls.
    // ignore: invalid_use_of_visible_for_testing_member
    SharedPreferences.setMockInitialValues({});
    final provider = LiveProvider()..feature = 'chat_cache';
    final insights = FakeInsightsProvider(richHistory());
    final store = InMemoryAiStore();
    AiAssistantController make() => AiAssistantController(
      insights: insights,
      provider: provider,
      store: store,
      currentUserId: () => 'local-cache-sample',
      clock: () => bNow,
      limiter: AiUsageLimiter(minInterval: Duration.zero),
    );
    final first = make();
    await first.open();
    await first.sendChat(
      'Give one brief study tip grounded in my recorded data.',
    );
    final generated =
        first.chatError == null && first.chat.last.role == ChatRole.assistant;
    final count = provider.calls.length;
    final reopened = make();
    await reopened.open();
    final passed =
        generated &&
        reopened.chat.length == first.chat.length &&
        reopened.chat.last.text == first.chat.last.text &&
        provider.calls.length == count;
    await File('build/gemini-live-cache-results.json').writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'passed': passed,
        'failure': first.chatError?.kind.name,
        'callsBeforeReopen': count,
        'callsAfterReopen': provider.calls.length,
        'persistence': 'in-memory, not Firestore',
        'calls': provider.calls,
      }),
    );
    first.dispose();
    reopened.dispose();
    expect(
      passed,
      isTrue,
      reason: 'See safe build/gemini-live-cache-results.json',
    );
  }, timeout: const Timeout(Duration(minutes: 2)));
}
