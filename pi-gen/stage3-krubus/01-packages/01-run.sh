#!/bin/bash -e

# 1. SDDM Wayland Display-Manager & Plymouth Flicker-Free Transition
install -d -m 755 "${ROOTFS_DIR}/etc/sddm.conf.d"
cat << 'EOF' > "${ROOTFS_DIR}/etc/sddm.conf.d/kde_settings.conf"
[General]
DisplayServer=wayland

[Wayland]
CompositorCommand=kwin_wayland --drm --no-lockscreen --no-global-shortcuts --locale1
SessionDir=/usr/share/wayland-sessions

[X11]
SessionDir=/usr/share/xsessions

[Theme]
Current=breeze
EOF

install -d -m 755 "${ROOTFS_DIR}/etc/systemd/system/plymouth-quit.service.d"
cat << 'EOF' > "${ROOTFS_DIR}/etc/systemd/system/plymouth-quit.service.d/retain-splash.conf"
[Service]
ExecStart=
ExecStart=-/usr/bin/plymouth quit --retain-splash
EOF

install -d -m 755 "${ROOTFS_DIR}/etc/systemd/system/sddm.service.d"
cat << 'EOF' > "${ROOTFS_DIR}/etc/systemd/system/sddm.service.d/override.conf"
[Unit]
After=plymouth-quit.service

[Service]
StandardOutput=journal
StandardError=journal
EOF

