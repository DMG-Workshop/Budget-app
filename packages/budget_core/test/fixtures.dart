import 'dart:convert';

import 'package:budget_core/budget_core.dart';
import 'package:transcript_core/transcript_core.dart';

/// A statement whose lines the fixture audit's evidence quotes are drawn from,
/// so quote verification has something real to check against.
const String statementText = '''
FIRST DIRECT CURRENT ACCOUNT
Statement period 01 Mar 2026 to 31 Mar 2026

02 Mar  ACME LTD SALARY          3000.00 CR
03 Mar  GREENFIELD LETTINGS RENT 1200.00
05 Mar  BRITISH GAS ENERGY        150.00
07 Mar  DELIVEROO ORDER            60.00
11 Mar  DELIVEROO ORDER            55.00
14 Mar  TESCO STORES              400.00
18 Mar  DELIVEROO ORDER            70.00
22 Mar  SPOTIFY PREMIUM            10.00
26 Mar  DELIVEROO ORDER            55.00
''';

/// An audit that is internally consistent: needs + wants = total_expenses, and
/// every leak is drawn from an item that exists in wants.
Map<String, dynamic> validAuditJson() => <String, dynamic>{
      'currency': 'GBP',
      'period_start': '2026-03-01',
      'period_end': '2026-03-31',
      'total_net_income': 3000.00,
      'total_expenses': 2000.00,
      'needs': <Map<String, dynamic>>[
        {
          'label': 'Rent',
          'amount': 1200.00,
          'category': 'housing',
          'evidence': <String, dynamic>{
            'quote': 'GREENFIELD LETTINGS RENT 1200.00',
            'date': '2026-03-03',
          },
        },
        {
          'label': 'British Gas',
          'amount': 150.00,
          'category': 'utilities',
          'evidence': <String, dynamic>{
            'quote': 'BRITISH GAS ENERGY 150.00',
            'date': '2026-03-05',
          },
        },
      ],
      'wants': <Map<String, dynamic>>[
        {
          'label': 'Deliveroo',
          'amount': 240.00,
          'category': 'delivery',
          'evidence': <String, dynamic>{
            'quote': 'DELIVEROO ORDER 60.00',
            'date': '2026-03-07',
          },
        },
        {
          'label': 'Tesco',
          'amount': 400.00,
          'category': 'groceries',
          'evidence': <String, dynamic>{'quote': 'TESCO STORES 400.00', 'date': '2026-03-14'},
        },
        {
          'label': 'Spotify',
          'amount': 10.00,
          'category': 'subscriptions',
          'evidence': <String, dynamic>{
            'quote': 'SPOTIFY PREMIUM 10.00',
            'date': '2026-03-22',
          },
        },
      ],
      'wasteful_leaks': <Map<String, dynamic>>[
        {
          'label': 'Deliveroo',
          'amount': 240.00,
          'monthly_equivalent': 240.00,
          'severity': 'severe',
          'verdict':
              'Four deliveries cost you 240.00 this month. That is 2880.00 a '
                  'year to avoid walking to a kitchen.',
          'evidence': <String, dynamic>{
            'quote': 'DELIVEROO ORDER 60.00',
            'date': '2026-03-07',
          },
        },
      ],
      'harsh_audit_summary':
          'You kept 1000.00 of 3000.00. Deliveroo took 240.00 of it, which is '
              '2880.00 a year for food you could have cooked.',
      'action_plan': <String>[
        'Cancel Deliveroo. It costs you 2880.00 a year.',
        'Move the 1000.00 surplus to savings on payday, not month end.',
      ],
    };

String validAuditResponse() => jsonEncode(validAuditJson());

/// Replays a queued list of responses, so the repair loop can be driven.
class SequencedStructuringProvider extends StructuringProvider {
  SequencedStructuringProvider(this._responses);

  final List<String> _responses;
  final List<StructureRequest> requests = [];

  @override
  ProviderId get id => const ProviderId('sequenced');

  @override
  String get displayName => 'Sequenced test provider';

  @override
  ProviderCapabilities get capabilities => const ProviderCapabilities(
        acceptsAudio: false,
        acceptsText: true,
        nativeJsonSchema: true,
        requiresApiKey: false,
        contextWindowTokens: 200000,
      );

  @override
  Future<ConnectionResult> test() async =>
      ConnectionResult.success(summary: 'Connected · sequenced');

  @override
  Future<StructureResponse> structure(StructureRequest request) async {
    requests.add(request);
    if (_responses.isEmpty) {
      throw StateError('ran out of responses on call ${requests.length}');
    }
    return StructureResponse(rawText: _responses.removeAt(0));
  }
}

/// A tiny but structurally valid PDF, so attachment tests exercise real bytes
/// rather than a string pretending to be a file.
List<int> tinyPdfBytes() => utf8.encode(
      '%PDF-1.4\n1 0 obj<</Type/Catalog>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF',
    );

/// A document-capable provider that records which path the pipeline chose.
class FakeDocumentProvider extends DocumentStructuringProvider {
  FakeDocumentProvider(this._responses, {this.maxBytes = 32 * 1024 * 1024});

  final List<String> _responses;
  final int maxBytes;

  final List<StructureRequest> textRequests = [];
  final List<StructureRequest> documentRequests = [];
  DocumentAttachment? lastAttachment;

  @override
  int get maxDocumentBytes => maxBytes;

  @override
  ProviderId get id => const ProviderId('fake-document');

  @override
  String get displayName => 'Fake document provider';

  @override
  ProviderCapabilities get capabilities => const ProviderCapabilities(
        acceptsAudio: false,
        acceptsText: true,
        nativeJsonSchema: true,
        requiresApiKey: false,
        contextWindowTokens: 200000,
      );

  @override
  Future<ConnectionResult> test() async =>
      ConnectionResult.success(summary: 'Connected · fake document');

  String _next(int call) {
    if (_responses.isEmpty) {
      throw StateError('ran out of responses on call $call');
    }
    return _responses.removeAt(0);
  }

  @override
  Future<StructureResponse> structure(StructureRequest request) async {
    textRequests.add(request);
    return StructureResponse(
      rawText: _next(textRequests.length + documentRequests.length),
    );
  }

  @override
  Future<StructureResponse> structureWithDocument(
    StructureRequest request,
    DocumentAttachment document,
  ) async {
    documentRequests.add(request);
    lastAttachment = document;
    return StructureResponse(
      rawText: _next(textRequests.length + documentRequests.length),
    );
  }
}
