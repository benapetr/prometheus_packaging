#!/bin/bash
################################################################################
# package-rpm.sh - Build and package prometheus for Fedora/RHEL/CentOS
################################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config"

NCPUS="$(nproc)"
RELEASE="1"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            APP_VERSION="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--version x.y.z]"
            exit 1
            ;;
    esac
done

echo "==============================="
echo "Building Prometheus for RPM"
echo "==============================="
echo "CPUs: $NCPUS"
echo "Version: $APP_VERSION-$RELEASE"
echo ""

if [ ! -d "$SCRIPT_DIR/../src/prometheus" ]; then
    echo "Error: source directory not found: $SCRIPT_DIR/../src/prometheus"
    exit 1
fi
if [ ! -f "$SCRIPT_DIR/../src/prometheus/go.mod" ]; then
    echo "Error: go.mod not found: $SCRIPT_DIR/../src/prometheus/go.mod"
    exit 1
fi

if ! command -v go >/dev/null 2>&1; then
    echo "Error: Go compiler not found in PATH."
    echo "Install Go using distro package (golang) or official tarball."
    exit 1
fi

GO_REQUIRED_VERSION="$(awk '/^go[[:space:]]+/ {print $2; exit}' "$SCRIPT_DIR/../src/prometheus/go.mod")"
GO_CURRENT_VERSION="$(go version | awk '{print $3}' | sed 's/^go//')"
if [ -n "$GO_REQUIRED_VERSION" ] && [ "$(printf '%s\n%s\n' "$GO_REQUIRED_VERSION" "$GO_CURRENT_VERSION" | sort -V | head -n1)" != "$GO_REQUIRED_VERSION" ]; then
    echo "Error: Go $GO_REQUIRED_VERSION or newer is required by src/prometheus/go.mod."
    echo "Current Go version: $GO_CURRENT_VERSION"
    echo "Install/update Go (distro package or official tarball) and retry."
    exit 1
fi