# Install responsive KRubus Plymouth Boot Splash theme
install -d -m 755 "${ROOTFS_DIR}/usr/share/plymouth/themes/krubus"
install -m 644 files/plymouth/krubus/* "${ROOTFS_DIR}/usr/share/plymouth/themes/krubus/"

# 2. Xwayland / X11 Fallback GPU & Touchpad Defaults
install -d -m 755 "${ROOTFS_DIR}/etc/X11/xorg.conf.d" "${ROOTFS_DIR}/usr/share/X11/xorg.conf.d"
cat << 'EOF' > "${ROOTFS_DIR}/etc/X11/xorg.conf.d/99-v3d.conf"
Section "OutputClass"
  Identifier "vc4"
  MatchDriver "vc4"
  Driver "modesetting"
  Option "PrimaryGPU" "true"
EndSection
EOF
cp "${ROOTFS_DIR}/etc/X11/xorg.conf.d/99-v3d.conf" "${ROOTFS_DIR}/usr/share/X11/xorg.conf.d/99-v3d.conf"

cat << 'EOF' > "${ROOTFS_DIR}/etc/X11/xorg.conf.d/40-libinput-touchpad.conf"
Section "InputClass"
  Identifier "libinput touchpad catchall"
  MatchIsTouchpad "on"
  MatchDevicePath "/dev/input/event*"
  Driver "libinput"
  Option "Tapping" "on"
  Option "ClickMethod" "clickfinger"
EndSection
EOF

# 3. KDE Plasma 6 Performance, Baloo Flash Protection & Desktop Polish
install -d -m 755 "${ROOTFS_DIR}/etc/xdg" "${ROOTFS_DIR}/etc/xdg/menus" "${ROOTFS_DIR}/etc/xdg/ddcutil" "${ROOTFS_DIR}/etc/xdg/xdg-desktop-portal"

cat << 'EOF' > "${ROOTFS_DIR}/etc/xdg/baloofilerc"
[Basic Settings]
Indexing-Enabled=false

[General]
only basic indexing=true
EOF

cat << 'EOF' > "${ROOTFS_DIR}/etc/xdg/ksplashrc"
[KSplash]
Engine=none
Theme=None
EOF

cat << 'EOF' > "${ROOTFS_DIR}/etc/xdg/xdg-desktop-portal/kde-portals.conf"
[preferred]
default=kde
org.freedesktop.impl.portal.Settings=kde
org.freedesktop.impl.portal.Secret=kwallet
org.freedesktop.impl.portal.Lockdown=none
EOF

cat << 'EOF' > "${ROOTFS_DIR}/etc/xdg/plasma-localerc"
[Formats]
LANG=de_DE.UTF-8

[Translations]
LANGUAGE=de
EOF

cat << 'EOF' > "${ROOTFS_DIR}/etc/xdg/kwinrc"
[Compositing]
LatencyPolicy=low
EOF

cat << 'EOF' > "${ROOTFS_DIR}/etc/xdg/kuprc"
[Kup settings]
Backups enabled=false
EOF

for KDEDRC in "${ROOTFS_DIR}/etc/xdg/kded5rc" "${ROOTFS_DIR}/etc/xdg/kded6rc"; do
	cat << 'EOF' > "$KDEDRC"
[Module-kded_bolt]
autoload=false

[Module-kded_plasma-welcome]
autoload=false

[Module-donationmessage]
autoload=false
EOF
done

cat << 'EOF' > "${ROOTFS_DIR}/etc/xdg/plasma-nm"
[General]
SystemConnectionsByDefault=true
EOF

cat << 'EOF' > "${ROOTFS_DIR}/etc/xdg/ddcutil/ddcutilrc"
[global]
options: --disable-dynamic-sleep --sleep-multiplier 0.1 --disable-heuristic-unsupported
EOF

if [ -f "${ROOTFS_DIR}/etc/xdg/menus/plasma-applications.menu" ] && [ ! -e "${ROOTFS_DIR}/etc/xdg/menus/applications.menu" ]; then
	ln -sf plasma-applications.menu "${ROOTFS_DIR}/etc/xdg/menus/applications.menu"
fi

# Prevent drkonqi-coredump-launcher infinite loop under SDDM system user
rm -f "${ROOTFS_DIR}/etc/systemd/user/sockets.target.upholds/drkonqi-coredump-launcher.socket"
sed -i 's/^UpheldBy=sockets.target/#UpheldBy=sockets.target/' "${ROOTFS_DIR}/usr/lib/systemd/user/drkonqi-coredump-launcher.socket" 2>/dev/null || true

# Ensure /run/utmp for sddm-helper & suppress pam_sss smartcard error spam
install -d -m 755 "${ROOTFS_DIR}/etc/tmpfiles.d" "${ROOTFS_DIR}/etc/pam.d"
cat << 'EOF' > "${ROOTFS_DIR}/etc/tmpfiles.d/legacy-utmp.conf"
f /run/utmp 0664 root utmp -
EOF

cat << 'EOF' > "${ROOTFS_DIR}/etc/pam.d/kde-smartcard"
#%PAM-1.0
auth     required       pam_deny.so
account  required       pam_deny.so
password required       pam_deny.so
session  required       pam_deny.so
EOF

install -d -m 755 "${ROOTFS_DIR}/etc/systemd/user/obex.service.d" "${ROOTFS_DIR}/etc/systemd/user/plasma-powerdevil.service.d" "${ROOTFS_DIR}/etc/systemd/user/ssh-agent.service.d"
cat << 'EOF' > "${ROOTFS_DIR}/etc/systemd/user/obex.service.d/10-disable-phonebook.conf"
[Service]
ExecStart=
ExecStart=/usr/libexec/bluetooth/obexd -P irmc,pbap
EOF

cat << 'EOF' > "${ROOTFS_DIR}/etc/systemd/user/plasma-powerdevil.service.d/override.conf"
[Service]
UnsetEnvironment=LC_ALL
Environment=LC_NUMERIC=C.UTF-8
EOF

cat << 'EOF' > "${ROOTFS_DIR}/etc/systemd/user/ssh-agent.service.d/override.conf"
[Service]
SuccessExitStatus=2
EOF

if [ -f "${ROOTFS_DIR}/usr/lib/udev/rules.d/90-alsa-restore.rules" ] && ! grep -q '^LABEL="alsa_restore_std"' "${ROOTFS_DIR}/usr/lib/udev/rules.d/90-alsa-restore.rules"; then
	echo 'LABEL="alsa_restore_std"' >> "${ROOTFS_DIR}/usr/lib/udev/rules.d/90-alsa-restore.rules"
fi
if [ -f "${ROOTFS_DIR}/usr/lib/sysctl.d/50-bubblewrap.conf" ]; then
	sed -i 's/^kernel\.unprivileged_userns_clone=1/-kernel.unprivileged_userns_clone=1/' "${ROOTFS_DIR}/usr/lib/sysctl.d/50-bubblewrap.conf"
fi

# Universal KDE Plasma 6 UI Polish Hook (SDDM Breeze, Kickoff favorites, Animation speed & Panel launchers)
install -d -m 755 "${ROOTFS_DIR}/usr/local/sbin"
cat << 'EOF' > "${ROOTFS_DIR}/usr/local/sbin/krubus-kde-polish"
#!/usr/bin/env python3
import configparser
import os
import sys

root = sys.argv[1] if len(sys.argv) > 1 and os.path.isdir(sys.argv[1]) else ""

def rpath(rel):
    return os.path.join(root, rel) if root else "/" + rel

# 1. Hide dead Suspend button in SDDM Breeze when canSuspend is false & fix Qt6 QML parameter warning
qml_path = rpath("usr/share/sddm/themes/breeze/Main.qml")
if os.path.isfile(qml_path):
    with open(qml_path, "r", encoding="utf-8") as f:
        qml = f.read()
    changed = False
    target = "enabled: sddm.canSuspend\n                    }"
    replacement = "enabled: sddm.canSuspend\n                        visible: sddm.canSuspend\n                    }"
    if target in qml and "visible: sddm.canSuspend" not in qml:
        qml = qml.replace(target, replacement)
        changed = True
    if "onLoginRequest: {" in qml:
        qml = qml.replace("onLoginRequest: {", "onLoginRequest: function(username, password) {")
        changed = True
    if changed:
        with open(qml_path, "w", encoding="utf-8") as f:
            f.write(qml)

# 2. Clean up Kickoff/Kicker default favorites (replace uninstalled kontact with konsole) & symbolic start icon
for kxml in [
    "usr/share/plasma/plasmoids/org.kde.plasma.kickoff/contents/config/main.xml",
    "usr/share/plasma/plasmoids/org.kde.plasma.kicker/contents/config/main.xml",
]:
    xml_path = rpath(kxml)
    if os.path.isfile(xml_path):
        with open(xml_path, "r", encoding="utf-8") as f:
            xml = f.read()
        if "org.kde.kontact.desktop," in xml:
            xml = xml.replace("org.kde.kontact.desktop,", "org.kde.konsole.desktop,")
            with open(xml_path, "w", encoding="utf-8") as f:
                f.write(xml)

for bdir in ["usr/share/icons/breeze/places", "usr/share/icons/breeze-dark/places"]:
    pdir = rpath(bdir)
    for res in ["16", "22", "24"]:
        rdir = os.path.join(pdir, res)
        if os.path.isdir(rdir) and not os.path.exists(os.path.join(rdir, "start-here-kde-symbolic.svg")):
            src = os.path.join(rdir, "start-here-kde.svg")
            if os.path.exists(src):
                try:
                    os.symlink("start-here-kde.svg", os.path.join(rdir, "start-here-kde-symbolic.svg"))
                except OSError:
                    pass

# 3. Snappy 2x animation speed (AnimationDurationFactor=0.5) & crisp RGB subpixel font rendering
for kg in ["etc/xdg/kdeglobals", "etc/skel/.config/kdeglobals"]:
    kg_path = rpath(kg)
    os.makedirs(os.path.dirname(kg_path), exist_ok=True)
    try:
        cp = configparser.ConfigParser(interpolation=None)
        cp.optionxform = str
        if os.path.isfile(kg_path):
            cp.read(kg_path, encoding="utf-8")
        if not cp.has_section("KDE"):
            cp.add_section("KDE")
        cp.set("KDE", "AnimationDurationFactor", "0.5")
        if not cp.has_section("General"):
            cp.add_section("General")
        cp.set("General", "XftSubPixel", "rgb")
        cp.set("General", "XftHintStyle", "hintslight")
        with open(kg_path, "w", encoding="utf-8") as f:
            cp.write(f)
    except Exception:
        pass

# 4. Pin Firefox, Dolphin & Konsole in default Plasma panel
layout_js = rpath("usr/share/plasma/layout-templates/org.kde.plasma.desktop.defaultPanel/contents/layout.js")
if os.path.isfile(layout_js):
    try:
        with open(layout_js, "r", encoding="utf-8") as f:
            ljs = f.read()
        ff_desktop = "firefox.desktop" if os.path.isfile(rpath("usr/share/applications/firefox.desktop")) else "firefox-esr.desktop"
        target_tasks = 'panel.addWidget("org.kde.plasma.icontasks")'
        if target_tasks in ljs and "tasks.writeConfig" not in ljs:
            replacement_tasks = f"""var tasks = panel.addWidget("org.kde.plasma.icontasks");
tasks.currentConfigGroup = ["General"];
tasks.writeConfig("launchers", [
    "applications:{ff_desktop}",
    "applications:org.kde.dolphin.desktop",
    "applications:org.kde.konsole.desktop"
]);"""
            ljs = ljs.replace(target_tasks, replacement_tasks, 1)
            with open(layout_js, "w", encoding="utf-8") as f:
                f.write(ljs)
    except Exception:
        pass
EOF
chmod 755 "${ROOTFS_DIR}/usr/local/sbin/krubus-kde-polish"

cat << 'EOF' > "${ROOTFS_DIR}/etc/apt/apt.conf.d/99-krubus-kde-polish"
DPkg::Post-Invoke { "if [ -x /usr/local/sbin/krubus-kde-polish ]; then /usr/local/sbin/krubus-kde-polish || true; fi"; };
EOF

# 4. CPU Governor, Kernel VM, Btrfs Cache, Storage I/O Schedulers, IRQ Affinity & TCP BBR
install -d -m 755 "${ROOTFS_DIR}/etc/udev/rules.d" "${ROOTFS_DIR}/etc/modules-load.d" "${ROOTFS_DIR}/etc/sysctl.d"
echo 'KERNEL=="cpu*", SUBSYSTEM=="cpu", ATTR{cpufreq/scaling_governor}="schedutil"' > "${ROOTFS_DIR}/etc/udev/rules.d/60-ondemand-governor.rules"
rm -f "${ROOTFS_DIR}/etc/udev/rules.d/60-readahead.rules"

echo "tcp_bbr" > "${ROOTFS_DIR}/etc/modules-load.d/bbr.conf"
echo "i2c-dev" > "${ROOTFS_DIR}/etc/modules-load.d/i2c-dev.conf"

cat << 'EOF' > "${ROOTFS_DIR}/etc/sysctl.d/99-krubus-pi5.conf"
vm.swappiness = 100
vm.page-cluster = 0
vm.vfs_cache_pressure = 50
vm.dirty_background_ratio = 5
vm.dirty_ratio = 10
fs.inotify.max_user_watches = 524288
net.core.default_qdisc = fq
net.core.rps_sock_flow_entries = 32768
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
EOF

cat << 'EOF' > "${ROOTFS_DIR}/usr/sbin/krubus-runtime-tune"
#!/bin/sh
# Spread heavy ARM64 GICv2 Level IRQs across CPU0..CPU3
for irq_dir in /proc/irq/[0-9]*; do
    [ -d "$irq_dir" ] || continue
    aff_file="$irq_dir/smp_affinity_list"
    [ -w "$aff_file" ] || continue
    for action_dir in "$irq_dir"/*; do
        [ -d "$action_dir" ] || continue
        name=$(basename "$action_dir")
        case "$name" in
            *dwc2*) echo 1 > "$aff_file" 2>/dev/null || true; break ;;
            *v3d*) echo 2 > "$aff_file" 2>/dev/null || true; break ;;
            *vc4*|*hvs*|*mmc0*|*mmc1*) echo 3 > "$aff_file" 2>/dev/null || true; break ;;
        esac
    done
done

# Enable 4-Core Receive Packet Steering (RPS/RFS) on active network interfaces
for rx_dir in /sys/class/net/wlan*/queues/rx-0 /sys/class/net/eth*/queues/rx-0; do
    [ -d "$rx_dir" ] || continue
    echo f > "$rx_dir/rps_cpus" 2>/dev/null || true
    echo 4096 > "$rx_dir/rps_flow_cnt" 2>/dev/null || true
