#!/bin/bash -e

install -d -m 755 "${ROOTFS_DIR}/etc/apt/keyrings" "${ROOTFS_DIR}/usr/share/keyrings"
install -m 644 files/krubus.gpg "${ROOTFS_DIR}/etc/apt/keyrings/krubus.gpg"
install -m 644 files/krubus.gpg "${ROOTFS_DIR}/usr/share/keyrings/krubus.gpg"

install -m 644 files/krubus.list "${ROOTFS_DIR}/etc/apt/sources.list.d/krubus.list"
install -m 644 files/krubus-pi5.pref "${ROOTFS_DIR}/etc/apt/preferences.d/krubus-pi5.pref"

install -d -m 755 "${ROOTFS_DIR}/etc/apt/apt.conf.d"
cat << 'EOF' > "${ROOTFS_DIR}/etc/apt/apt.conf.d/99-krubus.conf"
// KRubus APT Download, Network & Cache Tuning
Acquire::Queue-Mode "host";
Acquire::http::Pipeline-Depth "5";
Acquire::Retries "3";
APT::Keep-Downloaded-Packages "false";
Binary::apt::APT::Keep-Downloaded-Packages "false";
EOF

on_chroot <<- \EOF
	export DEBIAN_FRONTEND=noninteractive
	apt-get update
	apt-get dist-upgrade -y --allow-downgrades
EOF
