/// Provider-agnostic core for Coldwater, the statement auditor.
///
/// The AI layer — provider adapters, capabilities, transport, schema dialects,
/// tolerant JSON extraction, the schema validator and the quote verifier — is
/// EchoCodex's `transcript_core`, reused wholesale. What lives here is only
/// what a bank statement needs and a transcript does not: the audit schema, the
/// Harsh Auditor prompt, PDF attachment support, the dual ingestion route, and
/// the arithmetic verifier.
///
/// Pure Dart with no Flutter, so all of it is unit-testable without a device,
/// a network or an API key.
library;

export 'src/ingest/statement_document.dart';
export 'src/model/audit_report.dart';
export 'src/model/money.dart';
export 'src/model/spending_breakdown.dart';
export 'src/pipeline/arithmetic_check.dart';
export 'src/pipeline/audit_pipeline.dart';
export 'src/prompts/auditor_prompt.dart';
export 'src/providers/document_provider.dart';
export 'src/schema/audit_schema.dart';