done
EOF
chmod 755 "${ROOTFS_DIR}/usr/sbin/krubus-runtime-tune"

cat << 'EOF' > "${ROOTFS_DIR}/etc/udev/rules.d/68-krubus-no-mtp-probe.rules"
# Skip slow 3s mtp-probe on USB root hubs, mass storage (SD readers/flash drives), HID, video & BT
# Known Android/MTP phones already carry ID_MTP_DEVICE=="1" via udev hwdb!
ACTION=="add|bind", SUBSYSTEM=="usb", ATTR{idVendor}=="1d6b", ENV{MTP_NO_PROBE}="1"
ACTION=="add|bind", SUBSYSTEM=="usb", ENV{ID_MTP_DEVICE}!="1", ENV{ID_USB_INTERFACES}=="*:08*:*|*:03*:*|*:09*:*|*:0e*:*|*:e0*:*", ENV{MTP_NO_PROBE}="1"
EOF

cat << 'EOF' > "${ROOTFS_DIR}/etc/udev/rules.d/90-krubus-runtime.rules"
# Optimal I/O Scheduler, Read-Ahead & Core Queue Affinity for NVMe SSDs, eMMC/SD & USB storage
ACTION=="add|change", SUBSYSTEM=="block", ENV{DEVTYPE}=="disk", KERNEL=="nvme[0-9]*n[0-9]*", ATTR{queue/scheduler}="none", ATTR{queue/read_ahead_kb}="512", ATTR{queue/rq_affinity}="2"
ACTION=="add|change", SUBSYSTEM=="block", ENV{DEVTYPE}=="disk", KERNEL=="mmcblk[0-9]*", ATTR{queue/scheduler}="mq-deadline", ATTR{queue/read_ahead_kb}="256", ATTR{queue/rq_affinity}="2"
ACTION=="add|change", SUBSYSTEM=="block", ENV{DEVTYPE}=="disk", KERNEL=="sd[a-z]*", ATTR{queue/rotational}=="1", ATTR{queue/scheduler}="bfq", ATTR{queue/rq_affinity}="2"
ACTION=="add|change", SUBSYSTEM=="block", ENV{DEVTYPE}=="disk", KERNEL=="sd[a-z]*", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline", ATTR{queue/read_ahead_kb}="256", ATTR{queue/rq_affinity}="2"

