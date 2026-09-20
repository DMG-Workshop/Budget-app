import 'package:coldwater/src/settings/local_endpoint.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:transcript_core/transcript_core.dart';

void main() {
  group('parse', () {
    test('accepts a bare host and supplies the flavour default port', () {
      expect(
        LocalEndpoint.parse('192.168.1.10')?.toString(),
        'http://192.168.1.10:11434',
      );
      expect(
        LocalEndpoint.parse('192.168.1.10', flavor: LocalFlavor.lmStudio)
            ?.toString(),
        'http://192.168.1.10:1234',
      );
    });

    test('accepts host:port without reading the host as a scheme', () {
      final uri = LocalEndpoint.parse('192.168.1.10:1234');
      expect(uri?.host, '192.168.1.10');
      expect(uri?.port, 1234);
      expect(uri?.scheme, 'http');
    });

    test('keeps an explicit scheme and defaults https to 443', () {
      final uri = LocalEndpoint.parse('https://coldwater.local');
      expect(uri?.scheme, 'https');
      expect(uri?.port, 443);
      expect(uri?.host, 'coldwater.local');
    });

    test('rejects nonsense rather than producing a broken URL', () {
      expect(LocalEndpoint.parse(''), isNull);
      expect(LocalEndpoint.parse('   '), isNull);
      expect(LocalEndpoint.parse('ftp://192.168.1.10'), isNull);
    });
  });

  group('Android loopback rewriting', () {
    test('rewrites loopback to the emulator host alias on Android', () {
      for (final host in LocalEndpoint.loopbackHosts) {
        // An IPv6 literal has to be bracketed in a URL; Uri strips the
        // brackets back off when it reports the host.
        final literal = host.contains(':') ? '[$host]' : host;
        final uri =
            LocalEndpoint.parse('http://$literal:11434', isAndroid: true);
        expect(uri?.host, LocalEndpoint.androidEmulatorHost,
            reason: '$host should be rewritten');
      }
    });

    test('leaves loopback alone off Android', () {
      expect(
        LocalEndpoint.parse('http://localhost:11434')?.host,
        'localhost',
      );
    });

    test('never rewrites a real LAN address', () {
      expect(
        LocalEndpoint.parse('http://192.168.1.10:11434', isAndroid: true)?.host,
        '192.168.1.10',
      );
    });
  });

  group('explainProblem', () {
    test('is silent when the address is usable', () {
      expect(LocalEndpoint.explainProblem('192.168.1.10:11434'), isNull);
    });

    test('asks for an address when the field is empty', () {
      expect(LocalEndpoint.explainProblem(''), contains('Enter the address'));
    });

    test('explains that a path will not work', () {
      // The provider adapters address /v1/... from the root, so a proxy
      // mounted under a path silently loses its prefix.
      expect(
        LocalEndpoint.explainProblem('192.168.1.10:11434/ollama'),
        contains('Paths are not supported'),
      );
    });

    test('rejects an unusable address with a worked example', () {
      final message = LocalEndpoint.explainProblem('!!!');
      expect(message, contains('11434'));
    });
  });

  test('flags plain http as needing a cleartext exception', () {
    expect(
      LocalEndpoint.needsCleartextException(Uri.parse('http://10.0.2.2:11434')),
      isTrue,
    );
    expect(
      LocalEndpoint.needsCleartextException(Uri.parse('https://coldwater.local')),
      isFalse,
    );
  });
}
