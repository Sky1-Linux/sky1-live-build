#!/bin/bash
# Build Sky1 Linux raw disk image from live-build chroot
#
# Usage: sudo ./scripts/build-image.sh <desktop> <loadout> [track]
#
# Example: sudo ./scripts/build-image.sh gnome desktop
#          sudo ./scripts/build-image.sh gnome desktop rc
#
# Output: sky1-linux-<desktop>-<loadout>[-<track>]-YYYYMMDD.img.xz
#
# Prerequisites:
# - Must have a built chroot from lb build (or run build.sh first)
# - Requires root privileges

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$(dirname "$SCRIPT_DIR")"
cd "$BUILD_DIR"

DESKTOP="${1:-gnome}"
LOADOUT="${2:-desktop}"
TRACK="${3:-main}"
IMAGE_SIZE=14              # GB - fits 16GB SD cards, expands on first boot
DATE=$(date +%Y%m%d)

# Single chroot per desktop — track controls which kernel was installed
CHROOT_DIR="desktop-choice/${DESKTOP}/chroot"

# Track-aware output naming and kernel glob
if [ "$TRACK" = "main" ]; then
    IMAGE_NAME="sky1-linux-${DESKTOP}-${LOADOUT}-${DATE}.img"
    KERNEL_GLOB="*-sky1 *-sky1.r*"
else
    IMAGE_NAME="sky1-linux-${DESKTOP}-${LOADOUT}-${TRACK}-${DATE}.img"
    KERNEL_GLOB="*-sky1-${TRACK} *-sky1-${TRACK}.r*"
fi

EFI_SIZE=512               # MB
ROOT_SIZE=$((IMAGE_SIZE * 1024 - EFI_SIZE))  # MB

# Check root
if [ "$(id -u)" -ne 0 ]; then
    echo "Error: This script must be run as root"
    exit 1
fi

# Check for desktop-specific chroot
if [ -d "$CHROOT_DIR" ]; then
    CHROOT_SOURCE="$CHROOT_DIR"
elif [ -L "chroot" ] && [ -d "chroot" ]; then
    # Follow symlink if it exists and points to valid directory
    CHROOT_SOURCE="$(readlink -f chroot)"
    echo "Using chroot via symlink: $CHROOT_SOURCE"
elif [ -d "chroot" ]; then
    echo "Warning: Using legacy 'chroot' directory"
    echo "         Consider running 'build.sh $DESKTOP desktop iso' for an isolated chroot"
    CHROOT_SOURCE="chroot"
else
    echo "Error: No chroot found for $DESKTOP."
    echo "       Run 'build.sh $DESKTOP desktop iso' first to create the chroot."
    exit 1
fi

echo "=== Building Sky1 Linux Disk Image ==="
echo "Desktop: $DESKTOP"
echo "Loadout: $LOADOUT"
echo "Track:   $TRACK"
echo "Chroot:  $CHROOT_SOURCE"
echo "Image size: ${IMAGE_SIZE}GB"
echo "Output: $IMAGE_NAME"
echo ""

