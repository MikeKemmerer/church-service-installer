# Church Service Installer

Interactive and command-line coordinator for installing church AV services on
Raspberry Pi OS and Ubuntu 26.04 LTS.

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
a fresh Ubuntu installation. The repair command configures the same hats for an
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
- Ubuntu 26.04 LTS

Later phases add backup restoration, Ubuntu kiosk auto-login, SSH X11
forwarding, attached-display VNC, and monitoring-server disaster recovery.

## Tests

```bash
bash tests/test-bootstrap.sh
```