#!/usr/bin/env sh
# =============================================================================
# Unregister runners and remove them from GitLab.
#
# Usage:
#   ./scripts/unregister-runner.sh                 # unregister the whole fleet
#   ./scripts/unregister-runner.sh gitlab-runner-02  # unregister one container
# =============================================================================
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/../.env" ]; then
  set -a; . "$SCRIPT_DIR/../.env"; set +a
fi

if [ "$#" -ge 1 ]; then
  TARGETS="$*"
else
  TARGETS="${RUNNER_CONTAINERS:-gitlab-runner gitlab-runner-01 gitlab-runner-02 gitlab-runner-03 gitlab-runner-04}"
fi

for R in $TARGETS; do
  if docker inspect -f '{{.State.Running}}' "$R" >/dev/null 2>&1; then
    echo "==> Unregistering all runners in $R..."
    docker exec "$R" gitlab-runner unregister --all-runners || true
  else
    echo "==> $R not running, skipping."
  fi
done
echo "==> Done."
