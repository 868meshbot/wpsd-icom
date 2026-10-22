# Icom Access Point / Terminal Mode for WPSD

Runs G4KLX's DStarRepeater with an Icom radio over USB (tested setup: ID-50E, `0c26:0046`)
instead of MMDVMHost, talking to WPSD's existing D-STAR gateway on 127.0.0.1:20010.

## Files

| File                         | What it does                                                                                       |
| ---------------------------- | -------------------------------------------------------------------------------------------------- |
| `install.sh`                 | Builds DStarRepeater on the Pi and installs everything below                                       |
| `install-all.sh`             | Same as `install.sh` but self-contained (the other files are embedded), for a single-file download |
| `99-icom-ta.rules`           | udev rule: the radio always appears as `/dev/icom_ta`                                              |
| `dstarrepeater-icom.service` | systemd service for DStarRepeater (not started at boot)                                            |
| `icom-mode`                  | Switches between WPSD (MMDVMHost) and Icom mode                                                    |

## Install (once)

On the Pi, either clone the repo:

```
git clone https://github.com/868meshbot/wpsd-icom.git
cd wpsd-icom
sudo ./install.sh
```

or fetch just the self-contained installer:

```
curl -fsSLO https://raw.githubusercontent.com/868meshbot/wpsd-icom/main/install-all.sh
sudo bash install-all.sh
```

Build takes 10–20+ minutes on a Pi Zero. It installs `git g++ make libasound2-dev libusb-1.0-0-dev`,
builds from https://github.com/g4klx/DStarRepeater into `/usr/local/src/DStarRepeater`, and adds a
temporary swap file during the build if the Pi is short of memory.

The config (`/etc/dstarrepeater/icom.ini`) is generated from your WPSD callsign and D-STAR module.
If you change those in WPSD, run `sudo icom-mode config` to refresh it.

## Radio

Plug the radio into the Pi's **data** port (Pi Zero: the inner port marked USB) with a data cable,
then on the ID-50E: **MENU → DV Gateway → Access Point Mode** (or Terminal Mode to talk on the ID-50E itself).
In Access Point Mode, use low power and a simplex frequency your band plan allows for hotspots.

## Use

```
sudo icom-mode start --watch   # run in this terminal and watch it; Ctrl+C = back to WPSD
sudo icom-mode start           # run in the background
icom-mode log                  # watch the background one live (Ctrl+C just stops watching)
icom-mode status               # services, radio, last few log lines
sudo icom-mode stop            # back to normal WPSD
```

Logs also go to `/var/log/pi-star/dstarrepeaterd-YYYY-MM-DD.log`.

## Things to know

- While Icom mode is on, MMDVMHost is stopped, so other modes (DMR, YSF…) and the Nextion screen are off.
- If WPSD's watchdog restarts MMDVMHost, the two will clash. `icom-mode status` warns about this.
- DStarRepeater keeps running even if it can't open the radio. `icom-mode start` checks for
  "Cannot open the D-Star modem" and warns you; check the cable, port and radio mode.
- A WPSD update shouldn't touch these files, but it may restart MMDVMHost. Re-run `sudo icom-mode start` afterwards.
- `install-all.sh` embeds copies of `99-icom-ta.rules`, `dstarrepeater-icom.service` and `icom-mode`.
  If you change one of those files, update the copy in `install-all.sh` too.
- Undo: `sudo icom-mode stop`, then delete `/usr/local/bin/icom-mode`, `/etc/systemd/system/dstarrepeater-icom.service`,
  `/etc/udev/rules.d/99-icom-ta.rules`, `/etc/dstarrepeater/` and `/usr/bin/dstarrepeaterd`.

## Credits

DStarRepeater is by Jonathan Naylor G4KLX: https://github.com/g4klx/DStarRepeater.
WPSD is by W0CHP. This repo only adds the glue to run them together with an Icom radio.

## License

Copyright (C) 2026 868meshbot. Licensed under the GNU General Public License v3.0 or later;
see [LICENSE](LICENSE). DStarRepeater is separately licensed by G4KLX (GPL-2.0-or-later) and
is downloaded and built on your Pi, not included here.
