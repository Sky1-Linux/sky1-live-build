# Sky1 Linux Live Build

Live-build configuration for creating Sky1 Linux live ISOs and installable disk images.

## Requirements

```bash
sudo apt install live-build
```

## Quick Start

```bash
# Build GNOME desktop ISO (default)
./scripts/build.sh gnome desktop iso

# Build GNOME desktop disk image
sudo ./scripts/build.sh gnome desktop image

# Clean build
./scripts/build.sh gnome desktop iso clean
```

## Build Options

```
./scripts/build.sh <desktop> <loadout> <format> [clean]

Desktop:  gnome | kde | xfce | none
Loadout:  minimal | desktop | server | developer
Format:   iso | image
```

### Examples

```bash
# GNOME with full desktop apps
./scripts/build.sh gnome desktop iso

# KDE minimal (no extra apps)
./scripts/build.sh kde minimal iso

# XFCE developer workstation
./scripts/build.sh xfce developer iso

# Headless server disk image
sudo ./scripts/build.sh none server image
```

## Output Files

- **ISO**: `sky1-linux-<desktop>-<loadout>-YYYYMMDD.iso` - Bootable live/installer
- **Disk Image**: `sky1-linux-<desktop>-<loadout>-YYYYMMDD.img.xz` - Direct write to storage

### Writing Disk Images

```bash
# Write to storage device (replace sdX)
xzcat sky1-linux-gnome-desktop-*.img.xz | sudo dd of=/dev/sdX bs=4M status=progress
sync
```

## Project Structure

```
sky1-live-build/
├── scripts/
│   ├── build.sh              # Main build script
│   └── build-image.sh        # Disk image builder
├── desktop-choice/           # Desktop environment configs
│   ├── gnome/
│   │   ├── chroot/           # GNOME-specific chroot (isolated)
│   │   ├── package-lists/    # GNOME packages
│   │   ├── hooks/            # GNOME setup hook
│   │   ├── includes.chroot/  # Live-specific overlay
│   │   └── includes.chroot.image/  # Disk image overlay
│   ├── kde/
│   │   ├── chroot/           # KDE-specific chroot (isolated)
│   │   └── ...
│   ├── xfce/
│   └── none/
├── chroot -> desktop-choice/gnome/chroot  # Symlink to active chroot
├── package-loadouts/         # Package sets
│   ├── minimal/
│   ├── desktop/
│   ├── server/
│   └── developer/
├── config/
│   ├── package-lists/        # Base packages
│   ├── archives/             # APT repos and pinning
│   ├── hooks/live/           # Build-time hooks
│   ├── includes.chroot/      # Live filesystem overlay
│   └── includes.chroot.image/  # Disk image overlay
└── auto/                     # live-build auto scripts
```

## Isolated Chroots

Each desktop environment has its own isolated chroot under `desktop-choice/<desktop>/chroot/`.
This prevents cross-contamination of packages and configurations between desktop environments.

- First build for a desktop creates its chroot via `lb build`
- Subsequent builds reuse the existing desktop-specific chroot
- Use `clean` to force a fresh chroot: `./scripts/build.sh gnome desktop iso clean`
- The top-level `chroot` symlink points to the active desktop's chroot for live-build compatibility

## Architecture

The build system uses **separate overlays** for live ISO and disk image:

1. **Hook** creates neutral base config (no autologin, no skip markers)
2. **For live ISO**: `includes.chroot` overlay adds live settings (autologin, skip wizards)
3. **For disk image**: `includes.chroot.image` overlay replaces live settings (no autologin, run setup wizard)

This avoids having to undo live-specific settings when building disk images.

## Features

- ARM64 UEFI boot with patched GRUB
- Multiple desktop environments (GNOME, KDE, XFCE)
- Automatic first-boot configuration (partition expansion, user setup)
- Hardware-accelerated video (V4L2M2M, AV1)
- Pre-built DKMS modules (r8126, VPU)
- Mesa pinned for Panthor stability

## Clean Rebuilds

When switching between desktops or recovering from build failures, a clean rebuild may be needed.

### Full clean rebuild (single desktop)

```bash
# Remove desktop-specific chroot and rebuild
./scripts/build.sh gnome desktop iso clean
```

### Manual deep clean (all artifacts)

```bash
# Remove all build artifacts
sudo rm -rf chroot binary .build cache
sudo lb clean --purge

# Remove a specific desktop's chroot
sudo rm -rf desktop-choice/gnome/chroot

# Start fresh
./scripts/build.sh gnome desktop iso
```

### When to clean rebuild

- After updating kernel packages in the APT repo
- When build fails mid-way and leaves corrupted state
- When switching between very different configurations
- If you see "Directory nonexistent" or mount errors

## Kernel Meta Packages

The build uses `linux-image-sky1` and `linux-headers-sky1` meta packages that automatically
pull the latest stable kernel. No manual version updates needed in config files.

When a new kernel is released:
1. Kernel packages are uploaded to APT repo with updated meta packages
2. Existing chroots can be updated: `sudo chroot desktop-choice/gnome/chroot apt-get update && apt-get dist-upgrade`
3. Or do a clean rebuild to get everything fresh

## Customization

- **Add packages**: Edit `package-loadouts/<loadout>/package-lists/loadout.list.chroot`
- **Desktop tweaks**: Edit `desktop-choice/<desktop>/hooks/live/0450-*-config.hook.chroot`
- **APT pinning**: Edit `config/archives/*.pref.chroot`
