#!/bin/bash
# Ubuntu 24.04.3 Server → Firefox Kiosk with persistent profiles, splash, TTS, clean logs
# Run as root

set -e

echo "=== Updating system ==="
apt update && apt upgrade -y

echo "=== Installing core packages ==="
apt install --no-install-recommends -y \
    xorg openbox xinit dbus-x11 pulseaudio alsa-utils \
    firefox curl wget nano systemd-cron xdotool \
    espeak espeak-ng speech-dispatcher speech-dispatcher-espeak-ng xdg-utils

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

# Ensure Firefox persistent profiles exist
mkdir -p ~/firefox-profiles
firefox -CreateProfile "splash ~/firefox-profiles/splash" >/dev/null
firefox -CreateProfile "live ~/firefox-profiles/live" >/dev/null

# Autostart Speech Dispatcher
mkdir -p ~/.config/autostart
cat > ~/.config/autostart/speech-dispatcher.desktop <<'EOT'
[Desktop Entry]
Type=Application
Exec=speech-dispatcher -d
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
Name=Speech Dispatcher
EOT

# Splash page with dynamic loader
mkdir -p ~/kiosk-fallback
cat > ~/kiosk-fallback/splash.html <<'EOL'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Loading Scanning Station...</title>
<style>
html, body { height:100%; margin:0; display:flex; justify-content:center; align-items:center; background:#ffffff; font-family:Arial,sans-serif; overflow:hidden;}
.container {text-align:center; animation: fadein 1.5s ease-out;}
.logo {width:200px;height:200px;margin:0 auto 1em;background-size:contain;background-repeat:no-repeat;background-position:center;background-image:url('data:image/png;base64,PASTE_YOUR_BASE64_IMAGE_HERE');}
.loader {border:8px solid #e0e0e0;border-top:8px solid #0078d7;border-radius:50%;width:60px;height:60px;margin:20px auto;animation:spin 1s linear infinite;}
p {font-size:1.5em;margin:0;opacity:0.85;}
@keyframes spin {0%{transform:rotate(0deg);}100%{transform:rotate(360deg);}}
@keyframes fadein {from{opacity:0;transform:translateY(20px);}to{opacity:1;transform:translateY(0);}}
@keyframes fadeout {from{opacity:1;}to{opacity:0;}}
</style>
</head>
<body>
<div class="container" id="container">
  <div class="logo"></div>
  <div class="loader"></div>
  <p>Loading Scanning Station...</p>
</div>
<script>
function fadeOutSplash() {
  const c=document.getElementById('container');
  const loader=document.querySelector('.loader');
  let speed=1;
  const speedInterval=setInterval(()=>{
    if(speed>0.1){speed-=0.1;loader.style.animation=`spin ${speed}s linear infinite`;}
  },100);
  c.style.transition="opacity 1s ease-out";
  c.style.opacity=0;
  setTimeout(()=>{clearInterval(speedInterval); window.close();},1200);
}
</script>
</body>
</html>
EOL

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
SPLASH_URL="file://$HOME/kiosk-fallback/splash.html"
SPLASH_PROFILE="$HOME/firefox-profiles/splash"
LIVE_PROFILE="$HOME/firefox-profiles/live"

OFFLINE_FLAG=1
ONLINE_FLAG=0

while true; do
    # Launch splash (suppress warnings)
    firefox --kiosk "$SPLASH_URL" --profile "$SPLASH_PROFILE" >/dev/null 2>&1 &
    SPLASH_PID=$!
    sleep 2

    # Monitor network
    while true; do
        if ping -c1 8.8.8.8 &>/dev/null; then
            if [ $ONLINE_FLAG -eq 0 ]; then
                # Fade out splash
                DISPLAY=:0 xdotool search --pid $SPLASH_PID behave %@ mouse-enter key --delay 0 "windowactivate %@"
                espeak-ng "Network restored. Scanning station live."
                ONLINE_FLAG=1
                OFFLINE_FLAG=0
            fi
            # Kill splash and launch live page
            sleep 1.2
            kill $SPLASH_PID || true
            firefox --kiosk "$TARGET_URL" --profile "$LIVE_PROFILE" >/dev/null 2>&1 &
            LIVE_PID=$!
            break
        else
            if [ $OFFLINE_FLAG -eq 0 ]; then
                espeak-ng "Attention. The scanning station is offline."
                OFFLINE_FLAG=1
                ONLINE_FLAG=0
            fi
        fi
        sleep 5
    done

    # Monitor live page
    while pgrep -f "firefox.*$LIVE_PID" >/dev/null; do sleep 5; done
    echo "Live Firefox crashed, restarting splash..."
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