# Start ModemManager on-demand ONLY when a real USB WWAN/4G/5G modem is plugged in
ACTION=="add", SUBSYSTEM=="usbmisc|tty|net", ENV{ID_USB_DRIVERS}=="qmi_wwan|cdc_mbim|option|huawei_cdc_ncm", TAG+="systemd", ENV{SYSTEMD_WANTS}+="ModemManager.service"

# 4-Core Receive Packet Steering (RPS/RFS) on network interfaces
ACTION=="add", SUBSYSTEM=="net", KERNEL=="wlan*|eth*", ATTR{queues/rx-0/rps_cpus}="f", ATTR{queues/rx-0/rps_flow_cnt}="4096"

# Runtime IRQ tuning on DRM init
ACTION=="add", SUBSYSTEM=="drm", KERNEL=="card0", RUN+="/usr/sbin/krubus-runtime-tune"
EOF

# Slim initramfs: strip 14 MB udev vendor text database & NTFS helper from initramfs image
install -d -m 755 "${ROOTFS_DIR}/etc/initramfs-tools/hooks"
cat << 'EOF' > "${ROOTFS_DIR}/etc/initramfs-tools/hooks/zz-krubus-slim"
#!/bin/sh
PREREQ="udev plymouth"
case "$1" in
    prereqs) echo "$PREREQ"; exit 0 ;;
