/// An exact monetary amount, held in minor units (cents, pence).
///
/// Bank statement arithmetic is the whole point of this app, so it never runs on
/// doubles. A model returns `1234.56`; binary floating point cannot hold that
/// exactly, and summing 200 such values drifts far enough to turn a small surplus
/// into a small deficit — which is precisely the number the user is being shown in
/// large red text.
///
/// Amounts are signed: income is positive, spending is positive within its own
/// category totals, and only [AuditReport.netCashflow] can be negative.
class Money implements Comparable<Money> {
  const Money(this.minorUnits);

  /// Cents, pence, øre — whatever the currency's minor unit is.
  final int minorUnits;

  static const Money zero = Money(0);

  /// Parses whatever the model actually emitted.
  ///
  /// The schema says `number`, and a provider in strict structured-output mode
  /// honours that. Local models routinely do not: they return `"$1,234.56"`, or
  /// `"(45.00)"` for a credit because that is how the statement printed it. The
  /// schema validator rejects those before this is reached, but the repair loop is
  /// bounded and degrading to a wrong number is worse than degrading to null.
  static Money? tryParse(Object? value) {
    if (value == null) return null;
    if (value is int) return Money(value * 100);
    if (value is double) return fromDouble(value);
    if (value is! String) return null;

    var text = value.trim();
    if (text.isEmpty) return null;

    // Accounting parentheses mean negative: (45.00) is -45.00.
    var negative = false;
    if (text.startsWith('(') && text.endsWith(')')) {
      negative = true;
      text = text.substring(1, text.length - 1).trim();
    }
    if (text.startsWith('-')) {
      negative = !negative;
      text = text.substring(1).trim();
    }

    // Strip everything that is not a digit or a separator: currency symbols,
    // ISO codes, spaces, non-breaking spaces.
    text = text.replaceAll(RegExp(r'[^0-9.,]'), '');
    if (text.isEmpty) return null;

    // Work out which separator is the decimal point. A statement may be
    // British (1,234.56), European (1.234,56) or neither, and reading the
    // second as the first turns twelve hundred pounds into one pound twenty —
    // the kind of error that is invisible on screen and wrong by a factor of a
    // thousand.
    final lastDot = text.lastIndexOf('.');
    final lastComma = text.lastIndexOf(',');

    if (lastDot >= 0 && lastComma >= 0) {
      // Both present: whichever comes last is the decimal separator, and the
      // other is grouping.
      final grouping = lastDot > lastComma ? ',' : '.';
      final decimal = lastDot > lastComma ? '.' : ',';
      text = text.replaceAll(grouping, '');
      final at = text.lastIndexOf(decimal);
      text = '${text.substring(0, at)}.${text.substring(at + 1)}';
    } else if (lastComma >= 0) {
      // Only commas. Two trailing digits means it is a decimal comma; anything
      // else is thousands grouping.
      final trailing = text.length - lastComma - 1;
      final singleComma = text.indexOf(',') == lastComma;
      text = singleComma && trailing == 2
          ? '${text.substring(0, lastComma)}.${text.substring(lastComma + 1)}'
          : text.replaceAll(',', '');
    }
    // Only dots, or no separator at all: already in a form double can read.
    // "1.234" is genuinely ambiguous and is read as one point two three four,
    // which is what a statement printed in English means by it.

    final parsed = double.tryParse(text);
    if (parsed == null) return null;
    final money = fromDouble(parsed);
    return negative ? -money : money;
  }

  /// Rounds half away from zero, matching how a statement rounds.
  static Money fromDouble(double value) => Money((value * 100).round());

  double get asDouble => minorUnits / 100;

  bool get isNegative => minorUnits < 0;
  bool get isZero => minorUnits == 0;

  Money get abs => Money(minorUnits.abs());

  Money operator +(Money other) => Money(minorUnits + other.minorUnits);
  Money operator -(Money other) => Money(minorUnits - other.minorUnits);
  Money operator -() => Money(-minorUnits);
  Money operator *(int factor) => Money(minorUnits * factor);

  bool operator >(Money other) => minorUnits > other.minorUnits;
  bool operator <(Money other) => minorUnits < other.minorUnits;
  bool operator >=(Money other) => minorUnits >= other.minorUnits;
  bool operator <=(Money other) => minorUnits <= other.minorUnits;

  static Money sum(Iterable<Money> values) =>
      values.fold(zero, (a, b) => a + b);

  /// Share of [total], 0..1. Zero when [total] is zero — a donut chart asking for
  /// the fraction of nothing should render an empty ring, not a NaN sweep.
  double fractionOf(Money total) =>
      total.minorUnits == 0 ? 0 : minorUnits / total.minorUnits;

  /// The JSON form is the decimal the schema declares, not the minor units.
  double toJson() => asDouble;

  @override
  int compareTo(Money other) => minorUnits.compareTo(other.minorUnits);

  @override
  bool operator ==(Object other) =>
      other is Money && other.minorUnits == minorUnits;

  @override
  int get hashCode => minorUnits.hashCode;

  @override
  String toString() {
    final sign = minorUnits < 0 ? '-' : '';
    final units = minorUnits.abs();
    final major = units ~/ 100;
    final minor = (units % 100).toString().padLeft(2, '0');
    return '$sign$major.$minor';
  }
}
