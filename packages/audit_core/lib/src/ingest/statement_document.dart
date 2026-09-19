import 'package:transcript_core/transcript_core.dart';

import '../providers/document_provider.dart';

/// Which of the two ingestion paths a statement will take.
enum IngestionRoute {
  /// The PDF itself goes to the model, which reads its table structure.
  /// Available only on providers that accept documents — Claude and Gemini.
  attachment,

  /// Text extracted from the PDF on the device goes in the prompt. The only
  /// path a local model or a text-only cloud model can take, and the only path
  /// on which nothing but text ever leaves the device.
  extractedText,
}

/// Why a statement is taking the path it is.
///
/// Surfaced in the UI. "Sent as text because Ollama cannot read PDFs" is a very
/// different fact from "sent as text because your statement is 40 MB", and the
/// user can act on the second one.
class IngestionDecision {
  const IngestionDecision(this.route, this.reason);

  final IngestionRoute route;
  final String reason;
}

/// A bank statement, in whichever forms the device managed to produce.
///
/// Both may be present: the picker holds the bytes, and text extraction runs
/// regardless so that evidence quotes can be verified offline even when the
/// PDF itself was sent. That verification is the cheapest hallucination check
/// available and it would be a shame to lose it by taking the better path.
class StatementDocument {
  const StatementDocument({
    required this.filename,
    this.pdfBytes,
    this.extractedText,
  });

  final String filename;

  /// The raw PDF. Null when the user supplied text directly, or when reading
  /// the file failed but extraction had already succeeded.
  final List<int>? pdfBytes;

  /// Text pulled out of the PDF on the device. Null when extraction failed —
  /// a scanned statement with no text layer is the usual cause.
  final String? extractedText;

  bool get hasBytes => pdfBytes != null && pdfBytes!.isNotEmpty;
  bool get hasText => (extractedText ?? '').trim().isNotEmpty;

  /// Rough token cost of the text path, on the ~3.5 characters per token
  /// heuristic transcript_core uses for the same purpose.
  int get estimatedTextTokens =>
      hasText ? (extractedText!.length / 3.5).ceil() : 0;

  DocumentAttachment? get attachment => hasBytes
      ? DocumentAttachment(bytes: pdfBytes!, filename: filename)
      : null;

  /// Picks a path for [provider].
  ///
  /// Prefers the attachment path wherever it is available, because a bank
  /// statement is a table and flattening a table to text is lossy in exactly
  /// the way that matters: a column of dates and a column of amounts become
  /// one undifferentiated stream of numbers.
  IngestionDecision routeFor(StructuringProvider provider) {
    final doc = attachment;

    if (provider is DocumentStructuringProvider && doc != null) {
      if (provider.canAttach(doc)) {
        return const IngestionDecision(
          IngestionRoute.attachment,
          'Sent as a PDF so the model can read the table layout directly.',
        );
      }
      if (hasText) {
        final mb = (doc.encodedLength / (1024 * 1024)).toStringAsFixed(1);
        return IngestionDecision(
          IngestionRoute.extractedText,
          'The statement is too large to attach ($mb MB encoded), so text '
              'extracted on this device was sent instead.',
        );
      }
    }

    if (hasText) {
      return IngestionDecision(
        IngestionRoute.extractedText,
        provider is DocumentStructuringProvider
            ? 'Sent as text extracted on this device.'
            : '${provider.displayName} cannot read PDFs, so text extracted on '
                'this device was sent instead.',
      );
    }

    return const IngestionDecision(
      IngestionRoute.extractedText,
      'No text could be read from this PDF.',
    );
  }
}
