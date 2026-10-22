#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 868meshbot
# Build G4KLX DStarRepeater on this Pi and install Icom Access Point/Terminal Mode
# support for WPSD. Self-contained: save as install.sh and run: sudo bash install.sh
set -euo pipefail

SRC=/usr/local/src/DStarRepeater
REPO=https://github.com/g4klx/DStarRepeater

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo: sudo bash install.sh"; exit 1; }
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
cat > /etc/udev/rules.d/99-icom-ta.rules <<'RULES'
# Icom ID-50E (USB 0c26:0046) -> /dev/icom_ta
# For another Icom radio, check its ID with `lsusb` and add a line with its idProduct.
SUBSYSTEM=="tty", ATTRS{idVendor}=="0c26", ATTRS{idProduct}=="0046", SYMLINK+="icom_ta", GROUP="dialout", MODE="0660"
RULES
udevadm control --reload-rules
udevadm trigger --subsystem-match=tty

cat > /etc/systemd/system/dstarrepeater-icom.service <<'UNIT'
[Unit]
Description=DStarRepeater - Icom Access Point/Terminal Mode
After=network.target
# Not enabled at boot: started and stopped by `icom-mode`.

[Service]
Type=simple
RuntimeDirectory=dstarrepeater
Environment=DSTAR_RUN_DIR=/run/dstarrepeater
ExecStart=/usr/bin/dstarrepeaterd /etc/dstarrepeater/icom.ini
Restart=on-failure
RestartSec=3s
TimeoutStopSec=10s
KillSignal=SIGTERM
StandardOutput=journal
StandardError=journal
SyslogIdentifier=dstarrepeaterd

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload

cat > /usr/local/bin/icom-mode <<'ICOMMODE'
#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 868meshbot
# icom-mode: switch a WPSD hotspot between MMDVMHost and DStarRepeater driving an
# Icom radio in Access Point / Terminal Mode (USB, /dev/icom_ta).
#
#   icom-mode start          stop MMDVMHost, start DStarRepeater as a service
#   icom-mode start --watch  same, but run in this terminal; Ctrl+C returns to WPSD
#   icom-mode stop           stop DStarRepeater, start MMDVMHost again
#   icom-mode status         what's running, radio present, recent log
#   icom-mode log            follow the DStarRepeater log live
#   icom-mode config         (re)write the DStarRepeater config from WPSD's settings

set -u

MMDVM_CONF=${MMDVM_CONF:-/etc/mmdvmhost}
GW_CONF=${GW_CONF:-/etc/ircddbgateway}
ICOM_CONF=${ICOM_CONF:-/etc/dstarrepeater/icom.ini}
ICOM_PORT=${ICOM_PORT:-/dev/icom_ta}
LOG_DIR=${LOG_DIR:-/var/log/pi-star}
SERVICE=dstarrepeater-icom
MMDVM_SERVICE=mmdvmhost
DAEMON=/usr/bin/dstarrepeaterd

die()  { echo "icom-mode: $*" >&2; exit 1; }
warn() { echo "icom-mode: warning: $*" >&2; }
need_root() { [ "$(id -u)" -eq 0 ] || die "run with sudo"; }

