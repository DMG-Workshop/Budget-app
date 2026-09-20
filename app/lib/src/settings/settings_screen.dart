import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:transcript_core/transcript_core.dart';

import '../audit/audit_controller.dart';
import 'local_endpoint.dart';
import 'provider_config.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _modelController = TextEditingController();
  final _baseUrlController = TextEditingController();
  final _keyController = TextEditingController();

  ConnectionResult? _testResult;
  bool _testing = false;
  bool _loaded = false;

  @override
  void dispose() {
    _modelController.dispose();
    _baseUrlController.dispose();
    _keyController.dispose();
    super.dispose();
  }

  Future<void> _hydrate(ProviderConfig config) async {
    if (_loaded) return;
    _loaded = true;
    _modelController.text = config.model;
    _baseUrlController.text = config.baseUrl ?? '';
    final key = await ref.read(configStoreProvider).readKey(config.kind);
    if (mounted) _keyController.text = key ?? '';
  }

  Future<void> _apply(ProviderConfig config) async {
    await ref.read(configProvider.notifier).save(config);
    if (config.kind.needsApiKey) {
      await ref
          .read(configProvider.notifier)
          .setKey(config.kind, _keyController.text.trim());
    }
    setState(() => _testResult = null);
  }

  Future<void> _test(ProviderConfig config) async {
    setState(() {
      _testing = true;
      _testResult = null;
    });

    await _apply(config);
    final provider = ProviderFactory.build(
      config: config,
      transport: ref.read(transportProvider),
      apiKey: _keyController.text.trim(),
    );

    final result = await provider.test();
    if (mounted) {
      setState(() {
        _testing = false;
        _testResult = result;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final async = ref.watch(configProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (config) {
          _hydrate(config);
          final isLocal = config.kind == ProviderKind.local;

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text('Where the audit runs',
                  style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),

              RadioGroup<ProviderKind>(
                groupValue: config.kind,
                onChanged: (next) async {
                  if (next == null) return;
                  final updated = config.copyWith(kind: next);
                  _modelController.text = updated.model;
                  _keyController.text =
                      await ref.read(configStoreProvider).readKey(next) ?? '';
                  await _apply(updated);
                },
                child: Column(
                  children: [
                    for (final kind in ProviderKind.values)
                      RadioListTile<ProviderKind>(
                        value: kind,
                        title: Text(kind.label),
                        subtitle: Text(kind.blurb),
                      ),
                  ],
                ),
              ),

              const Divider(height: 32),

              TextField(
                controller: _modelController,
                decoration: const InputDecoration(
                  labelText: 'Model',
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (value) =>
                    _apply(config.copyWith(model: value.trim())),
              ),
              const SizedBox(height: 16),

              if (config.kind.needsApiKey)
                TextField(
                  controller: _keyController,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: '${config.kind.label} API key',
                    helperText: 'Stored in this device\'s keystore, never in '
                        'the audit and never in a log.',
                    border: const OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _apply(config),
                ),

              if (isLocal) ...[
                SegmentedButton<LocalFlavor>(
                  segments: [
                    for (final flavor in LocalFlavor.values)
                      ButtonSegment(value: flavor, label: Text(flavor.label)),
                  ],
                  selected: {config.flavor},
                  onSelectionChanged: (next) =>
                      _apply(config.copyWith(flavor: next.first)),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _baseUrlController,
                  autocorrect: false,
                  keyboardType: TextInputType.url,
                  decoration: InputDecoration(
                    labelText: 'Server address',
                    hintText: '192.168.1.10:${config.flavor.defaultPort}',
                    errorText: _baseUrlController.text.isEmpty
                        ? null
                        : LocalEndpoint.explainProblem(
                            _baseUrlController.text,
                            flavor: config.flavor,
                          ),
                    border: const OutlineInputBorder(),
                  ),
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (value) =>
                      _apply(config.copyWith(baseUrl: value.trim())),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final preset in LocalEndpoint.presets)
                      ActionChip(
                        label: Text(preset.label),
                        onPressed: () {
                          _baseUrlController.text = preset.template;
                          _apply(config.copyWith(
                            baseUrl: preset.template,
                            flavor: preset.flavor ?? config.flavor,
                          ));
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  'A model server usually binds to its own loopback only. It '
                  'has to listen on the network before a phone can reach it.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],

              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: _testing
                    ? null
                    : () => _test(config.copyWith(
                          model: _modelController.text.trim(),
                          baseUrl: _baseUrlController.text.trim(),
                        )),
                icon: _testing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.wifi_tethering_rounded),
                label: const Text('Test connection'),
              ),

              if (_testResult != null) ...[
                const SizedBox(height: 16),
                _ConnectionResultCard(result: _testResult!),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// transcript_core's connection tester already phrases failures as remedies,
/// so this only has to render what it returns.
class _ConnectionResultCard extends StatelessWidget {
  const _ConnectionResultCard({required this.result});

  final ConnectionResult result;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ok = result.ok;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  ok ? Icons.check_circle_outline : Icons.error_outline,
                  color: ok ? Colors.green : theme.colorScheme.error,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(result.summary,
                      style: theme.textTheme.titleSmall),
                ),
              ],
            ),
            if (result.detail != null) ...[
              const SizedBox(height: 8),
              Text(result.detail!, style: theme.textTheme.bodySmall),
            ],
            if (result.remedy != null) ...[
              const SizedBox(height: 8),
              Text(
                result.remedy!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
