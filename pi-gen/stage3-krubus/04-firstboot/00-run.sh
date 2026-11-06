#!/bin/bash -e

install -d -m 755 "${ROOTFS_DIR}/usr/local/sbin" "${ROOTFS_DIR}/etc/systemd/system" "${ROOTFS_DIR}/etc/systemd/journald.conf.d"

# Persistent systemd journal with flash-safe size cap
rm -f "${ROOTFS_DIR}/etc/systemd/journald.conf.d/00-persistent.conf"
cat << 'JCONF' > "${ROOTFS_DIR}/etc/systemd/journald.conf.d/99-persistent.conf"
[Journal]
Storage=persistent
SystemMaxUse=100M
RuntimeMaxUse=50M
JCONF
install -d -m 2755 "${ROOTFS_DIR}/var/log/journal"

cat << 'EOF' > "${ROOTFS_DIR}/usr/local/sbin/krubus-firstboot.sh"
#!/bin/bash
set -u

export TERM=linux
export NEWT_COLORS='
root=,blue
window=,lightgray
border=black,lightgray
shadow=,black
title=blue,lightgray
button=white,blue
actbutton=white,red
listbox=black,lightgray
actlistbox=white,blue
textbox=black,lightgray
entry=black,white
'

# Stop Plymouth splash and switch to TTY1 for interactive setup
/usr/bin/plymouth deactivate 2>/dev/null || true
/usr/bin/plymouth quit 2>/dev/null || true
chvt 1 2>/dev/null || true
clear

# --- 1. Keyboard Layout ---
KB_LAYOUT=$(whiptail --title "KRubus First-Boot Setup (1/6) - Keyboard Layout" \
    --menu "Please select your keyboard layout:" 18 70 8 \
    "de"            "German (Standard QWERTZ)" \
    "de-nodeadkeys" "German (No dead keys)" \
    "ch"            "German (Switzerland)" \
    "at"            "German (Austria)" \
    "us"            "English (US QWERTY)" \
    "gb"            "English (UK QWERTY)" \
    "fr"            "French (AZERTY)" \
    "es"            "Spanish" \
    3>&1 1>&2 2>&3) || KB_LAYOUT="de"

case "$KB_LAYOUT" in
    de-nodeadkeys) XKB_LAYOUT="de"; XKB_VARIANT="nodeadkeys" ;;
    de)            XKB_LAYOUT="de"; XKB_VARIANT="" ;;
    ch)            XKB_LAYOUT="ch"; XKB_VARIANT="" ;;
    at)            XKB_LAYOUT="at"; XKB_VARIANT="" ;;
    fr)            XKB_LAYOUT="fr"; XKB_VARIANT="" ;;
    es)            XKB_LAYOUT="es"; XKB_VARIANT="" ;;
    gb)            XKB_LAYOUT="gb"; XKB_VARIANT="" ;;
    us)            XKB_LAYOUT="us"; XKB_VARIANT="" ;;
    *)             XKB_LAYOUT="$KB_LAYOUT"; XKB_VARIANT="" ;;
esac

grep -q "^XKBLAYOUT=" /etc/default/keyboard && sed -i "s/^XKBLAYOUT=.*/XKBLAYOUT=\"$XKB_LAYOUT\"/" /etc/default/keyboard || echo "XKBLAYOUT=\"$XKB_LAYOUT\"" >> /etc/default/keyboard
grep -q "^XKBVARIANT=" /etc/default/keyboard && sed -i "s/^XKBVARIANT=.*/XKBVARIANT=\"$XKB_VARIANT\"/" /etc/default/keyboard || echo "XKBVARIANT=\"$XKB_VARIANT\"" >> /etc/default/keyboard
grep -q "^XKBMODEL=" /etc/default/keyboard || echo 'XKBMODEL="pc105"' >> /etc/default/keyboard

if [ -n "$XKB_VARIANT" ]; then
    ckbcomp "$XKB_LAYOUT" "$XKB_VARIANT" 2>/dev/null | loadkeys 2>/dev/null || true
    localectl set-x11-keymap "$XKB_LAYOUT" pc105 "$XKB_VARIANT" 2>/dev/null || true
else
    ckbcomp "$XKB_LAYOUT" 2>/dev/null | loadkeys 2>/dev/null || true
    localectl set-x11-keymap "$XKB_LAYOUT" pc105 "" 2>/dev/null || true
fi
setupcon -k --force 2>/dev/null || true
setupcon --save-only 2>/dev/null || true
udevadm trigger --subsystem-match=input --action=change 2>/dev/null || true

