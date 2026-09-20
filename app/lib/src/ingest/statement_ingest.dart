import 'dart:typed_data';

import 'package:audit_core/audit_core.dart';
import 'package:file_picker/file_picker.dart';
import 'package:pdfrx/pdfrx.dart';

/// What happened when the device tried to read the PDF's text layer.
class TextExtraction {
  const TextExtraction({this.text, this.pageCount = 0, this.failure});

  /// Null when nothing could be read.
  final String? text;

  final int pageCount;

  /// Why extraction produced nothing, phrased for the user.
  final String? failure;

  bool get succeeded => (text ?? '').trim().isNotEmpty;
}

/// Getting a bank statement off the user's phone and into a form a model can
/// read.
///
/// Both forms are produced wherever possible: the bytes for the attachment
/// path, and the text for the extracted-text path and — regardless of which
/// path is taken — for offline verification of the evidence quotes the model
/// cites. Losing that check to save one extraction pass would be a poor trade.
class StatementIngest {
  const StatementIngest._();

  /// Larger than any real statement, small enough that a mis-picked file does
  /// not exhaust memory on an older phone. Provider limits bite well below
  /// this anyway, and exceeding one falls back to the text path.
  static const int maxBytes = 50 * 1024 * 1024;

  /// Shows the system picker and reads whatever the user chose.
  ///
  /// Returns null when the user cancelled, which is not an error and should
  /// not produce a message.
  static Future<StatementDocument?> pick() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['pdf'],
      // The bytes come back in memory rather than as a path. On Android a
      // content:// URI is not a file path, and asking for one forces a copy
      // into the cache that then has to be cleaned up.
      withData: true,
    );

    final file = result?.files.singleOrNull;
    final bytes = file?.bytes;
    if (file == null || bytes == null) return null;

    return read(filename: file.name, bytes: bytes);
  }

  /// Builds a [StatementDocument] from bytes already in hand.
  static Future<StatementDocument> read({
    required String filename,
    required Uint8List bytes,
  }) async {
    if (bytes.length > maxBytes) {
      throw StatementTooLargeException(bytes.length, maxBytes);
    }

    final extraction = await extractText(bytes);
    return StatementDocument(
      filename: filename,
      pdfBytes: bytes,
      extractedText: extraction.text,
    );
  }

  /// Pulls the text layer out of a PDF with pdfium.
  ///
  /// Never throws: a statement that cannot be read as text is a normal
  /// outcome — a scan, or a bank that ships images — and the attachment path
  /// may still be able to handle it. The reason is returned rather than
  /// logged so the UI can say which of the two situations the user is in.
  static Future<TextExtraction> extractText(Uint8List bytes) async {
    PdfDocument? document;
    try {
      // pdfrx 2.x loads its native engine lazily and will not open anything
      // until this has run. Idempotent, so calling it per extraction is
      // cheaper than tracking whether startup already did.
      await pdfrxFlutterInitialize();

      document = await PdfDocument.openData(bytes);

      final buffer = StringBuffer();
      for (final page in document.pages) {
        final text = await page.loadText();
        final content = text?.fullText.trim() ?? '';
        if (content.isNotEmpty) {
          // Page boundaries are kept: a transaction table that continues
          // across a page break reads very differently from one that does
          // not, and the model is told which it is looking at.
          buffer
            ..writeln('--- page ${page.pageNumber} ---')
            ..writeln(content);
        }
      }

      final joined = buffer.toString().trim();
      if (joined.isEmpty) {
        return TextExtraction(
          pageCount: document.pages.length,
          failure: 'This PDF has no text layer — it is probably a scan. '
              'Claude and Gemini can still read it directly; a local model '
              'cannot, and would need an OCR pass first.',
        );
      }

      return TextExtraction(text: joined, pageCount: document.pages.length);
    } on Object catch (e) {
      return TextExtraction(
        failure: 'The PDF could not be opened on this device ($e). If it is '
            'password protected, remove the password and try again.',
      );
    } finally {
      await document?.dispose();
    }
  }
}

/// The chosen file is implausibly large for a bank statement.
class StatementTooLargeException implements Exception {
  const StatementTooLargeException(this.actual, this.limit);

  final int actual;
  final int limit;

  String get message =>
      'That file is ${(actual / (1024 * 1024)).toStringAsFixed(1)} MB. '
      'The limit is ${limit ~/ (1024 * 1024)} MB — bank statements are '
      'rarely more than a few.';

  @override
  String toString() => message;
}
