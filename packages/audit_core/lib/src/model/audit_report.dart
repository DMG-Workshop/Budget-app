import 'money.dart';

/// How badly a leak is bleeding the user, as judged by the model.
///
/// Ordered. The UI sorts by this and colours by it, and the arithmetic verifier
/// uses it to decide which discrepancies are worth interrupting the user over.
enum LeakSeverity {
  minor('minor'),
  moderate('moderate'),
  severe('severe'),
  critical('critical');

  const LeakSeverity(this.wire);

  /// The value as it appears in JSON. Kept separate from the Dart name so the
  /// enum can be renamed without changing the model-facing contract.
  final String wire;

  static LeakSeverity fromWire(String value) => LeakSeverity.values.firstWhere(
        (s) => s.wire == value,
        orElse: () => LeakSeverity.moderate,
      );

  /// Higher is worse. Used for sorting, not arithmetic.
  int get rank => index;
}

/// Where a figure came from in the statement.
///
/// This is the anti-hallucination hook, and the reason every line item carries
/// one. An LLM asked to audit a statement will cheerfully invent a plausible
/// "Streaming subscriptions £41.97" that appears nowhere in the document. The
/// quote is checked against the extracted statement text offline, for free, and
/// anything that fails is shown as unverified rather than trusted or silently
/// dropped — the same posture EchoCodex takes with transcript quotes.
class Evidence {
  const Evidence({required this.quote, this.date});

  /// A verbatim fragment of the statement line this figure came from.
  final String quote;

  /// ISO-8601 date of the transaction, when the statement gave one.
  final String? date;

  static Evidence fromJson(Map<String, dynamic> json) => Evidence(
        quote: json['quote'] as String? ?? '',
        date: json['date'] as String?,
      );

  Map<String, dynamic> toJson() => {'quote': quote, 'date': date};
}

/// One categorised outgoing. A "Need" and a "Want" have identical shape — what
/// separates them is which list the model put them in, which is the judgement
/// call the prompt is mostly about.
class SpendItem {
  const SpendItem({
    required this.label,
    required this.amount,
    required this.category,
    required this.evidence,
  });

  /// What the user would call it: "Rent", "Deliveroo", "Gym".
  final String label;

  /// Total across the statement period. Always positive.
  final Money amount;

  /// A coarse grouping — "housing", "groceries", "transport". Free text by
  /// design: a fixed taxonomy would force every unfamiliar merchant into
  /// "other", which tells the user nothing.
  final String category;

  final Evidence evidence;

  static SpendItem fromJson(Map<String, dynamic> json) => SpendItem(
        label: json['label'] as String? ?? 'Unlabelled',
        amount: Money.tryParse(json['amount']) ?? Money.zero,
        category: json['category'] as String? ?? 'other',
        evidence: Evidence.fromJson(
          (json['evidence'] as Map?)?.cast<String, dynamic>() ?? const {},
        ),
      );

  Map<String, dynamic> toJson() => {
        'label': label,
        'amount': amount.toJson(),
        'category': category,
        'evidence': evidence.toJson(),
      };
}

/// Money the audit says is being wasted, with the model's verdict attached.
class WastefulLeak {
  const WastefulLeak({
    required this.label,
    required this.amount,
    required this.monthlyEquivalent,
    required this.severity,
    required this.verdict,
    required this.evidence,
  });

  final String label;

  /// Total across the statement period.
  final Money amount;

  /// Normalised to one month, so a leak found in a two-week statement and one
  /// found in a quarterly statement can sit in the same sorted list. The model
  /// is asked for this explicitly rather than it being derived here, because
  /// only the model knows whether a charge recurs or was a one-off.
  final Money monthlyEquivalent;

  final LeakSeverity severity;

  /// The blunt one-liner. This is the app's voice and it is deliberately not
  /// softened anywhere between the model and the screen.
  final String verdict;

  final Evidence evidence;

  /// What this costs over a year if nothing changes. The number that actually
  /// moves people.
  Money get annualCost => monthlyEquivalent * 12;

  static WastefulLeak fromJson(Map<String, dynamic> json) => WastefulLeak(
        label: json['label'] as String? ?? 'Unlabelled',
        amount: Money.tryParse(json['amount']) ?? Money.zero,
        monthlyEquivalent: Money.tryParse(json['monthly_equivalent']) ??
            Money.tryParse(json['amount']) ??
            Money.zero,
        severity: LeakSeverity.fromWire(json['severity'] as String? ?? 'moderate'),
        verdict: json['verdict'] as String? ?? '',
        evidence: Evidence.fromJson(
          (json['evidence'] as Map?)?.cast<String, dynamic>() ?? const {},
        ),
      );

  Map<String, dynamic> toJson() => {
        'label': label,
        'amount': amount.toJson(),
        'monthly_equivalent': monthlyEquivalent.toJson(),
        'severity': severity.wire,
        'verdict': verdict,
        'evidence': evidence.toJson(),
      };
}