# Configure KDE Plasma 6 Wayland keyboard defaults (/etc/xdg/kxkbrc & /etc/skel/.config/kxkbrc)
mkdir -p /etc/xdg /etc/skel/.config
cat << KXKB > /etc/xdg/kxkbrc
[Layout]
DisplayNames=
LayoutList=${XKB_LAYOUT}
Model=pc105
Use=true
VariantList=${XKB_VARIANT}
KXKB
cp /etc/xdg/kxkbrc /etc/skel/.config/kxkbrc

whiptail --title "KRubus First-Boot Setup (1/6) - Keyboard Test" \
    --inputbox "Keyboard layout applied. You can test typing here (e.g. Z, Y, @, ?, -, _):\n(Select 'OK' or press Enter to continue)" 12 70 "" 3>&1 1>&2 2>&3 || true

# --- 2. System Language & Timezone ---
LOCALE_CHOICE=$(whiptail --title "KRubus First-Boot Setup (2/6) - Language & Timezone" \
    --menu "Please select your system language and timezone:" 16 70 6 \
    "de_DE.UTF-8" "German (Germany)  - Europe/Berlin" \
    "de_AT.UTF-8" "German (Austria)  - Europe/Vienna" \
    "de_CH.UTF-8" "German (Swiss)    - Europe/Zurich" \
    "en_US.UTF-8" "English (US)      - UTC" \
    "en_GB.UTF-8" "English (UK)      - Europe/London" \
    "fr_FR.UTF-8" "French (France)   - Europe/Paris" \
    3>&1 1>&2 2>&3) || LOCALE_CHOICE="de_DE.UTF-8"

case "$LOCALE_CHOICE" in
    en_GB.UTF-8) TZ_CHOICE="Europe/London"; WIFI_CC="GB"; KDE_LANG="en_GB" ;;
    de_DE.UTF-8) TZ_CHOICE="Europe/Berlin"; WIFI_CC="DE"; KDE_LANG="de" ;;
    de_AT.UTF-8) TZ_CHOICE="Europe/Vienna"; WIFI_CC="AT"; KDE_LANG="de" ;;
    de_CH.UTF-8) TZ_CHOICE="Europe/Zurich"; WIFI_CC="CH"; KDE_LANG="de" ;;
    fr_FR.UTF-8) TZ_CHOICE="Europe/Paris";  WIFI_CC="FR"; KDE_LANG="fr" ;;
    *)           TZ_CHOICE="UTC";           WIFI_CC="US"; KDE_LANG="en_US" ;;
esac

if [ -n "$LOCALE_CHOICE" ]; then
    grep -q "^${LOCALE_CHOICE} UTF-8" /etc/locale.gen 2>/dev/null || echo "${LOCALE_CHOICE} UTF-8" >> /etc/locale.gen
    if ! locale -a 2>/dev/null | grep -qi "^${LOCALE_CHOICE%.UTF-8}"; then
        whiptail --title "Language Setup" --infobox "Generating locale ${LOCALE_CHOICE}, please wait..." 8 55
        locale-gen "$LOCALE_CHOICE" >/dev/null 2>&1 || locale-gen >/dev/null 2>&1 || true
    fi
    update-locale --reset LANG="$LOCALE_CHOICE" LANGUAGE="${LOCALE_CHOICE%%.*}" 2>/dev/null || echo "LANG=$LOCALE_CHOICE" > /etc/locale.conf
    sed -i '/^LANG=/d' /etc/environment 2>/dev/null || true
    echo "LANG=${LOCALE_CHOICE}" >> /etc/environment
    if [ -f /etc/systemd/system.conf.d/99-krubus-timeout.conf ]; then
        sed -i "s/^DefaultEnvironment=LANG=.*/DefaultEnvironment=LANG=${LOCALE_CHOICE}/" /etc/systemd/system.conf.d/99-krubus-timeout.conf
    fi
    cat << PLOC > /etc/xdg/plasma-localerc
[Formats]
LANG=${LOCALE_CHOICE}

[Translations]
LANGUAGE=${KDE_LANG}
PLOC
    cp /etc/xdg/plasma-localerc /etc/skel/.config/plasma-localerc
fi
raspi-config nonint do_change_timezone "$TZ_CHOICE" 2>/dev/null || true
raspi-config nonint do_wifi_country "$WIFI_CC" 2>/dev/null || true
rfkill unblock wifi 2>/dev/null || true
nmcli radio wifi on 2>/dev/null || true

