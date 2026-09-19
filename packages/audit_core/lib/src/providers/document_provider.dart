import 'dart:convert';

import 'package:transcript_core/transcript_core.dart';

/// A document sent alongside the prompt.
///
/// Bank statements are tables. Extracting them to plain text on the device
/// loses the column structure that tells an amount from a running balance, so
/// where a provider can read the PDF itself, it should.
class DocumentAttachment {
  const DocumentAttachment({
    required this.bytes,
    required this.filename,
    this.mimeType = 'application/pdf',
  });

  final List<int> bytes;
  final String filename;
  final String mimeType;

  int get byteLength => bytes.length;

  /// Base64 with no line wrapping, which is what both APIs expect.
  String get base64Data => base64Encode(bytes);

  /// Roughly what this costs to send. Base64 inflates by 4/3, and both APIs
  /// measure their limit against the encoded payload.
  int get encodedLength => (bytes.length * 4 / 3).ceil();
}

/// A structuring provider that can additionally be handed a document.
///
/// transcript_core's [StructureRequest] is text-only, so this is the seam where
/// the budget app adds PDF support without forking the upstream package. Each
/// implementation delegates identity, capabilities and connection testing to
/// the upstream adapter and overrides nothing but the request body — so when
/// attachments are upstreamed into [StructureRequest], these classes are
/// deleted rather than migrated.
abstract class DocumentStructuringProvider extends StructuringProvider {
  /// Largest document this provider will accept, measured base64-encoded.
  int get maxDocumentBytes;

  /// Runs the request with [document] attached.
  Future<StructureResponse> structureWithDocument(
    StructureRequest request,
    DocumentAttachment document,
  );

  /// Whether [document] is small enough to attach. Too large means the caller
  /// falls back to the extracted-text path rather than failing the audit.
  bool canAttach(DocumentAttachment document) =>
      document.encodedLength <= maxDocumentBytes;
}

/// Claude with a PDF attached.
///
/// The Messages API takes a `document` content block whose source is base64
/// PDF. Everything else about the call — model, cache breakpoint on the system
/// prompt, `output_config` schema, refusal handling — matches the upstream
/// adapter, because diverging on any of it would mean two behaviours to debug.
class AnthropicDocumentProvider extends DocumentStructuringProvider {
  AnthropicDocumentProvider({
    required HttpTransport transport,
    required String apiKey,
    this.model = AnthropicStructuringProvider.defaultModel,
    Uri? baseUrl,
  })  : _transport = transport,
        _apiKey = apiKey,
        _baseUrl = baseUrl ?? Uri.parse('https://api.anthropic.com'),
        _inner = AnthropicStructuringProvider(
          transport: transport,
          apiKey: apiKey,
          model: model,
          baseUrl: baseUrl,
        );

  final HttpTransport _transport;
  final String _apiKey;
  final Uri _baseUrl;
  final String model;
  final AnthropicStructuringProvider _inner;

  /// 32 MB, the documented ceiling for a request carrying a PDF.
  @override
  int get maxDocumentBytes => 32 * 1024 * 1024;

  @override
  ProviderId get id => _inner.id;

  @override
  String get displayName => _inner.displayName;

  @override
  ProviderCapabilities get capabilities => _inner.capabilities;

  @override
  Future<ConnectionResult> test() => _inner.test();

  @override
  Future<StructureResponse> structure(StructureRequest request) =>
      _inner.structure(request);

  @override
  Future<StructureResponse> structureWithDocument(
    StructureRequest request,
    DocumentAttachment document,
  ) async {
    final reply = await _transport.send(HttpCall(
      method: 'POST',
      url: _baseUrl.resolve('/v1/messages'),
      headers: {
        'x-api-key': _apiKey,
        'anthropic-version': AnthropicStructuringProvider.apiVersion,
        'anthropic-beta': AnthropicStructuringProvider.fallbackBeta,
        'accept': 'application/json',
      },
      // A 30-page statement takes appreciably longer than the same content as
      // text, because the model is doing layout analysis as well as reading.
      timeout: const Duration(minutes: 10),
      jsonBody: {
        'model': model,
        'max_tokens': request.maxOutputTokens,
        'system': [
          {
            'type': 'text',
            'text': request.systemPrompt,
            'cache_control': {'type': 'ephemeral'},
          }
        ],
        'messages': [
          for (final turn in request.priorTurns)
            {'role': turn.role, 'content': turn.content},
          {
            'role': 'user',
            'content': [
              {
                'type': 'document',
                'source': {
                  'type': 'base64',
                  'media_type': document.mimeType,
                  'data': document.base64Data,
                },
                // Caches the parsed document, so a repair round-trip does not
                // pay to re-read the statement.
                'cache_control': {'type': 'ephemeral'},
              },
              {'type': 'text', 'text': request.userContent},
            ],
          },
        ],
        'thinking': {'type': 'adaptive'},
        'output_config': {
          'effort': 'high',
          'format': {
            'type': 'json_schema',
            'schema': renderSchema(request.schema, SchemaDialect.plain),
          },
        },
        'fallbacks': 'default',
      },
    ));

    if (!reply.ok) {
      throw ProviderException(
        displayName,
        reply.statusCode,
        providerErrorMessage(reply.json, reply.body),
      );
    }

    final body = reply.json ?? const <String, dynamic>{};

    if (body['stop_reason'] == 'refusal') {
      throw ProviderException(
        displayName,
        200,
        'The model declined to read this document.',
      );
    }

    final content = body['content'];
    final text = content is List
        ? content
            .whereType<Map<String, dynamic>>()
            .where((b) => b['type'] == 'text')
            .map((b) => (b['text'] as Object?).toString())
            .join()
        : '';

    final usage = (body['usage'] as Map?)?.cast<String, dynamic>();
    return StructureResponse(
      rawText: text,
      inputTokens: usage?['input_tokens'] as int?,
      outputTokens: usage?['output_tokens'] as int?,
      model: body['model'] as String?,
    );
  }
}

