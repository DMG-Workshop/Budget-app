import 'package:audit_core/audit_core.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:transcript_core/transcript_core.dart';

import 'local_endpoint.dart';

/// Which backend the audit runs on.
enum ProviderKind {
  anthropic('Claude', 'Reads the PDF directly. Best on table-heavy statements.'),
  gemini('Gemini', 'Reads the PDF directly. Cheap and fast.'),
  openai('OpenAI', 'Text only — the statement is extracted on this device first.'),
  local('Ollama / LM Studio', 'Runs on your own machine. Nothing leaves your network.');

  const ProviderKind(this.label, this.blurb);

  final String label;
  final String blurb;

  bool get needsApiKey => this != ProviderKind.local;

  /// Whether this backend can be handed the PDF itself.
  bool get readsDocuments =>
      this == ProviderKind.anthropic || this == ProviderKind.gemini;

  String get defaultModel => switch (this) {
        ProviderKind.anthropic => AnthropicStructuringProvider.defaultModel,
        ProviderKind.gemini => GeminiStructuringProvider.defaultModel,
        ProviderKind.openai => 'gpt-4o',
        ProviderKind.local => 'llama3.1:8b',
      };
}

/// Everything about the chosen backend except the key.
class ProviderConfig {
  const ProviderConfig({
    required this.kind,
    required this.model,
    this.baseUrl,
    this.flavor = LocalFlavor.ollama,
  });

  const ProviderConfig.defaults()
      : kind = ProviderKind.anthropic,
        model = AnthropicStructuringProvider.defaultModel,
        baseUrl = null,
        flavor = LocalFlavor.ollama;

  final ProviderKind kind;
  final String model;

  /// Set for local servers, and for anyone pointing a cloud provider at a
  /// proxy of their own.
  final String? baseUrl;

  final LocalFlavor flavor;

  ProviderConfig copyWith({
    ProviderKind? kind,
    String? model,
    String? baseUrl,
    LocalFlavor? flavor,
  }) =>
      ProviderConfig(
        kind: kind ?? this.kind,
        // Switching backend switches to that backend's default model, unless
        // a model is named in the same change. Carrying "claude-opus-5" over
        // to Ollama would produce a confusing 404 from the local server.
        model: model ?? (kind == null || kind == this.kind ? this.model : kind.defaultModel),
        baseUrl: baseUrl ?? this.baseUrl,
        flavor: flavor ?? this.flavor,
      );

  Uri? get resolvedBaseUrl => baseUrl == null
      ? null
      : LocalEndpoint.parse(baseUrl!, flavor: flavor);
}

/// Persists the configuration. Keys go to the platform keystore and nowhere
/// else — never to shared preferences, never to a log, never into an audit
/// that gets shared.
class ProviderConfigStore {
  ProviderConfigStore({
    FlutterSecureStorage? secure,
  }) : _secure = secure ?? const FlutterSecureStorage();

  final FlutterSecureStorage _secure;

  static const _kindKey = 'provider.kind';
  static const _modelKey = 'provider.model';
  static const _baseUrlKey = 'provider.baseUrl';
  static const _flavorKey = 'provider.flavor';

  Future<ProviderConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    final kind = ProviderKind.values.asNameMap()[prefs.getString(_kindKey)];
    if (kind == null) return const ProviderConfig.defaults();

    return ProviderConfig(
      kind: kind,
      model: prefs.getString(_modelKey) ?? kind.defaultModel,
      baseUrl: prefs.getString(_baseUrlKey),
      flavor: LocalFlavor.values.asNameMap()[prefs.getString(_flavorKey)] ??
          LocalFlavor.ollama,
    );
  }

  Future<void> save(ProviderConfig config) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kindKey, config.kind.name);
    await prefs.setString(_modelKey, config.model);
    await prefs.setString(_flavorKey, config.flavor.name);
    final baseUrl = config.baseUrl;
    if (baseUrl == null || baseUrl.isEmpty) {
      await prefs.remove(_baseUrlKey);
    } else {
      await prefs.setString(_baseUrlKey, baseUrl);
    }
  }

  /// Keys are stored per backend, so switching between Claude and Gemini does
  /// not make the user paste a key again.
  Future<String?> readKey(ProviderKind kind) =>
      _secure.read(key: 'apiKey.${kind.name}');

  Future<void> writeKey(ProviderKind kind, String value) => value.isEmpty
      ? _secure.delete(key: 'apiKey.${kind.name}')
      : _secure.write(key: 'apiKey.${kind.name}', value: value);
}

/// Builds the provider the pipeline will run against.
///
/// Claude and Gemini are built as their document-capable variants so the
/// attachment path is available; the pipeline still falls back to text on its
/// own if the statement is too large.
class ProviderFactory {
  const ProviderFactory._();

  static StructuringProvider build({
    required ProviderConfig config,
    required HttpTransport transport,
    String? apiKey,
  }) {
    final key = apiKey ?? '';
    final baseUrl = config.resolvedBaseUrl;

    switch (config.kind) {
      case ProviderKind.anthropic:
        return AnthropicDocumentProvider(
          transport: transport,
          apiKey: key,
          model: config.model,
          baseUrl: baseUrl,
        );
      case ProviderKind.gemini:
        return GeminiDocumentProvider(
          transport: transport,
          apiKey: key,
          model: config.model,
          baseUrl: baseUrl,
        );
      case ProviderKind.openai:
        return OpenAiStructuringProvider(
          transport: transport,
          apiKey: key,
          model: config.model,
          baseUrl: baseUrl,
        );
      case ProviderKind.local:
        return LocalStructuringProvider(
          transport: transport,
          baseUrl: baseUrl ??
              Uri.parse('http://${LocalEndpoint.androidEmulatorHost}:'
                  '${config.flavor.defaultPort}'),
          model: config.model,
          flavor: config.flavor,
          apiKey: key.isEmpty ? null : key,
        );
    }
  }
}
