import '../model/audit_report.dart';
import '../model/money.dart';

/// How much a finding matters.
enum FindingSeverity {
  /// Worth recording, not worth interrupting anyone over.
  info,

  /// The audit is usable but one of its numbers is suspect.
  warning,

  /// A number on the screen is wrong. The UI says so rather than presenting it
  /// as fact.
  error,
}

/// One thing wrong with the model's arithmetic.
class AuditFinding {
  const AuditFinding(this.pointer, this.message, this.severity);

  /// RFC 6901-style pointer at the offending value, matching the convention
  /// transcript_core's [SchemaViolation] uses.
  final String pointer;

  final String message;
  final FindingSeverity severity;

  @override
  String toString() =>
      '${pointer.isEmpty ? '(root)' : pointer}: $message';
}

/// The result of re-doing the model's sums.
class ArithmeticReport {
  const ArithmeticReport({
    required this.findings,
    required this.declaredExpenses,
    required this.computedExpenses,
  });

  final List<AuditFinding> findings;

  /// What the model said the total was.
  final Money declaredExpenses;

  /// What the line items actually add up to.
  final Money computedExpenses;

  Money get expenseDrift => computedExpenses - declaredExpenses;

  bool get isClean => findings.isEmpty;
  bool get hasErrors =>
      findings.any((f) => f.severity == FindingSeverity.error);

  List<AuditFinding> get errors =>
      findings.where((f) => f.severity == FindingSeverity.error).toList();
}

/// Re-computes everything the model claimed and reports what does not add up.
///
/// LLMs are poor arithmetic engines and good extraction engines. The design
/// follows from that: the model is trusted to find and categorise transactions,
/// and trusted with nothing at all that can be recomputed from them. Everything
/// checked here is checked offline, deterministically, at no cost per run.
///
/// This reports rather than silently corrects. A total that disagrees with its
/// own line items usually means an item was missed during extraction, and
/// quietly overwriting the total would hide exactly the failure the user needs
/// to know about. [AuditReport.withRecomputedTotals] exists for callers that
/// would rather show a consistent number and say so.
ArithmeticReport verifyArithmetic(
  AuditReport report, {
  Money? tolerance,
}) {
  final findings = <AuditFinding>[];

  // A cent per line item, floor of one currency unit. Models round each item to
  // two places and the roundings accumulate; anything inside that band is
  // arithmetic noise rather than a missed transaction.
  final itemCount = report.needs.length + report.wants.length;
  final slack = tolerance ?? Money(100 + itemCount);

  final computed = report.needsTotal + report.wantsTotal;
  final drift = (computed - report.totalExpenses).abs;

  if (drift > slack) {
    findings.add(AuditFinding(
      '/total_expenses',
      'Declared total is ${report.currency} ${report.totalExpenses}, but the '
          '$itemCount line items add up to ${report.currency} $computed — '
          'a difference of ${report.currency} $drift. Either an item is '
          'missing from the breakdown or the total is wrong.',
      FindingSeverity.error,
    ));
  }

  if (report.totalNetIncome.isNegative) {
    findings.add(const AuditFinding(
      '/total_net_income',
      'Net income is negative, which is not possible — money paid out is an '
          'expense, not negative income.',
      FindingSeverity.error,
    ));
  }

  _checkPositive(report.needs, 'needs', findings);
  _checkPositive(report.wants, 'wants', findings);

  _checkLeaks(report, findings, slack);
  _checkSeverities(report, findings);
  _checkPeriod(report, findings);

  if (report.actionPlan.isEmpty) {
    findings.add(const AuditFinding(
      '/action_plan',
      'The audit produced no action plan.',
      FindingSeverity.warning,
    ));
  }

  return ArithmeticReport(
    findings: findings,
    declaredExpenses: report.totalExpenses,
    computedExpenses: computed,
  );
}

