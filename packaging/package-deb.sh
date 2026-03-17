#!/bin/bash
################################################################################
# package-deb.sh - Build and package prometheus for Debian/Ubuntu
################################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

NCPUS="$(nproc)"

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

echo "================================"
echo "Building Prometheus for Debian"
echo "================================"
echo "CPUs: $NCPUS"
echo "Version: $APP_VERSION"
echo ""

if [ ! -d "$PROJECT_ROOT/src/prometheus" ]; then
    echo "Error: source directory not found: $PROJECT_ROOT/src/prometheus"
    exit 1
fi
if [ ! -f "$PROJECT_ROOT/src/prometheus/go.mod" ]; then
    echo "Error: go.mod not found: $PROJECT_ROOT/src/prometheus/go.mod"
    exit 1
fi

if ! command -v go >/dev/null 2>&1; then
    echo "Error: Go compiler not found in PATH."
    echo "Install Go using distro packages (golang-go) or official tarball."
    exit 1
fi

GO_REQUIRED_VERSION="$(awk '/^go[[:space:]]+/ {print $2; exit}' "$PROJECT_ROOT/src/prometheus/go.mod")"
GO_CURRENT_VERSION="$(go version | awk '{print $3}' | sed 's/^go//')"
if [ -n "$GO_REQUIRED_VERSION" ] && [ "$(printf '%s\n%s\n' "$GO_REQUIRED_VERSION" "$GO_CURRENT_VERSION" | sort -V | head -n1)" != "$GO_REQUIRED_VERSION" ]; then
    echo "Error: Go $GO_REQUIRED_VERSION or newer is required by src/prometheus/go.mod."
    echo "Current Go version: $GO_CURRENT_VERSION"
    echo "Install/update Go (distro package or official tarball) and retry."
    exit 1
fi

USE_SKIP_DEPS=0
if command -v dpkg-query >/dev/null 2>&1; then
    missing=()
    require_pkg() {
        local pkg="$1"
        if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed"; then
            missing+=("$pkg")
        fi
    }

    require_pkg build-essential
    require_pkg debhelper
    require_pkg dpkg-dev

    if [ ${#missing[@]} -gt 0 ]; then
        echo "Missing build dependencies detected."
        if command -v apt-get >/dev/null 2>&1; then
            echo "  sudo apt-get install ${missing[*]}"
        else
            for pkg in "${missing[@]}"; do
                echo "  - $pkg"
            done
        fi
        exit 1
    fi

    if ! dpkg-query -W -f='${Status}' golang-go 2>/dev/null | grep -q "install ok installed"; then
        USE_SKIP_DEPS=1
    fi
fi

if command -v dpkg-checkbuilddeps >/dev/null 2>&1; then
    set +e
    BUILDDEPS_OUTPUT="$(cd "$PROJECT_ROOT" && dpkg-checkbuilddeps 2>&1)"
    BUILDDEPS_RC=$?
    set -e

    if [ "$BUILDDEPS_RC" -ne 0 ] && echo "$BUILDDEPS_OUTPUT" | grep -q "golang-any"; then
        missing_tail="${BUILDDEPS_OUTPUT##*: }"
        only_golang_any=1
        for dep in $missing_tail; do
            if [ "$dep" != "golang-any" ]; then
                only_golang_any=0
                break
            fi
        done
        if [ "$only_golang_any" -eq 1 ]; then
            USE_SKIP_DEPS=1
        fi
    fi
fi

DEBIAN_DIR="$PROJECT_ROOT/debian"
CHANGELOG_PATH="$DEBIAN_DIR/changelog"

if [ ! -d "$DEBIAN_DIR" ]; then
    echo "Error: debian packaging metadata not found at $DEBIAN_DIR"
    exit 1
fi

DISTRO_TAG=""
if [ -r /etc/os-release ]; then
    . /etc/os-release
    if [ "${ID:-}" = "debian" ] && [ -n "${VERSION_ID:-}" ]; then
        DISTRO_TAG="deb${VERSION_ID}"
    elif [ "${ID:-}" = "ubuntu" ] && [ -n "${VERSION_ID:-}" ]; then
        DISTRO_TAG="ubuntu${VERSION_ID}"
    fi
fi

if [ -n "$DISTRO_TAG" ]; then
    DEB_VERSION="${APP_VERSION}-1~${DISTRO_TAG}"
else
    DEB_VERSION="${APP_VERSION}-1"
fi

BACKUP_CHANGELOG=""
if [ -f "$CHANGELOG_PATH" ]; then
    BACKUP_CHANGELOG="$(mktemp)"
    cp "$CHANGELOG_PATH" "$BACKUP_CHANGELOG"
fi

trap 'if [ -n "$BACKUP_CHANGELOG" ] && [ -f "$BACKUP_CHANGELOG" ]; then cp "$BACKUP_CHANGELOG" "$CHANGELOG_PATH"; rm -f "$BACKUP_CHANGELOG"; fi' EXIT

cat > "$CHANGELOG_PATH" <<EOF_CHANGELOG
${APP_NAME} (${DEB_VERSION}) unstable; urgency=medium

  * Automated build.

 -- ${MAINTAINER}  $(date -R)
EOF_CHANGELOG

echo ""
echo "Step 1: Building package with debhelper..."
cd "$PROJECT_ROOT"
if [ "$USE_SKIP_DEPS" -eq 1 ]; then
    echo "Using Go from PATH without distro Go build dependency package."
    echo "Running dpkg-buildpackage with -d to allow tarball-based Go installs."
    dpkg-buildpackage -d -b -us -uc
else
    dpkg-buildpackage -b -us -uc
fi

echo ""
echo "Step 2: Collecting .deb output..."

OUTPUT_DIR="$PROJECT_ROOT/packaging/output"
OUTPUT_PARENT="$(cd "$PROJECT_ROOT/.." && pwd)"
mkdir -p "$OUTPUT_DIR"

mapfile -t DEB_FILES < <(find "$OUTPUT_PARENT" "$PROJECT_ROOT" -maxdepth 1 -type f -name "${APP_NAME}_${DEB_VERSION}_*.deb" 2>/dev/null | sort -u)

if [ ${#DEB_FILES[@]} -eq 0 ]; then
    echo "Error: No .deb artifacts found in $OUTPUT_PARENT or $PROJECT_ROOT"
    echo "Expected pattern: ${APP_NAME}_${DEB_VERSION}_*.deb"
    exit 1
fi

for deb in "${DEB_FILES[@]}"; do
    cp -f "$deb" "$OUTPUT_DIR/"
    echo "Copied: $(basename "$deb")"
done

echo ""
echo "================================"
echo "Build complete!"
echo "================================"
echo "Debian packages copied to: $OUTPUT_DIR"
ls -1 "$OUTPUT_DIR"/*.deb