# --- 3. Hostname ---
CURRENT_HOST=$(hostname)
while true; do
    NEW_HOST=$(whiptail --title "KRubus First-Boot Setup (3/6) - Hostname" \
        --inputbox "Enter a network name (hostname) for this Raspberry Pi 5:" 12 70 "${CURRENT_HOST:-krubus-pi5}" \
        3>&1 1>&2 2>&3) || NEW_HOST="${CURRENT_HOST:-krubus-pi5}"
    if echo "$NEW_HOST" | grep -Eq '^[a-zA-Z0-9][a-zA-Z0-9-]{0,61}[a-zA-Z0-9]$'; then
        raspi-config nonint do_hostname "$NEW_HOST" 2>/dev/null || hostnamectl set-hostname "$NEW_HOST" 2>/dev/null || true
        echo "$NEW_HOST" > /etc/hostname
        sed -i "s/127\.0\.1\.1.*/127.0.1.1\t$NEW_HOST/" /etc/hosts 2>/dev/null || true
        break
    else
        whiptail --title "Invalid Hostname" --msgbox "The hostname may only contain letters, numbers, and hyphens." 10 65
    fi
done

# --- 4. Wi-Fi Configuration ---
if whiptail --title "KRubus First-Boot Setup (4/6) - Wi-Fi Setup" \
    --yesno "Would you like to connect to a Wi-Fi network now?\n(Select 'No' if using Ethernet or if you wish to configure Wi-Fi later in KDE Plasma)" 12 72; then
    rfkill unblock wifi 2>/dev/null || true
    nmcli radio wifi on 2>/dev/null || true
    sleep 2
    while true; do
        whiptail --title "Wi-Fi Scan" --infobox "Scanning for Wi-Fi networks..." 8 50
        mapfile -t WIFI_LIST < <(nmcli --terse --fields SSID,SIGNAL,SECURITY device wifi list --rescan yes 2>/dev/null | awk -F: 'NF>=1 && $1!="" && !seen[$1]++ {printf "%s\n%s%% (%s)\n", $1, $2, $3}')
        if [ "${#WIFI_LIST[@]}" -eq 0 ]; then
            if ! whiptail --title "No Networks Found" --yesno "No Wi-Fi networks were detected. Scan again?" 10 60; then
                break
            fi
            continue
        fi
        SSID=$(whiptail --title "KRubus First-Boot Setup (4/6) - Select Wi-Fi" \
            --menu "Choose your Wi-Fi network (Cancel to skip):" 20 75 10 \
            "${WIFI_LIST[@]}" \
            3>&1 1>&2 2>&3) || break

        PASS_MODE=$(whiptail --title "KRubus First-Boot Setup (4/6) - Password Input" \
            --menu "How would you like to enter the Wi-Fi password for '$SSID'?" 13 65 2 \
            "visible" "Show in plain text (Recommended to prevent typos)" \
            "hidden"  "Mask with asterisks (*)" \
            3>&1 1>&2 2>&3) || PASS_MODE="visible"

        if [ "$PASS_MODE" = "visible" ]; then
            WIFI_PASS=$(whiptail --title "Wi-Fi Password for '$SSID'" \
                --inputbox "Enter password for '$SSID' (leave empty for open networks):" 12 70 \
                3>&1 1>&2 2>&3) || continue
        else
            WIFI_PASS=$(whiptail --title "Wi-Fi Password for '$SSID'" \
                --passwordbox "Enter password for '$SSID' (leave empty for open networks):" 12 70 \
                3>&1 1>&2 2>&3) || continue
        fi

        whiptail --title "Wi-Fi" --infobox "Connecting to '$SSID'..." 8 55
        if [ -n "$WIFI_PASS" ]; then
            CONNECT_OUT=$(nmcli device wifi connect "$SSID" password "$WIFI_PASS" 2>&1)
            RES=$?
        else
            CONNECT_OUT=$(nmcli device wifi connect "$SSID" 2>&1)
            RES=$?
        fi

        if [ $RES -eq 0 ]; then
            whiptail --title "Wi-Fi Connected" --msgbox "Successfully connected to '$SSID'!" 10 60
            break
        else
            whiptail --title "Connection Failed" --yesno "Failed to connect:\n\n$CONNECT_OUT\n\nTry again?" 15 70 || break
        fi
    done
fi

# --- 5. Username, Password & Automatic Login ---
FIRST_USER=$(getent passwd 1000 | cut -d: -f1)
FIRST_USER=${FIRST_USER:-pi}