# Cleanup function
cleanup() {
    echo "Cleaning up..."
    if [ -n "$MOUNT_DIR" ] && mountpoint -q "$MOUNT_DIR/boot/efi" 2>/dev/null; then
        umount "$MOUNT_DIR/boot/efi" || true
    fi
    if [ -n "$MOUNT_DIR" ] && mountpoint -q "$MOUNT_DIR" 2>/dev/null; then
        umount "$MOUNT_DIR" || true
    fi
    if [ -n "$LOOP" ]; then
        losetup -d "$LOOP" 2>/dev/null || true
    fi
    if [ -n "$MOUNT_DIR" ] && [ -d "$MOUNT_DIR" ]; then
        rmdir "$MOUNT_DIR" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# Step 1: Create sparse image file
echo "[1/15] Creating ${IMAGE_SIZE}GB sparse image..."
rm -f "$IMAGE_NAME" "${IMAGE_NAME}.xz"
truncate -s ${IMAGE_SIZE}G "$IMAGE_NAME"

# Step 2: Partition with GPT
echo "[2/15] Creating GPT partition table..."
parted -s "$IMAGE_NAME" mklabel gpt
parted -s "$IMAGE_NAME" mkpart ESP fat32 1MiB ${EFI_SIZE}MiB
parted -s "$IMAGE_NAME" set 1 esp on
parted -s "$IMAGE_NAME" mkpart root ext4 ${EFI_SIZE}MiB 100%

# Step 3: Setup loop device
echo "[3/15] Setting up loop device..."
LOOP=$(losetup --find --show --partscan "$IMAGE_NAME")
EFI_PART="${LOOP}p1"
ROOT_PART="${LOOP}p2"

# Wait for partitions to appear
sleep 1
if [ ! -b "$EFI_PART" ] || [ ! -b "$ROOT_PART" ]; then
    echo "Error: Partition devices not found"
    exit 1
fi

echo "Loop device: $LOOP"
echo "EFI partition: $EFI_PART"
echo "Root partition: $ROOT_PART"

# Step 4: Format partitions
echo "[4/15] Formatting partitions..."
mkfs.vfat -F 32 -n SKY1EFI "$EFI_PART"
mkfs.ext4 -O ^metadata_csum -L sky1root -q "$ROOT_PART"

# Step 5: Mount partitions
echo "[5/15] Mounting partitions..."
MOUNT_DIR=$(mktemp -d)
mount "$ROOT_PART" "$MOUNT_DIR"
mkdir -p "$MOUNT_DIR/boot/efi"
mount "$EFI_PART" "$MOUNT_DIR/boot/efi"

# Step 6: Copy rootfs from chroot
echo "[6/15] Copying rootfs from $CHROOT_SOURCE (this may take a while)..."
rsync -aHAXq --numeric-ids \
    --exclude='/proc/*' \
    --exclude='/sys/*' \
    --exclude='/dev/*' \
    --exclude='/run/*' \
    --exclude='/tmp/*' \
    --exclude='/var/cache/apt/archives/*.deb' \
    --exclude='/var/lib/apt/lists/*' \
    "$CHROOT_SOURCE/" "$MOUNT_DIR/"

# Step 7: Remove live-boot packages, add disk image specific
echo "[7/15] Configuring for installed system..."

# Mount necessary filesystems for chroot operations
mount --bind /dev "$MOUNT_DIR/dev"
mount --bind /proc "$MOUNT_DIR/proc"
mount --bind /sys "$MOUNT_DIR/sys"

# Copy resolv.conf for network access in chroot
cp /etc/resolv.conf "$MOUNT_DIR/etc/resolv.conf"

# Remove live-specific packages
chroot "$MOUNT_DIR" apt-get remove -y --purge \
    live-boot live-config live-config-systemd live-tools \
    calamares calamares-settings-sky1 2>/dev/null || true

# Install disk image specific packages (desktop-aware)
chroot "$MOUNT_DIR" apt-get update -qq
chroot "$MOUNT_DIR" apt-get install -y -qq cloud-guest-utils parted

# Install first-boot user setup based on desktop choice
case "$DESKTOP" in
    kde)
        echo "Installing plasma-setup for KDE first-boot..."
        chroot "$MOUNT_DIR" apt-get install -y -qq plasma-setup
        ;;
    gnome)
        echo "Installing gnome-initial-setup for GNOME first-boot..."
        chroot "$MOUNT_DIR" apt-get install -y -qq gnome-initial-setup
        ;;
    *)
        echo "No first-boot user setup for desktop: $DESKTOP"
        ;;
esac

# Clean up
chroot "$MOUNT_DIR" apt-get autoremove -y -qq
chroot "$MOUNT_DIR" apt-get clean

# Unmount bind mounts
umount "$MOUNT_DIR/sys"
umount "$MOUNT_DIR/proc"
umount "$MOUNT_DIR/dev"

# Step 8: Remove live-system artifacts
echo "[8/15] Removing live-system artifacts..."

# Remove live user if present (gnome-initial-setup creates first user)
if chroot "$MOUNT_DIR" id sky1 >/dev/null 2>&1; then
    echo "Removing live user 'sky1'..."
    chroot "$MOUNT_DIR" userdel -r sky1 2>/dev/null || true
fi

# Remove desktop shortcuts for live session (installer, gparted)
rm -f "$MOUNT_DIR/etc/skel/Desktop/install-sky1-linux.desktop"
rm -f "$MOUNT_DIR/etc/skel/Desktop/gparted.desktop"
rmdir "$MOUNT_DIR/etc/skel/Desktop" 2>/dev/null || true

# Remove live-specific directories and configs
rm -rf "$MOUNT_DIR/etc/calamares"
rm -rf "$MOUNT_DIR/etc/live"
rm -rf "$MOUNT_DIR/var/lib/live"

# Remove live prompt marker (causes "(live)" prefix in terminal)
rm -f "$MOUNT_DIR/etc/debian_chroot"

