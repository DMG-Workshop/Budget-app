import 'package:audit_core/audit_core.dart';
import 'package:test/test.dart';
import 'package:transcript_core/transcript_core.dart';

import 'fixtures.dart';

void main() {
  final report = AuditReport.fromJson(validAuditJson());

  group('parsing', () {
    test('reads money exactly', () {
      expect(report.totalNetIncome, const Money(300000));
      expect(report.totalExpenses, const Money(200000));
      expect(report.needs.first.amount, const Money(120000));
    });

    test('reads severity from the wire value', () {
      expect(report.wastefulLeaks.single.severity, LeakSeverity.severe);
    });

    test('falls back rather than throwing on an unknown severity', () {
      final json = validAuditJson();
      (json['wasteful_leaks'] as List<Map<String, dynamic>>)[0]['severity'] =
          'apocalyptic';
      expect(
        AuditReport.fromJson(json).wastefulLeaks.single.severity,
        LeakSeverity.moderate,
      );
    });

    test('survives a response missing optional structure', () {
      final sparse = AuditReport.fromJson(const {'currency': 'USD'});
      expect(sparse.needs, isEmpty);
      expect(sparse.actionPlan, isEmpty);
      expect(sparse.totalExpenses, Money.zero);
    });

    test('keeps a null evidence date as null', () {
      expect(report.needs.first.evidence.date, '2026-03-03');
      final json = validAuditJson();
      ((json['needs'] as List<Map<String, dynamic>>)[0]['evidence']
          as Map<String, dynamic>)['date'] = null;
      expect(AuditReport.fromJson(json).needs.first.evidence.date, isNull);
    });
  });

  group('derived figures', () {
    test('net cashflow is income minus expenses', () {
      expect(report.netCashflow, const Money(100000));
      expect(report.isDeficit, isFalse);
    });

    test('a deficit is negative and says so', () {
      final json = validAuditJson()..['total_net_income'] = 1500.0;
      final deficit = AuditReport.fromJson(json);
      expect(deficit.netCashflow, const Money(-50000));
      expect(deficit.isDeficit, isTrue);
    });

    test('category totals come from the line items', () {
      expect(report.needsTotal, const Money(135000));
      expect(report.wantsTotal, const Money(65000));
      expect(report.needsTotal + report.wantsTotal, report.totalExpenses);
    });

    test('annualises the leak cost', () {
      expect(report.wastefulLeaks.single.annualCost, const Money(288000));
      expect(report.annualisedLeakCost, const Money(288000));
    });
  });

  group('leaksBySeverity', () {
    test('orders worst first, then by amount', () {
      final json = validAuditJson();
      final leaks = json['wasteful_leaks'] as List<Map<String, dynamic>>;
      leaks.addAll([
        {
          'label': 'Spotify',
          'amount': 10.0,
          'monthly_equivalent': 10.0,
          'severity': 'critical',
          'verdict': 'Unused since January.',
          'evidence': <String, dynamic>{
            'quote': 'SPOTIFY PREMIUM 10.00',
            'date': null,
          },
        },
        {
          'label': 'Tesco',
          'amount': 400.0,
          'monthly_equivalent': 400.0,
          'severity': 'severe',
          'verdict': 'Meal deals every day.',
          'evidence': <String, dynamic>{
            'quote': 'TESCO STORES 400.00',
            'date': null,
          },
        },
      ]);

      final ordered = AuditReport.fromJson(json)
          .leaksBySeverity
          .map((l) => l.label)
          .toList();

      // critical first; within severe, the larger amount leads.
      expect(ordered, ['Spotify', 'Tesco', 'Deliveroo']);
    });

    test('does not mutate the underlying list', () {
      final before = report.wastefulLeaks.map((l) => l.label).toList();
      report.leaksBySeverity;
      expect(report.wastefulLeaks.map((l) => l.label).toList(), before);
    });
  });

  group('serialisation', () {
    test('round-trips back through the schema validator', () {
      final roundTripped = report.toJson();
      expect(SchemaValidator(auditReportSchema).validate(roundTripped), isEmpty);
      expect(AuditReport.fromJson(roundTripped).netCashflow,
          report.netCashflow);
    });

    test('writes money as a decimal, not minor units', () {
      expect(report.toJson()['total_expenses'], 2000.0);
    });
  });

  group('withRecomputedTotals', () {
    test('replaces the declared total with the line-item sum', () {
      final wrong = AuditReport.fromJson(
        validAuditJson()..['total_expenses'] = 1500.0,
      );
      expect(wrong.totalExpenses, const Money(150000));

      final fixed = wrong.withRecomputedTotals();
      expect(fixed.totalExpenses, const Money(200000));
      expect(verifyArithmetic(fixed).isClean, isTrue);
    });

    test('leaves everything else alone', () {
      final fixed = report.withRecomputedTotals();
      expect(fixed.harshAuditSummary, report.harshAuditSummary);
      expect(fixed.wastefulLeaks.length, report.wastefulLeaks.length);
      expect(fixed.totalNetIncome, report.totalNetIncome);
    });
  });
}
