# |
# | BASE CONFIGURATION
# |

FROM archlinux:base AS rootfs

# Remove container specific storage optimization in Pacman
RUN sed -i -e 's|^NoExtract.*||g' /etc/pacman.conf && \
    pacman --noconfirm -Syu

# Clock
RUN ln -sf /usr/share/zoneinfo/Europe/Stockholm /etc/localtime

# Language
RUN echo 'LANG=en_US.UTF-8' | tee /etc/locale.conf && \
    echo 'en_US.UTF-8 UTF-8' | tee /etc/locale.gen && \
    locale-gen

# Peripherals
RUN echo 'KEYMAP=sv-latin1' | tee /etc/vconsole.conf

# Networking
RUN pacman --noconfirm -S networkmanager && \
    systemctl enable NetworkManager.service && \
    systemctl mask systemd-networkd-wait-online.service

# SSHD
RUN pacman --noconfirm -S openssh && \
    systemctl enable sshd && \
    echo "PermitRootLogin yes" >> /etc/ssh/sshd_config

# Root password
RUN echo "root:ostree" | chpasswd

## |
## | OSTREE DEPENDENCIES
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
    e2fsprogs \
    \
    sudo \
    less \
    \
    ostree \
    grub \
    which \
    podman

# Bootloader integration
RUN curl https://raw.githubusercontent.com/ostreedev/ostree/v2023.6/src/boot/grub2/grub2-15_ostree -o /etc/grub.d/15_ostree && \
    chmod +x /etc/grub.d/15_ostree

## |
## | OSTREEIFY
## |

# https://ostree.readthedocs.io/en/stable/manual/adapting-existing/

RUN sed -i \
    -e 's|^#\(DBPath\s*=\s*\).*|\1/usr/lib/pacman|g' \
    -e 's|^#\(IgnoreGroup\s*=\s*\).*|\1modified|g' \
    /etc/pacman.conf && \
    mv /var/lib/pacman /usr/lib/

RUN mv /home /var/ && \
	ln -s var/home /home

RUN mv /mnt /var/ && \
	ln -s var/mnt /mnt

# This is recommended by ostree but I don't see a good reason for it.
# rmdir "$rootfs/var/opt"
# mv "$rootfs/opt" "$rootfs/var/"
# ln -s var/opt "$rootfs/opt"

RUN mv /root /var/roothome && \
	ln -s var/roothome /root

RUN rm -r /usr/local && \
	ln -s ../var/usrlocal /usr/local

RUN mv /srv /var/srv && \
	ln -s var/srv /srv

RUN echo "d /var/log/journal 0755 root root -" >> /usr/lib/tmpfiles.d/ostree-0-integration.conf && \
    echo "L /var/home - - - - ../sysroot/home" >> /usr/lib/tmpfiles.d/ostree-0-integration.conf && \
    echo "#d /var/opt 0755 root root -" >> /usr/lib/tmpfiles.d/ostree-0-integration.conf && \
    echo "d /var/srv 0755 root root -" >> /usr/lib/tmpfiles.d/ostree-0-integration.conf && \
    echo "d /var/roothome 0700 root root -" >> /usr/lib/tmpfiles.d/ostree-0-integration.conf && \
    echo "d /var/usrlocal 0755 root root -" >> /usr/lib/tmpfiles.d/ostree-0-integration.conf && \
    echo "d /var/usrlocal/bin 0755 root root -" >> /usr/lib/tmpfiles.d/ostree-0-integration.conf && \
    echo "d /var/usrlocal/etc 0755 root root -" >> /usr/lib/tmpfiles.d/ostree-0-integration.conf && \
    echo "d /var/usrlocal/games 0755 root root -" >> /usr/lib/tmpfiles.d/ostree-0-integration.conf && \
    echo "d /var/usrlocal/include 0755 root root -" >> /usr/lib/tmpfiles.d/ostree-0-integration.conf && \
    echo "d /var/usrlocal/lib 0755 root root -" >> /usr/lib/tmpfiles.d/ostree-0-integration.conf && \
    echo "d /var/usrlocal/man 0755 root root -" >> /usr/lib/tmpfiles.d/ostree-0-integration.conf && \
    echo "d /var/usrlocal/sbin 0755 root root -" >> /usr/lib/tmpfiles.d/ostree-0-integration.conf && \
    echo "d /var/usrlocal/share 0755 root root -" >> /usr/lib/tmpfiles.d/ostree-0-integration.conf && \
    echo "d /var/usrlocal/src 0755 root root -" >> /usr/lib/tmpfiles.d/ostree-0-integration.conf && \
    echo "d /var/mnt 0755 root root -" >> /usr/lib/tmpfiles.d/ostree-0-integration.conf && \
    echo "d /run/media 0755 root root -" >> /usr/lib/tmpfiles.d/ostree-0-integration.conf

RUN rm -r /var/*

RUN mkdir /sysroot && \
    ln -s sysroot/ostree /ostree

RUN mv /etc /usr/

RUN moduledir=$(find /usr/lib/modules -mindepth 1 -maxdepth 1 -type d) && \
    echo $moduledir && \
	cat \
		/boot/*-ucode.img \
		/boot/initramfs-linux-fallback.img \
		> $moduledir/initramfs.img