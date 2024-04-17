## OSTree in Arch Linux using Podman

Massive shout-out to [M1cha](https://github.com/M1cha/) for making this possible ([M1cha/archlinux-ostree](https://github.com/M1cha/archlinux-ostree)).

### Overview

This is a helper script which aids in curating your own setup by demonstrating how to:
1. Build an immutable OSTree image by using rootfs from a Podman Containerfile.
2. Partition and prepare UEFI/GPT disks for a minimal OSTree host system.
3. Generate OSTree repository in a empty filesystem.
4. Integrate OSTree with GRUB2 bootloader.
5. Upgrade an existing OSTree repository with a new rootfs image.

### Disk structure

```console
/
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

### Persistence

Everything is deleted between deployments **except** for:
- `/dev` partitions which OSTree does not reside on are untouched.
- `/etc` only if `--merge` option is specified.
- `/home` is symlinked to `/var/home` (see below).
- `/var` data here is mounted from `/ostree/deploy/archlinux/var` to avoid duplication.

Notes:
- `/var/cache/podman` is populated _only_ after the first deployment (to avoid including old data from the build machine), this speeds up consecutive builds.
- `/var/lib/containers` same as above but for Podman layers and images. Base images are updated automatically during `upgrade` command.

### Technology stack

- OSTree
- Podman with CRUN and Native-Overlayfs
- GRUB2
- XFS _(not required)_

### Motivation

My vision is to build a secure and minimal base system which is resilient against breakage and provides setup automation to reduce the burden of doing manual tasks. This can be achieved by:

- Git.
- Read-only system files.
- Restore points.
- Automatic deployment, installation & configuration.
- Using only required components like kernel/firmware/driver, microcode and GGC in the base.
- Doing the rest in temporary namespaces such as Podman.

### Goal

- Reproducible deployments.
- Versioned rollbacks.
- Immutable filesystem.
- Distribution agnostic toolset.
- Configuration management.
- Rootfs creation via containers.
- Each deployment does a factory reset of system's configuration _(unless overridden)_.

### Similar projects

- **[Elemental Toolkit](https://github.com/rancher/elemental-toolkit)**
- **[KairOS](https://github.com/kairos-io/kairos)**
- **[BootC](https://github.com/containers/bootc)**
- [NixOS](https://nixos.org)
- [ABRoot](https://github.com/Vanilla-OS/ABRoot)
- [Transactional Update + BTRFS snapshots](https://microos.opensuse.org)
- [AshOS](https://github.com/ashos/ashos)
- [LinuxKit](https://github.com/linuxkit/linuxkit)

## Usage

1. **Boot into any Arch Linux system:**

   For instance, using a live CD/USB ISO image from: [Arch Linux Downloads](https://archlinux.org/download).

2. **Clone this repository:**

   ```console
   $ sudo pacman -Sy git
   $ git clone https://github.com/GrabbenD/ostree-utility.git && cd ostree-utility
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

   `ostree.sh` is destructive and has no prompts while partitioning the specified disk, **proceed with caution**:

   ```console
   $ chmod +x ostree.sh
   $ sudo ./ostree.sh install --dev scsi-360022480c22be84f8a61b39bbaed612f
   ```

   ⚙️ Update your BIOS boot order to access the installation.

   💡 Default login is: `root` / `ostree`

   💡 Use different Containerfile(s) with `--file FILE1:TAG1,FILE2:TAG2` option

5. **Upgrade an existing installation:**

   While booted into a OSTree system, use:

   ```console
   $ sudo ./ostree.sh upgrade
   ```

   💡 Use `--merge` option to preserve contents of `/etc`

6. **Revert to previous commit:**

   To undo the latest deployment _(0)_; boot into the previous configuration _(1)_ and execute:

   ```console
   $ sudo ./ostree.sh revert
   ```

## Tips

### Read-only

This attribute can be temporarily removed with Overlay filesystem which allows you to modify read-only paths without persisting the changes:

```console
$ ostree admin unlock
```

### Outdated repository cache

> `error: failed retrieving file '{name}.pkg.tar.zst' from {source} : The requested URL returned error: 404`

Your persistent cache is out of sync with upstream, this can be resolved with:

```console
$ ./ostree.sh upgrade --no-podman-cache
```
