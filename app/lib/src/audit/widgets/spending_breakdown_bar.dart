import 'package:audit_core/audit_core.dart';
import 'package:flutter/material.dart';

import '../../format.dart';
import '../../theme.dart';

/// Needs versus wants, with waste carved out and called by name.
///
/// A horizontal stacked bar rather than a donut. Part-to-whole is what a
/// stacked bar is for, and a two-slice donut is the form this data would be
/// worst served by — the eye compares lengths along a shared baseline far
/// better than it compares angles.
///
/// The secondary encoding here is load-bearing, not styling. The palette
/// validates with two advisories — the wants colour is under 3:1 on the light
/// surface, and wants and leaks separate by only 7.2 deltaE under deuteranopia
/// on the dark surface — and both are only permissible because identity is
/// also carried by the direct labels, the 2px gaps between segments and the
/// icon beside the leak entry. Removing any of them makes the chart
/// unreadable for some people.
class SpendingBreakdownBar extends StatelessWidget {
  const SpendingBreakdownBar({
    required this.report,
    super.key,
  });

  final AuditReport report;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = ChartColors.of(theme.brightness);
    final breakdown = SpendingBreakdown.of(report);

    if (breakdown.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Text(
            'No spending was found in this statement.',
            style: theme.textTheme.bodyMedium,
          ),
        ),
      );
    }

    final segments = [
      _Segment('Needs', breakdown.needs, colors.needs, null),
      _Segment('Wants', breakdown.wants, colors.wants, null),
      _Segment('Wasteful', breakdown.leaks, colors.leaks, Icons.warning_amber_rounded),
    ].where((s) => s.amount.minorUnits > 0).toList();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Where it went', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              formatMoney(breakdown.total, report.currency),
              style: ColdwaterTheme.money(theme.textTheme.headlineSmall),
            ),
            const SizedBox(height: 16),

            // The bar itself carries no text; every figure is in the legend
            // below, which is what makes it readable without colour.
            Semantics(
              label: _semanticSummary(breakdown, segments),
              excludeSemantics: true,
              child: SizedBox(
                height: 28,
                width: double.infinity,
                child: CustomPaint(
                  painter: _StackedBarPainter(
                    segments: segments,
                    total: breakdown.total,
                    gap: colors.surface,
                  ),
                ),
              ),
            ),

            const SizedBox(height: 16),
            for (final segment in segments)
              _LegendRow(
                segment: segment,
                fraction: breakdown.fractionOf(segment.amount),
                currency: report.currency,
              ),

            if (breakdown.unattributedLeaks.minorUnits > 0) ...[
              const SizedBox(height: 12),
              Text(
                '${formatMoney(breakdown.unattributedLeaks, report.currency)} '
                'of flagged waste matched no line item and is not shown in '
                'the bar.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _semanticSummary(
    SpendingBreakdown breakdown,
    List<_Segment> segments,
  ) =>
      'Spending breakdown. ${segments.map((s) => '${s.label}: '
          '${formatPercent(breakdown.fractionOf(s.amount))}').join(', ')}.';
}

class _Segment {
  const _Segment(this.label, this.amount, this.color, this.icon);

  final String label;
  final Money amount;
  final Color color;

  /// Status colours never carry meaning alone, so the waste segment brings an
  /// icon into its legend entry.
  final IconData? icon;
}

/// Direct labels: the figure sits beside its swatch rather than only in a
/// tooltip, which a touch device has no room for anyway.
class _LegendRow extends StatelessWidget {
  const _LegendRow({
    required this.segment,
    required this.fraction,
    required this.currency,
  });

  final _Segment segment;
  final double fraction;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              color: segment.color,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          const SizedBox(width: 10),
          if (segment.icon != null) ...[
            Icon(segment.icon, size: 16, color: segment.color),
            const SizedBox(width: 4),
          ],
          Expanded(
            child: Text(segment.label, style: theme.textTheme.bodyMedium),
          ),
          Text(
            formatPercent(fraction),
            style: ColdwaterTheme.money(theme.textTheme.bodyMedium).copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 12),
          Text(
            formatMoney(segment.amount, currency),
            style: ColdwaterTheme.money(theme.textTheme.bodyMedium),
          ),
        ],
      ),
    );
  }
}

class _StackedBarPainter extends CustomPainter {
  const _StackedBarPainter({
    required this.segments,
    required this.total,
    required this.gap,
  });

  final List<_Segment> segments;
  final Money total;

  /// Segments are separated by a 2px strip of the surface colour rather than
  /// being butted together, so adjacent fills never blend into one another.
  final Color gap;

  static const double _gapWidth = 2;
  static const double _radius = 4;

  @override
  void paint(Canvas canvas, Size size) {
    if (total.minorUnits <= 0 || segments.isEmpty) return;

    final gaps = (segments.length - 1) * _gapWidth;
    final usable = (size.width - gaps).clamp(0.0, size.width);

    var x = 0.0;
    for (var i = 0; i < segments.length; i++) {
      final fraction = segments[i].amount.fractionOf(total);
      final width = usable * fraction;
      if (width <= 0) continue;

      // Only the outer ends are rounded; interior edges stay square so the
      // segments read as one continuous total rather than separate bars.
      final isFirst = i == 0;
      final isLast = i == segments.length - 1;
      final rect = RRect.fromRectAndCorners(
        Rect.fromLTWH(x, 0, width, size.height),
        topLeft: Radius.circular(isFirst ? _radius : 0),
        bottomLeft: Radius.circular(isFirst ? _radius : 0),
        topRight: Radius.circular(isLast ? _radius : 0),
        bottomRight: Radius.circular(isLast ? _radius : 0),
      );

      canvas.drawRRect(rect, Paint()..color = segments[i].color);
      x += width + _gapWidth;
    }
  }

  @override
  bool shouldRepaint(_StackedBarPainter old) =>
      old.segments.length != segments.length ||
      old.total != total ||
      old.gap != gap;
}
