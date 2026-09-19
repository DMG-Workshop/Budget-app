import 'package:transcript_core/transcript_core.dart';

/// A one-tap starting point for pointing the app at a model server.
class EndpointPreset {
  const EndpointPreset({
    required this.label,
    required this.template,
    required this.detail,
    this.flavor,
  });

  final String label;

  /// Shown in the field for the user to complete, with the host left to them.
  final String template;

  final String detail;

  /// Null for the self-hosted appliance, which is not Ollama or LM Studio but
  /// this app's own server.
  final LocalFlavor? flavor;
}

/// Turning what a user types into a base URL that will actually connect.
///
/// Every function here is pure and takes the platform as an argument rather
/// than reading it, so the awkward cases — and they are all awkward — are unit
/// tested rather than discovered on a device.
class LocalEndpoint {
  const LocalEndpoint._();

  /// The Android emulator's alias for the machine hosting it. Inside the
  /// emulator, `localhost` is the emulated phone, not the developer's PC, and
  /// this is the single most common reason a local model "does not work".
  static const String androidEmulatorHost = '10.0.2.2';

  static const Set<String> loopbackHosts = {
    'localhost',
    '127.0.0.1',
    '::1',
    '0.0.0.0',
  };

  static const List<EndpointPreset> presets = [
    EndpointPreset(
      label: 'Ollama on this network',
      template: 'http://192.168.1.10:11434',
      detail: 'Run `OLLAMA_HOST=0.0.0.0 ollama serve` on the machine, or it '
          'only listens on its own loopback and nothing else can reach it.',
      flavor: LocalFlavor.ollama,
    ),
    EndpointPreset(
      label: 'LM Studio on this network',
      template: 'http://192.168.1.10:1234',
      detail: 'Enable "Serve on Local Network" in LM Studio\'s server tab.',
      flavor: LocalFlavor.lmStudio,
    ),
    EndpointPreset(
      label: 'Ollama on the Android emulator host',
      template: 'http://$androidEmulatorHost:11434',
      detail: 'Reaches the machine running the emulator.',
      flavor: LocalFlavor.ollama,
    ),
    EndpointPreset(
      label: 'Self-hosted appliance',
      template: 'https://coldwater.local',
      detail: 'The all-in-one server. Uses HTTPS with its own certificate, so '
          'no cleartext exception is needed on either platform.',
    ),
  ];

  /// Parses what the user typed into a usable base URL, or returns null.
  ///
  /// Accepts `192.168.1.10`, `192.168.1.10:11434`, `http://192.168.1.10` and
  /// the full form, because all four are things people type.
  static Uri? parse(
    String raw, {
    LocalFlavor flavor = LocalFlavor.ollama,
    bool isAndroid = false,
  }) {
    var text = raw.trim();
    if (text.isEmpty) return null;

    // A bare host or host:port has no scheme, and Uri.parse would read
    // "192.168.1.10:11434" as scheme "192.168.1.10".
    if (!text.contains('://')) text = 'http://$text';

    final parsed = Uri.tryParse(text);
    if (parsed == null || parsed.host.isEmpty) return null;
    if (parsed.scheme != 'http' && parsed.scheme != 'https') return null;
    // Uri is far more permissive about hosts than DNS is: "!!!" parses
    // happily as a reg-name. Anything that is not a hostname, an IPv4
    // literal or a bracketed IPv6 literal is a typo, and saying so beats
    // handing it to the socket layer to fail obscurely later.
    if (!_plausibleHost.hasMatch(parsed.host)) return null;

    final withPort = parsed.hasPort
        ? parsed
        : parsed.replace(
            port: parsed.scheme == 'https' ? 443 : flavor.defaultPort,
          );

    return rewriteLoopbackForAndroid(withPort, isAndroid: isAndroid);
  }

  /// Hostnames, IPv4 literals, and the `::1`-style IPv6 literal that Uri
  /// hands back with its brackets already stripped.
  static final RegExp _plausibleHost =
      RegExp(r'^([a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?)(\.[a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?)*$|^[0-9a-fA-F:]+$');

  /// Rewrites a loopback host to the emulator's host alias on Android.
  ///
  /// On Android — emulator or handset — loopback is the phone itself, and the
  /// phone is not running the model. On the emulator [androidEmulatorHost]
  /// is the right answer; on a handset nothing is, and pointing at the alias
  /// at least produces a prompt connection failure rather than a confusing
  /// one against the phone's own closed port.
  static Uri rewriteLoopbackForAndroid(Uri uri, {required bool isAndroid}) =>
      isAndroid && loopbackHosts.contains(uri.host)
          ? uri.replace(host: androidEmulatorHost)
          : uri;

  /// A human explanation of why a URL will not work, or null if it will.
  static String? explainProblem(
    String raw, {
    LocalFlavor flavor = LocalFlavor.ollama,
  }) {
    if (raw.trim().isEmpty) return 'Enter the address of your model server.';

    final uri = parse(raw, flavor: flavor);
    if (uri == null) {
      return 'That is not an address this app can reach. Try something like '
          '192.168.1.10:${flavor.defaultPort}.';
    }
    if (uri.path.isNotEmpty && uri.path != '/') {
      return 'Paths are not supported — the provider APIs are addressed from '
          'the root, so mount any reverse proxy at / rather than '
          '${uri.path}.';
    }
    return null;
  }

  /// Whether reaching this endpoint needs a cleartext exception.
  ///
  /// Both platforms block plain HTTP by default. HTTPS to the appliance needs
  /// none of that, which is the reason the appliance terminates TLS at all on
  /// a private network.
  static bool needsCleartextException(Uri uri) => uri.scheme == 'http';
}
