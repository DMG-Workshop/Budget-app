import 'audit_report.dart';
import 'money.dart';

/// The three segments the spending bar shows.
///
/// Exists because the obvious rendering is wrong. Leaks are drawn *from*
/// needs and wants rather than added alongside them, so painting
/// needs + wants + leaks would show a bar longer than the money that was
/// actually spent, and every percentage on it would be understated.
///
/// Each leak is attributed back to the item it came from by label, the same
/// way the arithmetic verifier matches them. A leak matching nothing is
/// counted separately rather than silently dropped: the verifier already
/// raises it as an error, and the bar should not quietly disagree with the
/// total printed above it.
class SpendingBreakdown {
  const SpendingBreakdown({
    required this.needs,
    required this.wants,
    required this.leaks,
    required this.unattributedLeaks,
  });

  factory SpendingBreakdown.of(AuditReport report) {
    var leakFromNeeds = Money.zero;
    var leakFromWants = Money.zero;
    var unattributed = Money.zero;

    final needsByLabel = _totals(report.needs);
    final wantsByLabel = _totals(report.wants);

    for (final leak in report.wastefulLeaks) {
      final key = _key(leak.label);
      final inWants = wantsByLabel[key];
      final inNeeds = needsByLabel[key];

      if (inWants != null) {
        // Never carve out more than the item holds; a leak larger than its
        // source is a verifier error, and clamping keeps the bar honest
        // while that is surfaced elsewhere.
        leakFromWants += _min(leak.amount, inWants);
      } else if (inNeeds != null) {
        leakFromNeeds += _min(leak.amount, inNeeds);
      } else {
        unattributed += leak.amount;
      }
    }

    return SpendingBreakdown(
      needs: report.needsTotal - leakFromNeeds,
      wants: report.wantsTotal - leakFromWants,
      leaks: leakFromNeeds + leakFromWants,
      unattributedLeaks: unattributed,
    );
  }

  /// Needs, with any leaks carved out of them.
  final Money needs;

  /// Wants, with any leaks carved out of them.
  final Money wants;

  /// Leaks that were successfully attributed to a line item.
  final Money leaks;

  /// Leaks matching no line item. Not painted — it would inflate the bar past
  /// the spending it claims to represent — but exposed so the UI can say so.
  final Money unattributedLeaks;

  /// What the bar's segments add up to.
  Money get total => needs + wants + leaks;

  bool get isEmpty => total.minorUnits <= 0;

  double fractionOf(Money part) => part.fractionOf(total);

  static Map<String, Money> _totals(List<SpendItem> items) {
    final out = <String, Money>{};
    for (final item in items) {
      final key = _key(item.label);
      out[key] = (out[key] ?? Money.zero) + item.amount;
    }
    return out;
  }

  static Money _min(Money a, Money b) => a <= b ? a : b;

  static String _key(String label) =>
      label.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
}