esac
rm -f "${DESTDIR}/usr/lib/udev/hwdb.bin" "${DESTDIR}/lib/udev/hwdb.bin"
rm -f "${DESTDIR}"/usr/lib/*/libntfs-3g.so* "${DESTDIR}/usr/bin/ntfs-3g"
exit 0
EOF
chmod 755 "${ROOTFS_DIR}/etc/initramfs-tools/hooks/zz-krubus-slim"

# Defer SPI EEPROM update check to 90s after boot & run smartmontools only when NVMe is present
install -d -m 755 "${ROOTFS_DIR}/etc/systemd/system" "${ROOTFS_DIR}/etc/systemd/system/smartmontools.service.d"
cat << 'EOF' > "${ROOTFS_DIR}/etc/systemd/system/rpi-eeprom-update.timer"
[Unit]
Description=Deferred Raspberry Pi EEPROM Update Check

[Timer]
OnBootSec=90s
Unit=rpi-eeprom-update.service

[Install]
WantedBy=timers.target
EOF

cat << 'EOF' > "${ROOTFS_DIR}/etc/systemd/system/smartmontools.service.d/nvme-only.conf"
[Unit]
ConditionPathExistsGlob=/dev/nvme*
EOF

# 5. Firefox Wayland Zero-Copy DMABUF, V3D WebRender, Flash-Safe RAM Cache & Widevine DRM
install -d -m 755 \
	"${ROOTFS_DIR}/etc/firefox/policies" \
	"${ROOTFS_DIR}/etc/firefox-esr/policies" \
	"${ROOTFS_DIR}/usr/lib/firefox/gmp-widevinecdm" \
	"${ROOTFS_DIR}/usr/lib/firefox-esr/gmp-widevinecdm" \
	"${ROOTFS_DIR}/etc/environment.d" \
	"${ROOTFS_DIR}/etc/profile.d"

ln -sf /opt/WidevineCdm/gmp-widevinecdm/latest "${ROOTFS_DIR}/usr/lib/firefox/gmp-widevinecdm/system-installed"
ln -sf /opt/WidevineCdm/gmp-widevinecdm/latest "${ROOTFS_DIR}/usr/lib/firefox-esr/gmp-widevinecdm/system-installed"

cat << 'EOF' > "${ROOTFS_DIR}/etc/environment.d/50-gmpwidevine.conf"
MOZ_GMP_PATH=$MOZ_GMP_PATH${MOZ_GMP_PATH:+:}/opt/WidevineCdm/gmp-widevinecdm/latest
EOF

cat << 'EOF' > "${ROOTFS_DIR}/etc/profile.d/gmpwidevine.sh"
if [[ ":$MOZ_GMP_PATH:" != *":/opt/WidevineCdm/gmp-widevinecdm/latest:"* ]]; then
    export MOZ_GMP_PATH="${MOZ_GMP_PATH}${MOZ_GMP_PATH:+:}/opt/WidevineCdm/gmp-widevinecdm/latest"
fi
EOF

cat << 'EOF' > "${ROOTFS_DIR}/etc/firefox/policies/policies.json"
{
  "policies": {
    "EncryptedMediaExtensions": {
      "Enabled": true,
      "Locked": false
    },
    "Preferences": {
      "gfx.webrender.all": {
        "Value": true,
        "Status": "default"
      },
      "gfx.canvas.accelerated": {
        "Value": true,
        "Status": "default"
      },
      "layers.gpu-process.enabled": {
        "Value": true,
        "Status": "default"
      },
      "widget.dmabuf.force-enabled": {
        "Value": true,
        "Status": "default"
      },
      "media.ffmpeg.vaapi.enabled": {
        "Value": false,
        "Status": "default"
      },
      "media.rdd-process.enabled": {
        "Value": true,
        "Status": "default"
      },
      "media.eme.enabled": {
        "Value": true,
        "Status": "default"
      },
      "media.gmp-widevinecdm.enabled": {
        "Value": true,
        "Status": "default"
      },
      "media.gmp-widevinecdm.visible": {
        "Value": true,
        "Status": "default"
      },
      "media.gmp-widevinecdm.version": {
        "Value": "latest",
        "Status": "default"
      },
      "media.gmp-widevinecdm.autoupdate": {
        "Value": false,
        "Status": "default"
      },
      "browser.cache.disk.enable": {
        "Value": false,
        "Status": "default"
      },
      "browser.cache.memory.enable": {
        "Value": true,
        "Status": "default"
      }
    }
  }
}
EOF
cp "${ROOTFS_DIR}/etc/firefox/policies/policies.json" "${ROOTFS_DIR}/etc/firefox-esr/policies/policies.json"

# 6. NetworkManager Wi-Fi Stability, Avahi Dual-Stack Fix, Local DNS Cache & Polkit Rules
install -d -m 755 "${ROOTFS_DIR}/etc/NetworkManager/conf.d" "${ROOTFS_DIR}/etc/systemd/resolved.conf.d" "${ROOTFS_DIR}/etc/polkit-1/rules.d"
cat << 'EOF' > "${ROOTFS_DIR}/etc/NetworkManager/conf.d/99-krubus-wifi-powersave-off.conf"
[connection]
wifi.powersave = 2
EOF

cat << 'EOF' > "${ROOTFS_DIR}/etc/systemd/resolved.conf.d/99-krubus-dns.conf"
[Resolve]
FallbackDNS=1.1.1.1 9.9.9.9 2606:4700:4700::1111 2620:fe::fe
Cache=yes
DNSStubListener=yes
EOF
rm -f "${ROOTFS_DIR}/etc/resolv.conf"
cp /etc/resolv.conf "${ROOTFS_DIR}/etc/resolv.conf"

if [ -f "${ROOTFS_DIR}/etc/avahi/avahi-daemon.conf" ]; then
	sed -i 's/^#*use-iff-running=.*/use-iff-running=yes/' "${ROOTFS_DIR}/etc/avahi/avahi-daemon.conf"
	sed -i 's/^#*disallow-other-stacks=.*/disallow-other-stacks=yes/' "${ROOTFS_DIR}/etc/avahi/avahi-daemon.conf"
	sed -i 's/^#*publish-aaaa-on-ipv4=.*/publish-aaaa-on-ipv4=no/' "${ROOTFS_DIR}/etc/avahi/avahi-daemon.conf"
	sed -i 's/^#*publish-a-on-ipv6=.*/publish-a-on-ipv6=no/' "${ROOTFS_DIR}/etc/avahi/avahi-daemon.conf"
