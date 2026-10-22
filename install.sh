#!/bin/bash
# Build G4KLX DStarRepeater on this Pi and install Icom Access Point/Terminal Mode
# support for WPSD. Run from the folder containing these files:   sudo ./install.sh
set -euo pipefail

SRC=/usr/local/src/DStarRepeater
REPO=https://github.com/g4klx/DStarRepeater
HERE=$(cd "$(dirname "$0")" && pwd)

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo: sudo ./install.sh"; exit 1; }
for f in 99-icom-ta.rules dstarrepeater-icom.service icom-mode; do
    [ -f "$HERE/$f" ] || { echo "Missing $f - keep all the files in one folder"; exit 1; }
done

# Pi-Star-style read-only root, just in case
command -v rpi-rw >/dev/null 2>&1 && rpi-rw || true

echo "== Installing build tools"
apt-get update
apt-get install -y git g++ make libusb-1.0-0-dev
# libasound2-dev must match the installed ALSA library exactly (WPSD may use a backports version)
ASOUND_VER=$(dpkg-query -W -f='${Version}' libasound2t64 2>/dev/null || dpkg-query -W -f='${Version}' libasound2 2>/dev/null || true)
CODENAME=$(sed -n 's/^VERSION_CODENAME=//p' /etc/os-release | tr -d '"')
if dpkg -s libasound2-dev >/dev/null 2>&1; then
    echo "   libasound2-dev already installed"
elif [ -n "$ASOUND_VER" ] && apt-get install -y "libasound2-dev=$ASOUND_VER"; then
    :
elif [ -n "$CODENAME" ] && apt-get install -y -t "$CODENAME-backports" libasound2t64 libasound2-dev; then
    :
else
    apt-get install -y libasound2-dev
fi

# A Pi Zero has 512 MB RAM; make sure there's some swap so the compiler doesn't get killed.
swap_kb=$(awk '/SwapTotal/ {print $2}' /proc/meminfo)
mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
TMPSWAP=""
if [ "$mem_kb" -lt 1500000 ] && [ "$swap_kb" -lt 500000 ]; then
    echo "== Low memory: adding a temporary 512 MB swap file for the build"
    TMPSWAP=/var/tmp/dstarrepeater-build.swap
    fallocate -l 512M "$TMPSWAP" 2>/dev/null || dd if=/dev/zero of="$TMPSWAP" bs=1M count=512
    chmod 600 "$TMPSWAP"; mkswap "$TMPSWAP" >/dev/null; swapon "$TMPSWAP"
fi
cleanup() { if [ -n "$TMPSWAP" ]; then swapoff "$TMPSWAP" 2>/dev/null || true; rm -f "$TMPSWAP"; fi; }
trap cleanup EXIT

echo "== Getting DStarRepeater source"
if [ -d "$SRC/.git" ]; then
    git -C "$SRC" pull --ff-only
else
    git clone --depth 1 "$REPO" "$SRC"
fi
git -C "$SRC" log -1 --format='   version: %h %ci'

echo "== Building (10-20+ minutes on a Pi Zero, be patient)"
make -C "$SRC" clean >/dev/null 2>&1 || true
JOBS=$(nproc); [ "$mem_kb" -lt 1500000 ] && JOBS=1
make -C "$SRC" MQTT=0 GPIO=0 -j"$JOBS"
make -C "$SRC" MQTT=0 GPIO=0 install

echo "== Installing udev rule, service and icom-mode"
install -m 0644 "$HERE/99-icom-ta.rules" /etc/udev/rules.d/99-icom-ta.rules
udevadm control --reload-rules
udevadm trigger --subsystem-match=tty
install -m 0644 "$HERE/dstarrepeater-icom.service" /etc/systemd/system/dstarrepeater-icom.service
systemctl daemon-reload
install -m 0755 "$HERE/icom-mode" /usr/local/bin/icom-mode

echo "== Writing DStarRepeater config from your WPSD settings"
/usr/local/bin/icom-mode config

echo
echo "Done. With the radio plugged in and in Access Point (or Terminal) mode:"
echo "   sudo icom-mode start --watch    run it here and watch; Ctrl+C returns to WPSD"
echo "   sudo icom-mode start            run it in the background; 'icom-mode log' to watch"
echo "   sudo icom-mode stop             back to normal WPSD"
[ -e /dev/icom_ta ] && echo "Radio found at /dev/icom_ta." || echo "Radio not found at /dev/icom_ta yet - plug it in (data port) and switch it on."
