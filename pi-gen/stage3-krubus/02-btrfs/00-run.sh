#!/bin/bash -e

# 1. High-performance Btrfs rootfs in /etc/fstab (zstd:1 low-latency compression, async discard, RAM /tmp)
cat << 'EOF' > "${ROOTFS_DIR}/etc/fstab"
proc            /proc           proc    defaults          0       0
BOOTDEV  /boot/firmware  vfat    defaults,noatime,x-systemd.automount,nofail  0  0
ROOTDEV  /               btrfs   defaults,compress=zstd:1,noatime,nodiratime,commit=60,ssd,discard=async,space_cache=v2 0 0
tmpfs           /tmp            tmpfs   defaults,noatime,nosuid,nodev,mode=1777 0 0
EOF

# 2. Update /boot/firmware/cmdline.txt for Btrfs rootfs & quiet Plymouth splash
if [ -f "${ROOTFS_DIR}/boot/firmware/cmdline.txt" ]; then
	sed -i 's/rootfstype=ext4/rootfstype=btrfs rootflags=compress=zstd:1,noatime,nodiratime,commit=60/g' "${ROOTFS_DIR}/boot/firmware/cmdline.txt"
	sed -i 's/fsck.repair=yes/fsck.repair=no/g' "${ROOTFS_DIR}/boot/firmware/cmdline.txt"
	sed -i 's/\bresize\b//g; s/[[:space:]]*$//' "${ROOTFS_DIR}/boot/firmware/cmdline.txt"
	if ! grep -q "cgroup_enable=memory" "${ROOTFS_DIR}/boot/firmware/cmdline.txt"; then
		sed -i 's/$/ cgroup_enable=memory psi=1 nvme_core.default_ps_max_latency_us=5500/' "${ROOTFS_DIR}/boot/firmware/cmdline.txt"
	fi
	if ! grep -q "splash" "${ROOTFS_DIR}/boot/firmware/cmdline.txt"; then
		sed -i 's/$/ quiet splash plymouth.ignore-serial-consoles vt.global_cursor_default=0 loglevel=3 systemd.show_status=auto rd.udev.log_level=3/' "${ROOTFS_DIR}/boot/firmware/cmdline.txt"
	fi
fi

# 3. Ensure Btrfs & Zstd modules in initramfs
install -d -m 755 "${ROOTFS_DIR}/etc/initramfs-tools"
for mod in btrfs zstd_compress crc32c; do
	if ! grep -qx "$mod" "${ROOTFS_DIR}/etc/initramfs-tools/modules" 2>/dev/null; then
		echo "$mod" >> "${ROOTFS_DIR}/etc/initramfs-tools/modules"
	fi
done

# 4. First-Boot online Btrfs partition & filesystem expansion
install -d -m 755 "${ROOTFS_DIR}/usr/local/sbin" "${ROOTFS_DIR}/etc/systemd/system"
cat << 'EOF' > "${ROOTFS_DIR}/usr/local/sbin/krubus-btrfs-resize.sh"
#!/bin/bash
set -e
ROOT_PART="$(findmnt -n -o SOURCE /)"
ROOT_PART="${ROOT_PART%%\[*}"
if [[ "$ROOT_PART" =~ ^/dev/(mmcblk[0-9]+|nvme[0-9]+n[0-9]+)p([0-9]+)$ ]]; then
	DISK="${BASH_REMATCH[1]}"
	PART="${BASH_REMATCH[2]}"
	if command -v growpart >/dev/null 2>&1; then
		growpart "/dev/${DISK}" "${PART}" 2>/dev/null || true
	else
		echo ", +" | sfdisk -N "${PART}" --no-reread "/dev/${DISK}" 2>/dev/null || true
	fi
	partx -u "${PART}" "/dev/${DISK}" 2>/dev/null || partprobe "/dev/${DISK}" 2>/dev/null || true
elif [[ "$ROOT_PART" =~ ^/dev/(sd[a-z]+)([0-9]+)$ ]]; then
	DISK="${BASH_REMATCH[1]}"
	PART="${BASH_REMATCH[2]}"
	if command -v growpart >/dev/null 2>&1; then
		growpart "/dev/${DISK}" "${PART}" 2>/dev/null || true
	else
		echo ", +" | sfdisk -N "${PART}" --no-reread "/dev/${DISK}" 2>/dev/null || true
	fi
	partx -u "${PART}" "/dev/${DISK}" 2>/dev/null || partprobe "/dev/${DISK}" 2>/dev/null || true
