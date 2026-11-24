import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:vivora/core/config/gemini_config.dart';
import 'package:vivora/features/ai_assistant/data/ai_provider.dart';
import 'package:vivora/features/ai_assistant/data/gemini_ai_provider.dart';
import 'package:vivora/features/ai_assistant/domain/ai_failure.dart';
import 'package:vivora/features/ai_assistant/domain/ai_models.dart';

const request = AiRequest(format: AiOutputFormat.text, prompt: 'hello');
Matcher failure(AiFailureKind kind) =>
    isA<AiFailure>().having((e) => e.kind, 'kind', kind);
http.Response answer(String text, {String finish = 'STOP'}) => http.Response(
  jsonEncode({
    'candidates': [
      {
        'finishReason': finish,
        'content': {
          'parts': [
            {'text': 'private reasoning', 'thought': true},
            {'text': text},
          ],
        },
      },
    ],
  }),
  200,
);
GeminiAiProvider provider(
  Future<http.Response> Function(http.Request) handler, {
  String key = 'test-only-key',
  bool signedIn = true,
  Duration timeout = const Duration(seconds: 1),
}) => GeminiAiProvider(
  apiKey: key,
  isSignedIn: () => signedIn,
  timeout: timeout,
  retryDelay: Duration.zero,
  clientFactory: () => MockClient(handler),
);

