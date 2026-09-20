import 'package:audit_core/audit_core.dart';
import 'package:flutter/material.dart';

import '../../format.dart';
import '../../theme.dart';
import '../audit_controller.dart';

/// The top of the screen: the number, and the sentence that explains it.
///
/// Colour alone never says whether this is good or bad — "Surplus" and
/// "Deficit" are printed beside the figure, and an icon sits with them. A
/// red number means nothing to a reader who cannot see red.
class RealityCheckCard extends StatelessWidget {
  const RealityCheckCard({required this.state, super.key});

  final AuditReady state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final report = state.report;
    final deficit = report.isDeficit;
    final verdictColor = deficit ? StatusColors.critical : StatusColors.good;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  deficit
                      ? Icons.trending_down_rounded
                      : Icons.trending_up_rounded,
                  color: verdictColor,
                  size: 20,
                ),
                const SizedBox(width: 6),
                Text(
                  deficit ? 'Deficit' : 'Surplus',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: verdictColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                Text(
                  formatPeriod(report.periodStart, report.periodEnd),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // The hero figure.
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                formatMoney(report.netCashflow, report.currency, signed: true),
                style: ColdwaterTheme.money(theme.textTheme.displaySmall)
                    .copyWith(
                  color: verdictColor,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${formatMoney(report.totalNetIncome, report.currency)} in · '
              '${formatMoney(report.totalExpenses, report.currency)} out',
              style: ColdwaterTheme.money(theme.textTheme.bodyMedium).copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),

            const SizedBox(height: 16),
            Text(
              report.harshAuditSummary,
              style: theme.textTheme.bodyLarge?.copyWith(height: 1.45),
            ),

            if (state.committedAnnualSaving.minorUnits > 0) ...[
              const SizedBox(height: 16),
              Row(
                children: [
                  const Icon(Icons.check_circle_outline,
                      size: 18, color: StatusColors.good),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Cut so far: '
                      '${formatMoney(state.committedAnnualSaving, report.currency)} '
                      'a year.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: StatusColors.good,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Says out loud when the audit should not be fully trusted.
///
/// Shown whenever the arithmetic did not reconcile or a cited transaction
/// could not be found in the statement. The alternative — presenting a number
/// the app already knows is suspect as though it were fact — is the one thing
/// a tool like this must never do.
class TrustBanner extends StatelessWidget {
  const TrustBanner({required this.outcome, super.key});

  final AuditOutcome outcome;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final problems = <String>[
      for (final finding in outcome.arithmetic.findings)
        if (finding.severity != FindingSeverity.info) finding.message,
      if (outcome.unverifiedEvidence.isNotEmpty)
        'These figures cite a transaction that could not be found in the '
            'statement: ${outcome.unverifiedEvidence.join(', ')}.',
    ];

    if (problems.isEmpty) return const SizedBox.shrink();

    final isError = outcome.arithmetic.hasErrors;
    final color = isError ? StatusColors.critical : StatusColors.warning;

    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: color),
      ),
      child: ExpansionTile(
        shape: const Border(),
        collapsedShape: const Border(),
        leading: Icon(
          isError ? Icons.error_outline : Icons.warning_amber_rounded,
          color: color,
        ),
        title: Text(
          isError
              ? "The model's arithmetic does not add up"
              : 'Some of this audit could not be verified',
          style: theme.textTheme.titleSmall?.copyWith(color: color),
        ),
        subtitle: Text(
          '${problems.length} issue${problems.length == 1 ? '' : 's'} found '
          'by checks that ran on this device',
          style: theme.textTheme.bodySmall,
        ),
        children: [
          for (final problem in problems)
            ListTile(
              dense: true,
              leading: const Icon(Icons.circle, size: 7),
              title: Text(problem, style: theme.textTheme.bodySmall),
            ),
        ],
      ),
    );
  }
}
