#!/bin/bash
# Update a desktop chroot with latest packages from apt
#
# Usage: sudo ./scripts/update-chroot.sh [desktop] [expected-version]
#
# Example: sudo ./scripts/update-chroot.sh gnome
#          sudo ./scripts/update-chroot.sh gnome 6.18.8
#          sudo ./scripts/update-chroot.sh kde 6.18.8
#
# When expected-version is given, the script waits for the apt repository
# to serve that version before upgrading (handles CDN propagation delay).
#
# This updates an existing chroot's packages (kernel, firmware, etc.)
# without rebuilding from scratch. Use after uploading new packages to apt.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$(dirname "$SCRIPT_DIR")"
cd "$BUILD_DIR"

DESKTOP="${1:-gnome}"
EXPECTED_VERSION="$2"
CHROOT_DIR="desktop-choice/${DESKTOP}/chroot"

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: This script must be run as root"
    exit 1
fi

if [ ! -d "$CHROOT_DIR" ]; then
    echo "Error: No chroot found at $CHROOT_DIR"
    echo "       Run 'build.sh $DESKTOP desktop iso' first to create it."
    exit 1
fi

echo "=== Updating $DESKTOP chroot ==="
echo "Chroot: $CHROOT_DIR"
echo ""

# Fix DNS resolution
cp /etc/resolv.conf "$CHROOT_DIR/etc/resolv.conf"

# Remove raspi-firmware hooks that break non-RPi systems
rm -f "$CHROOT_DIR/etc/initramfs/post-update.d/z50-raspi-firmware"
rm -f "$CHROOT_DIR/etc/kernel/postinst.d/z50-raspi-firmware"
rm -f "$CHROOT_DIR/etc/kernel/postrm.d/z50-raspi-firmware"

echo "[1/5] Updating package lists..."
chroot "$CHROOT_DIR" apt-get update -qq

# If expected version given, wait for apt to see it
if [ -n "$EXPECTED_VERSION" ]; then
    MAX_RETRIES=10
    RETRY_DELAY=15
    for i in $(seq 1 $MAX_RETRIES); do
        CANDIDATE=$(chroot "$CHROOT_DIR" apt-cache policy linux-image-sky1 2>/dev/null \
            | grep 'Candidate:' | awk '{print $2}')
        if [ "$CANDIDATE" = "$EXPECTED_VERSION" ]; then
            echo "  apt sees linux-image-sky1 $EXPECTED_VERSION"
            break
        fi
        if [ "$i" -eq "$MAX_RETRIES" ]; then
            echo "Error: apt still sees linux-image-sky1 $CANDIDATE after $MAX_RETRIES retries"
            echo "       Expected $EXPECTED_VERSION — CDN may not have propagated yet"
            exit 1
        fi
        echo "  Waiting for $EXPECTED_VERSION (apt sees $CANDIDATE, retry $i/$MAX_RETRIES)..."
        sleep "$RETRY_DELAY"
        chroot "$CHROOT_DIR" apt-get update -qq
    done
fi

echo "[2/5] Upgrading packages..."
chroot "$CHROOT_DIR" apt-get dist-upgrade -y

echo "[3/5] Removing deprecated DKMS packages (if present)..."
chroot "$CHROOT_DIR" apt-get remove -y \
    r8126-dkms sky1-vpu-dkms sky1-npu-dkms 2>/dev/null || true

# Clean stale DKMS modules from updates/dkms/
MODULES_DIR="$CHROOT_DIR/lib/modules"
for kdir in "$MODULES_DIR"/*/updates/dkms; do
    if [ -d "$kdir" ]; then
        echo "  Removing stale DKMS modules: $kdir"
        rm -rf "$kdir"
    fi
done

echo "[4/5] Regenerating initramfs..."
chroot "$CHROOT_DIR" update-initramfs -u -k all

echo "[5/5] Cleaning up..."
chroot "$CHROOT_DIR" apt-get autoremove -y -qq
chroot "$CHROOT_DIR" apt-get clean

# Show result
KERNEL=$(ls "$CHROOT_DIR/boot/vmlinuz-"*-sky1 2>/dev/null | sed 's|.*/vmlinuz-||' | sort -V | tail -1)
echo ""
echo "=== Update complete ==="
echo "Kernel: $KERNEL"
echo "Desktop: $DESKTOP"

# Verify expected version if given
if [ -n "$EXPECTED_VERSION" ]; then
    INSTALLED=$(chroot "$CHROOT_DIR" dpkg-query -W -f='${Version}' linux-image-sky1 2>/dev/null)
    if [ "$INSTALLED" != "$EXPECTED_VERSION" ]; then
        echo ""
        echo "WARNING: Expected kernel $EXPECTED_VERSION but installed $INSTALLED"
        exit 1
    fi
fi

echo ""
echo "Next steps:"
echo "  sudo SKIP_COMPRESS=1 ./scripts/build-image.sh $DESKTOP desktop  # Build image"
echo "  sudo ./scripts/build-image.sh $DESKTOP desktop                  # Build + compress"