while true; do
    NEW_USER=$(whiptail --title "KRubus First-Boot Setup (5/6) - Username" \
        --inputbox "Desired username (lowercase letters, numbers; starts with a letter):" 12 70 "$FIRST_USER" \
        3>&1 1>&2 2>&3) || NEW_USER="$FIRST_USER"
    if echo "$NEW_USER" | grep -Eq '^[a-z][a-z0-9_-]{0,30}$' && [ "$NEW_USER" != "root" ]; then
        break
    else
        whiptail --title "Invalid Username" --msgbox "Please use lowercase letters, numbers, '-' or '_' (minimum 1 character, not 'root')." 10 70
    fi
done

while true; do
    PASS1=$(whiptail --title "KRubus First-Boot Setup (5/6) - Password" \
        --passwordbox "Enter new password for user '$NEW_USER':" 12 70 \
        3>&1 1>&2 2>&3) || continue
    if [ -z "$PASS1" ]; then
        whiptail --title "Error" --msgbox "The password cannot be empty." 10 50
        continue
    fi
    PASS2=$(whiptail --title "KRubus First-Boot Setup (5/6) - Confirm Password" \
        --passwordbox "Please re-enter the password to confirm:" 12 70 \
        3>&1 1>&2 2>&3) || continue
    if [ "$PASS1" != "$PASS2" ]; then
        whiptail --title "Error" --msgbox "Passwords do not match. Please try again." 10 65
        continue
    fi
    break
done

if [ "$NEW_USER" != "$FIRST_USER" ] && getent passwd "$FIRST_USER" >/dev/null; then
    usermod -l "$NEW_USER" -d "/home/$NEW_USER" -m "$FIRST_USER" 2>/dev/null || true
    groupmod -n "$NEW_USER" "$FIRST_USER" 2>/dev/null || true
    if [ -f /etc/sudoers.d/010_pi-nopasswd ]; then
        sed -i "s/^${FIRST_USER}\b/${NEW_USER}/" /etc/sudoers.d/010_pi-nopasswd 2>/dev/null || true
    fi
fi
echo "${NEW_USER}:${PASS1}" | chpasswd
for grp in sudo adm dialout cdrom audio users video plugdev input netdev render i2c; do
    usermod -aG "$grp" "$NEW_USER" 2>/dev/null || true
done

USER_HOME=$(getent passwd "$NEW_USER" | cut -d: -f6)
if [ -n "$USER_HOME" ] && [ -d "$USER_HOME" ]; then
    mkdir -p "$USER_HOME/.config"
    cp /etc/xdg/kxkbrc "$USER_HOME/.config/kxkbrc" 2>/dev/null || true
    cp /etc/xdg/plasma-localerc "$USER_HOME/.config/plasma-localerc" 2>/dev/null || true
    chown -R "${NEW_USER}:${NEW_USER}" "$USER_HOME/.config" 2>/dev/null || true
fi

mkdir -p /etc/sddm.conf.d
rm -f /etc/sddm.conf.d/autologin.conf
if whiptail --title "KRubus First-Boot Setup (5/6) - Automatic Login" \
    --yesno "Would you like to automatically log into KDE Plasma 6 (Wayland) without entering your password on boot?\n\n(Select 'No' to require your password on the SDDM login screen)" 12 74; then
    PLASMA_SESS="plasma"
    if [ ! -f /usr/share/wayland-sessions/plasma.desktop ]; then
        FIRST_WL="$(ls /usr/share/wayland-sessions/*.desktop 2>/dev/null | head -n 1 || true)"
        [ -n "$FIRST_WL" ] && PLASMA_SESS="$(basename "$FIRST_WL" .desktop)"
    fi
    cat << ALCONF > /etc/sddm.conf.d/autologin.conf
[Autologin]
User=${NEW_USER}
Session=${PLASMA_SESS}
Relogin=false
ALCONF
fi

# --- 6. Optional Hardware & System Tweaks ---
TWEAK_CHOICES=$(whiptail --title "KRubus First-Boot Setup (6/6) - Optional System Tweaks" \
    --checklist "Select optional hardware features and tweaks to enable:\n(Use UP/DOWN arrows to navigate, SPACE to toggle [X], ENTER to confirm)" 17 78 6 \
    "pcie_gen3"  "PCIe Gen 3.0 mode (~850 MB/s for fast NVMe SSDs)" "OFF" \
    "oc_2800"    "Overclock CPU to 2.8 GHz (Requires active cooling)" "OFF" \
    "usb_boost"  "Unlock 1.6A USB port current on non-PD 5V power" "OFF" \
    "ssh_server" "Enable SSH server for remote terminal/SFTP access" "OFF" \
    "i2c_spi"    "Enable GPIO I2C & SPI buses (Sensors, Displays, HATs)" "ON" \
    "bt_auto"    "Enable Bluetooth automatically on system startup" "ON" \
    3>&1 1>&2 2>&3) || TWEAK_CHOICES="\"i2c_spi\" \"bt_auto\""

