#!/bin/bash
# Registers the runner on first start (RUNNER_TOKEN), then runs it. The
# registration is kept in the runner-home volume, so restarts need no token.
set -euo pipefail
cd /home/runner/actions-runner
if [ ! -f .runner ]; then
  : "${RUNNER_TOKEN:?Set RUNNER_TOKEN to a registration token, see ci/RUNNERS.md}"
  ./config.sh --unattended --replace \
    --url "${RUNNER_URL:-https://github.com/felixbennettio/Cirrus}" \
    --token "$RUNNER_TOKEN" \
    --name "${RUNNER_NAME:-cirrus-linux}" \
    --labels "${RUNNER_LABELS:-cirrus-linux}" \
    --work _work
fi
exec ./run.sh
