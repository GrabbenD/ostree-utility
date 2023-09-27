#!/bin/bash
set -x
set -u
set -e

# [ENVIRONMENT]: OVERRIDE DEFAULTS
function ENV_CREATE_OPTS {
    if [[ ! -d "/ostree" ]]; then
        # Do not touch disks in a booted system:
        export OSTREE_DEV_DISK=${OSTREE_DEV_DISK:="/dev/disk/by-id/${OSTREE_DEV_SCSI}"}
        export OSTREE_DEV_BOOT=${OSTREE_DEV_BOOT:="${OSTREE_DEV_DISK}-part1"}
        export OSTREE_DEV_ROOT=${OSTREE_DEV_ROOT:="${OSTREE_DEV_DISK}-part2"}
        export OSTREE_DEV_HOME=${OSTREE_DEV_HOME:="${OSTREE_DEV_DISK}-part3"}
        export OSTREE_SYS_ROOT=${OSTREE_SYS_ROOT:="/mnt"}
    fi

    export OSTREE_SYS_ROOT=${OSTREE_SYS_ROOT:="/"}
    export OSTREE_SYS_BUILD=${OSTREE_SYS_BUILD:="/tmp/rootfs"}
    export OSTREE_SYS_BOOT_LABEL=${OSTREE_SYS_BOOT_LABEL:="SYS_BOOT"}
    export OSTREE_SYS_ROOT_LABEL=${OSTREE_SYS_ROOT_LABEL:="SYS_ROOT"}
    export OSTREE_SYS_HOME_LABEL=${OSTREE_SYS_HOME_LABEL:="SYS_HOME"}
    export OSTREE_OPT_NOMERGE=(${OSTREE_OPT_NOMERGE="--no-merge"})

    if [[ -n ${SYSTEM_OPT_TIMEZONE:-} ]]; then
        # Do not modify host's time unless explicitly specified
        timedatectl set-timezone ${SYSTEM_OPT_TIMEZONE}
        timedatectl set-ntp true
    fi
    export SYSTEM_OPT_TIMEZONE=${SYSTEM_OPT_TIMEZONE:="Etc/UTC"}
    export PODMAN_OPT_BUILDFILE=${PODMAN_OPT_BUILDFILE:="$(dirname $0)/Containerfile.base.archlinux:ostree/base,$(dirname $0)/Containerfile.host.example:ostree/host"}
}

# [ENVIRONMENT]: INSTALL DEPENDENCIES
# | Todo: add persistent Pacman cache
function ENV_CREATE_DEPS {
    # Skip in OSTree as filesystem is read-only
    if ! grep -q ostree /proc/cmdline; then
        pacman --noconfirm --needed -S $@
    fi
}

# [ENVIRONMENT]: OSTREE CHECK
function ENV_VERIFY_LOCAL {
    if [[ ! -d "/ostree" ]]; then
        exit 1
    fi
}

# [DISK]: PARTITIONING (GPT+UEFI)
function DISK_CREATE_LAYOUT {
    ENV_CREATE_DEPS parted
    umount --lazy --recursive ${OSTREE_DEV_DISK}-part* ${OSTREE_SYS_ROOT} || :
    parted -a optimal -s ${OSTREE_DEV_DISK} -- \
        mklabel gpt \
        mkpart ${OSTREE_SYS_BOOT_LABEL} fat32 0% 257MiB \
        set 1 esp on \
        mkpart ${OSTREE_SYS_ROOT_LABEL} xfs 257MiB 25GiB \
        mkpart ${OSTREE_SYS_HOME_LABEL} xfs 25GiB 100%
}

# [DISK]: FILESYSTEM (ESP+XFS)
function DISK_CREATE_FORMAT {
    ENV_CREATE_DEPS dosfstools xfsprogs
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
    ENV_CREATE_DEPS ostree wget which
    ostree admin init-fs --sysroot=${OSTREE_SYS_ROOT} --modern ${OSTREE_SYS_ROOT}
    ostree admin stateroot-init --sysroot=${OSTREE_SYS_ROOT} archlinux
    ostree init --repo=${OSTREE_SYS_ROOT}/ostree/repo --mode=bare
    ostree config --repo=${OSTREE_SYS_ROOT}/ostree/repo set sysroot.bootprefix "true"
}