USE_RPM_NODEPS=0
if command -v rpm >/dev/null 2>&1; then
    missing=()

    require_pkg() {
        local pkg="$1"
        if ! rpm -q "$pkg" >/dev/null 2>&1; then
            missing+=("$pkg")
        fi
    }

    require_pkg rpm-build
    require_pkg systemd-rpm-macros

    if [ ${#missing[@]} -gt 0 ]; then
        echo "Missing build dependencies detected."
        if command -v dnf >/dev/null 2>&1; then
            echo "  sudo dnf install ${missing[*]}"
        elif command -v yum >/dev/null 2>&1; then
            echo "  sudo yum install ${missing[*]}"
        else
            for pkg in "${missing[@]}"; do
                echo "  - $pkg"
            done
        fi
        exit 1
    fi

    if ! rpm -q golang >/dev/null 2>&1; then
        USE_RPM_NODEPS=1
    fi
fi

PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
RPM_TOPDIR="$HOME/rpmbuild"
mkdir -p "$RPM_TOPDIR"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

TMP_SRC_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_SRC_DIR"' EXIT

SOURCE_DIR_NAME="${APP_NAME}-${APP_VERSION}"
mkdir -p "$TMP_SRC_DIR/$SOURCE_DIR_NAME/src"
cp -a "$PROJECT_ROOT/src/prometheus" "$TMP_SRC_DIR/$SOURCE_DIR_NAME/src/"
mkdir -p "$TMP_SRC_DIR/$SOURCE_DIR_NAME/packaging"
cp -a "$PROJECT_ROOT/packaging/prometheus.service" "$TMP_SRC_DIR/$SOURCE_DIR_NAME/packaging/"
cp -a "$PROJECT_ROOT/packaging/prometheus.sysconfig" "$TMP_SRC_DIR/$SOURCE_DIR_NAME/packaging/"
cp -a "$PROJECT_ROOT/packaging/prometheus.yml" "$TMP_SRC_DIR/$SOURCE_DIR_NAME/packaging/"

SOURCE_TARBALL="$RPM_TOPDIR/SOURCES/$SOURCE_DIR_NAME.tar.gz"
tar -C "$TMP_SRC_DIR" -czf "$SOURCE_TARBALL" "$SOURCE_DIR_NAME"

SPEC_PATH="$RPM_TOPDIR/SPECS/$APP_NAME.spec"
cat > "$SPEC_PATH" <<EOF_SPEC
%global debug_package %{nil}

Name:           $APP_NAME
Version:        $APP_VERSION
Release:        $RELEASE%{?dist}
Summary:        $DESCRIPTION

License:        Apache-2.0
URL:            https://github.com/prometheus/prometheus
Source0:        %{name}-%{version}.tar.gz

BuildRequires:  golang
BuildRequires:  systemd-rpm-macros
Requires(pre):  shadow-utils

%description
Prometheus is a monitoring system and time series database.

%prep
%autosetup

%build
cd src/prometheus
CGO_ENABLED=0 GOTOOLCHAIN=local go build -trimpath -buildvcs=false -ldflags "-s -w" -o prometheus ./cmd/prometheus

%install
rm -rf %{buildroot}
install -Dm755 src/prometheus/prometheus %{buildroot}%{_bindir}/prometheus
install -Dm644 src/prometheus/README.md %{buildroot}%{_docdir}/%{name}/README.md
install -Dm644 src/prometheus/LICENSE %{buildroot}%{_docdir}/%{name}/LICENSE
install -Dm644 packaging/prometheus.service %{buildroot}%{_unitdir}/prometheus.service
install -Dm644 packaging/prometheus.sysconfig %{buildroot}%{_sysconfdir}/sysconfig/prometheus
install -Dm644 packaging/prometheus.yml %{buildroot}%{_sysconfdir}/prometheus/prometheus.yml
install -d %{buildroot}/var/lib/prometheus

%pre
getent group prometheus >/dev/null || groupadd -r prometheus
getent passwd prometheus >/dev/null || \
    useradd -r -g prometheus -d /nonexistent -s /sbin/nologin -c "Prometheus server" prometheus
mkdir -p /var/lib/prometheus
chown prometheus:prometheus /var/lib/prometheus || true

%post
%systemd_post prometheus.service

%preun
%systemd_preun prometheus.service

%postun
%systemd_postun_with_restart prometheus.service

%files
%license %{_docdir}/%{name}/LICENSE
%doc %{_docdir}/%{name}/README.md
%{_bindir}/prometheus
%config(noreplace) %{_sysconfdir}/sysconfig/prometheus
%config(noreplace) %{_sysconfdir}/prometheus/prometheus.yml
%dir /var/lib/prometheus
%{_unitdir}/prometheus.service

%changelog
* $(date '+%a %b %d %Y') $MAINTAINER - $APP_VERSION-$RELEASE
- Automated package build
EOF_SPEC

if [ "$USE_RPM_NODEPS" -eq 1 ]; then
    echo "Go package golang is not installed via rpm; using Go from PATH."
    echo "Running rpmbuild with --nodeps to allow tarball-based Go installs."
    rpmbuild --nodeps --define "_topdir $RPM_TOPDIR" -ba "$SPEC_PATH"
else
    rpmbuild --define "_topdir $RPM_TOPDIR" -ba "$SPEC_PATH"
fi

OUTPUT_DIR="$PROJECT_ROOT/packaging/output"
mkdir -p "$OUTPUT_DIR"
cp -f "$RPM_TOPDIR"/RPMS/*/${APP_NAME}-${APP_VERSION}-${RELEASE}*.rpm "$OUTPUT_DIR/"
cp -f "$RPM_TOPDIR"/SRPMS/${APP_NAME}-${APP_VERSION}-${RELEASE}*.src.rpm "$OUTPUT_DIR/"

echo ""
echo "==============================="
echo "Build complete!"
echo "==============================="
echo "RPM packages copied to: $OUTPUT_DIR"
ls -1 "$OUTPUT_DIR"/*.rpm
