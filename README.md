# Church Service Installer

Interactive and command-line coordinator for installing church AV services on
Debian 12+ and Raspberry Pi OS.

This repository is the top-level installer. It downloads only allowlisted
`master` branches from the `MikeKemmerer` GitHub repositories and delegates to
each project's existing installer.

## Current Capability

The initial implementation supports a validated fresh-install workflow for:

- `church-calendar`
- `videokiosk2`
- `cameras`
- `church-monitoring-server`
- `church-monitoring-client`

The monitoring server and client cannot be installed together because they
both own `/etc/church-monitoring`.

```bash
git clone https://github.com/MikeKemmerer/church-service-installer.git
cd church-service-installer
sudo ./install.sh --services church-calendar,cameras --fresh
```

### Camera Control And Monitoring

Install Camera Control and the Church Monitoring server together on the
dashboard host. Camera Control uses Apache's default port 80 vhost; the
Monitoring server uses port 8080:

```bash
sudo ./install.sh --services cameras,church-monitoring-server --fresh --configure-apparmor
```

Save the enrollment token printed by the server installer. On every monitored
host, install the Monitoring client separately and provide that server address
and token when prompted:

```bash
sudo ./install.sh --services church-monitoring-client --fresh
```

Do not select both Monitoring roles on one host; they share
`/etc/church-monitoring`. The optional `--configure-apparmor` flag configures
separate Apache hats for Camera Control and any installed Monitoring role after
a fresh Debian installation. The repair command configures the same hats for an
existing deployment:

```bash
sudo ./install.sh --repair-apparmor
```

Both flows let Camera Control and Monitoring run on the dashboard host without
replacing one another's policy:

This command detects installed services, refreshes their trusted catalog
checkouts, and reapplies their policy and systemd/Apache attachment. On
Raspberry Pi OS it reports a no-op; it does not install or require AppArmor.

Validate the selected services and host without changing the machine:

```bash
./install.sh --services church-calendar,cameras --dry-run
```

## Platform Support

- Raspberry Pi OS
- Debian 12 or newer

Run `sudo ./install.sh` without `--services` to use the guided service selector.
It uses Whiptail on an interactive terminal when available and otherwise falls
back to a plain-text menu. `--menu-mode text` forces the fallback, while
`--menu-mode none` requires `--services`.

When `videokiosk2` is selected on a Debian minimal host, the installer also
installs Xorg, LightDM, Openbox, VLC, Falkon, and required X11 tools. It creates
an installer-owned LightDM drop-in that autologins the selected kiosk user into
Openbox, switches the host to `graphical.target`, and reports that a reboot is
required before the kiosk display can start.

The guided kiosk flow collects the video feed URL, browser failover URL,
restart-schedule URL, restart delay, and optional GPIO restart button before
the host is changed. On a newly provisioned desktop, the service defers X11
authority discovery until LightDM starts the graphical session after reboot.
For direct HDMI audio, select `--kiosk-audio-output alsa` and provide the VLC
ALSA device with `--kiosk-alsa-audio-device`, for example
`hdmi:CARD=PCH,DEV=0`. Before choosing a device, list the target host's HDMI
identifiers:

```bash
aplay -L | grep '^hdmi:'
```

Use one full identifier from that output. During an interactive central
installation, the same HDMI entries appear before the audio-device prompt.
For unattended runs, provide every kiosk choice:

```bash
sudo ./install.sh --services videokiosk2 --fresh --non-interactive --yes \
	--kiosk-user saint-demetrios \
	--kiosk-feed-url http://stream.example:8086/2.ts \
	--kiosk-browser-url http://calendar.example:8000 \
	--kiosk-schedule-url http://calendar.example:8000/api/service-restart-schedule \
	--kiosk-restart-delay-minutes 0 --kiosk-audio-output alsa \
	--kiosk-alsa-audio-device hdmi:CARD=PCH,DEV=0 --kiosk-no-gpio
```

Later phases add backup restoration, Debian kiosk auto-login, SSH X11
forwarding, attached-display VNC, and monitoring-server disaster recovery.

## Tests

```bash
bash tests/test-bootstrap.sh
```