# Remove first-boot markers (live ISO sets these, but disk images need initial-setup)
case "$DESKTOP" in
    gnome)
        rm -f "$MOUNT_DIR/etc/skel/.config/gnome-initial-setup-done"
        ;;
    kde)
        rm -f "$MOUNT_DIR/etc/plasma-setup-done"
        ;;
esac

# Step 9: Install disk-image-specific overlay files
echo "[9/15] Installing disk image configuration..."
if [ -d "config/includes.chroot.image" ]; then
    cp -a config/includes.chroot.image/* "$MOUNT_DIR/"
fi

# Update dconf database after overlay (recompile with image-specific settings)
mount --bind /dev "$MOUNT_DIR/dev"
mount --bind /proc "$MOUNT_DIR/proc"
chroot "$MOUNT_DIR" dconf update 2>/dev/null || true
chroot "$MOUNT_DIR" systemctl enable sky1-firstboot.service 2>/dev/null || true
umount "$MOUNT_DIR/proc"
umount "$MOUNT_DIR/dev"

# Step 10: Generate fstab with UUIDs
echo "[10/16] Generating fstab..."
EFI_UUID=$(blkid -s UUID -o value "$EFI_PART")
ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")

cat > "$MOUNT_DIR/etc/fstab" << EOF
# Sky1 Linux fstab (auto-generated for disk image)
# <filesystem>   <mount>      <type>  <options>           <dump> <pass>
UUID=$ROOT_UUID  /            ext4    defaults,noatime    0      1
UUID=$EFI_UUID   /boot/efi    vfat    defaults,noatime    0      2
EOF

# Step 11: Install bootloader
echo "[11/16] Installing bootloader..."
mkdir -p "$MOUNT_DIR/boot/efi/EFI/BOOT"
mkdir -p "$MOUNT_DIR/boot/efi/EFI/sky1"
mkdir -p "$MOUNT_DIR/boot/efi/GRUB"

# Copy patched GRUB
PATCHED_GRUB="config/includes.chroot/usr/share/sky1/grubaa64-install.efi"
if [ -f "$PATCHED_GRUB" ]; then
    cp "$PATCHED_GRUB" "$MOUNT_DIR/boot/efi/EFI/BOOT/BOOTAA64.EFI"
    cp "$PATCHED_GRUB" "$MOUNT_DIR/boot/efi/EFI/sky1/grubaa64.efi"
else
    echo "Warning: Patched GRUB not found at $PATCHED_GRUB"
fi

# Find kernel version (newest sky1 kernel matching this track)
# KERNEL_GLOB may contain multiple patterns (space-separated)
KERNEL_VERSION=""
for pattern in $KERNEL_GLOB; do
    match=$(ls "$MOUNT_DIR/boot/vmlinuz-"${pattern} 2>/dev/null | sed 's|.*/vmlinuz-||' | sort -V | tail -1)
    if [ -n "$match" ]; then
        KERNEL_VERSION="$match"
    fi
done
if [ -z "$KERNEL_VERSION" ]; then
    KERNEL_VERSION=$(ls "$MOUNT_DIR/boot/vmlinuz-"* | sed 's|.*/vmlinuz-||' | sort -V | tail -1)
fi

echo "Kernel version: $KERNEL_VERSION"

# Verify initrd exists - abort if missing (indicates broken chroot)
if [ ! -f "$MOUNT_DIR/boot/initrd.img-$KERNEL_VERSION" ]; then
    echo "ERROR: initrd.img-$KERNEL_VERSION not found in chroot /boot/"
    echo "       This usually means initramfs-tools failed to install."
    echo "       Check the build log and try a clean rebuild."
    exit 1
fi

# Ensure DTBs are in /boot/dtbs (copy from kernel package location if needed)
mkdir -p "$MOUNT_DIR/boot/dtbs"
DTB_SOURCE="$MOUNT_DIR/usr/lib/linux-image-$KERNEL_VERSION/cix"
if [ -d "$DTB_SOURCE" ]; then
    echo "Copying DTBs from $DTB_SOURCE..."
    cp "$DTB_SOURCE"/sky1-*.dtb "$MOUNT_DIR/boot/dtbs/" 2>/dev/null || true
fi

# Verify DTBs exist
for dtb in sky1-orion-o6 sky1-orion-o6n sky1-orangepi-6-plus; do
    if [ ! -f "$MOUNT_DIR/boot/dtbs/${dtb}.dtb" ]; then
        echo "Warning: ${dtb}.dtb not found"
    fi
done