/// The complete audit of one bank statement.
class AuditReport {
  const AuditReport({
    required this.currency,
    required this.periodStart,
    required this.periodEnd,
    required this.totalNetIncome,
    required this.totalExpenses,
    required this.needs,
    required this.wants,
    required this.wastefulLeaks,
    required this.harshAuditSummary,
    required this.actionPlan,
  });

  /// ISO 4217, as printed on the statement. Never assumed: showing a sterling
  /// statement with dollar signs undermines every number on the screen.
  final String currency;

  /// ISO-8601 dates bounding the statement.
  final String periodStart;
  final String periodEnd;

  /// Money in, after tax and deductions, as it actually landed in the account.
  final Money totalNetIncome;

  /// Money out across the whole period.
  final Money totalExpenses;

  final List<SpendItem> needs;
  final List<SpendItem> wants;

  /// Not a third category — leaks are drawn from [wants] (and occasionally from
  /// an overpriced [needs] item) and called out separately. Their amounts are
  /// therefore already counted in [totalExpenses]; adding them again would
  /// double-count, which is the single easiest way to get this screen wrong.
  final List<WastefulLeak> wastefulLeaks;

  /// The blunt paragraph shown at the top of the Reality Check card.
  final String harshAuditSummary;

  /// Concrete steps, most valuable first.
  final List<String> actionPlan;

  /// The number in large type. Negative means spending outran income.
  Money get netCashflow => totalNetIncome - totalExpenses;

  bool get isDeficit => netCashflow.isNegative;

  Money get needsTotal => Money.sum(needs.map((e) => e.amount));
  Money get wantsTotal => Money.sum(wants.map((e) => e.amount));
  Money get leaksTotal => Money.sum(wastefulLeaks.map((e) => e.amount));

  /// What the flagged leaks cost over a year if nothing changes.
  Money get annualisedLeakCost =>
      Money.sum(wastefulLeaks.map((e) => e.annualCost));

  /// Leaks worst-first, then most expensive first within a severity.
  List<WastefulLeak> get leaksBySeverity {
    final sorted = [...wastefulLeaks];
    sorted.sort((a, b) {
      final bySeverity = b.severity.rank.compareTo(a.severity.rank);
      return bySeverity != 0 ? bySeverity : b.amount.compareTo(a.amount);
    });
    return sorted;
  }

  /// The same audit with [totalExpenses] replaced by what the line items
  /// actually sum to.
  ///
  /// For callers that would rather show an internally consistent figure than
  /// the model's declared one. Never applied silently — the caller is expected
  /// to tell the user the total was corrected, because a drift big enough to
  /// matter usually means a transaction was missed during extraction, and that
  /// is information the user needs.
  AuditReport withRecomputedTotals() => AuditReport(
        currency: currency,
        periodStart: periodStart,
        periodEnd: periodEnd,
        totalNetIncome: totalNetIncome,
        totalExpenses: needsTotal + wantsTotal,
        needs: needs,
        wants: wants,
        wastefulLeaks: wastefulLeaks,
        harshAuditSummary: harshAuditSummary,
        actionPlan: actionPlan,
      );

  static AuditReport fromJson(Map<String, dynamic> json) => AuditReport(
        currency: json['currency'] as String? ?? 'USD',
        periodStart: json['period_start'] as String? ?? '',
        periodEnd: json['period_end'] as String? ?? '',
        totalNetIncome: Money.tryParse(json['total_net_income']) ?? Money.zero,
        totalExpenses: Money.tryParse(json['total_expenses']) ?? Money.zero,
        needs: _items(json['needs'], SpendItem.fromJson),
        wants: _items(json['wants'], SpendItem.fromJson),
        wastefulLeaks: _items(json['wasteful_leaks'], WastefulLeak.fromJson),
        harshAuditSummary: json['harsh_audit_summary'] as String? ?? '',
        actionPlan: (json['action_plan'] as List?)
                ?.whereType<String>()
                .toList(growable: false) ??
            const [],
      );

  Map<String, dynamic> toJson() => {
        'currency': currency,
        'period_start': periodStart,
        'period_end': periodEnd,
        'total_net_income': totalNetIncome.toJson(),
        'total_expenses': totalExpenses.toJson(),
        'needs': needs.map((e) => e.toJson()).toList(),
        'wants': wants.map((e) => e.toJson()).toList(),
        'wasteful_leaks': wastefulLeaks.map((e) => e.toJson()).toList(),
        'harsh_audit_summary': harshAuditSummary,
        'action_plan': actionPlan,
      };

  static List<T> _items<T>(
    Object? raw,
    T Function(Map<String, dynamic>) parse,
  ) =>
      (raw as List?)
          ?.whereType<Map<Object?, Object?>>()
          .map((e) => parse(e.cast<String, dynamic>()))
          .toList(growable: false) ??
      const [];
}
