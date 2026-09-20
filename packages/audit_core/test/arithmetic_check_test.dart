import 'package:audit_core/audit_core.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

AuditReport _report(void Function(Map<String, dynamic>) mutate) {
  final json = validAuditJson();
  mutate(json);
  return AuditReport.fromJson(json);
}

List<String> _pointers(ArithmeticReport report) =>
    report.findings.map((f) => f.pointer).toList();

void main() {
  test('a consistent audit produces no findings', () {
    final result = verifyArithmetic(AuditReport.fromJson(validAuditJson()));
    expect(result.findings, isEmpty, reason: result.findings.join('\n'));
    expect(result.isClean, isTrue);
    expect(result.computedExpenses, const Money(200000));
    expect(result.expenseDrift, Money.zero);
  });

  test('catches a total that disagrees with its own line items', () {
    final result = verifyArithmetic(_report((j) => j['total_expenses'] = 1500.0));

    expect(_pointers(result), contains('/total_expenses'));
    expect(result.hasErrors, isTrue);
    expect(result.computedExpenses, const Money(200000));
    expect(result.declaredExpenses, const Money(150000));
    expect(result.errors.single.message, contains('500.00'));
  });

  test('tolerates per-item rounding drift', () {
    // Five items rounded to two places can legitimately be a few cents out.
    final result = verifyArithmetic(_report((j) => j['total_expenses'] = 2000.02));
    expect(result.isClean, isTrue);
  });

  test('catches a leak that appears in neither needs nor wants', () {
    final result = verifyArithmetic(_report((j) {
      (j['wasteful_leaks'] as List<Map<String, dynamic>>)[0]['label'] =
          'Uber Eats';
    }));

    expect(_pointers(result), contains('/wasteful_leaks/0'));
    expect(result.hasErrors, isTrue);
  });

  test('matches leak labels case- and punctuation-insensitively', () {
    final result = verifyArithmetic(_report((j) {
      (j['wasteful_leaks'] as List<Map<String, dynamic>>)[0]['label'] =
          'DELIVEROO!';
    }));
    expect(result.isClean, isTrue);
  });

  test('catches a leak larger than the spending it is drawn from', () {
    final result = verifyArithmetic(_report((j) {
      final leak = (j['wasteful_leaks'] as List<Map<String, dynamic>>)[0];
      leak['amount'] = 500.0;
      leak['severity'] = 'critical';
    }));

    expect(_pointers(result), contains('/wasteful_leaks/0/amount'));
  });

  test('catches an understated severity', () {
    final result = verifyArithmetic(_report((j) {
      (j['wasteful_leaks'] as List<Map<String, dynamic>>)[0]['severity'] =
          'minor';
    }));

    final finding = result.findings
        .firstWhere((f) => f.pointer == '/wasteful_leaks/0/severity');
    expect(finding.severity, FindingSeverity.warning);
    expect(finding.message, contains('8.0%'));
    expect(finding.message, contains('severe'));
  });

  test('allows a severity harsher than the thresholds require', () {
    // An unused subscription is severe regardless of size; the prompt says so
    // and the verifier must not argue with it.
    final result = verifyArithmetic(_report((j) {
      (j['wasteful_leaks'] as List<Map<String, dynamic>>)[0]['severity'] =
          'critical';
    }));
    expect(result.isClean, isTrue);
  });

  test('catches negative spending', () {
    final result = verifyArithmetic(_report((j) {
      (j['wants'] as List<Map<String, dynamic>>)[1]['amount'] = -400.0;
      j['total_expenses'] = 1200.0;
    }));

    expect(_pointers(result), contains('/wants/1/amount'));
  });

  test('catches negative income', () {
    final result = verifyArithmetic(_report((j) => j['total_net_income'] = -10.0));
    expect(_pointers(result), contains('/total_net_income'));
    expect(result.hasErrors, isTrue);
  });

  test('catches an empty action plan', () {
    final result = verifyArithmetic(_report((j) => j['action_plan'] = <String>[]));
    expect(_pointers(result), contains('/action_plan'));
  });

  test('catches a period that ends before it starts', () {
    final result = verifyArithmetic(_report((j) {
      j['period_start'] = '2026-03-31';
      j['period_end'] = '2026-03-01';
    }));
    expect(_pointers(result), contains('/period_end'));
  });

  test('notes an unreadable period without failing the audit', () {
    final result = verifyArithmetic(_report((j) => j['period_start'] = 'March'));
    expect(result.hasErrors, isFalse);
    expect(_pointers(result), contains('/period_start'));
  });
}
