#!/usr/bin/env bash
# Builds the deployment bundle, so nothing is compiled on the server:
#
#   dist/cirrus-license-<version>/
#     bin/cirrus-license-amd64, bin/cirrus-license-arm64   static, CGO_ENABLED=0
#     Dockerfile.runtime, docker-compose.yml, .dockerignore
#     cirrus-license.service                               optional systemd unit
#     smoke-test.sh                                        end-to-end check
#     .env.example, DEPLOY.md, README.md
#     SHA256SUMS
#   dist/cirrus-license-<version>.tar.gz
#
# Usage: ./build-bundle.sh            (version = YYYYMMDD-<git short sha>)
#        VERSION=1.0.0 ./build-bundle.sh
set -euo pipefail
cd "$(dirname "$0")"

GO=${GO:-go}
command -v "$GO" >/dev/null 2>&1 || GO=/usr/local/go/bin/go
command -v "$GO" >/dev/null 2>&1 || { echo "Go not found; set GO=/path/to/go" >&2; exit 1; }

if [ -z "${VERSION:-}" ]; then
  sha=$(git rev-parse --short HEAD 2>/dev/null || echo local)
  if [ -n "$(git status --porcelain -- . 2>/dev/null)" ]; then sha="$sha-dirty"; fi
  VERSION="$(date +%Y%m%d)-$sha"
fi
case "$VERSION" in *[!A-Za-z0-9._-]*) echo "bad VERSION: $VERSION" >&2; exit 1 ;; esac

name="cirrus-license-$VERSION"
out="dist/$name"
rm -rf "$out" "dist/$name.tar.gz"
mkdir -p "$out/bin"

for arch in amd64 arm64; do
  echo "building linux/$arch"
  CGO_ENABLED=0 GOOS=linux GOARCH=$arch "$GO" build -trimpath \
    -ldflags "-s -w -X main.version=$VERSION" \
    -o "$out/bin/cirrus-license-$arch" ./cmd/cirrus-license
done

cp deploy/Dockerfile.runtime deploy/docker-compose.yml deploy/cirrus-license.service deploy/smoke-test.sh "$out/"
cp deploy/dockerignore "$out/.dockerignore"
cp .env.example DEPLOY.md README.md "$out/"
echo "$VERSION" > "$out/VERSION"

(cd "$out" && find . -type f ! -name SHA256SUMS | LC_ALL=C sort | sed 's|^\./||' | xargs sha256sum > SHA256SUMS)
tar -C dist -czf "dist/$name.tar.gz" "$name"

echo
echo "bundle:  $out/"
echo "archive: dist/$name.tar.gz ($(du -h "dist/$name.tar.gz" | cut -f1))"
echo "sha256:  $(sha256sum "dist/$name.tar.gz" | cut -d' ' -f1)"
