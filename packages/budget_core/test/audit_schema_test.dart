import 'package:budget_core/budget_core.dart';
import 'package:test/test.dart';
import 'package:transcript_core/transcript_core.dart';

import 'fixtures.dart';

/// Walks every object node in a schema, so invariants can be asserted across
/// the whole document rather than spot-checked at the root.
void _forEachObject(Object? node, void Function(Map<String, dynamic>) visit) {
  if (node is List) {
    for (final child in node) {
      _forEachObject(child, visit);
    }
    return;
  }
  if (node is! Map) return;
  final map = node.cast<String, dynamic>();
  if (map['type'] == 'object' && map['properties'] is Map) visit(map);
  for (final value in map.values) {
    _forEachObject(value, visit);
  }
}

void main() {
  group('canonical schema', () {
    test('every property is required, as OpenAI strict mode demands', () {
      _forEachObject(auditReportSchema, (object) {
        final properties =
            (object['properties'] as Map).keys.cast<String>().toSet();
        final required =
            ((object['required'] as List?) ?? const []).cast<String>().toSet();
        expect(
          properties.difference(required),
          isEmpty,
          reason: 'optional properties must be spelled as a nullable type, '
              'not by omission from "required"',
        );
      });
    });

    test('every object forbids additional properties', () {
      _forEachObject(auditReportSchema, (object) {
        expect(object['additionalProperties'], isFalse);
      });
    });

    test('describes every field it asks the model to fill', () {
      _forEachObject(auditReportSchema, (object) {
        final properties = (object['properties'] as Map).cast<String, dynamic>();
        for (final entry in properties.entries) {
          final value = entry.value;
          if (value is Map && value.containsKey(r'$ref')) continue;
          expect(
            (value as Map)['description'],
            isA<String>(),
            reason: '"${entry.key}" has no description; in structured-output '
                'mode the description is the only instruction the model sees',
          );
        }
      });
    });
  });

  group('dialect rendering', () {
    test(r'plain keeps $defs and drops annotation keywords', () {
      final rendered = renderSchema(auditReportSchema, SchemaDialect.plain);
      expect(rendered.containsKey(r'$defs'), isTrue);
      expect(rendered.containsKey(r'$schema'), isFalse);
      expect(rendered.containsKey(r'$id'), isFalse);
    });

    test('OpenAI strict inlines every reference', () {
      final rendered = renderSchema(auditReportSchema, SchemaDialect.openAiStrict);
      expect(rendered.containsKey(r'$defs'), isFalse);
      expect(rendered.toString(), isNot(contains(r'$ref')));
    });

    test('Gemini drops additionalProperties and spells null as nullable', () {
      final rendered = renderSchema(auditReportSchema, SchemaDialect.gemini);
      expect(rendered.toString(), isNot(contains('additionalProperties')));
      expect(rendered.toString(), isNot(contains(r'$ref')));

      final evidence = ((((rendered['properties'] as Map)['needs']
              as Map)['items'] as Map)['properties'] as Map)['evidence'] as Map;
      final date = (evidence['properties'] as Map)['date'] as Map;
      expect(date['nullable'], isTrue);
      expect(date['type'], 'string');
    });

    test('Gemini gets an explicit property ordering', () {
      final rendered = renderSchema(auditReportSchema, SchemaDialect.gemini);
      expect(rendered['propertyOrdering'], contains('harsh_audit_summary'));
    });
  });

  group('validation', () {
    final validator = SchemaValidator(auditReportSchema);

    test('accepts a well-formed audit', () {
      expect(validator.validate(validAuditJson()), isEmpty);
    });

    test('rejects a missing required field', () {
      final json = validAuditJson()..remove('harsh_audit_summary');
      expect(
        validator.validate(json).map((v) => v.pointer),
        contains('/harsh_audit_summary'),
      );
    });

    test('rejects an unknown severity', () {
      final json = validAuditJson();
      (json['wasteful_leaks'] as List<Map<String, dynamic>>)[0]['severity'] =
          'apocalyptic';
      expect(validator.validate(json), isNotEmpty);
    });

    test('rejects a field the model invented', () {
      final json = validAuditJson()..['encouragement'] = 'You are doing great!';
      expect(
        validator.validate(json).map((v) => v.pointer),
        contains('/encouragement'),
      );
    });

    test('accepts a null evidence date', () {
      final json = validAuditJson();
      ((json['needs'] as List<Map<String, dynamic>>)[0]['evidence']
          as Map<String, dynamic>)['date'] = null;
      expect(validator.validate(json), isEmpty);
    });
  });
}
