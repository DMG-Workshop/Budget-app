#!/usr/bin/env bash
#
# Turns a Debian, Ubuntu or Raspberry Pi OS machine into a Coldwater
# appliance: Docker, the compose stack, mDNS so it answers to
# coldwater.local, and a systemd unit so it comes back after a reboot.
#
#   curl -fsSL https://raw.githubusercontent.com/DMG-Workshop/Budget-app/main/appliance/scripts/install.sh | sudo bash
#
# or, from a clone:
#
#   sudo ./appliance/scripts/install.sh
#
# Idempotent: running it again upgrades in place and keeps your data volume.

set -euo pipefail

REPO_URL="${COLDWATER_REPO:-https://github.com/DMG-Workshop/Budget-app.git}"
BRANCH="${COLDWATER_BRANCH:-main}"
PREFIX="${COLDWATER_PREFIX:-/opt/coldwater}"
HOSTNAME_LOCAL="${COLDWATER_HOSTNAME:-coldwater}"

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m==>\033[0m %s\n' "$*" >&2; }
die()   { printf '\033[1;31m==>\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run this with sudo."

# --- sanity ---------------------------------------------------------------

if ! grep -qiE 'debian|ubuntu|raspbian' /etc/os-release 2>/dev/null; then
    warn "This installer targets Debian, Ubuntu and Raspberry Pi OS."
    warn "Continuing anyway — the compose stack itself is portable."
fi

ARCH="$(uname -m)"
case "$ARCH" in
    x86_64|aarch64) ;;
    armv7l) warn "32-bit ARM: Ollama does not publish an image for it. Use a "
            warn "cloud provider, or a model server on another machine." ;;
    *) warn "Unrecognised architecture $ARCH; continuing." ;;
esac

TOTAL_MB="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)"
if (( TOTAL_MB < 3500 )); then
    warn "Only ${TOTAL_MB} MB of RAM. An 8B model needs roughly 6 GB; this box"
    warn "can still run Coldwater against a cloud provider or another machine."
fi

# --- packages -------------------------------------------------------------

info "Installing packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
    ca-certificates curl git avahi-daemon avahi-utils

if ! command -v docker >/dev/null 2>&1; then
    info "Installing Docker"
    curl -fsSL https://get.docker.com | sh
else
    info "Docker already present"
fi

docker compose version >/dev/null 2>&1 \
    || die "Docker Compose v2 is required (docker compose, not docker-compose)."

# --- source ---------------------------------------------------------------

if [[ -d "$PREFIX/.git" ]]; then
    info "Updating $PREFIX"
    git -C "$PREFIX" fetch --depth 1 origin "$BRANCH"
    git -C "$PREFIX" reset --hard "origin/$BRANCH"
else
    info "Cloning into $PREFIX"
    rm -rf "$PREFIX"
    git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$PREFIX"
fi

[[ -f "$PREFIX/appliance/.env" ]] || cp "$PREFIX/appliance/.env.example" "$PREFIX/appliance/.env"
chmod 600 "$PREFIX/appliance/.env"

# --- mDNS -----------------------------------------------------------------

info "Advertising as ${HOSTNAME_LOCAL}.local"
install -m 0644 "$PREFIX/appliance/avahi/coldwater.service" /etc/avahi/services/coldwater.service

# The certificate is issued for coldwater.local, so the host has to actually
# answer to that name rather than to whatever the box was called.
if [[ "$(hostname)" != "$HOSTNAME_LOCAL" ]]; then
    info "Setting hostname to $HOSTNAME_LOCAL (was $(hostname))"
    hostnamectl set-hostname "$HOSTNAME_LOCAL" || warn "Could not set hostname."
fi

systemctl enable --now avahi-daemon
systemctl restart avahi-daemon

# --- service --------------------------------------------------------------

info "Installing the systemd unit"
install -m 0644 "$PREFIX/appliance/systemd/coldwater.service" /etc/systemd/system/coldwater.service
install -m 0755 "$PREFIX/appliance/scripts/coldwater-ca" /usr/local/bin/coldwater-ca
systemctl daemon-reload
systemctl enable coldwater.service

info "Building and starting (this takes a while on first run)"
systemctl restart coldwater.service

# --- first model ----------------------------------------------------------

MODEL="$(grep -E '^COLDWATER_MODEL=' "$PREFIX/appliance/.env" | cut -d= -f2- || true)"
MODEL="${MODEL:-llama3.1:8b}"

if [[ "$(grep -E '^COLDWATER_PROVIDER=' "$PREFIX/appliance/.env" | cut -d= -f2-)" == "local" ]]; then
    info "Pulling $MODEL — several gigabytes, and only happens once"
    ( cd "$PREFIX/appliance" && docker compose exec -T ollama ollama pull "$MODEL" ) \
        || warn "Could not pull $MODEL. Pull it later with:
    cd $PREFIX/appliance && docker compose exec ollama ollama pull $MODEL"
fi

# --- done -----------------------------------------------------------------

IP="$(hostname -I 2>/dev/null | awk '{print $1}')"

cat <<DONE

  Coldwater is up.

    https://${HOSTNAME_LOCAL}.local        (from any device on this network)
    https://${IP:-this-machine}            (if mDNS is not working)

  Your browser and your phones will warn about the certificate until you
  install the appliance's own CA. Export it with:

    sudo coldwater-ca --save coldwater-ca.crt

  Then install that file on each device. On Android it is what lets the app
  reach the appliance at all without a cleartext exemption.

  Useful commands:

    systemctl status coldwater          service state
    cd $PREFIX/appliance && docker compose logs -f
    cd $PREFIX/appliance && docker compose exec ollama ollama list

DONE
