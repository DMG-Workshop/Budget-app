import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../settings/settings_screen.dart';
import 'audit_controller.dart';
import 'widgets/cut_list.dart';
import 'widgets/reality_check_card.dart';
import 'widgets/spending_breakdown_bar.dart';

class AuditScreen extends ConsumerWidget {
  const AuditScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(auditControllerProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Coldwater'),
        actions: [
          if (state is AuditReady)
            IconButton(
              tooltip: 'Audit another statement',
              icon: const Icon(Icons.refresh_rounded),
              onPressed: () =>
                  ref.read(auditControllerProvider.notifier).pickAndAudit(),
            ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const SettingsScreen(),
              ),
            ),
          ),
        ],
      ),
      body: switch (state) {
        AuditIdle() => const _Empty(),
        AuditWorking(:final step) => _Working(step: step),
        AuditFailed(:final message, :final detail) =>
          _Failed(message: message, detail: detail),
        AuditReady() => _Results(state: state),
      },
    );
  }
}

class _Empty extends ConsumerWidget {
  const _Empty();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.ac_unit_rounded,
                size: 56,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(height: 20),
              Text(
                'Hand over a bank statement.',
                style: theme.textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 10),
              Text(
                'It gets read, added up, and described back to you without '
                'any encouragement.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 28),
              FilledButton.icon(
                onPressed: () =>
                    ref.read(auditControllerProvider.notifier).pickAndAudit(),
                icon: const Icon(Icons.upload_file_rounded),
                label: const Text('Choose a PDF statement'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Working extends StatelessWidget {
  const _Working({required this.step});

  final String step;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 24),
              Text(
                step,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          ),
        ),
      );
}

class _Failed extends ConsumerWidget {
  const _Failed({required this.message, this.detail});

  final String message;
  final String? detail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline,
                  size: 44, color: theme.colorScheme.error),
              const SizedBox(height: 16),
              Text(
                message,
                style: theme.textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              if (detail != null && detail!.trim().isNotEmpty) ...[
                const SizedBox(height: 16),
                Card(
                  child: ExpansionTile(
                    shape: const Border(),
                    collapsedShape: const Border(),
                    title: const Text('What went wrong'),
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                        child: SelectableText(
                          detail!,
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 20),
              Wrap(
                spacing: 12,
                alignment: WrapAlignment.center,
                children: [
                  OutlinedButton(
                    onPressed: () =>
                        ref.read(auditControllerProvider.notifier).reset(),
                    child: const Text('Start over'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const SettingsScreen(),
                      ),
                    ),
                    child: const Text('Check settings'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Results extends ConsumerWidget {
  const _Results({required this.state});

  final AuditReady state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final report = state.report;
    final leaks = state.remainingLeaks;
    final unverified = state.outcome.unverifiedEvidence.toSet();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        RealityCheckCard(state: state),
        const SizedBox(height: 12),
        TrustBanner(outcome: state.outcome),
        const SizedBox(height: 12),
        SpendingBreakdownBar(report: report),
        const SizedBox(height: 20),

        Row(
          children: [
            Text('The cut list', style: theme.textTheme.titleLarge),
            const Spacer(),
            if (leaks.isNotEmpty)
              Text(
                'Swipe to commit',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),

        if (leaks.isEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Text(
                state.dismissed.isEmpty
                    ? 'No waste was flagged in this statement. That is rarer '
                        'than you think.'
                    : 'That is the whole list. Now actually cancel them.',
                style: theme.textTheme.bodyMedium,
              ),
            ),
          )
        else
          for (final leak in leaks)
            LeakCard(
              leak: leak,
              currency: report.currency,
              unverified: unverified.contains(leak.label),
              onDismissed: () {
                ref.read(auditControllerProvider.notifier).dismiss(leak.label);
                ScaffoldMessenger.of(context)
                  ..hideCurrentSnackBar()
                  ..showSnackBar(
                    SnackBar(
                      content: Text('${leak.label} cut.'),
                      action: SnackBarAction(
                        label: 'Undo',
                        onPressed: () => ref
                            .read(auditControllerProvider.notifier)
                            .restore(leak.label),
                      ),
                    ),
                  );
              },
            ),

        const SizedBox(height: 20),
        ActionPlanCard(steps: report.actionPlan),

        const SizedBox(height: 16),
        Text(
          state.outcome.routeReason,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
