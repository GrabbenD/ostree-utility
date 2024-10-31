#!/usr/bin/env bash
set -o errexit # Exit on non-zero status
set -o nounset # Error on unset variables

# [ENVIRONMENT]: OVERRIDE DEFAULTS
function ENV_CREATE_OPTS {
    if [[ ${CLI_QUIET:-} != 1 ]]; then
        set -o xtrace # Print executed commands while performing tasks
    fi

    if [[ ! -d '/ostree' ]]; then
        # Do not touch disks in a booted system:
        declare -g OSTREE_DEV_DISK=${OSTREE_DEV_DISK:="/dev/disk/by-id/${OSTREE_DEV_SCSI}"}
        declare -g OSTREE_DEV_BOOT=${OSTREE_DEV_BOOT:="${OSTREE_DEV_DISK}-part1"}
        declare -g OSTREE_DEV_ROOT=${OSTREE_DEV_ROOT:="${OSTREE_DEV_DISK}-part2"}
        declare -g OSTREE_DEV_HOME=${OSTREE_DEV_HOME:="${OSTREE_DEV_DISK}-part3"}
        declare -g OSTREE_SYS_ROOT=${OSTREE_SYS_ROOT:='/tmp/chroot'}
    fi

    declare -g OSTREE_SYS_ROOT=${OSTREE_SYS_ROOT:='/'}
    declare -g OSTREE_SYS_TREE=${OSTREE_SYS_TREE:='/tmp/rootfs'}
    declare -g OSTREE_SYS_KARG=${OSTREE_SYS_KARG:=''}
    declare -g OSTREE_SYS_BOOT_LABEL=${OSTREE_SYS_BOOT_LABEL:='SYS_BOOT'}
    declare -g OSTREE_SYS_ROOT_LABEL=${OSTREE_SYS_ROOT_LABEL:='SYS_ROOT'}
    declare -g OSTREE_SYS_HOME_LABEL=${OSTREE_SYS_HOME_LABEL:='SYS_HOME'}
    declare -g OSTREE_OPT_NOMERGE=${OSTREE_OPT_NOMERGE='--no-merge'}
    declare -g OSTREE_REP_NAME=${OSTREE_REP_NAME:='archlinux'}

    if [[ -n ${SYSTEM_OPT_TIMEZONE:-} ]]; then
        # Do not modify host's time unless explicitly specified
        timedatectl set-timezone ${SYSTEM_OPT_TIMEZONE}
        timedatectl set-ntp 1
    fi
    declare -g SYSTEM_OPT_TIMEZONE=${SYSTEM_OPT_TIMEZONE:='Etc/UTC'}
    declare -g SYSTEM_OPT_KEYMAP=${SYSTEM_OPT_KEYMAP:='us'}

    declare -g PODMAN_OPT_BUILDFILE=${PODMAN_OPT_BUILDFILE:="${0%/*}/archlinux/Containerfile.base:ostree/base","${0%/*}/Containerfile.host.example:ostree/host"}
    declare -g PODMAN_OPT_NOCACHE=${PODMAN_OPT_NOCACHE:='0'}
    declare -g PACMAN_OPT_NOCACHE=${PACMAN_OPT_NOCACHE:='0'}
}


# [ENVIRONMENT]: OSTREE CHECK
function ENV_VERIFY_LOCAL {
    if [[ ! -d '/ostree' ]]; then
        printf >&2 '\e[31m%s\e[0m\n' 'OSTree could not be found in: /ostree'
        return 1
    fi
}

# [ENVIRONMENT]: BUILD DEPENDENCIES
function ENV_CREATE_DEPS {
    # Skip in OSTree as filesystem is read-only
    if ! ENV_VERIFY_LOCAL 2>/dev/null; then
        pacman --noconfirm --sync --needed $@
    fi
}

