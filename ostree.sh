#!/bin/bash
set -x
set -u
set -e

# [ENVIRONMENT]: REQUIRED
# OSTREE_DEV_SCSI=

# [ENVIRONMENT]: CONFIGURABLE
export OSTREE_DEV_DISK=/dev/disk/by-id/${OSTREE_DEV_SCSI}
export OSTREE_DEV_BOOT=${OSTREE_DEV_DISK}-part1
export OSTREE_DEV_HOME=${OSTREE_DEV_DISK}-part2
export OSTREE_DEV_ROOT=${OSTREE_DEV_DISK}-part3
export OSTREE_SYS_ROOT=/mnt
export OSTREE_SYS_BUILD=/tmp/rootfs

# [DISK]: PARTITIONING (GPT+UEFI)
function DISK_CREATE_LAYOUT {
    pacman --noconfirm --needed -S parted
    umount --lazy --recursive ${OSTREE_SYS_ROOT} || :
    parted -a optimal -s ${OSTREE_DEV_DISK} -- \
        mklabel gpt \
        mkpart "SYS_BOOT" fat32 0% 257MiB \
        set 1 esp on \
        mkpart "SYS_ROOT" ext4 257MiB 25GiB \
        mkpart "SYS_HOME" ext4 25GiB 100%
}

# [DISK]: FILESYSTEM (ESP+EXT4)
function DISK_CREATE_FORMAT {
    pacman --noconfirm --needed -S dosfstools e2fsprogs
    mkfs.vfat -n SYS_BOOT -F 32 ${OSTREE_DEV_BOOT}
    mkfs.ext4 -L SYS_ROOT -F ${OSTREE_DEV_ROOT}
    mkfs.ext4 -L SYS_HOME -F ${OSTREE_DEV_HOME}
}

# [DISK]: WORKDIR
function DISK_CREATE_MOUNTS {
    mount --mkdir ${OSTREE_DEV_ROOT} ${OSTREE_SYS_ROOT}
    mount --mkdir ${OSTREE_DEV_BOOT} ${OSTREE_SYS_ROOT}/boot/efi
}

# [OSTREE]: INITIALIZATION
function OSTREE_CREATE_REPO {
    pacman --noconfirm --needed -S ostree wget which 
    ostree admin init-fs --sysroot=${OSTREE_SYS_ROOT} --modern ${OSTREE_SYS_ROOT}
    ostree admin os-init --sysroot=${OSTREE_SYS_ROOT} archlinux
    ostree init --repo=${OSTREE_SYS_ROOT}/ostree/repo --mode=bare
    ostree config --repo=${OSTREE_SYS_ROOT}/ostree/repo set sysroot.bootprefix 'true'
}

# [OSTREE]: CONTAINER
# | Todo: add persistent Pacman cache
# | Todo: delete /etc in Contailerfile (https://github.com/containers/podman/issues/20001)
# | Todo: use tar format (`podman build -f Containerfile -o dest=${OSTREE_SYS_BUILD}.tar,type=tar`)
function OSTREE_CREATE_IMAGE {
    # Add support for overlay storage driver in LiveCD
    if [[ $(df --output=fstype / | tail -n 1) = "overlay" ]]; then
        pacman --noconfirm --needed -S "fuse-overlayfs"
        export TMPDIR="/tmp/podman"
        PODMAN_ARGS=(
            --root ${TMPDIR}/storage
            --tmpdir ${TMPDIR}/tmp
        )
    fi

    # Create rootfs directory (workaround: `podman build --output local` doesn't preserve ownership)
    pacman --noconfirm --needed -S podman
    podman ${PODMAN_ARGS[@]} build -f Containerfile -t rootfs
    rm -rf ${OSTREE_SYS_BUILD}
    mkdir ${OSTREE_SYS_BUILD}
    podman ${PODMAN_ARGS[@]} export $(podman ${PODMAN_ARGS[@]} create rootfs bash) | tar -xC ${OSTREE_SYS_BUILD}
    rm -rf ${OSTREE_SYS_BUILD}/etc
}

# [OSTREE]: COMMIT
function OSTREE_DEPLOY_IMAGE {
    # Update repository and boot entries in GRUB
    #ostree commit --repo=${OSTREE_SYS_ROOT}/ostree/repo --branch=archlinux/latest --tree=tar=${OSTREE_SYS_BUILD}.tar --tar-autocreate-parents
    ostree commit --repo=${OSTREE_SYS_ROOT}/ostree/repo --branch=archlinux/latest --tree=dir=${OSTREE_SYS_BUILD}
    ostree admin deploy --sysroot=${OSTREE_SYS_ROOT} --karg="root=LABEL=SYS_ROOT" --karg="rw" --os=archlinux --no-merge --retain archlinux/latest
}

# [BOOTLOADER]: FIRST BOOT
# | Todo: improve grub-mkconfig
function BOOTLOADER_CREATE {
    grub-install --target=x86_64-efi --efi-directory=${OSTREE_SYS_ROOT}/boot/efi --removable --boot-directory=${OSTREE_SYS_ROOT}/boot/efi/EFI --bootloader-id=archlinux ${OSTREE_DEV_BOOT}
    
    export OSTREE_SYS_PATH=$(ls -d ${OSTREE_SYS_ROOT}/ostree/deploy/archlinux/deploy/*|head -n 1)
    
    rm -rfv ${OSTREE_SYS_PATH}/boot/*
    mount --mkdir --rbind ${OSTREE_SYS_ROOT}/boot ${OSTREE_SYS_PATH}/boot
    mount --mkdir --rbind ${OSTREE_SYS_ROOT}/ostree ${OSTREE_SYS_PATH}/sysroot/ostree
    
    for i in /dev /proc /sys; do mount -o bind $i ${OSTREE_SYS_PATH}${i}; done
    chroot ${OSTREE_SYS_PATH} /bin/bash -c "grub-mkconfig -o /boot/efi/EFI/grub/grub.cfg"

    umount -R ${OSTREE_SYS_ROOT}
}

# Tasks to perform
DISK_CREATE_LAYOUT
DISK_CREATE_FORMAT
DISK_CREATE_MOUNTS

OSTREE_CREATE_REPO
OSTREE_CREATE_IMAGE
OSTREE_DEPLOY_IMAGE

BOOTLOADER_CREATE