/// Gemini with a PDF attached, sent as `inlineData`.
class GeminiDocumentProvider extends DocumentStructuringProvider {
  GeminiDocumentProvider({
    required HttpTransport transport,
    required String apiKey,
    this.model = GeminiStructuringProvider.defaultModel,
    Uri? baseUrl,
  })  : _transport = transport,
        _apiKey = apiKey,
        _baseUrl = baseUrl ??
            Uri.parse('https://generativelanguage.googleapis.com'),
        _inner = GeminiStructuringProvider(
          transport: transport,
          apiKey: apiKey,
          model: model,
          baseUrl: baseUrl,
        );

  final HttpTransport _transport;
  final String _apiKey;
  final Uri _baseUrl;
  final String model;
  final GeminiStructuringProvider _inner;

  /// Inline data tops out around 20 MB on the generateContent request; anything
  /// larger needs the resumable Files API, which is not worth the complexity
  /// for a bank statement. Held slightly under the ceiling for headroom.
  @override
  int get maxDocumentBytes => 18 * 1024 * 1024;

  @override
  ProviderId get id => _inner.id;

  @override
  String get displayName => _inner.displayName;

  @override
  ProviderCapabilities get capabilities => _inner.capabilities;

  @override
  Future<ConnectionResult> test() => _inner.test();

  @override
  Future<StructureResponse> structure(StructureRequest request) =>
      _inner.structure(request);

  @override
  Future<StructureResponse> structureWithDocument(
    StructureRequest request,
    DocumentAttachment document,
  ) async {
    final reply = await _transport.send(HttpCall(
      method: 'POST',
      url: _baseUrl.resolve('/v1beta/models/$model:generateContent'),
      headers: {'x-goog-api-key': _apiKey, 'accept': 'application/json'},
      timeout: const Duration(minutes: 10),
      jsonBody: {
        'systemInstruction': {
          'parts': [
            {'text': request.systemPrompt}
          ]
        },
        'contents': [
          for (final turn in request.priorTurns)
            {
              'role': turn.role == 'assistant' ? 'model' : 'user',
              'parts': [
                {'text': turn.content}
              ],
            },
          {
            'role': 'user',
            'parts': [
              {
                'inlineData': {
                  'mimeType': document.mimeType,
                  'data': document.base64Data,
                }
              },
              {'text': request.userContent},
            ],
          },
        ],
        'generationConfig': {
          'responseMimeType': 'application/json',
          'responseSchema': renderSchema(request.schema, SchemaDialect.gemini),
          'maxOutputTokens': request.maxOutputTokens,
        },
      },
    ));

    if (!reply.ok) {
      throw ProviderException(
        displayName,
        reply.statusCode,
        providerErrorMessage(reply.json, reply.body),
      );
    }

    final body = reply.json ?? const <String, dynamic>{};
    final candidates = body['candidates'];
    final first = candidates is List && candidates.isNotEmpty
        ? (candidates.first as Map?)?.cast<String, dynamic>()
        : null;

    final parts = ((first?['content'] as Map?)?.cast<String, dynamic>())?['parts'];
    final text = parts is List
        ? parts
            .whereType<Map<String, dynamic>>()
            .map((p) => p['text'])
            .whereType<String>()
            .join()
        : '';

    final usage = (body['usageMetadata'] as Map?)?.cast<String, dynamic>();
    return StructureResponse(
      rawText: text,
      inputTokens: usage?['promptTokenCount'] as int?,
      outputTokens: usage?['candidatesTokenCount'] as int?,
      model: body['modelVersion'] as String?,
    );
  }
}