# [DISK]: PARTITIONING (GPT+UEFI)
function DISK_CREATE_LAYOUT {
    ENV_CREATE_DEPS parted
    mkdir -p ${OSTREE_SYS_ROOT}
    lsblk --noheadings --output='MOUNTPOINTS' | grep -w ${OSTREE_SYS_ROOT} | xargs -r umount --lazy --verbose
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

# [DISK]: BUILD DIRECTORY
function DISK_CREATE_MOUNTS {
    mount --mkdir ${OSTREE_DEV_ROOT} ${OSTREE_SYS_ROOT}
    mount --mkdir ${OSTREE_DEV_BOOT} ${OSTREE_SYS_ROOT}/boot/efi
}

# [OSTREE]: FIRST INITIALIZATION
function OSTREE_CREATE_REPO {
    ENV_CREATE_DEPS ostree which
    ostree admin init-fs --sysroot="${OSTREE_SYS_ROOT}" --modern ${OSTREE_SYS_ROOT}
    ostree admin stateroot-init --sysroot="${OSTREE_SYS_ROOT}" ${OSTREE_REP_NAME}
    ostree init --repo="${OSTREE_SYS_ROOT}/ostree/repo" --mode='bare'
    ostree config --repo="${OSTREE_SYS_ROOT}/ostree/repo" set sysroot.bootprefix 1
}

# [OSTREE]: BUILD ROOTFS
function OSTREE_CREATE_ROOTFS {
    # Add support for overlay storage driver in LiveCD
    if [[ $(df --output=fstype / | tail --lines 1) = 'overlay' ]]; then
        ENV_CREATE_DEPS fuse-overlayfs
        declare -x TMPDIR='/tmp/podman'
        local PODMAN_OPT_GLOBAL=(
            --root="${TMPDIR}/storage"
            --tmpdir="${TMPDIR}/tmp"
        )
    fi

    # Install Podman
    ENV_CREATE_DEPS podman

    # Copy Pacman package cache into /var by default (to avoid duplication)
    if [[ ${PACMAN_OPT_NOCACHE} == 0 ]]; then
        mkdir -p "${TMPDIR:-}/var/cache/pacman"
        local PODMAN_OPT_BUILD=(
            --volume="${TMPDIR:-}/var/cache/pacman:${TMPDIR:-}/var/cache/pacman"
        )
    fi

    # Skip Podman layer cache if requested
    if [[ ${PODMAN_OPT_NOCACHE} == 1 ]]; then
        local PODMAN_OPT_BUILD=(
            ${PODMAN_OPT_BUILD[@]}
            --no-cache='1'
        )
    fi

    # Podman: create rootfs from multiple Containerfiles
    for TARGET in ${PODMAN_OPT_BUILDFILE//,/ }; do
        local PODMAN_OPT_IMG=(${TARGET%:*})
        local PODMAN_OPT_TAG=(${TARGET#*:})
        podman ${PODMAN_OPT_GLOBAL[@]} build \
            ${PODMAN_OPT_BUILD[@]} \
            --file="${PODMAN_OPT_IMG}" \
            --tag="${PODMAN_OPT_TAG}" \
            --cap-add='SYS_ADMIN' \
            --build-arg="OSTREE_SYS_BOOT_LABEL=${OSTREE_SYS_BOOT_LABEL}" \
            --build-arg="OSTREE_SYS_HOME_LABEL=${OSTREE_SYS_HOME_LABEL}" \
            --build-arg="OSTREE_SYS_ROOT_LABEL=${OSTREE_SYS_ROOT_LABEL}" \
            --build-arg="SYSTEM_OPT_TIMEZONE=${SYSTEM_OPT_TIMEZONE}" \
            --build-arg="SYSTEM_OPT_KEYMAP=${SYSTEM_OPT_KEYMAP}" \
            --pull='newer'
    done

    # Ostreeify: retrieve rootfs (workaround: `podman build --output local` doesn't preserve ownership)
    rm -rf ${OSTREE_SYS_TREE}
    mkdir -p ${OSTREE_SYS_TREE}
    podman ${PODMAN_OPT_GLOBAL[@]} export $(podman ${PODMAN_OPT_GLOBAL[@]} create ${PODMAN_OPT_TAG} bash) | tar -xC ${OSTREE_SYS_TREE}
}

# [OSTREE]: DIRECTORY STRUCTURE (https://ostree.readthedocs.io/en/stable/manual/adapting-existing)
function OSTREE_CREATE_LAYOUT {
    # Doing it here allows the container to be runnable/debuggable and Containerfile reusable
    mv ${OSTREE_SYS_TREE}/etc ${OSTREE_SYS_TREE}/usr/

    rm -r ${OSTREE_SYS_TREE}/home
    ln -s var/home ${OSTREE_SYS_TREE}/home

    rm -r ${OSTREE_SYS_TREE}/mnt
    ln -s var/mnt ${OSTREE_SYS_TREE}/mnt

    rm -r ${OSTREE_SYS_TREE}/opt
    ln -s var/opt ${OSTREE_SYS_TREE}/opt

    rm -r ${OSTREE_SYS_TREE}/root
    ln -s var/roothome ${OSTREE_SYS_TREE}/root

    rm -r ${OSTREE_SYS_TREE}/srv
    ln -s var/srv ${OSTREE_SYS_TREE}/srv

    mkdir ${OSTREE_SYS_TREE}/sysroot
    ln -s sysroot/ostree ${OSTREE_SYS_TREE}/ostree

    rm -r ${OSTREE_SYS_TREE}/usr/local
    ln -s ../var/usrlocal ${OSTREE_SYS_TREE}/usr/local

    printf >&1 '%s\n' 'Creating tmpfiles'
    echo 'd /var/home 0755 root root -' >> ${OSTREE_SYS_TREE}/usr/lib/tmpfiles.d/ostree-0-integration.conf
    echo 'd /var/lib 0755 root root -' >> ${OSTREE_SYS_TREE}/usr/lib/tmpfiles.d/ostree-0-integration.conf
    echo 'd /var/log/journal 0755 root root -' >> ${OSTREE_SYS_TREE}/usr/lib/tmpfiles.d/ostree-0-integration.conf
    echo 'd /var/mnt 0755 root root -' >> ${OSTREE_SYS_TREE}/usr/lib/tmpfiles.d/ostree-0-integration.conf
    echo 'd /var/opt 0755 root root -' >> ${OSTREE_SYS_TREE}/usr/lib/tmpfiles.d/ostree-0-integration.conf
    echo 'd /var/roothome 0700 root root -' >> ${OSTREE_SYS_TREE}/usr/lib/tmpfiles.d/ostree-0-integration.conf
    echo 'd /var/srv 0755 root root -' >> ${OSTREE_SYS_TREE}/usr/lib/tmpfiles.d/ostree-0-integration.conf
    echo 'd /var/usrlocal 0755 root root -' >> ${OSTREE_SYS_TREE}/usr/lib/tmpfiles.d/ostree-0-integration.conf
    echo 'd /var/usrlocal/bin 0755 root root -' >> ${OSTREE_SYS_TREE}/usr/lib/tmpfiles.d/ostree-0-integration.conf
    echo 'd /var/usrlocal/etc 0755 root root -' >> ${OSTREE_SYS_TREE}/usr/lib/tmpfiles.d/ostree-0-integration.conf
    echo 'd /var/usrlocal/games 0755 root root -' >> ${OSTREE_SYS_TREE}/usr/lib/tmpfiles.d/ostree-0-integration.conf
    echo 'd /var/usrlocal/include 0755 root root -' >> ${OSTREE_SYS_TREE}/usr/lib/tmpfiles.d/ostree-0-integration.conf
    echo 'd /var/usrlocal/lib 0755 root root -' >> ${OSTREE_SYS_TREE}/usr/lib/tmpfiles.d/ostree-0-integration.conf
    echo 'd /var/usrlocal/man 0755 root root -' >> ${OSTREE_SYS_TREE}/usr/lib/tmpfiles.d/ostree-0-integration.conf
    echo 'd /var/usrlocal/sbin 0755 root root -' >> ${OSTREE_SYS_TREE}/usr/lib/tmpfiles.d/ostree-0-integration.conf
    echo 'd /var/usrlocal/share 0755 root root -' >> ${OSTREE_SYS_TREE}/usr/lib/tmpfiles.d/ostree-0-integration.conf
    echo 'd /var/usrlocal/src 0755 root root -' >> ${OSTREE_SYS_TREE}/usr/lib/tmpfiles.d/ostree-0-integration.conf
    echo 'd /run/media 0755 root root -' >> ${OSTREE_SYS_TREE}/usr/lib/tmpfiles.d/ostree-0-integration.conf

    # Only retain information about Pacman packages in new rootfs
    mv ${OSTREE_SYS_TREE}/var/lib/pacman ${OSTREE_SYS_TREE}/usr/lib/
    sed -i \
        -e 's|^#\(DBPath\s*=\s*\).*|\1/usr/lib/pacman|g' \
        -e 's|^#\(IgnoreGroup\s*=\s*\).*|\1modified|g' \
        ${OSTREE_SYS_TREE}/usr/etc/pacman.conf

    # Allow Pacman to store update notice id during unlock mode
    mkdir ${OSTREE_SYS_TREE}/usr/lib/pacmanlocal

    # OSTree mounts /ostree/deploy/${OSTREE_REP_NAME}/var to /var
    rm -r ${OSTREE_SYS_TREE}/var/*
}

# [OSTREE]: CREATE COMMIT
function OSTREE_DEPLOY_IMAGE {
    # Update repository and boot entries in GRUB2
    ostree commit --repo="${OSTREE_SYS_ROOT}/ostree/repo" --branch="${OSTREE_REP_NAME}/latest" --tree=dir="${OSTREE_SYS_TREE}"
    ostree admin deploy --sysroot="${OSTREE_SYS_ROOT}" --karg="root=LABEL=${OSTREE_SYS_ROOT_LABEL} rw ${OSTREE_SYS_KARG}" --os="${OSTREE_REP_NAME}" ${OSTREE_OPT_NOMERGE} --retain ${OSTREE_REP_NAME}/latest
}

# [OSTREE]: UNDO COMMIT
function OSTREE_REVERT_IMAGE {
    ostree admin undeploy --sysroot="${OSTREE_SYS_ROOT}" 0
}

# [BOOTLOADER]: FIRST BOOT
# | Todo: improve grub-mkconfig
function BOOTLOADER_CREATE {
    grub-install --target='x86_64-efi' --efi-directory="${OSTREE_SYS_ROOT}/boot/efi" --boot-directory="${OSTREE_SYS_ROOT}/boot/efi/EFI" --bootloader-id="${OSTREE_REP_NAME}" --removable ${OSTREE_DEV_BOOT}

    local OSTREE_SYS_PATH=$(ls -d ${OSTREE_SYS_ROOT}/ostree/deploy/${OSTREE_REP_NAME}/deploy/* | head -n 1)

    rm -rfv ${OSTREE_SYS_PATH}/boot/*
    mount --mkdir --rbind ${OSTREE_SYS_ROOT}/boot ${OSTREE_SYS_PATH}/boot
    mount --mkdir --rbind ${OSTREE_SYS_ROOT}/ostree ${OSTREE_SYS_PATH}/sysroot/ostree

    for i in /dev /proc /sys; do mount -o bind $i ${OSTREE_SYS_PATH}${i}; done
    chroot ${OSTREE_SYS_PATH} /bin/bash -c 'grub-mkconfig -o /boot/efi/EFI/grub/grub.cfg'

    umount --recursive ${OSTREE_SYS_ROOT}
}

# [CLI]: TASK FINECONTROL
function CLI_SETUP {
    CLI_ARGS=$(getopt \
        --alternative \
        --options='b:,c:,d:,f:,k:,t:,m::,n::,q::' \
        --longoptions='base-os:,cmdline:,dev:,file:,keymap:,time:,merge::,no-cache::,no-pacman-cache::,no-podman-cache::,quiet::' \
        --name="${0##*/}" \
        -- "${@}"
    )

    # Rewrite "${@}"
    eval set -- "${CLI_ARGS}"

    # Arguments
    while [[ ${#} > 0 ]]; do
        CLI_ARG=${1:-}
        CLI_VAL=${2:-}

        # Options
        case ${CLI_ARG} in
            '-b' | '--base-os')
                declare -g OSTREE_REP_NAME=${CLI_VAL}
            ;;

            '-c' | '--cmdline')
                declare -g OSTREE_SYS_KARG=${CLI_VAL}
            ;;

            '-d' | '--dev')
                declare -g OSTREE_DEV_SCSI=${CLI_VAL}
            ;;

            '-f' | '--file')
                declare -g PODMAN_OPT_BUILDFILE=${CLI_VAL}
            ;;

            '-k' | '--keymap')
                declare -g SYSTEM_OPT_KEYMAP=${CLI_VAL}
            ;;

            '-t' | '--time')
                declare -g SYSTEM_OPT_TIMEZONE=${CLI_VAL}
            ;;
        esac

        # Switches
        [[ ${CLI_VAL@L} == 'true' ]] && CLI_VAL='1'
        [[ ${CLI_VAL@L} == 'false' ]] && CLI_VAL='0'
        case ${CLI_ARG} in
            '-m' | '--merge')
                declare -g OSTREE_OPT_NOMERGE=${CLI_VAL:-}
            ;;

            '-n' | '--no-cache')
                declare -g PACMAN_OPT_NOCACHE=${CLI_VAL:-1}
                declare -g PODMAN_OPT_NOCACHE=${CLI_VAL:-1}
            ;;

            '--no-pacman-cache')
                declare -g PACMAN_OPT_NOCACHE=${CLI_VAL:-1}
            ;;

            '--no-podman-cache')
                declare -g PODMAN_OPT_NOCACHE=${CLI_VAL:-1}
            ;;

            '-q' | '--quiet')
                declare -g CLI_QUIET=${CLI_VAL:-1}
            ;;
        esac

        # Commands
        if [[ ${CLI_ARG} == '--' ]]; then
            case ${CLI_VAL} in
                'install')
                    ENV_CREATE_OPTS

                    DISK_CREATE_LAYOUT
                    DISK_CREATE_FORMAT
                    DISK_CREATE_MOUNTS

                    OSTREE_CREATE_REPO
                    OSTREE_CREATE_ROOTFS
                    OSTREE_CREATE_LAYOUT
                    OSTREE_DEPLOY_IMAGE

                    BOOTLOADER_CREATE
                ;;

                'upgrade')
                    ENV_VERIFY_LOCAL || exit $?
                    ENV_CREATE_OPTS

                    OSTREE_CREATE_ROOTFS
                    OSTREE_CREATE_LAYOUT
                    OSTREE_DEPLOY_IMAGE
                ;;

                'revert')
                    ENV_VERIFY_LOCAL || exit $?
                    ENV_CREATE_OPTS

                    OSTREE_REVERT_IMAGE
                ;;

                *)
                    if [[ $(type -t ${CLI_VAL}) == 'function' ]]; then
                        ENV_CREATE_OPTS
                        ${CLI_VAL}
                    fi
                ;;&

                * | 'help')
                    local USAGE=(
                        'Usage:'
                        "  ${0##*/} <command|function> [options]"
                        'Commands:'
                        '  install : (Create deployment) : Partitions, formats and initializes a new OSTree repository'
                        '  upgrade : (Update deployment) : Creates a new OSTree commit'
                        '  revert  : (Update deployment) : Rolls back version 0'
                        'Options:'
                        '  -b, --base-os string      : (install/upgrade) : Name of OS to use as a base. Defaults to archlinux'
                        '  -c, --cmdline string      : (install/upgrade) : List of kernel arguments for boot'
                        '  -d, --dev     string      : (install        ) : Device SCSI (ID-LINK) for new installation'
                        '  -f, --file    stringArray : (install/upgrade) : Containerfile(s) for new deployment'
                        '  -k, --keymap  string      : (install/upgrade) : TTY keyboard layout for new deployment'
                        '  -t, --time    string      : (install/upgrade) : Update host timezone for new deployment'
                        'Switches:'
                        '  -m, --merge               : (        upgrade) : Retain contents of /etc for existing deployment'
                        '  -n, --no-cache            : (install/upgrade) : Skip any cached data (note: implied for first deployment)'
                        '      --no-pacman-cache     : (install/upgrade) : Skip Pacman package cache'
                        '      --no-podman-cache     : (install/upgrade) : Skip Podman layer cache'
                        '  -q, --quiet               : (install/upgrade) : Reduce verbosity'
                    )
                    printf >&1 '%s\n' "${USAGE[@]}"

                    if [[ ${CLI_VAL} != 'help' && -n ${CLI_VAL} ]]; then
                        printf >&2 '\n%s\n' "${0##*/}: unrecognized command '${CLI_VAL}'"
                        exit 127
                    fi
                ;;
            esac
            break
        fi

        # Continue to the next argument
        shift 2
    done
}

CLI_SETUP "${@}"
