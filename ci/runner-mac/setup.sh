#!/bin/bash
# Installs a self-hosted GitHub Actions runner for Cirrus's Apple jobs on
# this Mac, as a launch agent of the current user (it runs while the user is
# logged in, with their keychain). See ci/RUNNERS.md.
#
#   RUNNER_TOKEN=<registration token> ci/runner-mac/setup.sh
set -euo pipefail
: "${RUNNER_TOKEN:?Set RUNNER_TOKEN to a registration token, see ci/RUNNERS.md}"
DIR="${RUNNER_DIR:-$HOME/actions-runner-cirrus}"
ARCH=$(uname -m | sed 's/x86_64/x64/')
VERSION="${RUNNER_VERSION:-$(curl -fsSL -o /dev/null -w '%{url_effective}' https://github.com/actions/runner/releases/latest | sed 's|.*/v||')}"
echo "actions runner $VERSION"

mkdir -p "$DIR"
cd "$DIR"
if [ ! -f .runner ]; then
  curl -fsSL "https://github.com/actions/runner/releases/download/v${VERSION}/actions-runner-osx-${ARCH}-${VERSION}.tar.gz" | tar -xz
  ./config.sh --unattended --replace \
    --url "${RUNNER_URL:-https://github.com/felixbennettio/Cirrus}" \
    --token "$RUNNER_TOKEN" \
    --name "${RUNNER_NAME:-$(scutil --get LocalHostName)-cirrus}" \
    --labels cirrus-mac \
    --work _work
fi
./svc.sh install || true
./svc.sh start
./svc.sh status
