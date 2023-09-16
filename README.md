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
   NAME   TYPE FSTYPE   MODEL           ID-LINK                                                  SIZE MOUNTPOINTS           LABEL
   sda    disk          Virtual Disk    scsi-36002248069ffe44474a7a01ecf21298b                   127G
   ├─sda1 part vfat                     scsi-36002248069ffe44474a7a01ecf21298b-part1             256M                       SYS_BOOT
   ├─sda2 part ext4                     scsi-36002248069ffe44474a7a01ecf21298b-part2              95G                       SYS_HOME
   └─sda3 part ext4                     scsi-36002248069ffe44474a7a01ecf21298b-part3            31.7G                       SYS_ROOT
   ```
   
4. **Perform clean installation:**
   
   **⚠️ WARNING ⚠️**
   
   `install.sh` is destrucive and has no promps while partitioning, proceed with caution:
   
   ```console
   $ chmod +x install.sh
   $ sudo OSTREE_DEV_SCSI=scsi-36002248069ffe44474a7a01ecf21298b ./install.sh
   ```