BOOTCONF="/boot/firmware/config.txt"
[ ! -f "$BOOTCONF" ] && BOOTCONF="/boot/config.txt"

if [ -f "$BOOTCONF" ]; then
    sed -i '/^dtparam=pciex1_gen=/d' "$BOOTCONF"
    if [[ "$TWEAK_CHOICES" == *"pcie_gen3"* ]]; then
        echo "dtparam=pciex1_gen=3" >> "$BOOTCONF"
    fi

    sed -i '/^arm_freq=/d' "$BOOTCONF"
    if [[ "$TWEAK_CHOICES" == *"oc_2800"* ]]; then
        echo "arm_freq=2800" >> "$BOOTCONF"
    fi

    sed -i '/^usb_max_current_enable=/d' "$BOOTCONF"
    if [[ "$TWEAK_CHOICES" == *"usb_boost"* ]]; then
        echo "usb_max_current_enable=1" >> "$BOOTCONF"
    fi

    if [[ "$TWEAK_CHOICES" == *"i2c_spi"* ]]; then
        sed -i 's/^#*dtparam=i2c_arm=.*/dtparam=i2c_arm=on/' "$BOOTCONF"
        sed -i 's/^#*dtparam=spi=.*/dtparam=spi=on/' "$BOOTCONF"
    else
        sed -i 's/^dtparam=i2c_arm=.*/#dtparam=i2c_arm=on/' "$BOOTCONF"
        sed -i 's/^dtparam=spi=.*/#dtparam=spi=on/' "$BOOTCONF"
    fi
fi

if [[ "$TWEAK_CHOICES" == *"ssh_server"* ]]; then
    systemctl enable ssh.socket 2>/dev/null || true
    systemctl start ssh.socket 2>/dev/null || true
else
    systemctl disable ssh.socket ssh.service 2>/dev/null || true
fi

if [ -f /etc/bluetooth/main.conf ]; then
    if [[ "$TWEAK_CHOICES" == *"bt_auto"* ]]; then
        sed -i "s/^#*AutoEnable.*/AutoEnable = true/" /etc/bluetooth/main.conf 2>/dev/null || true
        rfkill unblock bluetooth 2>/dev/null || true
    else
        sed -i "s/^#*AutoEnable.*/AutoEnable = false/" /etc/bluetooth/main.conf 2>/dev/null || true
        rfkill block bluetooth 2>/dev/null || true
    fi
fi

systemctl disable krubus-firstboot.service 2>/dev/null || true
sync

if whiptail --title "KRubus Setup Complete" \
    --yesno "Setup is complete!\n\nYour KDE Plasma 6 (Wayland) configuration and hardware settings have been applied.\n\nA system restart is recommended so all hardware and locale settings take full effect.\n\nWould you like to restart now?" 15 72; then
    whiptail --title "Rebooting" --infobox "Rebooting into KRubus KDE Plasma 6, please wait..." 8 55
    sleep 1
    systemctl --no-block reboot
else
    exit 0
fi
EOF
chmod 755 "${ROOTFS_DIR}/usr/local/sbin/krubus-firstboot.sh"

cat << 'EOF' > "${ROOTFS_DIR}/etc/systemd/system/krubus-firstboot.service"
[Unit]
Description=KRubus Interactive TTY First-Boot Configuration Wizard
After=systemd-user-sessions.service NetworkManager.service krubus-btrfs-resize.service
Before=sddm.service display-manager.service getty@tty1.service plymouth-quit-wait.service
Conflicts=getty@tty1.service
ConditionPathExists=/usr/local/sbin/krubus-firstboot.sh

[Service]
Type=oneshot
TimeoutStartSec=0
ExecStartPre=-/usr/bin/plymouth deactivate
ExecStartPre=-/usr/bin/plymouth quit
ExecStartPre=-/bin/chvt 1
ExecStart=/usr/local/sbin/krubus-firstboot.sh
StandardInput=tty
StandardOutput=tty
StandardError=tty
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
TTYVTDisallocate=yes
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

on_chroot <<- \EOF
	apt-get purge -y cloud-init rpi-cloud-init-mods rpi-usb-gadget rpi-update libpam-chksshpwd userconf-pi 2>/dev/null || true
	apt-get autoremove -y --purge 2>/dev/null || true
	chown root:systemd-journal /var/log/journal 2>/dev/null || true
	systemctl enable krubus-firstboot.service
EOF