fi
btrfs filesystem resize max / || true

# Storage-aware Btrfs zstd tuning: zstd:1 for fast PCIe NVMe (~485 MiB/s), zstd:6 for SD/USB (~36.5 MiB/s cold read & max flash life)
if [[ "$ROOT_PART" =~ ^/dev/nvme ]]; then
	ZSTD_LVL=1
else
	ZSTD_LVL=6
fi
sed -i -E "s/compress=zstd:[0-9]+/compress=zstd:${ZSTD_LVL}/g" /etc/fstab 2>/dev/null || true
mount /boot/firmware 2>/dev/null || true
if [ -f /boot/firmware/cmdline.txt ]; then
	sed -i -E "s/compress=zstd:[0-9]+/compress=zstd:${ZSTD_LVL}/g" /boot/firmware/cmdline.txt 2>/dev/null || true
fi
mount -o "remount,compress=zstd:${ZSTD_LVL}" / 2>/dev/null || true

systemctl disable krubus-btrfs-resize.service || true
EOF
chmod 755 "${ROOTFS_DIR}/usr/local/sbin/krubus-btrfs-resize.sh"

cat << 'EOF' > "${ROOTFS_DIR}/etc/systemd/system/krubus-btrfs-resize.service"
[Unit]
Description=Resize KRubus Btrfs root filesystem on first boot
DefaultDependencies=no
After=local-fs.target
Before=multi-user.target

[Service]
Type=oneshot
TimeoutStartSec=60
ExecStart=/usr/local/sbin/krubus-btrfs-resize.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

cat << 'EOF' > "${ROOTFS_DIR}/usr/local/sbin/krubus-btrfs-compress.sh"
#!/bin/bash
set -e
[ -f /var/lib/krubus-btrfs-compressed ] && exit 0
ROOT_PART="$(findmnt -n -o SOURCE /)"
ROOT_PART="${ROOT_PART%%\[*}"
if [[ "$ROOT_PART" =~ ^/dev/nvme ]]; then
	ZSTD_LVL=1
else
	ZSTD_LVL=6
fi
# Compress boot hotpath (/usr/lib, /usr/bin) first so even an early reboot is fast, then the rest of /
btrfs filesystem defragment -r -czstd -L "${ZSTD_LVL}" /usr/lib /usr/bin 2>/dev/null || true
btrfs filesystem defragment -r -czstd -L "${ZSTD_LVL}" / 2>/dev/null || true
touch /var/lib/krubus-btrfs-compressed
systemctl disable krubus-btrfs-compress.timer 2>/dev/null || true
EOF
chmod 755 "${ROOTFS_DIR}/usr/local/sbin/krubus-btrfs-compress.sh"

cat << 'EOF' > "${ROOTFS_DIR}/etc/systemd/system/krubus-btrfs-compress.service"
[Unit]
Description=Background Btrfs Zstd Rootfs Compression (NVMe zstd:1 / SD zstd:6)
ConditionPathExists=!/var/lib/krubus-btrfs-compressed
After=krubus-btrfs-resize.service multi-user.target

[Service]
Type=oneshot
Nice=19
IOSchedulingClass=idle
CPUSchedulingPolicy=idle
ExecStart=/usr/local/sbin/krubus-btrfs-compress.sh
EOF

cat << 'EOF' > "${ROOTFS_DIR}/etc/systemd/system/krubus-btrfs-compress.timer"
[Unit]
Description=Trigger one-time idle Btrfs Zstd compression after first boot
ConditionPathExists=!/var/lib/krubus-btrfs-compressed

[Timer]
OnBootSec=120s
Unit=krubus-btrfs-compress.service

[Install]
WantedBy=timers.target
EOF

on_chroot <<- \EOF
	systemctl disable rpi-resize.service 2>/dev/null || true
	systemctl mask rpi-resize.service 2>/dev/null || true
	systemctl enable krubus-btrfs-resize.service krubus-btrfs-compress.timer
EOF
