import 'dart:convert';
import 'dart:io';

import 'package:audit_core/audit_core.dart';

/// Exports the audit contract for anything that is not this Dart package.
///
/// The self-hosted server has to send the same schema and the same prompt as
/// the app, or the same statement audited in a browser and on a phone gives
/// different answers — which would be a very hard bug to believe, let alone
/// find. Dart is the single source of truth; this writes what Python reads,
/// and the server's own tests assert byte equality against these files.
///
/// Run: dart run tool/export_contract.dart [outputDir]
/// Default output: ../../contracts
///
/// Follows EchoCodex's `tool/export_schema.dart` convention.
void main(List<String> args) {
  final dir = Directory(args.isEmpty ? '../../contracts' : args.first);
  dir.createSync(recursive: true);

  const encoder = JsonEncoder.withIndent('  ');

  _write(
    File('${dir.path}/audit_report.schema.json'),
    '${encoder.convert(auditReportSchema)}\n',
  );

  // Both branches of both conditionals in the prompt, pinned to a fixed date
  // so the output is byte-stable and a diff means a real change.
  _write(
    File('${dir.path}/harsh_auditor.attached.txt'),
    AuditorPrompts.system(
      referenceDate: _referenceDate,
      statementIsAttached: true,
      currencyHint: 'GBP',
    ),
  );

  _write(
    File('${dir.path}/harsh_auditor.text.txt'),
    AuditorPrompts.system(
      referenceDate: _referenceDate,
      statementIsAttached: false,
    ),
  );

  // A third variant, so the one block the server builds itself — the
  // user-context section — is checked against Dart rather than trusted.
  _write(
    File('${dir.path}/harsh_auditor.context.txt'),
    AuditorPrompts.system(
      referenceDate: _referenceDate,
      statementIsAttached: false,
      userContext: '{{USER_CONTEXT}}',
    ),
  );

  stdout.writeln('Wrote the audit contract to ${dir.path}');
}

/// Fixed, so re-running the exporter without changing the prompt produces no
/// diff.
const String _referenceDate = '2026-01-01';

void _write(File file, String contents) {
  file.writeAsStringSync(contents);
  stdout.writeln('  ${file.path}');
}
