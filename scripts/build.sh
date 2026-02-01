#!/bin/bash
# Unified build script for Sky1 Linux ISO and disk images
#
# Usage: ./scripts/build.sh <desktop> <loadout> <format> [clean]
#
# Desktop choices: gnome, kde, xfce, none
# Package loadouts: minimal, desktop, server, developer
# Output formats: iso, image
#
# Examples:
#   ./scripts/build.sh gnome desktop iso         # GNOME desktop ISO (default)
#   ./scripts/build.sh gnome desktop image       # GNOME desktop disk image
#   ./scripts/build.sh kde minimal iso clean     # KDE minimal ISO (clean build)
#   ./scripts/build.sh none server image         # Headless server disk image

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$(dirname "$SCRIPT_DIR")"
cd "$BUILD_DIR"

DESKTOPS="gnome kde xfce none"
LOADOUTS="minimal desktop server developer"
FORMATS="iso image"

DESKTOP="${1:-gnome}"
LOADOUT="${2:-desktop}"
FORMAT="${3:-iso}"
CLEAN="${4:-}"
DATE=$(date +%Y%m%d)

usage() {
    echo "Sky1 Linux Build System"
    echo ""
    echo "Usage: $0 <desktop> <loadout> <format> [clean]"
    echo ""
    echo "Desktop choices: $DESKTOPS"
    echo "Package loadouts: $LOADOUTS"
    echo "Output formats: $FORMATS"
    echo ""
    echo "Options:"
    echo "  clean   - Run lb clean --purge before build"
    echo ""
    echo "Examples:"
    echo "  $0 gnome desktop iso       # GNOME desktop ISO (default)"
    echo "  $0 gnome desktop image     # GNOME desktop disk image"
    echo "  $0 kde minimal iso clean   # KDE minimal, clean build"
    echo "  $0 none server image       # Headless server disk image"
    exit 1
}

# Validate parameters
echo "$DESKTOPS" | grep -qw "$DESKTOP" || { echo "Error: Unknown desktop '$DESKTOP'"; usage; }
echo "$LOADOUTS" | grep -qw "$LOADOUT" || { echo "Error: Unknown loadout '$LOADOUT'"; usage; }
echo "$FORMATS" | grep -qw "$FORMAT" || { echo "Error: Unknown format '$FORMAT'"; usage; }

DESKTOP_DIR="desktop-choice/$DESKTOP"
LOADOUT_DIR="package-loadouts/$LOADOUT"

[ -d "$DESKTOP_DIR" ] || { echo "Error: Desktop directory not found: $DESKTOP_DIR"; exit 1; }
[ -d "$LOADOUT_DIR" ] || { echo "Error: Loadout directory not found: $LOADOUT_DIR"; exit 1; }

OUTPUT_NAME="sky1-linux-${DESKTOP}-${LOADOUT}-${DATE}"
CHROOT_DIR="desktop-choice/${DESKTOP}/chroot"

echo "=== Building Sky1 Linux ==="
echo "Desktop: $DESKTOP"
echo "Loadout: $LOADOUT"
echo "Format:  $FORMAT"
echo "Chroot:  $CHROOT_DIR"
echo "Output:  $OUTPUT_NAME.$FORMAT"
echo ""

# Check for root when needed
if [ "$FORMAT" = "image" ] && [ "$(id -u)" -ne 0 ]; then
    echo "Error: Disk image builds require root. Run with sudo."
    exit 1
fi

# Set up desktop-specific chroot
# live-build expects 'chroot/' directory, so we symlink to the desktop-specific one
setup_chroot_symlink() {
    # Remove existing chroot symlink if present
    if [ -L "chroot" ]; then
        rm -f chroot
    fi

    # If chroot exists as a real directory (legacy), warn but don't delete
    if [ -d "chroot" ] && [ ! -L "chroot" ]; then
        echo "Warning: 'chroot' exists as a directory, not a symlink."
        echo "Consider moving it to desktop-choice/<desktop>/chroot for the appropriate desktop."
        echo "Continuing with existing chroot..."
        return
    fi

    # Create symlink to desktop-specific chroot
    if [ -d "$CHROOT_DIR" ]; then
        echo "Using existing chroot: $CHROOT_DIR"
        ln -sf "$CHROOT_DIR" chroot
    else
        echo "Will create new chroot: $CHROOT_DIR"
    fi
}

