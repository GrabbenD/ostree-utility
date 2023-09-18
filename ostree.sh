#!/bin/bash
set -x
set -u
set -e

# [ENVIRONMENT]: OPTIONS
function ENV_OPTS_CREATE {
    # Required
    # - OSTREE_DEV_SCSI (for install)

    # Configurable
    export OSTREE_DEV_DISK=${OSTREE_DEV_DISK:=/dev/disk/by-id/${OSTREE_DEV_SCSI}}
    export OSTREE_DEV_BOOT=${OSTREE_DEV_BOOT:=${OSTREE_DEV_DISK}-part1}
    export OSTREE_DEV_ROOT=${OSTREE_DEV_ROOT:=${OSTREE_DEV_DISK}-part2}
    export OSTREE_DEV_HOME=${OSTREE_DEV_HOME:=${OSTREE_DEV_DISK}-part3}

    export OSTREE_SYS_BOOT_LABEL=${OSTREE_SYS_BOOT_LABEL:=SYS_BOOT}
    export OSTREE_SYS_ROOT_LABEL=${OSTREE_SYS_ROOT_LABEL:=SYS_ROOT}
    export OSTREE_SYS_HOME_LABEL=${OSTREE_SYS_HOME_LABEL:=SYS_HOME}

    export OSTREE_SYS_ROOT=${OSTREE_SYS_ROOT:=/mnt}
    export OSTREE_SYS_BUILD=${OSTREE_SYS_BUILD:=/tmp/rootfs}

    export SCRIPT_DIRECTORY=$(dirname "$0")
}

# [ENVIRONMENT]: DEPENDENCIES
# | Todo: add persistent Pacman cache
function ENV_DEPS_CREATE {
    # Skip in OSTree as filesystem is read-only
    if ! grep -q ostree /proc/cmdline; then
        pacman --noconfirm --needed -S $@
    fi
}

# [DISK]: PARTITIONING (GPT+UEFI)
function DISK_CREATE_LAYOUT {
    ENV_DEPS_CREATE parted
    umount --lazy --recursive ${OSTREE_SYS_ROOT} || :
    parted -a optimal -s ${OSTREE_DEV_DISK} -- \
        mklabel gpt \
        mkpart ${OSTREE_SYS_BOOT_LABEL} fat32 0% 257MiB \
        set 1 esp on \
        mkpart ${OSTREE_SYS_ROOT_LABEL} xfs 257MiB 25GiB \
        mkpart ${OSTREE_SYS_HOME_LABEL} xfs 25GiB 100%
}

# [DISK]: FILESYSTEM (ESP+XFS)
function DISK_CREATE_FORMAT {
    ENV_DEPS_CREATE dosfstools xfsprogs
    mkfs.vfat -n ${OSTREE_SYS_BOOT_LABEL} -F 32 ${OSTREE_DEV_BOOT}
    mkfs.xfs -L ${OSTREE_SYS_ROOT_LABEL} -f ${OSTREE_DEV_ROOT} -n ftype=1
    mkfs.xfs -L ${OSTREE_SYS_HOME_LABEL} -f ${OSTREE_DEV_HOME} -n ftype=1
}

# [DISK]: WORKDIR
function DISK_CREATE_MOUNTS {
    mount --mkdir ${OSTREE_DEV_ROOT} ${OSTREE_SYS_ROOT}
    mount --mkdir ${OSTREE_DEV_BOOT} ${OSTREE_SYS_ROOT}/boot/efi
}

# [OSTREE]: INITIALIZATION
function OSTREE_CREATE_REPO {
    ENV_DEPS_CREATE ostree wget which 
    ostree admin init-fs --sysroot=${OSTREE_SYS_ROOT} --modern ${OSTREE_SYS_ROOT}
    ostree admin stateroot-init --sysroot=${OSTREE_SYS_ROOT} archlinux
    ostree init --repo=${OSTREE_SYS_ROOT}/ostree/repo --mode=bare
    ostree config --repo=${OSTREE_SYS_ROOT}/ostree/repo set sysroot.bootprefix 'true'
}

# [OSTREE]: CONTAINER
# | Todo: delete /etc in Containerfile (https://github.com/containers/podman/issues/20001)
# | Todo: use tar format (`podman build -f Containerfile -o dest=${OSTREE_SYS_BUILD}.tar,type=tar`)
function OSTREE_CREATE_IMAGE {
    # Add support for overlay storage driver in LiveCD
    if [[ $(df --output=fstype / | tail -n 1) = "overlay" ]]; then
        ENV_DEPS_CREATE fuse-overlayfs
        export TMPDIR="/tmp/podman"
        PODMAN_ARGS=(
            --root ${TMPDIR}/storage
            --tmpdir ${TMPDIR}/tmp
        )
    fi

    # Create rootfs directory (workaround: `podman build --output local` doesn't preserve ownership)
    ENV_DEPS_CREATE podman
    podman ${PODMAN_ARGS[@]} build \
        -f ${SCRIPT_DIRECTORY}/Containerfile \
        -t rootfs \
        --build-arg OSTREE_SYS_BOOT_LABEL=${OSTREE_SYS_BOOT_LABEL} \
        --build-arg OSTREE_SYS_HOME_LABEL=${OSTREE_SYS_HOME_LABEL} \
        --build-arg OSTREE_SYS_ROOT_LABEL=${OSTREE_SYS_ROOT_LABEL}
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
    
    export OSTREE_SYS_PATH=$(ls -d ${OSTREE_SYS_ROOT}/ostree/deploy/archlinux/deploy/* | head -n 1)
    
    rm -rfv ${OSTREE_SYS_PATH}/boot/*
    mount --mkdir --rbind ${OSTREE_SYS_ROOT}/boot ${OSTREE_SYS_PATH}/boot
    mount --mkdir --rbind ${OSTREE_SYS_ROOT}/ostree ${OSTREE_SYS_PATH}/sysroot/ostree
    
    for i in /dev /proc /sys; do mount -o bind $i ${OSTREE_SYS_PATH}${i}; done
    chroot ${OSTREE_SYS_PATH} /bin/bash -c "grub-mkconfig -o /boot/efi/EFI/grub/grub.cfg"

    umount -R ${OSTREE_SYS_ROOT}
}

# [CLI]: TASKS FINECONTROL
case ${1:-} in
    "install")
        ENV_OPTS_CREATE

        DISK_CREATE_LAYOUT
        DISK_CREATE_FORMAT
        DISK_CREATE_MOUNTS

        OSTREE_CREATE_REPO
        OSTREE_CREATE_IMAGE
        OSTREE_DEPLOY_IMAGE

        BOOTLOADER_CREATE
        ;;

    "upgrade")
        if [[ ! -d "/ostree" ]]; then
            exit 0
        fi

        export OSTREE_DEV_SCSI=
        export OSTREE_SYS_ROOT=/
        ENV_OPTS_CREATE

        OSTREE_CREATE_IMAGE
        OSTREE_DEPLOY_IMAGE
        ;;

    *)
        echo "Usage: ostree.sh [install|upgrade]"
        ;;
esac