# Generate GRUB config with entries for both O6 and O6N
# Firstboot script will remove the wrong board's entry
# Subsequent kernel updates managed by /usr/share/sky1/update-boot
CMDLINE="loglevel=7 console=tty0 console=ttyAMA2,115200"
CMDLINE+=" efi=noruntime earlycon=efifb earlycon=pl011,0x040d0000 acpi=off"
CMDLINE+=" clk_ignore_unused linlon_dp.enable_fb=1 linlon_dp.enable_render=0"
CMDLINE+=" fbcon=map:01111111 keep_bootcon panic=30"
CMDLINE+=" root=UUID=$ROOT_UUID rootwait rw"

cat > "$MOUNT_DIR/boot/efi/GRUB/grub.cfg" << EOF
# Sky1 Linux GRUB Configuration
# Generated by build-image.sh
# Subsequent updates managed by /usr/share/sky1/update-boot

# No default - require user selection on first boot
# Firstboot script will remove the wrong board's entry
set timeout=-1

insmod part_gpt
insmod fat
insmod ext2

search.fs_uuid $ROOT_UUID root
set prefix=(\$root)/boot/grub

menuentry 'Sky1 Linux ${KERNEL_VERSION} - O6' {
    devicetree (\$root)/boot/dtbs/sky1-orion-o6.dtb
    linux (\$root)/boot/vmlinuz-$KERNEL_VERSION \\
        $CMDLINE
    initrd (\$root)/boot/initrd.img-$KERNEL_VERSION
}

menuentry 'Sky1 Linux ${KERNEL_VERSION} - O6N' {
    devicetree (\$root)/boot/dtbs/sky1-orion-o6n.dtb
    linux (\$root)/boot/vmlinuz-$KERNEL_VERSION \\
        $CMDLINE
    initrd (\$root)/boot/initrd.img-$KERNEL_VERSION
}

menuentry 'Sky1 Linux ${KERNEL_VERSION} - Orange Pi 6 Plus' {
    devicetree (\$root)/boot/dtbs/sky1-orangepi-6-plus.dtb
    linux (\$root)/boot/vmlinuz-$KERNEL_VERSION \\
        $CMDLINE
    initrd (\$root)/boot/initrd.img-$KERNEL_VERSION
}
EOF

# Step 12: Clear machine-id (will be regenerated on first boot)
echo "[12/16] Clearing machine-id for first-boot generation..."
rm -f "$MOUNT_DIR/etc/machine-id"
rm -f "$MOUNT_DIR/var/lib/dbus/machine-id"
touch "$MOUNT_DIR/etc/machine-id"  # Empty file signals regeneration needed

# Step 13: Clear SSH host keys
echo "[13/16] Clearing SSH host keys..."
rm -f "$MOUNT_DIR/etc/ssh/ssh_host_"*

# Step 14: Cleanup
echo "[14/16] Final cleanup..."
rm -rf "$MOUNT_DIR/var/cache/apt/archives/"*.deb
rm -rf "$MOUNT_DIR/var/lib/apt/lists/"*
rm -rf "$MOUNT_DIR/tmp/"*
rm -f "$MOUNT_DIR/root/.bash_history"

# Step 15: Unmount
echo "[15/16] Unmounting..."
sync
umount "$MOUNT_DIR/boot/efi"
umount "$MOUNT_DIR"
losetup -d "$LOOP"
LOOP=""
rmdir "$MOUNT_DIR"
MOUNT_DIR=""

# Step 16: Compress (skip with SKIP_COMPRESS=1)
if [ "${SKIP_COMPRESS:-}" = "1" ]; then
    echo "[16/16] Skipping compression (SKIP_COMPRESS=1)"
    echo ""
    echo "=== Build Complete (uncompressed) ==="
    ls -lh "${IMAGE_NAME}"
    echo ""
    echo "To write directly to disk:"
    echo "  sudo dd if=${IMAGE_NAME} of=/dev/sdX bs=4M status=progress"
    echo ""
    echo "To compress later:"
    echo "  xz -T0 -9 -v ${IMAGE_NAME}"
else
    echo "[16/16] Compressing image (this may take a while)..."
    xz -T0 -9 -v "$IMAGE_NAME"
    echo ""
    echo "=== Build Complete ==="
    ls -lh "${IMAGE_NAME}.xz"
    echo ""
    echo "To write to disk:"
    echo "  xzcat ${IMAGE_NAME}.xz | sudo dd of=/dev/sdX bs=4M status=progress"
    echo ""
    echo "Or use Balena Etcher directly with the .img.xz file"
fi