# ini_get FILE SECTION KEY  - value from an INI file (MMDVMHost style)
ini_get() {
    awk -v s="[$2]" -v k="$3" '
        $0 == s { f = 1; next }
        /^\[/   { f = 0 }
        f { i = index($0, "="); if (i && substr($0, 1, i - 1) == k) { print substr($0, i + 1); exit } }
    ' "$1" 2>/dev/null
}

# flat_get FILE KEY  - value from a flat key=value file (ircDDBGateway style)
flat_get() {
    awk -v k="$2" '{ i = index($0, "="); if (i && substr($0, 1, i - 1) == k) { print substr($0, i + 1); exit } }' "$1" 2>/dev/null
}

trim() { local v="$*"; v="${v#"${v%%[![:space:]]*}"}"; printf '%s' "${v%"${v##*[![:space:]]}"}"; }

unit_exists() { systemctl cat "$1.service" >/dev/null 2>&1; }

write_config() {
    local call module gwport localport
    call=$(trim "$(flat_get "$GW_CONF" repeaterCall1)")
    [ -n "$call" ] || call=$(trim "$(ini_get "$MMDVM_CONF" General Callsign)")
    [ -n "$call" ] || die "can't find your callsign in $GW_CONF or $MMDVM_CONF"
    call=${call^^}

    module=$(trim "$(flat_get "$GW_CONF" repeaterBand1)")
    [ -n "$module" ] || module=$(trim "$(ini_get "$MMDVM_CONF" D-Star Module)")
    [ -n "$module" ] || module=B
    module=${module:0:1}; module=${module^^}

    gwport=$(trim "$(flat_get "$GW_CONF" hbPort)")
    [[ "$gwport" =~ ^[0-9]+$ ]] || gwport=20010
    localport=$(trim "$(flat_get "$GW_CONF" repeaterPort1)")
    [[ "$localport" =~ ^[0-9]+$ ]] || localport=20011

    [ ${#call} -le 7 ] || die "callsign '$call' is longer than 7 characters"
    local rptcall
    rptcall=$(printf '%-7s%s' "$call" "$module")

    mkdir -p "$(dirname "$ICOM_CONF")" "$LOG_DIR"
    cat > "$ICOM_CONF" <<EOF
# Generated by icom-mode from $GW_CONF / $MMDVM_CONF - re-run 'icom-mode config' to refresh.
[General]
Callsign=$rptcall
Gateway=
# 1 = Simplex (Icom mode is always simplex)
Mode=1
Ack=1
Restriction=0
RPT1Validation=0
DTMFBlanking=1
ErrorReply=1

[Log]
FilePath=$LOG_DIR
FileLevel=2
DisplayLevel=2
MQTTLevel=0

[Paths]
Data=/usr/share/dstarrepeater
Audio=/tmp

[Network]
GatewayAddress=127.0.0.1
GatewayPort=$gwport
LocalAddress=127.0.0.1
LocalPort=$localport
Name=

[Modem]
Type=Icom Access Point/Terminal Mode

[Icom]
Port=$ICOM_PORT

[Times]
Timeout=180
AckTime=500

[Beacon]
# 0 = no beacons, so the radio isn't keyed up on its own every few minutes
Time=0
Text=
Voice=0
Language=0

[Announcement]
Enabled=0

[Control]
Enabled=0

[Controller]
Type=

[Frame Logging]
Enabled=0
EOF
    echo "Wrote $ICOM_CONF: repeater '$rptcall', gateway 127.0.0.1:$gwport, local port $localport, radio $ICOM_PORT"
}

stop_mmdvm() {
    if unit_exists "$MMDVM_SERVICE"; then
        systemctl stop "$MMDVM_SERVICE" && echo "Stopped MMDVMHost"
    else
        warn "no $MMDVM_SERVICE service found; make sure MMDVMHost isn't running"
    fi
    pkill -x MMDVMHost 2>/dev/null && echo "Killed leftover MMDVMHost process"
    return 0
}

start_mmdvm() {
    if unit_exists "$MMDVM_SERVICE"; then
        systemctl start "$MMDVM_SERVICE" && echo "Started MMDVMHost - back to normal WPSD"
    fi
}

check_gateway() {
    local g
    for g in ircddbgateway dstargateway; do
        if unit_exists "$g"; then
            systemctl is-active --quiet "$g" || { echo "Starting $g"; systemctl start "$g"; }
            return 0
        fi
    done
    warn "no ircddbgateway/dstargateway service found - D-STAR needs one running on 127.0.0.1"
}

preflight() {
    need_root
    [ -x "$DAEMON" ] || die "$DAEMON not installed - run install.sh first"
    [ -e "$ICOM_PORT" ] || die "$ICOM_PORT not found - is the radio plugged into the Pi's data port and switched on?"
    [ -f "$ICOM_CONF" ] || write_config
}

check_modem_opened() {
    # dstarrepeaterd keeps running even if it can't open the radio, so look for that.
    sleep 3
    if journalctl -u "$SERVICE" --since "-10s" -o cat 2>/dev/null | grep -q "Cannot open the D-Star modem"; then
        warn "DStarRepeater could not open $ICOM_PORT - check the cable and that the radio is in Terminal/Access Point mode"
        return 1
    fi
}

cmd_start() {
    preflight
    systemctl is-active --quiet "$SERVICE" && { echo "Icom mode is already running (icom-mode log to watch)"; exit 0; }
    stop_mmdvm
    check_gateway
    if [ "${1:-}" = "--watch" ]; then
        echo "Running DStarRepeater in this terminal - Ctrl+C to stop and return to WPSD"
        mkdir -p /run/dstarrepeater
        trap 'echo; start_mmdvm' EXIT
        trap 'true' INT TERM
        DSTAR_RUN_DIR=/run/dstarrepeater stdbuf -oL "$DAEMON" "$ICOM_CONF" 2>&1 | grep -v --line-buffered RTI_DATA_NAK
    else
        systemctl start "$SERVICE" || die "failed to start $SERVICE (see: journalctl -u $SERVICE)"
        echo "Icom mode running. Watch it with: icom-mode log"
        check_modem_opened
    fi
}

cmd_stop() {
    need_root
    systemctl stop "$SERVICE" 2>/dev/null && echo "Stopped DStarRepeater"
    pkill -x dstarrepeaterd 2>/dev/null
    start_mmdvm
}

cmd_status() {
    local s
    for s in "$SERVICE" "$MMDVM_SERVICE" ircddbgateway dstargateway; do
        unit_exists "$s" && printf '%-20s %s\n' "$s" "$(systemctl is-active "$s")"
    done
    if [ -e "$ICOM_PORT" ]; then echo "radio: $ICOM_PORT -> $(readlink -f "$ICOM_PORT")"; else echo "radio: $ICOM_PORT not present"; fi
    if systemctl is-active --quiet "$SERVICE" && systemctl is-active --quiet "$MMDVM_SERVICE"; then
        warn "MMDVMHost has been restarted while Icom mode is on (WPSD watchdog?) - they will clash"
    fi
    echo "--- recent log ---"
    journalctl -u "$SERVICE" -n 200 -o cat --no-pager 2>/dev/null | grep -v RTI_DATA_NAK | tail -n 15
}

cmd_log() { journalctl -u "$SERVICE" -f -o short-iso | grep -v --line-buffered RTI_DATA_NAK; }

case "${1:-}" in
    start)  shift; cmd_start "$@" ;;
    stop)   cmd_stop ;;
    status) cmd_status ;;
    log)    cmd_log ;;
    config) need_root; write_config ;;
    *) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
ICOMMODE
chmod 0755 /usr/local/bin/icom-mode
echo "== Writing DStarRepeater config from your WPSD settings"
/usr/local/bin/icom-mode config

echo
echo "Done. With the radio plugged in and in Access Point (or Terminal) mode:"
echo "   sudo icom-mode start --watch    run it here and watch; Ctrl+C returns to WPSD"
echo "   sudo icom-mode start            run it in the background; 'icom-mode log' to watch"
echo "   sudo icom-mode stop             back to normal WPSD"
[ -e /dev/icom_ta ] && echo "Radio found at /dev/icom_ta." || echo "Radio not found at /dev/icom_ta yet - plug it in (data port) and switch it on."
