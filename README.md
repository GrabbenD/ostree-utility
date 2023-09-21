# OSTree in Arch Linux using Podman

Massive shoutout to [M1cha](https://github.com/M1cha/) for making this possible ([M1cha/archlinux-ostree](https://github.com/M1cha/archlinux-ostree)).

## Overview

This serves to demonstrate how to:
1. Build an immutable OSTree image using rootfs from a Podman Containerfile.
2. Partition and prepare UEFI/GPT disks for a minimal OSTree host system.
3. Generate OSTree repository in a empty filesystem.
4. Integrate OSTree with GRUB2 bootloader.
5. Upgrade an existing OSTree repository with a new rootfs image.

### Disk structure

```console
├── boot
│   └── efi
└── ostree
    ├── deploy
    │   └── archlinux
    └── repo
        ├── config
        ├── extensions
        ├── objects
        ├── refs
        ├── state
        └── tmp
```

### Motivation

I needed a approach which provides:
- Reproducible deployments
- Versioned rollbacks
- Immutable filesystem
- Distribution agnostic toolset
- Configuration management
- Rootfs creation via containers
- Each deployment does a factory reset of system files (unless overridden)

### Similar projects

- **[Elemental Toolkit](https://github.com/rancher/elemental-toolkit)**
- **[KairOS](https://github.com/kairos-io/kairos)**
- **[BootC](https://github.com/containers/bootc)**
- [NixOS](https://nixos.org)
- [ABRoot](https://github.com/Vanilla-OS/ABRoot)
- [Transactional Update + BTRFS snapshots](https://microos.opensuse.org)
- [AshOS](https://github.com/ashos/ashos)
- [LinuxKit](https://github.com/linuxkit/linuxkit)

# Usage

1. **Boot into any Arch Linux system:**

   For instance, using a live CD/USB ISO image from: [Arch Linux Downloads](https://archlinux.org/download).

2. **Clone this repository:**

   ```console
   $ sudo pacman -Sy git
   $ git https://github.com/GrabbenD/ostree-demo.git && cd ostree-demo
   ```

3. **Find `ID-LINK` for installation device where OSTree image will be deployed:**

   ```console
   $ lsblk -o NAME,TYPE,FSTYPE,MODEL,ID-LINK,SIZE,MOUNTPOINTS,LABEL
   NAME   TYPE FSTYPE MODEL        ID-LINK                                        SIZE MOUNTPOINTS LABEL
   sdb    disk        Virtual Disk scsi-360022480c22be84f8a61b39bbaed612f         300G
   ├─sdb1 part vfat                scsi-360022480c22be84f8a61b39bbaed612f-part1   256M             SYS_BOOT
   ├─sdb2 part xfs                 scsi-360022480c22be84f8a61b39bbaed612f-part2  24.7G             SYS_ROOT
   └─sdb3 part xfs                 scsi-360022480c22be84f8a61b39bbaed612f-part3   275G             SYS_HOME
   ```

4. **Perform a takeover installation:**

   **⚠️ WARNING ⚠️**

   `ostree.sh` is destrucive and has no promps while partitioning the specified disk, **proceed with caution**:

   ```console
   $ chmod +x ostree.sh
   $ sudo ./ostree.sh install --dev scsi-360022480c22be84f8a61b39bbaed612f
   ```

   💡 Update your BIOS boot order to access the installation.

   💡 Default login is: `root` / `ostree`

5. **Upgrade an existing installation:**

   While booted into a OSTree system, use:

   ```console
   $ sudo ./ostree.sh upgrade
   ```

   💡 Use `--merge` option to preserve contents of `/etc`

6. **Revert to previous commit:**

   ```console
   $ sudo ./ostree.sh revert
   ```
