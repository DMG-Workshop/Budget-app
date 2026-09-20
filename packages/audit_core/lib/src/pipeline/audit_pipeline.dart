import 'package:transcript_core/transcript_core.dart';

import '../ingest/statement_document.dart';
import '../model/audit_report.dart';
import '../prompts/auditor_prompt.dart';
import '../providers/document_provider.dart';
import '../schema/audit_schema.dart';
import 'arithmetic_check.dart';

/// A finished audit and everything learned while producing it.
class AuditOutcome {
  const AuditOutcome({
    required this.report,
    required this.raw,
    required this.arithmetic,
    required this.route,
    required this.routeReason,
    this.repairAttempts = 0,
    this.unverifiedEvidence = const [],
    this.evidenceChecked = false,
    this.inputTokens,
    this.outputTokens,
    this.model,
  });

  final AuditReport report;

  /// The validated JSON, kept so a future schema change can re-parse an audit
  /// that is already stored without re-running the model.
  final Map<String, dynamic> raw;

  final ArithmeticReport arithmetic;

  final IngestionRoute route;
  final String routeReason;

  /// How many repair round-trips the provider needed. A provider that needs
  /// them routinely is one the user should be told about.
  final int repairAttempts;

  /// Labels whose `evidence.quote` could not be found in the statement text.
  /// Shown as unverified rather than dropped — the item may still be real, and
  /// silently deleting a transaction is its own failure mode.
  final List<String> unverifiedEvidence;

  /// False when there was no extracted text to check against, which is
  /// different from "checked and everything passed".
  final bool evidenceChecked;

  final int? inputTokens;
  final int? outputTokens;
  final String? model;

  /// Whether anything at all should be flagged to the user about this audit's
  /// trustworthiness.
  bool get isFullyVerified =>
      arithmetic.isClean && unverifiedEvidence.isEmpty && evidenceChecked;
}

/// Turns a bank statement into a validated [AuditReport].
///
/// Mirrors the treatment transcript_core's [StructuringPipeline] gives a
/// transcript — tolerant parse, schema validation, bounded repair — so that
/// reliability does not depend on which provider the user configured. What it
/// adds is the dual ingestion path and the arithmetic verifier, neither of
/// which a transcript needs.
///
/// The parse/validate/repair loop here is deliberately the same shape as
/// `StructuringPipeline._structureValidated`. That method is private and
/// transcript-specific; if attachments and a generic loop are ever upstreamed,
/// this class shrinks to the prompt, the schema and the verifier.
class AuditPipeline {
  AuditPipeline({
    required this.provider,
    this.maxRepairAttempts = 2,
    Map<String, dynamic>? schema,
  })  : schema = schema ?? auditReportSchema,
        _validator = SchemaValidator(schema ?? auditReportSchema);

  final StructuringProvider provider;

  /// Two repairs, then give up. A model that cannot satisfy the schema in three
  /// attempts will not satisfy it in five, and each attempt re-sends the
  /// statement.
  final int maxRepairAttempts;

  final Map<String, dynamic> schema;
  final SchemaValidator _validator;

  Future<AuditOutcome> run({
    required StatementDocument statement,
    required String referenceDate,
    String? currencyHint,
    String? userContext,
  }) async {
    if (!statement.hasBytes && !statement.hasText) {
      throw const AuditException(
        'There is nothing to audit. The file produced neither readable text '
        'nor bytes to send.',
      );
    }

    final decision = statement.routeFor(provider);
    final attachedPath = decision.route == IngestionRoute.attachment;

    if (!attachedPath && !statement.hasText) {
      throw const AuditException(
        'No text could be read from this PDF, and the selected provider cannot '
        'read the file directly. A scanned statement with no text layer needs '
        'either Claude or Gemini, or an OCR pass first.',
      );
    }

    final systemPrompt = AuditorPrompts.system(
      referenceDate: referenceDate,
      statementIsAttached: attachedPath,
      currencyHint: currencyHint,
      userContext: userContext,
    );

    final userContent = attachedPath
        ? AuditorPrompts.userContentForAttachment
        : AuditorPrompts.userContentForText(statement.extractedText!);

    final validated = await _structureValidated(
      systemPrompt: systemPrompt,
      userContent: userContent,
      attachment: attachedPath ? statement.attachment : null,
    );

    final report = AuditReport.fromJson(validated.raw);

    return AuditOutcome(
      report: report,
      raw: validated.raw,
      arithmetic: verifyArithmetic(report),
      route: decision.route,
      routeReason: decision.reason,
      repairAttempts: validated.repairAttempts,
      unverifiedEvidence: verifyEvidence(report, statement.extractedText),
      evidenceChecked: statement.hasText,
      inputTokens: validated.inputTokens,
      outputTokens: validated.outputTokens,
      model: validated.model,
    );
  }

