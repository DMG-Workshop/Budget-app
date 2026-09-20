#!/usr/bin/env bash
#
# Bakes a bootable Coldwater appliance disk from a stock Debian cloud image
# and the cloud-init config beside this script.
#
# This is the honest version of "an all-in-one OS": it is Debian, plus a seed
# that installs Coldwater on first boot. Building a genuinely custom
# distribution would mean maintaining a distribution, and the result would be
# harder to trust and harder to update than a stock image that configures
# itself.
#
#   ./build-image.sh                 # x86-64 qcow2, for a VM or a NUC
#   ./build-image.sh --size 16G
#
# Needs: qemu-utils, cloud-image-utils (for cloud-localds), curl.
#
# For a Raspberry Pi, do not use this — write Raspberry Pi OS with the
# imager, and drop cloud-init/user-data onto the boot partition, or just run
# scripts/install.sh once the Pi is up. See docs/SELF_HOSTING.md.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${OUT_DIR:-$HERE/../build}"
SIZE="12G"
BASE_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --size) SIZE="$2"; shift 2 ;;
        --base) BASE_URL="$2"; shift 2 ;;
        -h|--help) sed -n '2,25p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

for tool in qemu-img cloud-localds curl; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "Missing $tool. On Debian/Ubuntu:" >&2
        echo "  sudo apt install qemu-utils cloud-image-utils curl" >&2
        exit 1
    }
done

mkdir -p "$OUT_DIR"
BASE_IMAGE="$OUT_DIR/$(basename "$BASE_URL")"
DISK="$OUT_DIR/coldwater.qcow2"
SEED="$OUT_DIR/coldwater-seed.iso"

if [[ ! -f "$BASE_IMAGE" ]]; then
    echo "==> Downloading the base image"
    curl -fL --progress-bar -o "$BASE_IMAGE" "$BASE_URL"
fi

echo "==> Building the cloud-init seed"
cloud-localds "$SEED" "$HERE/../cloud-init/user-data"

echo "==> Creating $DISK ($SIZE)"
rm -f "$DISK"
qemu-img create -F qcow2 -b "$(realpath "$BASE_IMAGE")" -f qcow2 "$DISK" "$SIZE" >/dev/null

cat <<DONE

  Built:
    disk  $DISK
    seed  $SEED

  Boot it:

    qemu-system-x86_64 -m 8G -smp 4 \\
      -drive file=$DISK,if=virtio \\
      -drive file=$SEED,if=virtio,format=raw \\
      -nic user,hostfwd=tcp::8443-:443

  First boot installs Docker and pulls a model, so give it a while. On a
  real network — rather than qemu's user-mode NIC — it answers to
  https://coldwater.local once it is up.

  The disk is a qcow2 overlay on the base image, so keep them together, or
  flatten it with:

    qemu-img convert -O qcow2 $DISK coldwater-standalone.qcow2

DONE
