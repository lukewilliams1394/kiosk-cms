#!/bin/bash
# Ubuntu 24.04.3 Server → Firefox Single Page Kiosk with Auto-Restart and TTS
# Run as root

set -e

echo "=== Updating system ==="
apt update && apt upgrade -y

echo "=== Installing core packages ==="
apt install --no-install-recommends -y \
    xorg openbox xinit dbus-x11 pulseaudio alsa-utils \
    firefox curl wget nano systemd-cron espeak espeak-ng xdg-utils

echo "=== Disabling systemd-networkd-wait-online ==="
systemctl disable systemd-networkd-wait-online.service
systemctl mask systemd-networkd-wait-online.service

# Create kiosk user if missing
if ! id "kiosk" &>/dev/null; then
    adduser kiosk --gecos "" --disabled-password
fi

echo "=== Configuring auto-login ==="
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat >/etc/systemd/system/getty@tty1.service.d/override.conf <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin kiosk --noclear %I $TERM
Type=idle
EOF
systemctl daemon-reexec
systemctl daemon-reload

echo "=== Setting up kiosk environment for 'kiosk' user ==="
su - kiosk -s /bin/bash <<'EOF'
set -e

# Auto-start X session
cat > ~/.bash_profile <<'EOB'
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
  startx
fi
EOB

# X session startup
cat > ~/.xinitrc <<'EOC'
#!/bin/bash
xset s off
xset -dpms
xset s noblank

pulseaudio --start
sleep 2
amixer -D pulse sset Master 100% || true

TARGET_URL="http://server02:4040/Tracking/Scanner"
OFFLINE_FLAG=1
ONLINE_FLAG=0

while true; do
    # Wait for network
    while ! ping -c1 8.8.8.8 &>/dev/null; do
        if [ $OFFLINE_FLAG -eq 0 ]; then
            espeak-ng "Attention. The scanning station is offline."
            OFFLINE_FLAG=1
            ONLINE_FLAG=0
        fi
        sleep 5
    done

    if [ $ONLINE_FLAG -eq 0 ]; then
        espeak-ng "Network restored. Scanning station live."
        ONLINE_FLAG=1
        OFFLINE_FLAG=0
    fi

    # Kill any existing Firefox instances
    pkill firefox || true
    sleep 1

    # Launch Firefox in kiosk mode
    firefox --kiosk "$TARGET_URL" >/dev/null 2>&1 &

    # Wait until Firefox crashes or is killed
    FIREFOX_PID=$!
    while kill -0 $FIREFOX_PID 2>/dev/null; do
        sleep 5
    done

    echo "Firefox crashed or closed. Restarting in 5s..."
    sleep 5
done
EOC

chmod +x ~/.xinitrc
EOF

# Force 1920x1080 resolution
mkdir -p /etc/X11/xorg.conf.d
cat >/etc/X11/xorg.conf.d/10-monitor.conf <<'EOF'
Section "Monitor"
    Identifier "Monitor0"
    Option "PreferredMode" "1920x1080"
EndSection
Section "Screen"
    Identifier "Screen0"
    Device "Device0"
    Monitor "Monitor0"
    SubSection "Display"
        Modes "1920x1080"
    EndSubSection
EndSection
EOF

# Hardening & daily reboot
systemctl mask ctrl-alt-del.target
cat >/etc/cron.d/kiosk-reboot <<'EOF'
0 3 * * * root /sbin/reboot
EOF
chmod 644 /etc/cron.d/kiosk-reboot

echo "=== Setup complete. Rebooting in 5 seconds ==="
sleep 5
reboot
