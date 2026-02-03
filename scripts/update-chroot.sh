#!/bin/bash
# Update a desktop chroot with latest packages from apt
#
# Usage: sudo ./scripts/update-chroot.sh <desktop> [track] [expected-version]
#
# Example: sudo ./scripts/update-chroot.sh gnome
#          sudo ./scripts/update-chroot.sh gnome main 6.18.8
#          sudo ./scripts/update-chroot.sh gnome rc 6.19.0-rc7
#          sudo ./scripts/update-chroot.sh kde latest 6.19.1
#
# When expected-version is given, the script waits for the apt repository
# to serve that version before upgrading (handles CDN propagation delay).
#
# This updates an existing chroot's packages (kernel, firmware, etc.)
# without rebuilding from scratch. Use after uploading new packages to apt.
# Switching tracks (e.g. main -> rc) swaps the kernel meta packages in-place.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$(dirname "$SCRIPT_DIR")"
cd "$BUILD_DIR"

DESKTOP="${1:-gnome}"
TRACK="${2:-main}"
EXPECTED_VERSION="$3"

APT_URL="https://sky1-linux.github.io/apt"

# Validate track
TRACKS="main latest rc next"
echo "$TRACKS" | grep -qw "$TRACK" || { echo "Error: Unknown track '$TRACK' (valid: $TRACKS)"; exit 1; }

# Single chroot per desktop — track controls which kernel is installed
CHROOT_DIR="desktop-choice/${DESKTOP}/chroot"

# Meta packages for requested track
if [ "$TRACK" = "main" ]; then
    INSTALL_META="linux-image-sky1 linux-headers-sky1"
    KERNEL_GLOB="*-sky1"
else
    INSTALL_META="linux-image-sky1-${TRACK} linux-headers-sky1-${TRACK}"
    KERNEL_GLOB="*-sky1-${TRACK}"
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: This script must be run as root"
    exit 1
fi

if [ ! -d "$CHROOT_DIR" ]; then
    echo "Error: No chroot found at $CHROOT_DIR"
    echo "       Run 'build.sh $DESKTOP desktop iso' first to create it."
    exit 1
fi

echo "=== Updating $DESKTOP chroot (track: $TRACK) ==="
echo "Chroot: $CHROOT_DIR"
echo "Install: $INSTALL_META"
echo ""

# Fix DNS resolution
cp /etc/resolv.conf "$CHROOT_DIR/etc/resolv.conf"

# Remove raspi-firmware hooks that break non-RPi systems
rm -f "$CHROOT_DIR/etc/initramfs/post-update.d/z50-raspi-firmware"
rm -f "$CHROOT_DIR/etc/kernel/postinst.d/z50-raspi-firmware"
rm -f "$CHROOT_DIR/etc/kernel/postrm.d/z50-raspi-firmware"

# Step 1: Update apt sources inside chroot for the requested track
echo "[1/8] Updating apt sources for track: $TRACK..."
SOURCES_FILE="$CHROOT_DIR/etc/apt/sources.list.d/sky1.list"
SIGNED_BY="[signed-by=/usr/share/keyrings/sky1-linux.asc]"
if [ "$TRACK" = "main" ]; then
    echo "deb ${SIGNED_BY} ${APT_URL} sid main non-free-firmware" > "$SOURCES_FILE"
else
    echo "deb ${SIGNED_BY} ${APT_URL} sid main ${TRACK} non-free-firmware" > "$SOURCES_FILE"
fi

echo "[2/8] Updating package lists..."
chroot "$CHROOT_DIR" apt-get update -qq

# Show candidate version and warn if no expected-version pinning
META_CHECK=$(echo "$INSTALL_META" | awk '{print $1}')
CANDIDATE=$(chroot "$CHROOT_DIR" apt-cache policy "$META_CHECK" 2>/dev/null \
    | grep 'Candidate:' | awk '{print $2}')

if [ -z "$EXPECTED_VERSION" ]; then
    echo ""
    echo "  NOTE: No expected-version given — will install whatever CDN serves"
    echo "  Candidate: $META_CHECK $CANDIDATE"
    echo "  Tip: after a fresh apt push, pass the expected version to wait for CDN:"
    echo "    sudo $0 $DESKTOP $TRACK <version>"
    echo ""
fi

# If expected version given, wait for apt to see it
if [ -n "$EXPECTED_VERSION" ]; then
    MAX_RETRIES=10
    RETRY_DELAY=15
    for i in $(seq 1 $MAX_RETRIES); do
        CANDIDATE=$(chroot "$CHROOT_DIR" apt-cache policy "$META_CHECK" 2>/dev/null \
            | grep 'Candidate:' | awk '{print $2}')
        if [ "$CANDIDATE" = "$EXPECTED_VERSION" ]; then
            echo "  apt sees $META_CHECK $EXPECTED_VERSION"
            break
        fi
        if [ "$i" -eq "$MAX_RETRIES" ]; then
            echo "Error: apt still sees $META_CHECK $CANDIDATE after $MAX_RETRIES retries"
            echo "       Expected $EXPECTED_VERSION — CDN may not have propagated yet"
            exit 1
        fi
        echo "  Waiting for $EXPECTED_VERSION (apt sees $CANDIDATE, retry $i/$MAX_RETRIES)..."
        sleep "$RETRY_DELAY"
        chroot "$CHROOT_DIR" apt-get update -qq
    done
