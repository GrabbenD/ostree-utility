# OSTree container in Arch Linux using Podman

Massive shoutout to @M1cha for making this possible (https://github.com/M1cha/archlinux-ostree)

# Overview

This serves to demonstrates how to:
1. Build a immutable OSTree image using rootfs from a declerative Podman Containerfile
2. Partition and prepare UEFI/GPT disks for a minimal OSTree host system
3. Generate OSTree repository in a empty filesystem
4. Integrate OSTree with GRUB2 bootloader

# Usage

1. **Boot into a Arch Linux system:**
   
   For instance, using a live CD/USB ISO image from: https://archlinux.org/download/
   
2. **Clone this repository to obtain install script:**
   
   ```console
   $ sudo pacman -Sy git
   $ git https://github.com/GrabbenD/ostree-demo.git && cd ostree-demo
   ```
   
3. **Find `ID-LINK` for installation device where OSTree image will be deployed:**
   
   ```console
   lsblk -o NAME,TYPE,FSTYPE,MODEL,ID-LINK,SIZE,MOUNTPOINTS,LABEL
   NAME   TYPE FSTYPE MODEL        ID-LINK                                        SIZE MOUNTPOINTS LABEL
   sdb    disk        Virtual Disk scsi-360022480c22be84f8a61b39bbaed612f         300G
   ├─sdb1 part vfat                scsi-360022480c22be84f8a61b39bbaed612f-part1   256M             SYS_BOOT
   ├─sdb2 part ext4                scsi-360022480c22be84f8a61b39bbaed612f-part2  24.7G             SYS_HOME
   └─sdb3 part ext4                scsi-360022480c22be84f8a61b39bbaed612f-part3   275G             SYS_ROOT
   ```
   
4. **Perform clean installation:**
   
   **⚠️ WARNING ⚠️**
   
   `install.sh` is destrucive and has no promps while partitioning, proceed with caution:
   
   ```console
   $ chmod +x install.sh
   $ sudo OSTREE_DEV_SCSI=scsi-360022480c22be84f8a61b39bbaed612f ./install.sh
   ```