void main() {
  test('stalled attempt times out and next transport recovers', () async {
    var calls = 0;
    final p = GeminiAiProvider(
      apiKey: 'test-only-key',
      isSignedIn: () => true,
      timeout: const Duration(seconds: 1),
      attemptTimeout: const Duration(milliseconds: 10),
      retryDelay: Duration.zero,
      clientFactory: () => MockClient((_) {
        calls++;
        return calls == 1
            ? Completer<http.Response>().future
            : Future.value(answer('Recovered'));
      }),
    );
    expect(await p.generate(request), 'Recovered');
    expect(calls, 2);
  });
  test(
    'transient server failure retries the same request and recovers',
    () async {
      final bodies = <String>[];
      final p = provider((r) async {
        bodies.add(r.body);
        return bodies.length == 1
            ? http.Response('busy', 503)
            : answer('Recovered');
      });
      expect(await p.generate(request), 'Recovered');
      expect(bodies.length, 2);
      expect(bodies.first, bodies.last);
    },
  );
  test(
    'retries are bounded and never repeat authentication or quota errors',
    () async {
      for (final status in [503, 403, 429]) {
        var calls = 0;
        final p = provider((_) async {
          calls++;
          return http.Response('error', status);
        });
        await expectLater(p.generate(request), throwsA(isA<AiFailure>()));
        expect(calls, status == 503 ? 3 : 1);
      }
    },
  );
  test('total timeout prevents another attempt after backoff', () async {
    var calls = 0;
    final p = GeminiAiProvider(
      apiKey: 'test-only-key',
      isSignedIn: () => true,
      timeout: const Duration(milliseconds: 5),
      retryDelay: const Duration(milliseconds: 30),
      clientFactory: () => MockClient((_) async {
        calls++;
        return http.Response('busy', 503);
      }),
    );
    await expectLater(
      p.generate(request),
      throwsA(failure(AiFailureKind.timeout)),
    );
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(calls, 1);
  });
  test('direct endpoint, header, system instruction and chat roles', () async {
    final p = provider((r) async {
      expect(
        r.url.toString(),
        'https://generativelanguage.googleapis.com/v1beta/models/${GeminiConfig.model}:generateContent',
      );
      expect(r.method, 'POST');
      expect(r.url.query, isEmpty);
      expect(r.headers['x-goog-api-key'], 'test-only-key');
      final body = jsonDecode(r.body) as Map;
      expect(
        body['systemInstruction']['parts'][0]['text'],
        contains('Personal Digital Twin'),
      );
      expect((body['contents'] as List).map((e) => e['role']), [
        'user',
        'model',
        'user',
      ]);
      expect(body['generationConfig']['maxOutputTokens'], 500);
      expect(body['generationConfig'].containsKey('responseSchema'), isFalse);
      return answer('Hello');
    });
    expect(
      await p.generate(
        const AiRequest(
          format: AiOutputFormat.text,
          prompt: 'now',
          history: [
            AiTurn(ChatRole.user, 'before'),
            AiTurn(ChatRole.assistant, 'reply'),
          ],
          maxOutputTokens: 500,
        ),
      ),
      'Hello',
    );
  });

  for (final format in [
    AiOutputFormat.advice,
    AiOutputFormat.goals,
    AiOutputFormat.summary,
    AiOutputFormat.studyPlan,
  ]) {
    test('structured schema sent for ${format.name}', () async {
      final p = provider((r) async {
        final config = jsonDecode(r.body)['generationConfig'];
        expect(config['responseMimeType'], 'application/json');
        final schema = config['responseSchema'];
        expect(schema['type'], 'object');
        expect(schema['required'], (schema['properties'] as Map).keys.toList());
        final expected = switch (format) {
          AiOutputFormat.advice => ['recommendations'],
          AiOutputFormat.goals => ['goalSuggestions'],
          AiOutputFormat.summary => [
            'headline',
            'overview',
            'highlights',
            'improvements',
            'nextSteps',
          ],
          _ => [
            'overview',
            'dailyStudyMinutes',
            'sessionsPerDay',
            'sessionMinutes',
            'breakMinutes',
            'priorities',
            'goalAlignment',
            'tips',
          ],
        };
        expect(schema['required'], expected);
        return answer('{}');
      });
      expect(await p.generate(AiRequest(format: format, prompt: 'data')), '{}');
    });
  }

  test('missing and placeholder keys never call HTTP', () async {
    for (final key in ['', ' ', 'PASTE_YOUR_GEMINI_API_KEY_HERE']) {
      final p = provider(
        (_) async => throw StateError('must not call'),
        key: key,
      );
      await expectLater(
        p.generate(request),
        throwsA(failure(AiFailureKind.notConfigured)),
      );
    }
  });
  test('signed-out requests never call HTTP', () async {
    await expectLater(
      provider(
        (_) async => throw StateError('must not call'),
        signedIn: false,
      ).generate(request),
      throwsA(failure(AiFailureKind.signedOut)),
    );
  });
  for (final entry in {
    400: AiFailureKind.notConfigured,
    401: AiFailureKind.notConfigured,
    403: AiFailureKind.notConfigured,
    404: AiFailureKind.modelUnavailable,
    429: AiFailureKind.rateLimited,
    503: AiFailureKind.server,
  }.entries) {
    test('HTTP ${entry.key} classified without leaking echoed key', () async {
      final p = provider(
        (_) async => http.Response('API key test-only-key invalid', entry.key),
      );
      try {
        await p.generate(request);
        fail('expected failure');
      } on AiFailure catch (e) {
        expect(e.kind, entry.value);
        expect(e.toString(), isNot(contains('test-only-key')));
        expect(e.message, isNot(contains('test-only-key')));
      }
    });
  }
  test(
    'blocked, missing, malformed and truncated responses are rejected',
    () async {
      final responses = [
        http.Response('{"promptFeedback":{"blockReason":"SAFETY"}}', 200),
        answer('partial', finish: 'MAX_TOKENS'),
        answer('blocked', finish: 'SAFETY'),
        http.Response('{}', 200),
        http.Response('not json', 200),
        answer(''),
      ];
      for (var i = 0; i < responses.length; i++) {
        await expectLater(
          provider((_) async => responses[i]).generate(request),
          throwsA(
            failure(
              i == 0 || i == 2
                  ? AiFailureKind.blocked
                  : AiFailureKind.malformed,
            ),
          ),
        );
      }
    },
  );
  test(
    'invalid structured JSON is rejected before feature validation',
    () async {
      for (final text in ['[]', 'not JSON']) {
        await expectLater(
          provider((_) async => answer(text)).generate(
            const AiRequest(format: AiOutputFormat.summary, prompt: 'data'),
          ),
          throwsA(failure(AiFailureKind.malformed)),
        );
      }
    },
  );
  test('network failure and timeout do not expose raw exceptions', () async {
    await expectLater(
      provider(
        (_) async => throw http.ClientException('test-only-key'),
      ).generate(request),
      throwsA(failure(AiFailureKind.offline)),
    );
    await expectLater(
      provider(
        (_) => Completer<http.Response>().future,
        timeout: const Duration(milliseconds: 5),
      ).generate(request),
      throwsA(failure(AiFailureKind.timeout)),
    );
  });
}