fi

# Step 3: Swap kernel meta packages if needed
echo "[3/8] Ensuring correct kernel track..."

# All possible kernel meta packages across all tracks
ALL_META="linux-image-sky1 linux-headers-sky1 linux-sky1"
ALL_META="$ALL_META linux-image-sky1-latest linux-headers-sky1-latest linux-sky1-latest"
ALL_META="$ALL_META linux-image-sky1-rc linux-headers-sky1-rc linux-sky1-rc"
ALL_META="$ALL_META linux-image-sky1-next linux-headers-sky1-next linux-sky1-next"

# Find meta packages from OTHER tracks that are installed
REMOVE_PKGS=""
for pkg in $ALL_META; do
    # Skip packages we want to keep
    echo "$INSTALL_META" | grep -qw "$pkg" && continue
    # Check if installed
    if chroot "$CHROOT_DIR" dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
        REMOVE_PKGS="$REMOVE_PKGS $pkg"
    fi
done

if [ -n "$REMOVE_PKGS" ]; then
    echo "  Removing old track packages:$REMOVE_PKGS"
    chroot "$CHROOT_DIR" apt-get remove -y $REMOVE_PKGS
fi

echo "  Installing: $INSTALL_META"
chroot "$CHROOT_DIR" apt-get install -y $INSTALL_META

echo "[4/8] Upgrading packages..."
chroot "$CHROOT_DIR" apt-get dist-upgrade -y

# Purge versioned kernel packages that don't belong to the target track.
# autoremove often misses these because they weren't auto-installed.
echo "[5/8] Removing old kernel packages..."

# Find the exact versioned packages that the meta packages depend on — these are the keepers
KEEP_PKGS=""
for meta in $INSTALL_META; do
    dep=$(chroot "$CHROOT_DIR" dpkg-query -W -f='${Depends}' "$meta" 2>/dev/null \
        | sed 's/ (.*)//g')  # strip version constraints
    [ -n "$dep" ] && KEEP_PKGS="$KEEP_PKGS $dep"
done

# Find all installed versioned sky1 kernel packages (image, headers, dbg)
STALE_KERNELS=""
for pkg in $(chroot "$CHROOT_DIR" dpkg-query -W -f='${Package}\n' 2>/dev/null \
        | grep -E '^linux-(image|headers)-[0-9].*-sky1'); do
    # Keep if it's a dependency of the current meta packages
    if echo "$KEEP_PKGS" | grep -qw "$pkg"; then
        continue
    fi
    STALE_KERNELS="$STALE_KERNELS $pkg"
done

if [ -n "$STALE_KERNELS" ]; then
    echo "  Purging stale kernels:$STALE_KERNELS"
    chroot "$CHROOT_DIR" apt-get purge -y $STALE_KERNELS
else
    echo "  No stale kernel packages found"
fi

echo "[6/8] Removing deprecated DKMS packages (if present)..."
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

echo "[7/8] Cleaning up and regenerating initramfs..."
chroot "$CHROOT_DIR" apt-get autoremove -y
chroot "$CHROOT_DIR" apt-get clean
chroot "$CHROOT_DIR" update-initramfs -u -k all

# Step 7: Show result
KERNEL=$(ls "$CHROOT_DIR/boot/vmlinuz-"${KERNEL_GLOB} 2>/dev/null | sed 's|.*/vmlinuz-||' | sort -V | tail -1)
if [ -z "$KERNEL" ]; then
    KERNEL=$(ls "$CHROOT_DIR/boot/vmlinuz-"* 2>/dev/null | sed 's|.*/vmlinuz-||' | sort -V | tail -1)
fi

echo ""
echo "[8/8] Verifying..."

# List all kernels in chroot
echo "  Kernels in chroot:"
for vmlinuz in "$CHROOT_DIR"/boot/vmlinuz-*; do
    [ -f "$vmlinuz" ] && echo "    $(basename "$vmlinuz" | sed 's/vmlinuz-//')"
done

echo ""
echo "=== Update complete ==="
echo "Active kernel: $KERNEL"
echo "Desktop: $DESKTOP"
echo "Track: $TRACK"

# Verify expected version if given
if [ -n "$EXPECTED_VERSION" ]; then
    META_CHECK=$(echo "$INSTALL_META" | awk '{print $1}')
    INSTALLED=$(chroot "$CHROOT_DIR" dpkg-query -W -f='${Version}' "$META_CHECK" 2>/dev/null)
    if [ "$INSTALLED" != "$EXPECTED_VERSION" ]; then
        echo ""
        echo "WARNING: Expected $META_CHECK $EXPECTED_VERSION but installed $INSTALLED"
        exit 1
    fi
fi

echo ""
echo "Next steps:"
echo "  sudo SKIP_COMPRESS=1 ./scripts/build-image.sh $DESKTOP desktop $TRACK  # Build image"
echo "  sudo ./scripts/build-image.sh $DESKTOP desktop $TRACK                  # Build + compress"