fi

cat << 'EOF' > "${ROOTFS_DIR}/etc/polkit-1/rules.d/50-networkmanager.rules"
polkit.addRule(function(action, subject) {
    if (action.id.indexOf("org.freedesktop.NetworkManager.") === 0 &&
        (subject.isInGroup("sudo") || subject.isInGroup("netdev"))) {
        return polkit.Result.YES;
    }
});
EOF

cat << 'EOF' > "${ROOTFS_DIR}/etc/polkit-1/rules.d/60-packagekit.rules"
polkit.addRule(function(action, subject) {
    if (action.id.indexOf("org.freedesktop.packagekit.") === 0 &&
        (subject.isInGroup("sudo") || subject.isInGroup("admin"))) {
        return polkit.Result.YES;
    }
});
EOF

# 7. Fast Driverless Network Scanner Discovery (sane-airscan eSCL/WSD) for Skanpage
if [ -f "${ROOTFS_DIR}/etc/sane.d/dll.d/hplip" ]; then
	sed -i 's/^[[:space:]]*hpaio/#hpaio/' "${ROOTFS_DIR}/etc/sane.d/dll.d/hplip"
fi
if [ -f "${ROOTFS_DIR}/etc/sane.d/dll.conf" ]; then
	sed -i -E 's/^[[:space:]]*(v4l|kodakaio|magicolor|epsonds|epson2|dell1600n_net|pixma|escl)$/#\1/' "${ROOTFS_DIR}/etc/sane.d/dll.conf"
fi
if [ -f "${ROOTFS_DIR}/etc/sane.d/airscan.conf" ] && ! grep -q "ws-discovery = fast" "${ROOTFS_DIR}/etc/sane.d/airscan.conf"; then
	sed -i '/^\[options\]/a discovery = enable\nws-discovery = fast' "${ROOTFS_DIR}/etc/sane.d/airscan.conf"
fi

