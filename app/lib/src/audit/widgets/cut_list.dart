import 'package:audit_core/audit_core.dart';
import 'package:flutter/material.dart';

import '../../format.dart';
import '../../theme.dart';

/// Severity, rendered so that it survives being printed in greyscale.
///
/// Four levels over three reserved status hues: the top two share `critical`
/// and are told apart by fill rather than by a fifth colour nobody could
/// distinguish from the fourth.
class SeverityChip extends StatelessWidget {
  const SeverityChip({required this.severity, super.key});

  final LeakSeverity severity;

  Color get _color => switch (severity) {
        LeakSeverity.minor => StatusColors.warning,
        LeakSeverity.moderate => StatusColors.serious,
        LeakSeverity.severe => StatusColors.critical,
        LeakSeverity.critical => StatusColors.critical,
      };

  bool get _filled => severity == LeakSeverity.critical;

  IconData get _icon => switch (severity) {
        LeakSeverity.minor => Icons.info_outline,
        LeakSeverity.moderate => Icons.warning_amber_rounded,
        LeakSeverity.severe => Icons.priority_high_rounded,
        LeakSeverity.critical => Icons.local_fire_department_rounded,
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onChip = _filled ? Colors.white : _color;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: _filled ? _color : _color.withValues(alpha: 0.12),
        border: Border.all(color: _color),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(_icon, size: 13, color: onChip),
          const SizedBox(width: 4),
          Text(
            severity.wire,
            style: theme.textTheme.labelSmall?.copyWith(
              color: onChip,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// One leak, swipeable away once the user has actually cancelled it.
///
/// Dismissing is a commitment, not a delete: the amount moves into the
/// running "cut so far" total on the Reality Check card, and undo is offered
/// for as long as the snackbar is up.
class LeakCard extends StatelessWidget {
  const LeakCard({
    required this.leak,
    required this.currency,
    required this.onDismissed,
    required this.unverified,
    super.key,
  });

  final WastefulLeak leak;
  final String currency;
  final VoidCallback onDismissed;

  /// True when this leak's cited transaction could not be found in the
  /// statement. Marked rather than hidden.
  final bool unverified;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Dismissible(
      key: ValueKey('leak:${leak.label}'),
      direction: DismissDirection.horizontal,
      background: _swipeBackground(context, Alignment.centerLeft),
      secondaryBackground: _swipeBackground(context, Alignment.centerRight),
      onDismissed: (_) => onDismissed(),
      child: Card(
        margin: const EdgeInsets.only(bottom: 10),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      leak.label,
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  SeverityChip(severity: leak.severity),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                '${formatMoney(leak.amount, currency)} this period · '
                '${formatMoney(leak.annualCost, currency)} a year',
                style: ColdwaterTheme.money(theme.textTheme.bodySmall)
                    .copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 10),
              Text(leak.verdict, style: theme.textTheme.bodyMedium),
              if (unverified) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    const Icon(Icons.help_outline,
                        size: 15, color: StatusColors.warning),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Could not find this transaction in the statement.',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: StatusColors.warning),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _swipeBackground(BuildContext context, Alignment alignment) =>
      Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 24),
        alignment: alignment,
        decoration: BoxDecoration(
          color: StatusColors.good.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(16),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_rounded, color: StatusColors.good),
            SizedBox(width: 8),
            Text(
              'Cut it',
              style: TextStyle(
                color: StatusColors.good,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      );
}

/// The action plan, as a list the user can work down.
class ActionPlanCard extends StatelessWidget {
  const ActionPlanCard({required this.steps, super.key});

  final List<String> steps;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (steps.isEmpty) return const SizedBox.shrink();

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Do this', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            for (var i = 0; i < steps.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 22,
                      height: 22,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primaryContainer,
                        shape: BoxShape.circle,
                      ),
                      child: Text(
                        '${i + 1}',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onPrimaryContainer,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        steps[i],
                        style: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
