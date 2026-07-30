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