  /// One provider round trip, with tolerant parsing, validation and bounded
  /// repair.
  ///
  /// The repair turn carries only the violations. Re-sending the statement —
  /// or worse, the PDF — would pay for the whole prompt again, and on the
  /// attachment path the document is already cached provider-side.
  Future<_ValidatedAudit> _structureValidated({
    required String systemPrompt,
    required String userContent,
    DocumentAttachment? attachment,
  }) async {
    final turns = <StructureTurn>[];
    var attempts = 0;
    int? inputTokens;
    int? outputTokens;

    while (true) {
      final request = StructureRequest(
        systemPrompt: systemPrompt,
        userContent: userContent,
        schema: schema,
        priorTurns: turns,
      );

      final response = attachment != null &&
              provider is DocumentStructuringProvider
          ? await (provider as DocumentStructuringProvider)
              .structureWithDocument(request, attachment)
          : await provider.structure(request);

      inputTokens = _add(inputTokens, response.inputTokens);
      outputTokens = _add(outputTokens, response.outputTokens);

      final parsed = extractJsonObject(response.rawText);
      final violations = parsed == null
          ? const [
              SchemaViolation('', 'response did not contain a JSON object')
            ]
          : _validator.validate(parsed);

      if (violations.isEmpty && parsed != null) {
        return _ValidatedAudit(
          parsed,
          attempts,
          inputTokens,
          outputTokens,
          response.model,
        );
      }

      if (attempts >= maxRepairAttempts) {
        throw AuditException(
          'The model could not produce a valid audit after '
          '${attempts + 1} attempts.',
          violations: violations.map((v) => v.toString()).toList(),
          lastResponse: response.rawText,
        );
      }

      turns
        ..add(StructureTurn('user', userContent))
        ..add(StructureTurn('assistant', response.rawText))
        ..add(StructureTurn(
          'user',
          StructuringPrompts.repair(
            violations.map((v) => v.toString()).toList(),
          ),
        ));
      attempts++;
    }
  }

  /// Checks every cited quote against the statement text and returns the labels
  /// that failed.
  ///
  /// Reuses transcript_core's [QuoteVerifier] unchanged — the problem is
  /// identical, only the haystack differs. Returns empty when there is no text
  /// to check against; [AuditOutcome.evidenceChecked] distinguishes that from a
  /// clean pass.
  static List<String> verifyEvidence(AuditReport report, String? statementText) {
    if (statementText == null || statementText.trim().isEmpty) return const [];

    final verifier = QuoteVerifier(statementText);
    final flagged = <String>[];

    void check(String label, Evidence evidence) {
      if (verifier.verify(evidence.quote).shouldFlag) flagged.add(label);
    }

    for (final item in report.needs) {
      check(item.label, item.evidence);
    }
    for (final item in report.wants) {
      check(item.label, item.evidence);
    }
    for (final leak in report.wastefulLeaks) {
      check(leak.label, leak.evidence);
    }
    return flagged;
  }

  static int? _add(int? a, int? b) =>
      a == null && b == null ? null : (a ?? 0) + (b ?? 0);
}

/// The audit failed in a way the user needs to know about.
class AuditException implements Exception {
  const AuditException(
    this.message, {
    this.violations = const [],
    this.lastResponse,
  });

  final String message;
  final List<String> violations;
  final String? lastResponse;

  static const int _excerpt = 300;

  @override
  String toString() {
    final out = StringBuffer('AuditException: $message');
    if (violations.isNotEmpty) out.write('\n${violations.join('\n')}');

    final reply = lastResponse?.trim();
    if (reply != null) {
      out.write('\n\nThe model replied: ');
      out.write(reply.isEmpty
          ? '(nothing at all)'
          : '"${reply.length > _excerpt ? '${reply.substring(0, _excerpt)}…' : reply}"');
    }
    return out.toString();
  }
}

class _ValidatedAudit {
  const _ValidatedAudit(
    this.raw,
    this.repairAttempts,
    this.inputTokens,
    this.outputTokens,
    this.model,
  );

  final Map<String, dynamic> raw;
  final int repairAttempts;
  final int? inputTokens;
  final int? outputTokens;
  final String? model;
}
