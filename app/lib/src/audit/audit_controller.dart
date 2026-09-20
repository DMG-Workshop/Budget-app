import 'package:audit_core/audit_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:transcript_core/transcript_core.dart';

import '../ingest/statement_ingest.dart';
import '../net/dio_transport.dart';
import '../settings/provider_config.dart';

final transportProvider = Provider<HttpTransport>((ref) => DioHttpTransport());

final configStoreProvider =
    Provider<ProviderConfigStore>((ref) => ProviderConfigStore());

/// The chosen backend, loaded from disk once and written back on every change.
class ConfigNotifier extends AsyncNotifier<ProviderConfig> {
  @override
  Future<ProviderConfig> build() => ref.read(configStoreProvider).load();

  Future<void> save(ProviderConfig config) async {
    state = AsyncData(config);
    await ref.read(configStoreProvider).save(config);
  }

  Future<void> setKey(ProviderKind kind, String key) =>
      ref.read(configStoreProvider).writeKey(kind, key);
}

final configProvider =
    AsyncNotifierProvider<ConfigNotifier, ProviderConfig>(ConfigNotifier.new);

/// Where an audit is up to.
sealed class AuditState {
  const AuditState();
}

final class AuditIdle extends AuditState {
  const AuditIdle();
}

final class AuditWorking extends AuditState {
  const AuditWorking(this.step);

  /// Shown under the spinner. Reading a 40-page PDF and waiting on a cold
  /// local model are both slow, and they are slow for different reasons the
  /// user is entitled to see.
  final String step;
}

final class AuditFailed extends AuditState {
  const AuditFailed(this.message, {this.detail});

  final String message;

  /// Schema violations or the model's actual reply, for the expandable
  /// section. Never a key.
  final String? detail;
}

final class AuditReady extends AuditState {
  const AuditReady(this.outcome, {this.dismissed = const {}});

  final AuditOutcome outcome;

  /// Labels the user has swiped away, kept here rather than in the report so
  /// that undo is possible and the underlying audit stays intact.
  final Set<String> dismissed;

  AuditReport get report => outcome.report;

  List<WastefulLeak> get remainingLeaks => report.leaksBySeverity
      .where((leak) => !dismissed.contains(leak.label))
      .toList(growable: false);

  /// What the user has committed to cutting, annualised. The number that
  /// makes swiping a card feel like progress rather than hiding a problem.
  Money get committedAnnualSaving => Money.sum(
        report.wastefulLeaks
            .where((leak) => dismissed.contains(leak.label))
            .map((leak) => leak.annualCost),
      );

  AuditReady withDismissed(Set<String> next) =>
      AuditReady(outcome, dismissed: next);
}

class AuditController extends Notifier<AuditState> {
  @override
  AuditState build() => const AuditIdle();

  /// Picks a statement and audits it.
  Future<void> pickAndAudit() async {
    try {
      state = const AuditWorking('Reading the statement…');

      final statement = await StatementIngest.pick();
      if (statement == null) {
        // Cancelling the picker is not a failure.
        state = const AuditIdle();
        return;
      }

      await auditStatement(statement);
    } on StatementTooLargeException catch (e) {
      state = AuditFailed(e.message);
    }
  }

  /// Audits a statement already in hand. Separated from picking so widget
  /// tests can drive it without a platform file picker.
  Future<void> auditStatement(StatementDocument statement) async {
    final config = await ref.read(configProvider.future);
    final key = await ref.read(configStoreProvider).readKey(config.kind);

    if (config.kind.needsApiKey && (key == null || key.isEmpty)) {
      state = AuditFailed(
        'No API key for ${config.kind.label}.',
        detail: 'Add one in settings, or switch to a local model, which needs '
            'no key at all.',
      );
      return;
    }

    final provider = ProviderFactory.build(
      config: config,
      transport: ref.read(transportProvider),
      apiKey: key,
    );

    state = AuditWorking(
      provider.isLocalEndpoint
          ? 'Auditing on your own machine. A cold model can take a minute.'
          : 'Auditing with ${provider.displayName}…',
    );

    try {
      final outcome = await AuditPipeline(provider: provider).run(
        statement: statement,
        referenceDate: _today(),
      );
      state = AuditReady(outcome);
    } on AuditException catch (e) {
      state = AuditFailed(
        e.message,
        detail: [
          if (e.violations.isNotEmpty) e.violations.join('\n'),
          if (e.lastResponse != null) 'The model replied: ${e.lastResponse}',
        ].join('\n\n'),
      );
    } on ProviderException catch (e) {
      state = AuditFailed('${e.provider} returned ${e.statusCode}.',
          detail: e.message);
    } on TransportException catch (e) {
      state = AuditFailed(_explain(e), detail: e.message);
    }
  }

  void dismiss(String label) {
    final current = state;
    if (current is! AuditReady) return;
    state = current.withDismissed({...current.dismissed, label});
  }

  void restore(String label) {
    final current = state;
    if (current is! AuditReady) return;
    state = current.withDismissed({...current.dismissed}..remove(label));
  }

  void reset() => state = const AuditIdle();

  /// Turns a transport failure into the remedy rather than the symptom.
  static String _explain(TransportException e) => switch (e.kind) {
        TransportFailure.refused =>
          'Nothing answered at that address. Check the model server is '
              'running and listening on the network rather than only on its '
              'own loopback.',
        TransportFailure.unresolved =>
          'That hostname could not be found on this network.',
        TransportFailure.timeout =>
          'The request timed out. A local model loading for the first time '
              'can take a while; try again once it is warm.',
        TransportFailure.tls =>
          'The secure connection failed. A self-signed certificate needs to '
              'be trusted on this device first.',
        TransportFailure.other =>
          'The request could not be sent. If the address is plain http on '
              'your own network, this platform may be blocking it.',
      };

  static String _today() {
    final now = DateTime.now();
    final month = now.month.toString().padLeft(2, '0');
    final day = now.day.toString().padLeft(2, '0');
    return '${now.year}-$month-$day';
  }
}

final auditControllerProvider =
    NotifierProvider<AuditController, AuditState>(AuditController.new);
