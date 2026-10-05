#!/usr/bin/env bash
# Packages the Linux release bundle as .tar.gz, .deb and .AppImage.
#
# Usage: scripts/package_linux.sh <version> [out-dir]
# Expects `flutter build linux --release` to have been run.
set -euo pipefail

VERSION="${1:?version required}"
OUT="${2:-dist}"
APP_ID="io.felixbennett.cirrus"
BUNDLE="build/linux/x64/release/bundle"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ICON="$ROOT/assets/branding/cirrus.png"

mkdir -p "$OUT"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

desktop_file() {
  cat <<EOF
[Desktop Entry]
Type=Application
Name=Cirrus
GenericName=Cloudflare client
Comment=Fast, native client for the Cloudflare API
Exec=$1
Icon=$APP_ID
Categories=Network;Development;
StartupWMClass=$APP_ID
Terminal=false
EOF
}

# --- tar.gz -------------------------------------------------------------
mkdir -p "$WORK/tar/cirrus"
cp -a "$BUNDLE/." "$WORK/tar/cirrus/"
cp "$ICON" "$WORK/tar/cirrus/$APP_ID.png"
desktop_file "cirrus" > "$WORK/tar/cirrus/$APP_ID.desktop"
tar -C "$WORK/tar" -czf "$OUT/Cirrus-$VERSION-linux-x64.tar.gz" cirrus

# --- .deb ---------------------------------------------------------------
PKG="$WORK/deb"
mkdir -p "$PKG/DEBIAN" "$PKG/opt/cirrus" "$PKG/usr/bin" "$PKG/usr/share/applications"
cp -a "$BUNDLE/." "$PKG/opt/cirrus/"
ln -s /opt/cirrus/cirrus "$PKG/usr/bin/cirrus"
desktop_file "/opt/cirrus/cirrus" > "$PKG/usr/share/applications/$APP_ID.desktop"
for size in 48 128 256 512; do
  dir="$PKG/usr/share/icons/hicolor/${size}x${size}/apps"
  mkdir -p "$dir"
  if command -v rsvg-convert >/dev/null; then
    rsvg-convert -w "$size" -h "$size" "$ROOT/assets/branding/cirrus.svg" -o "$dir/$APP_ID.png"
  else
    cp "$ICON" "$dir/$APP_ID.png"
  fi
done
INSTALLED_KB=$(du -sk "$PKG" | cut -f1)
cat > "$PKG/DEBIAN/control" <<EOF
Package: cirrus
Version: $VERSION
Section: net
Priority: optional
Architecture: amd64
Installed-Size: $INSTALLED_KB
Depends: libgtk-3-0, libsecret-1-0, libstdc++6
Recommends: gnome-keyring
Maintainer: Cirrus contributors <noreply@users.noreply.github.com>
Homepage: https://github.com/felixbennettio/Cirrus
Description: Cirrus - fast, native client for the Cloudflare API
 Manage DNS, SSL/TLS, rules, Workers, Pages, R2, KV, D1, Tunnels,
 Zero Trust and every other Cloudflare API endpoint from one app.
EOF
dpkg-deb --build --root-owner-group "$PKG" "$OUT/Cirrus-$VERSION-linux-amd64.deb"

# --- AppImage -----------------------------------------------------------
if [ "${SKIP_APPIMAGE:-0}" = "1" ]; then
  ls -la "$OUT"
  exit 0
fi
APPDIR="$WORK/Cirrus.AppDir"
mkdir -p "$APPDIR/usr/lib/cirrus"
cp -a "$BUNDLE/." "$APPDIR/usr/lib/cirrus/"
cp "$ICON" "$APPDIR/$APP_ID.png"
desktop_file "cirrus" > "$APPDIR/$APP_ID.desktop"
cat > "$APPDIR/AppRun" <<'EOF'
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
exec "$HERE/usr/lib/cirrus/cirrus" "$@"
EOF
chmod +x "$APPDIR/AppRun"
TOOL="$WORK/appimagetool"
curl -fsSL -o "$TOOL" https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage
chmod +x "$TOOL"
ARCH=x86_64 APPIMAGE_EXTRACT_AND_RUN=1 "$TOOL" --no-appstream "$APPDIR" "$OUT/Cirrus-$VERSION-linux-x86_64.AppImage"

ls -la "$OUT"
