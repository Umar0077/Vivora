import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../../../core/config/gemini_config.dart';
import '../../../core/services/session.dart';
import '../domain/ai_config.dart';
import '../domain/ai_failure.dart';
import '../domain/ai_models.dart';
import '../domain/ai_prompts.dart';
import 'ai_provider.dart';
import 'gemini_schemas.dart';

/// Direct Google Gemini Developer API. Never logs keys, bodies or exceptions.
class GeminiAiProvider implements AiProvider {
  GeminiAiProvider({
    String? model,
    String? apiKey,
    this.timeout = AiConfig.timeout,
    this.retryDelay = const Duration(seconds: 1),
    this.attemptTimeout = const Duration(seconds: 20),
    http.Client Function()? clientFactory,
    bool Function()? isSignedIn,
  }) : modelName = model ?? GeminiConfig.model,
       _apiKey = apiKey ?? GeminiConfig.apiKey,
       _clientFactory = clientFactory ?? http.Client.new,
       _isSignedIn = isSignedIn ?? (() => Session.currentUserId() != null);

  @override
  final String modelName;
  final String _apiKey;
  final Duration timeout;
  final Duration retryDelay;
  final Duration attemptTimeout;
  final http.Client Function() _clientFactory;
  final bool Function() _isSignedIn;

  @override
  Future<String> generate(AiRequest request) async {
    final watch = Stopwatch()..start();
    final traceId = DateTime.now().microsecondsSinceEpoch;
    // Debug-only operational metadata. Never include headers, keys, prompts,
    // response bodies, user IDs or raw exceptions in device diagnostics.
    void trace(String outcome, {int? httpStatus, int? attempt}) {
      if (kDebugMode) {
        debugPrint(
          'PDT_AI ${jsonEncode({'request': traceId, 'format': request.format.name, 'outcome': outcome, 'elapsedMs': watch.elapsedMilliseconds, if (httpStatus != null) 'httpStatus': httpStatus, if (attempt != null) 'attempt': attempt})}',
        );
      }
    }

    AiConfig.validate(modelName);
    final key = _apiKey.trim();
    if (key.isEmpty || key.contains('PASTE_') || RegExp(r'\s').hasMatch(key)) {
      throw const AiFailure(AiFailureKind.notConfigured);
    }
    if (!_isSignedIn()) throw const AiFailure(AiFailureKind.signedOut);
    http.Client? activeClient;
    var cancelled = false;
    try {
      final schema = GeminiSchemas.forFormat(request.format);
      final body = {
        'systemInstruction': {
          'parts': [
            {'text': AiPrompts.systemFor(request.format)},
          ],
        },
        'contents': [
          for (final turn in request.history)
            {
              'role': turn.role == ChatRole.user ? 'user' : 'model',
              'parts': [
                {'text': turn.text},
              ],
            },
          {
            'role': 'user',
            'parts': [
              {'text': request.prompt},
            ],
          },
        ],
        'generationConfig': {
          'maxOutputTokens': request.maxOutputTokens,
          if (const [
            'gemini-3.5-flash-lite',
            'gemini-3.6-flash',
          ].contains(modelName))
            'thinkingConfig': {'thinkingLevel': 'minimal'},
          'responseMimeType': schema == null
              ? 'text/plain'
              : 'application/json',
          if (schema != null) 'responseSchema': schema,
        },
      };
      Future<http.Response> send() async {
        for (var attempt = 0; ; attempt++) {
          if (cancelled) throw const AiFailure(AiFailureKind.timeout);
          final client = _clientFactory();
          activeClient = client;
          http.Response response;
          try {
            response = await client
                .post(
                  Uri.https(
                    'generativelanguage.googleapis.com',
                    '/v1beta/models/$modelName:generateContent',
                  ),
                  headers: {
                    'x-goog-api-key': key,
                    'Content-Type': 'application/json',
                  },
                  body: jsonEncode(body),
                )
                .timeout(attemptTimeout);
          } on TimeoutException {
            trace('attemptTimeout', attempt: attempt + 1);
            if (attempt >= 2 || cancelled) rethrow;
            await Future<void>.delayed(retryDelay * (attempt + 1));
            continue;
          } finally {
            client.close();
            if (identical(activeClient, client)) activeClient = null;
          }
          trace('http', httpStatus: response.statusCode, attempt: attempt + 1);
          if (attempt >= 2 ||
              !const [500, 502, 503, 504].contains(response.statusCode)) {
            return response;
          }
          await Future<void>.delayed(retryDelay * (attempt + 1));
        }
      }

      // One total timeout covers all attempts. Never retry key/quota errors.
      final response = await send().timeout(request.timeout ?? timeout);
      if (response.statusCode != 200) {
        throw mapAiHttpError(response.statusCode, response.body);
      }
      final decoded = jsonDecode(response.body) as Map<String, dynamic>;
      final feedback = decoded['promptFeedback'] as Map<String, dynamic>?;
      final block = feedback?['blockReason'];
      if (block != null && block != 'BLOCK_REASON_UNSPECIFIED') {
        throw const AiFailure(AiFailureKind.blocked);
      }
      final candidates = decoded['candidates'] as List?;
      if (candidates == null || candidates.isEmpty) {
        throw const AiFailure(AiFailureKind.malformed);
      }
      final candidate = candidates.first as Map<String, dynamic>;
      final finish = candidate['finishReason'];
      if (const [
        'SAFETY',
        'RECITATION',
        'BLOCKLIST',
        'PROHIBITED_CONTENT',
        'SPII',
      ].contains(finish)) {
        throw const AiFailure(AiFailureKind.blocked);
      }
      if (finish != 'STOP') throw const AiFailure(AiFailureKind.malformed);
      final parts =
          (candidate['content'] as Map<String, dynamic>)['parts'] as List;
      final text = parts
          .whereType<Map<String, dynamic>>()
          .where((part) => part['thought'] != true && part['text'] is String)
          .map((part) => part['text'] as String)
          .join();
      if (text.trim().isEmpty) throw const AiFailure(AiFailureKind.malformed);
      if (schema != null && jsonDecode(text) is! Map<String, dynamic>) {
        throw const AiFailure(AiFailureKind.malformed);
      }
      // Feature-specific bounds and evidence validation remain in the controller.
      trace('responseReceived');
      return text;
    } catch (error) {
      final failure = mapAiError(error);
      trace(failure.kind.name);
      throw failure;
    } finally {
      cancelled = true;
      activeClient?.close();
    }
  }
}

