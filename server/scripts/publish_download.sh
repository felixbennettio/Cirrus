#!/usr/bin/env bash
# Publishes installers on the website's download page (server/DEPLOY.md,
# "Publishing downloads"): copies them into the server's data/downloads,
# served at /downloads/<file>, and records them in data/downloads/manifest.json.
#
#   CIRRUS_SERVER=root@203.0.113.10 server/scripts/publish_download.sh <platform> <file>...
#
#   <platform>      windows, macos, linux or android
#   <file>...       the platform's installers, e.g. Cirrus-1.2.0-macos.dmg; they
#                   replace the platform's previous entry (the old files stay
#                   on the server until you delete them)
#   CIRRUS_SERVER   ssh destination of the licence server (user@host or an ssh alias)
#   CIRRUS_DIR      deployment directory there (default /opt/cirrus-license)
#   VERSION         version shown on the page (default: from the file name,
#                   Cirrus-<version>-…)
#   CIRRUS_DOWNLOADS  a local downloads directory instead of the server (tests)
#
# Checksums are computed here and checked again on the server before a file
# is moved into place. Files are uploaded under a hidden name first, so the
# site never serves half a file, and the manifest is replaced atomically.
set -euo pipefail

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
[ $# -ge 2 ] || usage
platform=$1; shift
case "$platform" in windows | macos | linux | android) ;; *) echo "unknown platform: $platform" >&2; usage ;; esac

sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }

names=() sums=()
for f in "$@"; do
  [ -f "$f" ] || { echo "no such file: $f" >&2; exit 1; }
  name=$(basename "$f")
  # What the server serves: plain names, no leading dot.
  [[ $name =~ ^[A-Za-z0-9_-][A-Za-z0-9._-]*$ && $name != manifest.json ]] || { echo "unsuitable file name: $name" >&2; exit 1; }
  names+=("$name") sums+=("$(sha256 "$f")")
done
version=${VERSION:-}
# Cirrus-<version>-<platform>…, e.g. Cirrus-1.2.0-beta.1-windows-setup.exe
if [ -z "$version" ] && [[ ${names[0]} =~ ^Cirrus-(.+)-$platform([-.]|$) ]]; then
  version=${BASH_REMATCH[1]}
fi
[[ $version =~ ^[0-9]+(\.[0-9]+)+([-+][0-9A-Za-z.]+)?$ ]] ||
  { echo "set VERSION: no version like 1.2.0 in ${names[0]}${version:+ (got $version)}" >&2; exit 1; }

if [ -n "${CIRRUS_DOWNLOADS:-}" ]; then
  dest=$CIRRUS_DOWNLOADS
  run() { bash -c "$1"; }
  put() { cp "$1" "$dest/$2"; }
  get() { cp "$dest/$1" "$2" 2>/dev/null; }
  owner=true
  mkdir -p "$dest"
else
  : "${CIRRUS_SERVER:?set CIRRUS_SERVER to the ssh destination of the server, user@host}"
  dest=${CIRRUS_DIR:-/opt/cirrus-license}/data/downloads
  run() { ssh "$CIRRUS_SERVER" "$1"; }
  put() { scp -q "$1" "$CIRRUS_SERVER:$dest/$2"; }
  get() { scp -q "$CIRRUS_SERVER:$dest/$1" "$2" 2>/dev/null; }
  # The container runs as uid 10001 and only needs to read the files.
  owner='[ "$(id -u)" = 0 ] && chown 10001:10001'
  run "mkdir -p '$dest' && chmod 755 '$dest'"
fi
# Names are restricted above, so single quotes are enough below.
for i in "${!names[@]}"; do
  name=${names[$i]} sum=${sums[$i]} part=".${names[$i]}.part"
  echo "upload $name ($sum)"
  put "${@:$((i + 1)):1}" "$part"
  got=$(run "cd '$dest' && { sha256sum '$part' 2>/dev/null || shasum -a 256 '$part'; }" | cut -d' ' -f1)
  if [ "$got" != "$sum" ]; then
    run "rm -f '$dest/$part'"
    echo "checksum mismatch after uploading $name" >&2
    exit 1
  fi
  run "cd '$dest' && chmod 644 '$part' && { $owner '$part' || true; } && mv -f '$part' '$name'"
done

# Merge the platform's entry into the manifest and replace it atomically.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
get manifest.json "$work/old.json" || echo '{}' > "$work/old.json"
python3 - "$work/old.json" "$work/new.json" "$platform" "$version" "${names[@]}" "${sums[@]}" <<'PY'
import json, sys
old, new, platform, version = sys.argv[1:5]
rest = sys.argv[5:]
names, sums = rest[: len(rest) // 2], rest[len(rest) // 2 :]
try:
    m = json.load(open(old))
except ValueError:
    m = {}
if not isinstance(m, dict):
    m = {}
files = m.get("files") if isinstance(m.get("files"), dict) else {}
entries = [{"file": n, "sha256": s, "version": version} for n, s in zip(names, sums)]
files[platform] = entries[0] if len(entries) == 1 else entries
m["files"] = dict(sorted(files.items()))
json.dump(m, open(new, "w"), indent=1, ensure_ascii=False)
open(new, "a").write("\n")
PY
put "$work/new.json" .manifest.json.part
run "cd '$dest' && chmod 644 .manifest.json.part && { $owner .manifest.json.part || true; } && mv -f .manifest.json.part manifest.json"
echo "published $platform $version: ${names[*]}"