# 8. PipeWire Quantum Floor & Prevent System User (SDDM) Audio Hijacking
install -d -m 755 "${ROOTFS_DIR}/etc/pipewire/pipewire.conf.d"
cat << 'EOF' > "${ROOTFS_DIR}/etc/pipewire/pipewire.conf.d/99-krubus.conf"
context.properties = {
    default.clock.min-quantum = 512
}
EOF

for unit in pipewire.socket pipewire-pulse.socket pipewire.service pipewire-pulse.service wireplumber.service filter-chain.service mpris-proxy.service; do
	install -d -m 755 "${ROOTFS_DIR}/etc/systemd/user/${unit}.d"
	cat << 'EOF' > "${ROOTFS_DIR}/etc/systemd/user/${unit}.d/nosystem.conf"
[Unit]
ConditionUser=!@system
EOF
done

# 9. Bluetooth AutoEnable=true at Boot / Login Screen
chmod 555 "${ROOTFS_DIR}/etc/bluetooth" 2>/dev/null || true
if grep -q "AutoEnable" "${ROOTFS_DIR}/etc/bluetooth/main.conf" 2>/dev/null; then
	sed -i "s/^#*AutoEnable.*/AutoEnable = true/" "${ROOTFS_DIR}/etc/bluetooth/main.conf"
elif [ -f "${ROOTFS_DIR}/etc/bluetooth/main.conf" ]; then
	sed -i "/\\[Policy\\]/a AutoEnable = true" "${ROOTFS_DIR}/etc/bluetooth/main.conf"
fi

