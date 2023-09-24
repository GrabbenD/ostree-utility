## |
## | BASE INSTALLATION
## |

FROM archlinux:base AS rootfs
ARG OSTREE_SYS_BOOT_LABEL
ARG OSTREE_SYS_ROOT_LABEL
ARG OSTREE_SYS_HOME_LABEL
ARG SYSTEM_OPT_TIMEZONE

# Remove container specific storage optimization in Pacman
RUN sed -i -e "s|^NoExtract.*||g" /etc/pacman.conf && \
    pacman --noconfirm -Syu

# Clock
RUN ln -sf /usr/share/zoneinfo/${SYSTEM_OPT_TIMEZONE} /etc/localtime

# Keymap hook
RUN echo "KEYMAP=sv-latin1" | tee /etc/vconsole.conf

# Language
RUN echo "LANG=en_US.UTF-8" | tee /etc/locale.conf && \
    echo "en_US.UTF-8 UTF-8" | tee /etc/locale.gen && \
    locale-gen

# Networking
RUN pacman --noconfirm -S networkmanager && \
    systemctl enable NetworkManager.service && \
    systemctl mask systemd-networkd-wait-online.service

## |
## | OSTREE INSTALLATION
## |

# Prepre OSTree integration
RUN mkdir -p /etc/mkinitcpio.conf.d && \
    echo "SD_NETWORK_CONFIG=/etc/systemd/network-initramfs" >> /etc/mkinitcpio.conf.d/ostree.conf && \
    echo "HOOKS=(base systemd ostree autodetect modconf kms keyboard sd-vconsole sd-network sd-tinyssh block sd-encrypt filesystems fsck)" >> /etc/mkinitcpio.conf.d/ostree.conf

# Install kernel, firmware, microcode, filesystem tools, bootloader, depndencies and run hooks once:
RUN pacman --noconfirm -S \
    linux \
    linux-headers \
    linux-firmware \
    amd-ucode \
    \
    dosfstools \
    xfsprogs \
    \
    podman \
    ostree \
    grub \
    which

# Native Overlay Diff for optimal Podman performance
RUN echo "options overlay metacopy=off redirect_dir=off" > /etc/modprobe.d/disable-overlay-redirect-dir.conf

# Bootloader integration
RUN curl https://raw.githubusercontent.com/ostreedev/ostree/v2023.6/src/boot/grub2/grub2-15_ostree -o /etc/grub.d/15_ostree && \
    chmod +x /etc/grub.d/15_ostree

# Mount disk locations
RUN echo "LABEL=${OSTREE_SYS_ROOT_LABEL} /         xfs  rw,relatime                                                                                           0 1" >> /etc/fstab && \
    echo "LABEL=${OSTREE_SYS_HOME_LABEL} /home     xfs  rw,relatime                                                                                           0 2" >> /etc/fstab && \
    echo "LABEL=${OSTREE_SYS_BOOT_LABEL} /boot/efi vfat rw,relatime,fmask=0022,dmask=0022,codepage=437,iocharset=ascii,shortname=mixed,utf8,errors=remount-ro 0 2" >> /etc/fstab

## |
## | CUSTOMIZE INSTALLATION
## |

# Add your own topping as late as possible to retain more layer caching

# SSHD
RUN pacman --noconfirm -S openssh && \
    systemctl enable sshd && \
    echo "PermitRootLogin yes" >> /etc/ssh/sshd_config

# Root password (todo move to secret)
RUN echo "root:ostree" | chpasswd
