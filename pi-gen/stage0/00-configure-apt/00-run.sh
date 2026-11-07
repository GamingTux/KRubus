#!/bin/bash -e

true > "${ROOTFS_DIR}/etc/apt/sources.list"
install -m 644 files/debian.sources "${ROOTFS_DIR}/etc/apt/sources.list.d/"
install -m 644 files/raspi.sources "${ROOTFS_DIR}/etc/apt/sources.list.d/"
sed -i "s/RELEASE/${RELEASE}/g" "${ROOTFS_DIR}/etc/apt/sources.list.d/debian.sources"
sed -i "s/RELEASE/${RELEASE}/g" "${ROOTFS_DIR}/etc/apt/sources.list.d/raspi.sources"

if [ -n "$APT_PROXY" ]; then
	install -m 644 files/51cache "${ROOTFS_DIR}/etc/apt/apt.conf.d/51cache"
	sed "${ROOTFS_DIR}/etc/apt/apt.conf.d/51cache" -i -e "s|APT_PROXY|${APT_PROXY}|"
else
	rm -f "${ROOTFS_DIR}/etc/apt/apt.conf.d/51cache"
fi

if [ -n "$TEMP_REPO" ]; then
	install -m 644 /dev/null "${ROOTFS_DIR}/etc/apt/sources.list.d/00-temp.list"
	echo "$TEMP_REPO" | sed "s/RELEASE/$RELEASE/g" > "${ROOTFS_DIR}/etc/apt/sources.list.d/00-temp.list"
else
	rm -f "${ROOTFS_DIR}/etc/apt/sources.list.d/00-temp.list"
fi

install -d -m 755 "${ROOTFS_DIR}/etc/dpkg/dpkg.cfg.d"
cat << 'DPKGEOF' > "${ROOTFS_DIR}/etc/dpkg/dpkg.cfg.d/01-krubus-pi5-only"
# Exclude legacy Pi 0/1/2/3/4 VideoCore bootloaders & DTBs (Pi 5 & CM5 boot purely from SPI EEPROM)
path-exclude=/usr/lib/raspi-firmware/bootcode.bin
path-exclude=/usr/lib/raspi-firmware/start*
path-exclude=/usr/lib/raspi-firmware/fixup*
path-include=/usr/lib/raspi-firmware/LICENCE.broadcom
path-exclude=/usr/lib/linux-image-*/broadcom/bcm2710-*.dtb
path-exclude=/usr/lib/linux-image-*/broadcom/bcm2711-*.dtb
path-exclude=/usr/lib/linux-image-*/broadcom/bcm2837-*.dtb
path-exclude=/usr/lib/modules/*/dtb/broadcom/bcm2710-*.dtb
path-exclude=/usr/lib/modules/*/dtb/broadcom/bcm2711-*.dtb
path-exclude=/usr/lib/modules/*/dtb/broadcom/bcm2837-*.dtb

# Exclude non-Pi-5 foreign GPU Vulkan drivers & ICD manifests (saves ~165 MB & speeds up Vulkan loader)
path-exclude=/usr/lib/aarch64-linux-gnu/libvulkan_intel*
path-exclude=/usr/lib/aarch64-linux-gnu/libvulkan_radeon*
path-exclude=/usr/lib/aarch64-linux-gnu/libvulkan_nouveau*
path-exclude=/usr/lib/aarch64-linux-gnu/libvulkan_panfrost*
path-exclude=/usr/lib/aarch64-linux-gnu/libvulkan_freedreno*
path-exclude=/usr/lib/aarch64-linux-gnu/libvulkan_asahi*
path-exclude=/usr/lib/aarch64-linux-gnu/libvulkan_powervr*
path-exclude=/usr/lib/aarch64-linux-gnu/libvulkan_gfxstream*
path-exclude=/usr/share/vulkan/icd.d/intel_*.json
path-exclude=/usr/share/vulkan/icd.d/radeon_*.json
path-exclude=/usr/share/vulkan/icd.d/nouveau_*.json
path-exclude=/usr/share/vulkan/icd.d/panfrost_*.json
path-exclude=/usr/share/vulkan/icd.d/freedreno_*.json
path-exclude=/usr/share/vulkan/icd.d/asahi_*.json
path-exclude=/usr/share/vulkan/icd.d/powervr_*.json
path-exclude=/usr/share/vulkan/icd.d/gfxstream_*.json

# Exclude heavy offline KDE DocBook HTML manuals (~45 MB)
path-exclude=/usr/share/doc/HTML/*
DPKGEOF

install -m 644 files/raspberrypi-archive-keyring.pgp "${ROOTFS_DIR}/usr/share/keyrings/"
install -d -m 755 "${ROOTFS_DIR}/etc/apt/keyrings" "${ROOTFS_DIR}/etc/apt/preferences.d" "${ROOTFS_DIR}/etc/apt/apt.conf.d"
install -m 644 files/krubus.gpg "${ROOTFS_DIR}/etc/apt/keyrings/krubus.gpg"
install -m 644 files/krubus.gpg "${ROOTFS_DIR}/usr/share/keyrings/krubus.gpg"
install -m 644 files/krubus.list "${ROOTFS_DIR}/etc/apt/sources.list.d/krubus.list"
install -m 644 files/krubus-pi5.pref "${ROOTFS_DIR}/etc/apt/preferences.d/krubus-pi5.pref"
cat << 'APTEOF' > "${ROOTFS_DIR}/etc/apt/apt.conf.d/99-krubus.conf"
// KRubus APT Download, Network & Cache Tuning
Acquire::Queue-Mode "host";
Acquire::http::Pipeline-Depth "5";
Acquire::Retries "3";
APT::Keep-Downloaded-Packages "false";
Binary::apt::APT::Keep-Downloaded-Packages "false";
APTEOF

on_chroot <<- \EOF
	export DEBIAN_FRONTEND=noninteractive
	apt-get update
	apt-get dist-upgrade -y --allow-downgrades
EOF
