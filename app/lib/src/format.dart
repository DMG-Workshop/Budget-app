import 'package:audit_core/audit_core.dart';
import 'package:intl/intl.dart';

/// Formats money for display.
///
/// Falls back to the bare code when a statement names a currency intl does
/// not know. Printing "XYZ 1,234.56" is honest; printing a dollar sign on a
/// statement that was not in dollars is not.
String formatMoney(Money amount, String currencyCode, {bool signed = false}) {
  final value = amount.asDouble;
  String body;
  try {
    body = NumberFormat.simpleCurrency(name: currencyCode).format(value.abs());
  } on Object {
    body = '$currencyCode ${NumberFormat('#,##0.00').format(value.abs())}';
  }

  if (amount.isNegative) return '-$body';
  return signed ? '+$body' : body;
}

/// A whole-number percentage, for legends and severity lines.
String formatPercent(double fraction) =>
    '${(fraction * 100).round()}%';

/// "1 Mar – 31 Mar 2026", or the raw strings when they are not parseable.
String formatPeriod(String start, String end) {
  final from = DateTime.tryParse(start);
  final to = DateTime.tryParse(end);
  if (from == null || to == null) return '$start – $end';

  final sameYear = from.year == to.year;
  final dayMonth = DateFormat('d MMM');
  final full = DateFormat('d MMM yyyy');
  return sameYear
      ? '${dayMonth.format(from)} – ${full.format(to)}'
      : '${full.format(from)} – ${full.format(to)}';
}
