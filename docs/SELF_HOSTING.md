# Running Coldwater on your own network

The appliance is a small web server, a local model runtime, and a reverse
proxy that gives the pair a name and a certificate. Once it is up, every
device in the house can audit a statement at `https://coldwater.local`, and
with the bundled model nothing leaves the building.

## The quickest way

On any Debian, Ubuntu or Raspberry Pi OS machine:

```bash
curl -fsSL https://raw.githubusercontent.com/DMG-Workshop/Budget-app/main/appliance/scripts/install.sh | sudo bash
```

That installs Docker, brings up the stack, sets the hostname, advertises
`coldwater.local` over mDNS, installs a systemd unit so it survives a reboot,
and pulls a model. It is idempotent — run it again to upgrade, and your data
volume is kept.

It needs about **6 GB of RAM** to run an 8B model comfortably, and roughly
**15 GB of disk**. Less than that is fine if you point it at a cloud provider
or at a model server on another machine instead; the installer warns rather
than refusing.

## From a clone

```bash
git clone https://github.com/DMG-Workshop/Budget-app
cd Budget-app/appliance
cp .env.example .env          # optional; the defaults are all-local
docker compose up -d
docker compose exec ollama ollama pull llama3.1:8b
```

With an NVIDIA GPU, layer the override on top:

```bash
docker compose -f docker-compose.yml -f docker-compose.gpu.yml up -d
```

## Podman Desktop

The stack runs under Podman, with three adjustments. Substitute `podman
compose` for `docker compose` throughout.

**Give the machine enough room first.** On macOS and Windows, Podman runs
everything inside a VM that defaults to about 2 GB of RAM — not enough to
load an 8B model, and the failure looks like a hang rather than an error.

```bash
podman machine stop
podman machine set --memory 8192 --cpus 4 --disk-size 60
podman machine start
```

**Move the ports.** Rootless Podman cannot bind below 1024, so `80:80`
fails. In `appliance/.env`:

```properties
COLDWATER_HTTP_PORT=8080
COLDWATER_HTTPS_PORT=8443
```

Then the appliance is at `https://localhost:8443`. The phone apps expect
the standard port, so for real use either run Podman rootful
(`podman machine set --rootful`) or allow the low ports on Linux with
`sudo sysctl net.ipv4.ip_unprivileged_port_start=80`.

**Then:**

```bash
cd appliance
podman compose up -d
podman compose exec ollama ollama pull llama3.1:8b
```

Image names are fully qualified in the compose file so Podman does not stop
to ask which registry to use, and the Caddyfile mount carries `,z` so it
works where SELinux is enforcing.

If `podman compose` is not wired up on your install, `podman-compose` from
pip works the same way, as does pointing Docker's own CLI at Podman's socket.

## The certificate — read this before the phones

The proxy issues its own certificate from a certificate authority it creates
on first boot. Until you install that CA, browsers and phones will warn.

```bash
sudo coldwater-ca --save coldwater-ca.crt
```

Then install `coldwater-ca.crt` on each device:

- **Android** — Settings → Security → Encryption & credentials → Install a
  certificate → CA certificate.
- **iOS** — AirDrop or email it, install the profile, then *enable* it under
  Settings → General → About → Certificate Trust Settings. The second step is
  easy to miss and nothing works without it.

This is worth the trouble rather than serving plain HTTP, because it is what
makes the **Android app** able to reach the appliance at all. Android's
network security config cannot express "any address on my Wi-Fi", but the app
does trust user-installed CAs for `.local` names — so a named HTTPS endpoint
works where a bare LAN IP over HTTP does not. See
[ANDROID.md](ANDROID.md) for the full explanation.

## A bootable image

`appliance/scripts/build-image.sh` bakes a Debian cloud image plus a
cloud-init seed that installs Coldwater on first boot:

```bash
sudo apt install qemu-utils cloud-image-utils
./appliance/scripts/build-image.sh
```

This is the honest version of "an all-in-one OS". It is stock Debian that
configures itself, not a bespoke distribution — because maintaining a
distribution means maintaining its security updates, and a self-configuring
stock image is both easier to trust and easier to update.

For a **Raspberry Pi**, don't use that script. Flash Raspberry Pi OS with the
imager, then either drop `appliance/cloud-init/user-data` onto the boot
partition or just run `install.sh` once it has booted. A Pi 5 with 8 GB runs
an 8B model slowly but usably; a Pi 4 is better pointed at a cloud provider.

## Configuration

Everything is optional. Defaults run locally with nothing leaving the network.

| Variable | Default | Meaning |
|---|---|---|
| `COLDWATER_PROVIDER` | `local` | `local`, `anthropic`, `gemini`, `openai` |
| `COLDWATER_BASE_URL` | `http://ollama:11434` | Where the local model lives |
| `COLDWATER_MODEL` | `llama3.1:8b` | Model name |
| `COLDWATER_API_KEY` | — | Cloud providers only; prefer the web UI |
| `COLDWATER_TOKEN` | — | Shared secret for the UI and API |
| `COLDWATER_CURRENCY` | — | ISO 4217 hint |
| `COLDWATER_KEEP_HISTORY` | `false` | Store audits on the appliance |

Anything set in the web UI is written to the data volume as `config.json`,
mode 0600. The API key is never returned to the browser — the settings page
is told only whether one is present.

### Should you set a token?

`COLDWATER_TOKEN` is unset by default. On a home network where everyone with
Wi-Fi access is someone you would hand the statement to, a password nobody
set is a password nobody can lose. Set it the moment that stops being true —
a flatshare, a guest network that is not segregated, or any port forwarding.

**Do not expose this to the internet.** It has no account system and no rate
limiting. If you need it remotely, put it behind a VPN or a tunnel that
authenticates before the request reaches Caddy.

## What is stored

| Thing | Where | Default |
|---|---|---|
| The statement PDF | Nowhere. It is read in memory and discarded. | — |
| The audit JSON | SQLite in the data volume | **Off** |
| The API key | `config.json` in the data volume, 0600 | As set |
| Logs | Caddy, warnings only, no filenames | — |

History is off by default because a stored audit contains a model's verdict on
every line of a bank statement. Turn it on in settings if you want to compare
months; `coldwater-ca` aside, nothing else persists.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `coldwater.local` does not resolve | mDNS. Check `avahi-daemon` is running; try the IP. Windows needs Bonjour. |
| Certificate warning | The CA is not installed on that device yet. |
| "Nothing answered at that address" | The model container is still starting, or no model is pulled. |
| First audit takes minutes | A cold model loading from disk. Subsequent ones are much faster. |
| Ollama will not start on a Pi | 32-bit ARM has no image. Use a 64-bit OS. |
| Out of disk | Models are several GB each. `docker compose exec ollama ollama list`. |

```bash
systemctl status coldwater
cd /opt/coldwater/appliance && docker compose logs -f coldwater
```
