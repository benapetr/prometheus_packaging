# Prometheus Packaging

This directory packages Prometheus server from `src/prometheus` into:
- `.deb` for Debian/Ubuntu
- `.rpm` for Fedora/RHEL/CentOS/Alma/Rocky

## Layout

- `src/prometheus/` - upstream source tree
- `debian/` - Debian metadata
- `packaging/` - package scripts and service/config assets

## Dependencies

Debian/Ubuntu:
```bash
sudo apt-get update
sudo apt-get install -y build-essential debhelper dpkg-dev
```

EL-based:
```bash
sudo dnf install -y rpm-build systemd-rpm-macros tar
```

Go:
- Go must be in `PATH`.
- Required minimum version is read from `src/prometheus/go.mod`.
- Distro and official tarball installs are both supported.

## Build

Debian:
```bash
./packaging/package-deb.sh
```

RPM:
```bash
./packaging/package-rpm.sh
```

Artifacts:
- `packaging/output/`

## Runtime

Installed service:
- `prometheus.service`

Runtime user:
- `prometheus`

Configuration:
- `/etc/prometheus/prometheus.yml`
- `/etc/default/prometheus` (Debian)
- `/etc/sysconfig/prometheus` (EL)

Data directory:
- `/var/lib/prometheus`