# Clean if requested
if [ "$CLEAN" = "clean" ]; then
    echo "Cleaning previous build for $DESKTOP..."
    rm -f chroot
    if [ -d "$CHROOT_DIR" ]; then
        sudo rm -rf "$CHROOT_DIR"
    fi
    sudo lb clean --purge 2>/dev/null || true
fi

# Set up the chroot symlink
setup_chroot_symlink

# Apply desktop choice (use copies, not symlinks, so they survive lb clean)
echo "Applying desktop choice: $DESKTOP..."
if [ -f "$DESKTOP_DIR/package-lists/desktop.list.chroot" ]; then
    cp -f "$DESKTOP_DIR/package-lists/desktop.list.chroot" "config/package-lists/desktop.list.chroot"
fi
if [ -f "$DESKTOP_DIR/hooks/live/0450-${DESKTOP}-config.hook.chroot" ]; then
    cp -f "$DESKTOP_DIR/hooks/live/0450-${DESKTOP}-config.hook.chroot" "config/hooks/live/0450-desktop-config.hook.chroot"
fi

# Copy desktop-specific includes (overlay into config/includes.chroot)
if [ -d "$DESKTOP_DIR/includes.chroot" ]; then
    cp -a "$DESKTOP_DIR/includes.chroot/"* config/includes.chroot/ 2>/dev/null || true
fi

# Copy desktop-specific image overlay (for disk image builds)
if [ -d "$DESKTOP_DIR/includes.chroot.image" ]; then
    cp -a "$DESKTOP_DIR/includes.chroot.image/"* config/includes.chroot.image/ 2>/dev/null || true
fi

# Apply package loadout
echo "Applying package loadout: $LOADOUT..."
if [ -f "$LOADOUT_DIR/package-lists/loadout.list.chroot" ]; then
    cp -f "$LOADOUT_DIR/package-lists/loadout.list.chroot" "config/package-lists/loadout.list.chroot"
fi

# After lb build, move chroot to desktop-specific directory
finalize_chroot() {
    # If lb build created a 'chroot' directory (not symlink), move it
    if [ -d "chroot" ] && [ ! -L "chroot" ]; then
        echo "Moving chroot to $CHROOT_DIR..."
        mkdir -p "$(dirname "$CHROOT_DIR")"
        mv chroot "$CHROOT_DIR"
        ln -sf "$CHROOT_DIR" chroot
    fi
}

# Build based on format
if [ "$FORMAT" = "iso" ]; then
    echo ""
    echo "Building ISO with live-build..."
    sudo lb build 2>&1 | tee build.log

    # Finalize chroot naming
    finalize_chroot

    # Find and rename output
    ISO_FILE=$(ls sky1-linux-*.iso 2>/dev/null | grep -v "$OUTPUT_NAME" | head -1)
    if [ -n "$ISO_FILE" ] && [ -f "$ISO_FILE" ]; then
        mv "$ISO_FILE" "$OUTPUT_NAME.iso"
        echo ""
        echo "=== Build Complete ==="
        ls -lh "$OUTPUT_NAME.iso"
    else
        echo ""
        echo "Warning: Expected ISO file not found"
        ls -lh sky1-linux*.iso 2>/dev/null || echo "No ISO files found"
    fi

elif [ "$FORMAT" = "image" ]; then
    # For disk images, we need a chroot first
    if [ ! -d "$CHROOT_DIR" ] && [ ! -d "chroot" ]; then
        echo ""
        echo "No chroot found for $DESKTOP. Building chroot first..."
        sudo lb build 2>&1 | tee build.log

        # Finalize chroot naming
        finalize_chroot
    fi

    # Ensure symlink is correct
    if [ -d "$CHROOT_DIR" ] && [ ! -L "chroot" ]; then
        ln -sf "$CHROOT_DIR" chroot
    fi

    echo ""
    echo "Building disk image..."
    sudo ./scripts/build-image.sh "$DESKTOP" "$LOADOUT"
fi

echo ""
echo "Build finished at $(date)"