void _checkPositive(
  List<SpendItem> items,
  String field,
  List<AuditFinding> findings,
) {
  for (var i = 0; i < items.length; i++) {
    if (items[i].amount.isNegative) {
      findings.add(AuditFinding(
        '/$field/$i/amount',
        '"${items[i].label}" has a negative amount. Refunds should be netted '
            'off the purchase, not listed as negative spending.',
        FindingSeverity.warning,
      ));
    }
  }
}

/// Leaks are a *view* of spending already counted, not extra spending. The two
/// failure modes are a leak that appears nowhere in the breakdown (invented, or
/// extra spending that will double-count if anyone sums it) and a leak larger
/// than the item it is drawn from.
void _checkLeaks(
  AuditReport report,
  List<AuditFinding> findings,
  Money slack,
) {
  final byLabel = <String, Money>{};
  for (final item in [...report.needs, ...report.wants]) {
    final key = _key(item.label);
    byLabel[key] = (byLabel[key] ?? Money.zero) + item.amount;
  }

  for (var i = 0; i < report.wastefulLeaks.length; i++) {
    final leak = report.wastefulLeaks[i];
    final source = byLabel[_key(leak.label)];

    if (source == null) {
      findings.add(AuditFinding(
        '/wasteful_leaks/$i',
        '"${leak.label}" is flagged as a leak but appears in neither needs nor '
            'wants. Leaks are drawn from spending already listed, so this is '
            'either miscategorised or was never in the statement.',
        FindingSeverity.error,
      ));
      continue;
    }

    if (leak.amount - source > slack) {
      findings.add(AuditFinding(
        '/wasteful_leaks/$i/amount',
        '"${leak.label}" is flagged at ${report.currency} ${leak.amount} but '
            'only ${report.currency} $source of it appears in the breakdown.',
        FindingSeverity.error,
      ));
    }
  }

  if (report.leaksTotal > report.totalExpenses + slack) {
    findings.add(AuditFinding(
      '/wasteful_leaks',
      'Flagged leaks total ${report.currency} ${report.leaksTotal}, which is '
          'more than all spending in the period.',
      FindingSeverity.error,
    ));
  }
}

/// The schema states severity thresholds as percentages of net income, so they
/// are arithmetic and can be checked. Only understatement is reported: the
/// prompt allows harsher grades for reasons the numbers do not carry, such as a
/// subscription with no matching usage.
void _checkSeverities(AuditReport report, List<AuditFinding> findings) {
  final income = report.totalNetIncome;
  if (income.isZero || income.isNegative) return;

  for (var i = 0; i < report.wastefulLeaks.length; i++) {
    final leak = report.wastefulLeaks[i];
    final share = leak.amount.fractionOf(income);
    final expected = share > 0.08
        ? LeakSeverity.critical
        : share > 0.03
            ? LeakSeverity.severe
            : share > 0.01
                ? LeakSeverity.moderate
                : LeakSeverity.minor;

    if (leak.severity.rank < expected.rank) {
      findings.add(AuditFinding(
        '/wasteful_leaks/$i/severity',
        '"${leak.label}" is ${(share * 100).toStringAsFixed(1)}% of net income '
            'and is graded ${leak.severity.wire}; the thresholds make it '
            '${expected.wire}.',
        FindingSeverity.warning,
      ));
    }
  }
}

void _checkPeriod(AuditReport report, List<AuditFinding> findings) {
  final start = DateTime.tryParse(report.periodStart);
  final end = DateTime.tryParse(report.periodEnd);

  if (start == null || end == null) {
    findings.add(const AuditFinding(
      '/period_start',
      'The statement period could not be read as a pair of dates.',
      FindingSeverity.info,
    ));
    return;
  }

  if (end.isBefore(start)) {
    findings.add(AuditFinding(
      '/period_end',
      'The statement period ends (${report.periodEnd}) before it begins '
          '(${report.periodStart}).',
      FindingSeverity.warning,
    ));
  }
}

/// Labels are matched case- and punctuation-insensitively, because a model will
/// write "Deliveroo" in one list and "DELIVEROO" in the other.
String _key(String label) =>
    label.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