# 10. Chroot Finalization: ZRAM, Locales, Flathub, Plymouth, Timeouts & Fast-Boot Presets
on_chroot <<- \EOF
	export DEBIAN_FRONTEND=noninteractive
	/usr/local/sbin/krubus-kde-polish || true
	update-alternatives --set x-www-browser /usr/bin/firefox || true
	update-alternatives --set gnome-www-browser /usr/bin/firefox || true
	plymouth-set-default-theme krubus || true
	for net_helper in /usr/lib/*/libexec/ksysguard/ksgrd_network_helper; do
		[ -f "$net_helper" ] && setcap cap_net_raw=ep "$net_helper" || true
	done

	# Slim KWin Wayland profile inside SDDM Greeter (disable all unneeded desktop plugins & prep cache)
	install -d -m 700 -o sddm -g sddm /var/lib/sddm/.config /var/lib/sddm/.cache
	cat <<- 'SDDMKWIN' > /var/lib/sddm/.config/kwinrc
	[Compositing]
	LatencyPolicy=low

	[Plugins]
	BounceKeysPluginEnabled=false
	KeyNotificationPluginEnabled=false
	MouseKeysPluginEnabled=false
	StickyKeysPluginEnabled=false
	buttonsrebindEnabled=false
	eisEnabled=false
	krunnerintegrationEnabled=false
	nightlightEnabled=false
	screencastEnabled=false
	SDDMKWIN
	chown -R sddm:sddm /var/lib/sddm/.config /var/lib/sddm/.cache
	chmod 600 /var/lib/sddm/.config/kwinrc

	flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo || true
	apt-get purge -y irqbalance xserver-xorg-video-fbdev xdg-desktop-portal-wlr xwaylandvideobridge 2>/dev/null || true

	# Disable heavy/redundant XDG autostarts (Konqueror 171 MB QtWebEngine preload, Kup backup daemon)
	for autostart_f in /etc/xdg/autostart/konqy_preload.desktop /etc/xdg/autostart/kup-daemon.desktop /etc/xdg/autostart/org.kde.xwaylandvideobridge.desktop; do
		if [ -f "$autostart_f" ] && ! grep -q '^Hidden=true' "$autostart_f"; then
			printf '\nHidden=true\n' >> "$autostart_f"
		fi
	done

	# Dynamic ZRAM (no disk swap wear, ultra-low-latency lzo-rle)
	install -d -m 755 /etc/rpi /etc/systemd
	cat <<- 'SWAPCONF' > /etc/rpi/swap.conf
	[Main]
	Mechanism=zram

	[Zram]
	RamMultiplier=1
	MaxSizeMiB=4096

	[File]
	MaxSizeMiB=0
	SWAPCONF

	cat <<- 'ZRAMCONF' > /etc/systemd/zram-generator.conf
	[zram0]
	compression-algorithm = lzo-rle
	ZRAMCONF
	rm -f /var/swap

	# Fast shutdown/reboot timeouts & Wayland environment variables
	install -d -m 755 /etc/systemd/system.conf.d /etc/systemd/user.conf.d /etc/systemd/system/user@.service.d
	cat <<- 'SYSCONF' > /etc/systemd/system.conf.d/99-krubus-timeout.conf
	[Manager]
	DefaultTimeoutStopSec=15s
	DefaultEnvironment=LANG=de_DE.UTF-8
	SYSCONF

	cat <<- 'USERCONF' > /etc/systemd/user.conf.d/99-krubus-timeout.conf
	[Manager]
	DefaultTimeoutStopSec=10s
	USERCONF

	cat <<- 'USERSVCCONF' > /etc/systemd/system/user@.service.d/timeout.conf
	[Service]
	TimeoutStopSec=10s
	USERSVCCONF

	sed -i '/^LANG=/d' /etc/environment 2>/dev/null || true
	echo 'LANG=de_DE.UTF-8' >> /etc/environment
	if ! grep -q "QT_QPA_PLATFORM" /etc/environment 2>/dev/null; then
		echo 'QT_QPA_PLATFORM="wayland;xcb"' >> /etc/environment
	fi
	if ! grep -q "MOZ_ENABLE_WAYLAND" /etc/environment 2>/dev/null; then
		echo 'MOZ_ENABLE_WAYLAND=1' >> /etc/environment
	fi
	if ! grep -q "MOZ_X11_EGL" /etc/environment 2>/dev/null; then
		echo 'MOZ_X11_EGL=1' >> /etc/environment
	fi

	# Pre-generate standard European locales so First-Boot language switch is instantaneous
	echo "locales locales/locales_to_be_generated multiselect de_DE.UTF-8 UTF-8, de_AT.UTF-8 UTF-8, de_CH.UTF-8 UTF-8, en_US.UTF-8 UTF-8, en_GB.UTF-8 UTF-8, fr_FR.UTF-8 UTF-8, es_ES.UTF-8 UTF-8, it_IT.UTF-8 UTF-8, nl_NL.UTF-8 UTF-8, pl_PL.UTF-8 UTF-8, pt_PT.UTF-8 UTF-8" | debconf-set-selections 2>/dev/null || true
	cat <<- 'LOCALECONF' > /etc/locale.gen
	de_DE.UTF-8 UTF-8
	de_AT.UTF-8 UTF-8
	de_CH.UTF-8 UTF-8
	en_US.UTF-8 UTF-8
	en_GB.UTF-8 UTF-8
	fr_FR.UTF-8 UTF-8
	es_ES.UTF-8 UTF-8
	it_IT.UTF-8 UTF-8
	nl_NL.UTF-8 UTF-8
	pl_PL.UTF-8 UTF-8
	pt_PT.UTF-8 UTF-8
	LOCALECONF
	locale-gen || true

	# Boot parallelization: decouple systemd-user-sessions from network.target
	cat <<- 'EOF_SESS' > /etc/systemd/system/systemd-user-sessions.service
	[Unit]
	Description=Permit User Sessions
	Documentation=man:systemd-user-sessions.service(8)
	After=remote-fs.target nss-user-lookup.target home.mount

	[Service]
	Type=oneshot
	RemainAfterExit=yes
	ExecStart=/usr/lib/systemd/systemd-user-sessions start
	ExecStop=/usr/lib/systemd/systemd-user-sessions stop
	EOF_SESS

	# Systemd First-Boot Preset protection (when machine-id=uninitialized)
	install -d -m 755 /etc/systemd/system-preset
	cat <<- 'EOF_PRESET' > /etc/systemd/system-preset/00-krubus.preset
	enable sddm.service
	enable krubus-btrfs-resize.service
	enable krubus-btrfs-compress.timer
	enable rpi-eeprom-update.timer
	enable cups.socket
	disable rpi-eeprom-update.service
	disable cups.service
	disable cups.path
	disable cups-browsed.service
	disable ModemManager.service
	disable udisks2.service
	disable ssh.service
	disable ssh.socket
	disable rpi-resize.service
	disable systemd-firstboot.service
	disable lm-sensors.service
	disable glamor-test.service
	disable rp1-test.service
	disable e2scrub_reap.service
	disable e2scrub_all.timer
	disable nfs-blkmap.service
	disable rpc-statd-notify.service
	disable apt-listchanges.timer
	EOF_PRESET

	systemctl enable sddm.service sshswitch.service rpi-eeprom-update.timer systemd-resolved.service fstrim.timer bluetooth.service earlyoom.service packagekit.service cups.socket || true
	systemctl disable rpi-eeprom-update.service cups.service cups.path cups-browsed.service ModemManager.service udisks2.service ssh.service ssh.socket lm-sensors.service glamor-test.service rp1-test.service e2scrub_reap.service e2scrub_all.timer nfs-blkmap.service rpc-statd-notify.service 2>/dev/null || true
	systemctl mask NetworkManager-wait-online.service systemd-networkd-wait-online.service rpi-resize.service systemd-firstboot.service 2>/dev/null || true
	systemctl set-default graphical.target
EOF