/// Inspect errors only to classify them; never retain Google's raw response.
AiFailure mapAiHttpError(int status, [String body = '']) {
  final lower = body.toLowerCase();
  final kind = switch (status) {
    401 || 403 => AiFailureKind.notConfigured,
    404 => AiFailureKind.modelUnavailable,
    429 =>
      lower.contains('perday') ||
              lower.contains('per day') ||
              lower.contains('daily') ||
              lower.contains('billing')
          ? AiFailureKind.quotaExceeded
          : AiFailureKind.rateLimited,
    408 || 504 => AiFailureKind.timeout,
    400 =>
      lower.contains('api_key') || lower.contains('api key')
          ? AiFailureKind.notConfigured
          : lower.contains('location') || lower.contains('model')
          ? AiFailureKind.modelUnavailable
          : AiFailureKind.malformed,
    >= 500 => AiFailureKind.server,
    _ => AiFailureKind.unknown,
  };
  return AiFailure(kind);
}

AiFailure mapAiError(Object error) {
  if (error is AiFailure) return error;
  if (error is TimeoutException) return const AiFailure(AiFailureKind.timeout);
  if (error is SocketException ||
      error is HandshakeException ||
      error is http.ClientException) {
    return const AiFailure(AiFailureKind.offline);
  }
  if (error is FormatException || error is TypeError) {
    return const AiFailure(AiFailureKind.malformed);
  }
  return const AiFailure(AiFailureKind.unknown);
}
