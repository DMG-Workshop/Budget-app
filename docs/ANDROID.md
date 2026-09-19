# Coldwater on Android

## Building

```bash
cd app
flutter pub get
flutter run                 # debug, on a connected device or emulator
flutter build apk --debug   # installable APK
```

Two things about this build are worth knowing before the first one fails:

**pdfium is downloaded during the build.** On-device text extraction uses
pdfium, which `pdfium_dart` fetches with a Dart native-asset build hook rather
than vendoring. The first build therefore needs outbound network beyond pub
and Maven, and an air-gapped build will not work. Native assets are enabled by
default on Flutter stable, so no flag is needed.

**`minSdk` is pinned to 24** in `android/app/build.gradle.kts` rather than
inherited from Flutter, so a Flutter upgrade cannot raise the floor without
someone noticing. file_picker and pdfium both need 21.

### Signing a release

The release build falls back to the debug key so `flutter run --release` works
on a fresh clone. For a real release, create `app/android/key.properties` —
untracked, and it must stay that way:

```properties
storeFile=/absolute/path/to/upload-keystore.jks
storePassword=…
keyAlias=upload
keyPassword=…
```

The Gradle config picks it up automatically when present.

R8 minification is deliberately **off**. Flutter's Dart code is already
tree-shaken and AOT-compiled, so shrinking the thin Java/Kotlin layer buys
little and breaks reflection-based plugin code in ways that surface at runtime
rather than at build time. `proguard-rules.pro` holds the rules this app would
need if that trade is ever revisited.

## Connecting to a model on your own network

This is the part that catches people out, and the reason is a real Android
limitation rather than a bug in the app.

### Android cannot express "any address on my Wi-Fi"

Android's network security config matches **DNS name suffixes**. It has no
wildcard for IP literals. This:

```xml
<domain includeSubdomains="true">192.168.*.*</domain>
```

is not a syntax error. It parses, it is accepted, and it never matches
anything. The request then fails at runtime with:

```
Cleartext HTTP traffic to 192.168.1.50 not permitted
```

iOS does not have this problem — `NSAllowsLocalNetworking` permits cleartext
to link-local addresses and `.local` names without weakening anything else,
and Coldwater's `Info.plist` sets it. Android has no equivalent.

So there are exactly three options, and the shipped config takes the first two.

### 1. Use a name, not an address (recommended)

`network_security_config.xml` permits cleartext for any `*.local`, `*.lan`,
`*.home.arpa` or `*.internal` host. Suffix matching *does* work for names. If
your model server is reachable as `ollama.local`, it works with no changes.

That config also trusts user-installed certificate authorities **for those
names only**, so a LAN server with its own certificate can be used over HTTPS
without weakening trust for anything else.

### 2. Develop against a debug build

Debug builds carry `<debug-overrides>`, so a hand-typed LAN IP works while
developing and the release build stays locked down.

On the **emulator**, use `10.0.2.2` — inside the emulator `localhost` is the
emulated phone, not your PC. The app rewrites loopback addresses to
`10.0.2.2` automatically on Android, and there is a one-tap preset for it.

### 3. Add your address explicitly

Uncomment the block in
`app/android/app/src/main/res/xml/network_security_config.xml` and put the
literal address in:

```xml
<domain-config cleartextTrafficPermitted="true">
    <domain includeSubdomains="false">192.168.1.10</domain>
</domain-config>
```

There is no pattern form. It has to be the actual address.

The fourth option — `cleartextTrafficPermitted="true"` on `base-config` —
weakens *every* connection the app makes, including to the cloud providers,
which is why it is not the default. Prefer option 1.

## Making the server reachable at all

A cleartext exception does nothing if the server is not listening on the
network. Both of these bind to their own loopback by default:

| Server | Port | To listen on the network |
|---|---|---|
| Ollama | 11434 | `OLLAMA_HOST=0.0.0.0 ollama serve` |
| LM Studio | 1234 | Enable "Serve on Local Network" in the server tab |

Then check from another machine before blaming the phone:

```bash
curl http://192.168.1.10:11434/api/tags      # Ollama
curl http://192.168.1.10:1234/v1/models      # LM Studio
```

## Troubleshooting

| What you see | What it means |
|---|---|
| "Cleartext HTTP traffic to … not permitted" | The address is not covered by the network security config. See the three options above. |
| "Nothing answered at that address" | The server is not running, or is bound to its own loopback. |
| "That hostname could not be found on this network" | mDNS did not resolve. Try the IP address. |
| Request times out on the first run | A cold local model can take most of a minute to load. The local timeout is 10 minutes for this reason. |
| "This PDF has no text layer" | A scanned statement. Claude and Gemini can still read it directly; a local model cannot. |
| "The model could not produce a valid audit after 3 attempts" | Usually a small local model that cannot hold the schema. Try a larger one, or a cloud provider. |

## What the app sends where

| Backend | What leaves the device |
|---|---|
| Claude, Gemini | The PDF itself, to that provider |
| OpenAI | Text extracted on the device, to OpenAI |
| Ollama, LM Studio | Text extracted on the device, to your own machine only |

API keys are stored in the Android Keystore via `flutter_secure_storage` and
are never written to preferences, logs, or the audit itself.
