import 'dart:convert';

import 'package:budget_core/budget_core.dart';
import 'package:test/test.dart';
import 'package:transcript_core/transcript_core.dart';

import 'fixtures.dart';

StructureRequest _request() => StructureRequest(
      systemPrompt: 'You are a forensic financial auditor.',
      userContent: AuditorPrompts.userContentForAttachment,
      schema: auditReportSchema,
    );

DocumentAttachment _pdf() =>
    DocumentAttachment(bytes: tinyPdfBytes(), filename: 'march.pdf');

HttpReply _anthropicReply() => HttpReply(
      200,
      jsonEncode({
        'model': 'claude-opus-5',
        'stop_reason': 'end_turn',
        'content': [
          {'type': 'text', 'text': validAuditResponse()},
        ],
        'usage': {'input_tokens': 4200, 'output_tokens': 900},
      }),
    );

HttpReply _geminiReply() => HttpReply(
      200,
      jsonEncode({
        'modelVersion': 'gemini-2.5-flash',
        'candidates': [
          {
            'content': {
              'parts': [
                {'text': validAuditResponse()},
              ],
            },
          },
        ],
        'usageMetadata': {
          'promptTokenCount': 4100,
          'candidatesTokenCount': 880,
        },
      }),
    );

void main() {
  group('DocumentAttachment', () {
    test('encodes base64 without wrapping', () {
      final doc = _pdf();
      expect(doc.base64Data, isNot(contains('\n')));
      expect(base64Decode(doc.base64Data), equals(tinyPdfBytes()));
    });

    test('measures the encoded size, which is what the API limits', () {
      final doc = DocumentAttachment(
        bytes: List.filled(3000, 0),
        filename: 'x.pdf',
      );
      expect(doc.byteLength, 3000);
      expect(doc.encodedLength, 4000);
    });
  });

  group('Anthropic', () {
    test('sends the PDF as a base64 document block', () async {
      final transport = RecordingTransport.single(_anthropicReply());
      final provider = AnthropicDocumentProvider(
        transport: transport,
        apiKey: 'sk-test',
      );

      await provider.structureWithDocument(_request(), _pdf());

      final call = transport.lastCall;
      expect(call.method, 'POST');
      expect(call.url.path, '/v1/messages');
      expect(call.headers['x-api-key'], 'sk-test');
      expect(call.headers['anthropic-version'],
          AnthropicStructuringProvider.apiVersion);

      final body = call.jsonBodyMap;
      final messages = body['messages'] as List;
      final content = (messages.single as Map)['content'] as List;

      final document = content.first as Map;
      expect(document['type'], 'document');
      final source = document['source'] as Map;
      expect(source['type'], 'base64');
      expect(source['media_type'], 'application/pdf');
      expect(base64Decode(source['data'] as String), equals(tinyPdfBytes()));

      expect((content[1] as Map)['type'], 'text');
    });

    test('caches the parsed document so a repair does not re-read it', () async {
      final transport = RecordingTransport.single(_anthropicReply());
      await AnthropicDocumentProvider(transport: transport, apiKey: 'k')
          .structureWithDocument(_request(), _pdf());

      final content =
          ((transport.lastCall.jsonBodyMap['messages'] as List).single
              as Map)['content'] as List;
      expect((content.first as Map)['cache_control'], {'type': 'ephemeral'});
    });

    test('sends the schema in the plain dialect', () async {
      final transport = RecordingTransport.single(_anthropicReply());
      await AnthropicDocumentProvider(transport: transport, apiKey: 'k')
          .structureWithDocument(_request(), _pdf());

      final format = ((transport.lastCall.jsonBodyMap['output_config']
          as Map)['format'] as Map);
      expect(format['type'], 'json_schema');
      expect((format['schema'] as Map).containsKey(r'$defs'), isTrue);
    });

    test('returns the text and the token counts', () async {
      final transport = RecordingTransport.single(_anthropicReply());
      final response =
          await AnthropicDocumentProvider(transport: transport, apiKey: 'k')
              .structureWithDocument(_request(), _pdf());

      expect(response.inputTokens, 4200);
      expect(response.outputTokens, 900);
      expect(response.model, 'claude-opus-5');
      expect(extractJsonObject(response.rawText), isNotNull);
    });

    test('surfaces an API error without leaking the key', () async {
      final transport = RecordingTransport.single(HttpReply(
        401,
        jsonEncode({
          'error': {'message': 'invalid x-api-key'}
        }),
      ));

      await expectLater(
        AnthropicDocumentProvider(transport: transport, apiKey: 'sk-secret')
            .structureWithDocument(_request(), _pdf()),
        throwsA(isA<ProviderException>()
            .having((e) => e.statusCode, 'status', 401)
            .having((e) => e.toString(), 'message',
                allOf(contains('invalid x-api-key'), isNot(contains('sk-secret'))))),
      );
    });

    test('treats a refusal as a failure rather than empty JSON', () async {
      final transport = RecordingTransport.single(HttpReply(
        200,
        jsonEncode({'stop_reason': 'refusal', 'content': <Object>[]}),
      ));

      await expectLater(
        AnthropicDocumentProvider(transport: transport, apiKey: 'k')
            .structureWithDocument(_request(), _pdf()),
        throwsA(isA<ProviderException>()),
      );
    });

    test('refuses to attach a document over the API ceiling', () {
      final provider = AnthropicDocumentProvider(
        transport: RecordingTransport(const []),
        apiKey: 'k',
      );
      expect(provider.canAttach(_pdf()), isTrue);
      expect(
        provider.canAttach(DocumentAttachment(
          bytes: List.filled(40 * 1024 * 1024, 0),
          filename: 'huge.pdf',
        )),
        isFalse,
      );
    });
  });

  group('Gemini', () {
    test('sends the PDF as inlineData', () async {
      final transport = RecordingTransport.single(_geminiReply());
      final provider =
          GeminiDocumentProvider(transport: transport, apiKey: 'goog-test');

      await provider.structureWithDocument(_request(), _pdf());

      final call = transport.lastCall;
      expect(call.headers['x-goog-api-key'], 'goog-test');
      expect(call.url.path, contains(':generateContent'));

      final contents = call.jsonBodyMap['contents'] as List;
      final parts = (contents.single as Map)['parts'] as List;
      final inline = (parts.first as Map)['inlineData'] as Map;

      expect(inline['mimeType'], 'application/pdf');
      expect(base64Decode(inline['data'] as String), equals(tinyPdfBytes()));
      expect((parts[1] as Map)['text'], isNotEmpty);
    });

    test('renders the schema in the OpenAPI subset Gemini accepts', () async {
      final transport = RecordingTransport.single(_geminiReply());
      await GeminiDocumentProvider(transport: transport, apiKey: 'k')
          .structureWithDocument(_request(), _pdf());

      final config = transport.lastCall.jsonBodyMap['generationConfig'] as Map;
      expect(config['responseMimeType'], 'application/json');

      final schema = config['responseSchema'] as Map;
      expect(schema.toString(), isNot(contains('additionalProperties')));
      expect(schema.toString(), isNot(contains(r'$ref')));
    });

    test('reads the reply and its usage metadata', () async {
      final transport = RecordingTransport.single(_geminiReply());
      final response =
          await GeminiDocumentProvider(transport: transport, apiKey: 'k')
              .structureWithDocument(_request(), _pdf());

      expect(response.inputTokens, 4100);
      expect(response.outputTokens, 880);
      expect(response.model, 'gemini-2.5-flash');
    });

    test('holds inline data under the generateContent ceiling', () {
      final provider = GeminiDocumentProvider(
        transport: RecordingTransport(const []),
        apiKey: 'k',
      );
      expect(
        provider.canAttach(DocumentAttachment(
          bytes: List.filled(19 * 1024 * 1024, 0),
          filename: 'big.pdf',
        )),
        isFalse,
      );
    });
  });

  group('delegation', () {
    test('identity and capabilities come from the upstream adapter', () {
      final provider = AnthropicDocumentProvider(
        transport: RecordingTransport(const []),
        apiKey: 'k',
      );
      expect(provider.id.value, 'anthropic');
      expect(provider.displayName, 'Claude');
      expect(provider.capabilities.nativeJsonSchema, isTrue);
      expect(provider.capabilities.acceptsAudio, isFalse);
    });

    test('the text path still goes through the upstream adapter', () async {
      final transport = RecordingTransport.single(_anthropicReply());
      await AnthropicDocumentProvider(transport: transport, apiKey: 'k')
          .structure(_request());

      final messages = transport.lastCall.jsonBodyMap['messages'] as List;
      expect((messages.single as Map)['content'], isA<String>());
    });
  });
}
