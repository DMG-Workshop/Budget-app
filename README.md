# Coldwater

Hand it a bank statement PDF. It reads it, adds it up, and tells you the truth
about your spending without any encouragement.

The audit runs on an AI backend **you** choose — Claude, Gemini, OpenAI, or a
model on your own machine via Ollama or LM Studio. With a local model, the
statement never leaves your network.

Two ways to run it: a **phone app**, or a **self-hosted appliance** on your own
network that every device in the house can use.

## What it does

1. You pick a statement PDF.
2. It goes to your chosen model, either as the PDF itself (Claude and Gemini
   can read table layout directly) or as text extracted on the device (for
   local models and text-only backends).
3. The model returns strict JSON — never prose — against a fixed schema.
4. The app re-does the arithmetic itself and checks that every transaction the
   model cited actually appears in the statement.
5. You get a net-cashflow figure, a needs/wants/waste breakdown, a blunt
   summary, and a cut list you swipe away as you actually cancel things.

Step 4 is the part that matters. An LLM is a good extraction engine and a poor
arithmetic engine, so the model is trusted to find and categorise transactions
and trusted with nothing that can be recomputed from them. Totals that
disagree with their own line items, leaks drawn from spending that does not
exist, and understated severities are all caught offline and shown to you
rather than silently corrected.

## Layout

```
app/                     Flutter app (Android; iOS builds from the same source)
packages/audit_core/     Pure Dart: schema, prompt, PDF routing, verifiers
contracts/               Schema + prompt, exported from Dart for non-Dart clients
server/                  Self-hosted FastAPI server and web UI
appliance/               docker compose, Caddy, mDNS, systemd, installer
.github/workflows/       CI: analyze, test, contract sync, APK, image build
```

The server is not a second implementation of the audit. It reads the **same
exported contract** — the schema and the prompt are authored once in Dart and
written to `contracts/`, and the server's tests compare what it builds against
those files byte for byte. A statement audited in a browser and on a phone
cannot take different instructions to the same model.

### It reuses EchoCodex

The AI layer is not reimplemented here. `audit_core` depends on
[`transcript_core`](https://github.com/DMG-Workshop/EchoCodex) from EchoCodex,
pinned to a commit, and reuses its provider adapters, capability model, HTTP
transport, schema dialect renderer, tolerant JSON extraction, schema validator
and quote verifier unchanged.

What is genuinely new here is only what a bank statement needs and a
transcript does not:

| Piece | Why it could not be reused |
|---|---|
| `Money` | Statement arithmetic must be exact; handles British and European decimal separators and accounting parentheses |
| Audit schema | Authored once, rendered per provider by EchoCodex's dialect renderer |
| Harsh Auditor prompt | The persona and the JSON contract |
| `DocumentStructuringProvider` | `transcript_core`'s `StructureRequest` is text-only, so PDF attachments needed a seam |
| Dual ingestion route | Prefer sending the PDF; a flattened table loses the columns that tell an amount from a balance |
| Arithmetic verifier | Recomputes every total the model claimed |

The PDF-attachment support is written as an additive change that can be
upstreamed into `transcript_core` later. Each provider delegates identity,
capabilities and connection testing upstream and overrides nothing but the
request body, so those classes get deleted rather than migrated.

## Build it

Requires Flutter 3.47.5 or newer.

```bash
# Tests — no device, no network, no API key needed
cd packages/audit_core && dart pub get && dart test
cd ../../app          && flutter pub get && flutter test

# Run it
cd app && flutter run
```

See **[docs/ANDROID.md](docs/ANDROID.md)** for building, signing, and — the
part that actually catches people out — connecting to a model on your own
network.

### Or run the appliance

```bash
curl -fsSL https://raw.githubusercontent.com/DMG-Workshop/Budget-app/main/appliance/scripts/install.sh | sudo bash
```

Docker, a local model, mDNS and a certificate, on any Debian, Ubuntu or
Raspberry Pi OS box. Then open `https://coldwater.local` from anything on the
network. See **[docs/SELF_HOSTING.md](docs/SELF_HOSTING.md)**.

## Status

| Part | State |
|---|---|
| `audit_core` | Complete. 88 tests. |
| Android app | Complete. 24 tests. |
| Self-hosted server + web UI | Complete. 120 tests. |
| Appliance packaging | Complete: compose, Caddy with its own CA, mDNS, systemd, installer, bootable image. |
| CI | analyze, both test suites, contract sync, Android APK, Docker image built and health-checked. |
| iOS app | Builds from the same source; never compiled — needs a Mac. |

**Nothing has been run against a real provider or a real bank statement.**
Every test uses recorded responses, a stub model server, and generated PDFs.
The wire formats match the documented APIs and EchoCodex's working adapters,
but the first real audit is unproven.

See [docs/ROADMAP.md](docs/ROADMAP.md) for what is deliberately not built yet,
including investments.

## Licence

Apache 2.0, matching EchoCodex.