# [OSTREE]: CONTAINER
function OSTREE_CREATE_IMAGE {
    # Podman: add support for overlay storage driver in LiveCD
    if [[ $(df --output=fstype / | tail -n 1) = "overlay" ]]; then
        ENV_CREATE_DEPS fuse-overlayfs
        export TMPDIR="/tmp/podman"
        export PODMAN_OPT_GLOBAL=(
            --root="${TMPDIR}/storage"
            --tmpdir="${TMPDIR}/tmp"
        )
    fi

    # Podman: create rootfs from multiple Containerfiles (workaround: `podman build --output local` doesn't preserve ownership)
    ENV_CREATE_DEPS podman
    for TARGET in ${PODMAN_OPT_BUILDFILE//,/ }; do
        export PODMAN_OPT_IMG=(${TARGET%:*})
        export PODMAN_OPT_TAG=(${TARGET#*:})
        podman ${PODMAN_OPT_GLOBAL[@]} build \
            --file="${PODMAN_OPT_IMG}" \
            --tag="${PODMAN_OPT_TAG}" \
            --build-arg="OSTREE_SYS_BOOT_LABEL=${OSTREE_SYS_BOOT_LABEL}" \
            --build-arg="OSTREE_SYS_HOME_LABEL=${OSTREE_SYS_HOME_LABEL}" \
            --build-arg="OSTREE_SYS_ROOT_LABEL=${OSTREE_SYS_ROOT_LABEL}" \
            --build-arg="SYSTEM_OPT_TIMEZONE=${SYSTEM_OPT_TIMEZONE}" \
            --pull="newer"
    done

    # Ostreeify: retrieve rootfs
    rm -rf ${OSTREE_SYS_BUILD}
    mkdir ${OSTREE_SYS_BUILD}
    podman ${PODMAN_OPT_GLOBAL[@]} export $(podman ${PODMAN_OPT_GLOBAL[@]} create ${PODMAN_OPT_TAG} bash) | tar -xC ${OSTREE_SYS_BUILD}

    # Ostreeify: Prepare microcode and initramfs
    moduledir=$(find ${OSTREE_SYS_BUILD}/usr/lib/modules -mindepth 1 -maxdepth 1 -type d)
    cat ${OSTREE_SYS_BUILD}/boot/*-ucode.img \
        ${OSTREE_SYS_BUILD}/boot/initramfs-linux-fallback.img \
        > ${moduledir}/initramfs.img

    # Ostreeify: Move Pacman database
    mv ${OSTREE_SYS_BUILD}/var/lib/pacman ${OSTREE_SYS_BUILD}/usr/lib/
    sed -i \
        -e "s|^#\(DBPath\s*=\s*\).*|\1/usr/lib/pacman|g" \
        -e "s|^#\(IgnoreGroup\s*=\s*\).*|\1modified|g" \
        ${OSTREE_SYS_BUILD}/etc/pacman.conf

    # Ostreeify: directory layout (https://ostree.readthedocs.io/en/stable/manual/adapting-existing)
    mv ${OSTREE_SYS_BUILD}/etc ${OSTREE_SYS_BUILD}/usr/

    rm -r ${OSTREE_SYS_BUILD}/home
    ln -s var/home ${OSTREE_SYS_BUILD}/home

    rm -r ${OSTREE_SYS_BUILD}/mnt
    ln -s var/mnt ${OSTREE_SYS_BUILD}/mnt

    rm -r ${OSTREE_SYS_BUILD}/opt
    ln -s var/opt ${OSTREE_SYS_BUILD}/opt

    rm -r ${OSTREE_SYS_BUILD}/root
    ln -s var/roothome ${OSTREE_SYS_BUILD}/root

    rm -r ${OSTREE_SYS_BUILD}/srv
    ln -s var/srv ${OSTREE_SYS_BUILD}/srv

    mkdir ${OSTREE_SYS_BUILD}/sysroot
    ln -s sysroot/ostree ${OSTREE_SYS_BUILD}/ostree

    rm -r ${OSTREE_SYS_BUILD}/usr/local
    ln -s var/usrlocal ${OSTREE_SYS_BUILD}/usr/local

    # Todo: pacman cache (/var/cache/pacman/pkg)
    rm -r ${OSTREE_SYS_BUILD}/var/*

    echo "Creating tmpfiles"
    echo "L /var/home - - - - ../sysroot/home" >> ${OSTREE_SYS_BUILD}/usr/lib/tmpfiles.d/ostree-0-integration.conf
    echo "d /var/log/journal 0755 root root -" >> ${OSTREE_SYS_BUILD}/usr/lib/tmpfiles.d/ostree-0-integration.conf
    echo "d /var/mnt 0755 root root -" >> ${OSTREE_SYS_BUILD}/usr/lib/tmpfiles.d/ostree-0-integration.conf
    echo "d /var/opt 0755 root root -" >> ${OSTREE_SYS_BUILD}/usr/lib/tmpfiles.d/ostree-0-integration.conf
    echo "d /var/roothome 0700 root root -" >> ${OSTREE_SYS_BUILD}/usr/lib/tmpfiles.d/ostree-0-integration.conf
    echo "d /run/media 0755 root root -" >> ${OSTREE_SYS_BUILD}/usr/lib/tmpfiles.d/ostree-0-integration.conf
    echo "d /var/srv 0755 root root -" >> ${OSTREE_SYS_BUILD}/usr/lib/tmpfiles.d/ostree-0-integration.conf
    echo "d /var/usrlocal 0755 root root -" >> ${OSTREE_SYS_BUILD}/usr/lib/tmpfiles.d/ostree-0-integration.conf
    echo "d /var/usrlocal/bin 0755 root root -" >> ${OSTREE_SYS_BUILD}/usr/lib/tmpfiles.d/ostree-0-integration.conf
    echo "d /var/usrlocal/etc 0755 root root -" >> ${OSTREE_SYS_BUILD}/usr/lib/tmpfiles.d/ostree-0-integration.conf
    echo "d /var/usrlocal/games 0755 root root -" >> ${OSTREE_SYS_BUILD}/usr/lib/tmpfiles.d/ostree-0-integration.conf
    echo "d /var/usrlocal/include 0755 root root -" >> ${OSTREE_SYS_BUILD}/usr/lib/tmpfiles.d/ostree-0-integration.conf
    echo "d /var/usrlocal/lib 0755 root root -" >> ${OSTREE_SYS_BUILD}/usr/lib/tmpfiles.d/ostree-0-integration.conf
    echo "d /var/usrlocal/man 0755 root root -" >> ${OSTREE_SYS_BUILD}/usr/lib/tmpfiles.d/ostree-0-integration.conf
    echo "d /var/usrlocal/sbin 0755 root root -" >> ${OSTREE_SYS_BUILD}/usr/lib/tmpfiles.d/ostree-0-integration.conf
    echo "d /var/usrlocal/share 0755 root root -" >> ${OSTREE_SYS_BUILD}/usr/lib/tmpfiles.d/ostree-0-integration.conf
    echo "d /var/usrlocal/src 0755 root root -" >> ${OSTREE_SYS_BUILD}/usr/lib/tmpfiles.d/ostree-0-integration.conf
}

# [OSTREE]: COMMIT
function OSTREE_DEPLOY_IMAGE {
    # Update repository and boot entries in GRUB2
    ostree commit --repo=${OSTREE_SYS_ROOT}/ostree/repo --branch=archlinux/latest --tree=dir=${OSTREE_SYS_BUILD}
    ostree admin deploy --sysroot=${OSTREE_SYS_ROOT} --karg="root=LABEL=SYS_ROOT" --karg="rw" --os=archlinux --retain archlinux/latest ${OSTREE_OPT_NOMERGE[@]}
}

# [OSTREE]: UNDO
function OSTREE_REVERT_IMAGE {
    ostree admin undeploy --sysroot=${OSTREE_SYS_ROOT} 0
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
argument=${1:-}

# Options
while [[ ${#} -gt 1 ]]; do
    case ${2} in
        -d|--dev)
            export OSTREE_DEV_SCSI=${3}
            shift 2 # Get value
        ;;

        -f|--file)
            export PODMAN_OPT_BUILDFILE=${3}
            shift 2 # Get value
        ;;

        -m|--merge)
            export OSTREE_OPT_NOMERGE=""
            shift 1 # Finish
        ;;

        -t|--time)
            export SYSTEM_OPT_TIMEZONE=${3}
            shift 2 # Get value
        ;;

        *)
            printf '%s\n' "Unknown option: ${2}"
            exit 2
        ;;
    esac
done

# Argument
case ${argument} in
    install)
        ENV_CREATE_OPTS

        DISK_CREATE_LAYOUT
        DISK_CREATE_FORMAT
        DISK_CREATE_MOUNTS

        OSTREE_CREATE_REPO
        OSTREE_CREATE_IMAGE
        OSTREE_DEPLOY_IMAGE

        BOOTLOADER_CREATE
    ;;

    upgrade)
        ENV_VERIFY_LOCAL
        ENV_CREATE_OPTS

        OSTREE_CREATE_IMAGE
        OSTREE_DEPLOY_IMAGE
    ;;

    revert)
        ENV_VERIFY_LOCAL
        ENV_CREATE_OPTS

        OSTREE_REVERT_IMAGE
    ;;

    *)
        help=(
            "Usage:"
            "  ostree.sh [command] [options]"
            "Commands:"
            "  install : (Create deployment) : Partitions, formats and initializes a new OSTree repository."
            "  upgrade : (Update deployment) : Creates a new OSTree commit."
            "  revert  : (Update deployment) : Rolls back version 0."
            "Options:"
            "  -d, --dev  string      : (install)         : Device SCSI (ID-LINK) for new installation."
            "  -f, --file stringArray : (install/upgrade) : Containerfile(s) for new deployment."
            "  -m, --merge            : (upgrade)         : Retain contents of /etc for existing deployment."
            "  -t, --time             : (install/upgrade) : Update host's timezone for new deployment."
        )
        printf '%s\n' "${help[@]}"
    ;;
esac
