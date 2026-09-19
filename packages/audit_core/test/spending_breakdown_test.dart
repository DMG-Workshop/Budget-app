import 'package:audit_core/audit_core.dart';
import 'package:test/test.dart';

import 'fixtures.dart';

AuditReport _report(void Function(Map<String, dynamic>) mutate) {
  final json = validAuditJson();
  mutate(json);
  return AuditReport.fromJson(json);
}

void main() {
  test('carves leaks out of wants rather than adding them', () {
    final breakdown =
        SpendingBreakdown.of(AuditReport.fromJson(validAuditJson()));

    expect(breakdown.needs, const Money(135000));
    // Wants are 650.00 with 240.00 of Deliveroo carved out.
    expect(breakdown.wants, const Money(41000));
    expect(breakdown.leaks, const Money(24000));

    // The segments still add up to what was actually spent.
    expect(breakdown.total, const Money(200000));
    expect(breakdown.unattributedLeaks, Money.zero);
  });

  test('carves a leak out of needs when that is where it came from', () {
    final breakdown = SpendingBreakdown.of(_report((j) {
      (j['wasteful_leaks'] as List<Map<String, dynamic>>)[0]['label'] =
          'British Gas';
      (j['wasteful_leaks'] as List<Map<String, dynamic>>)[0]['amount'] = 150.0;
    }));

    expect(breakdown.needs, const Money(120000));
    expect(breakdown.wants, const Money(65000));
    expect(breakdown.leaks, const Money(15000));
    expect(breakdown.total, const Money(200000));
  });

  test('never carves out more than the source item holds', () {
    final breakdown = SpendingBreakdown.of(_report((j) {
      (j['wasteful_leaks'] as List<Map<String, dynamic>>)[0]['amount'] = 900.0;
    }));

    // Without the clamp, wants would go to -250.00 and the bar would paint
    // backwards; with it, only the 240.00 that exists is carved out.
    expect(breakdown.wants, const Money(41000));
    expect(breakdown.leaks, const Money(24000));
    expect(breakdown.total, const Money(200000));
  });

  test('keeps an unattributable leak out of the bar but reports it', () {
    final breakdown = SpendingBreakdown.of(_report((j) {
      (j['wasteful_leaks'] as List<Map<String, dynamic>>)[0]['label'] =
          'Uber Eats';
    }));

    expect(breakdown.leaks, Money.zero);
    expect(breakdown.unattributedLeaks, const Money(24000));
    expect(breakdown.total, const Money(200000),
        reason: 'the bar must still match total spending');
  });

  test('an audit with no spending renders an empty bar, not a crash', () {
    final breakdown = SpendingBreakdown.of(_report((j) {
      j['needs'] = <Map<String, dynamic>>[];
      j['wants'] = <Map<String, dynamic>>[];
      j['wasteful_leaks'] = <Map<String, dynamic>>[];
      j['total_expenses'] = 0.0;
    }));

    expect(breakdown.isEmpty, isTrue);
    expect(breakdown.fractionOf(breakdown.needs), 0);
  });
}
