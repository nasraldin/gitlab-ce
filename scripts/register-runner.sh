#!/usr/bin/env sh
# =============================================================================
# Register / ensure a SINGLE runner container is provisioned.
#
# Usage:
#   ./scripts/register-runner.sh [container-name]     # default: gitlab-runner
#
# This is a thin wrapper around bootstrap-runners.sh scoped to one container.
# It is idempotent: if the container is already registered it is left as-is.
#
# To add a brand-new runner beyond the default fleet:
#   1. Add a `gitlab-runner-05` service + `gitlab-runner-config-05` volume to
#      docker-compose.yml (copy an existing runner block).
#   2. docker compose up -d gitlab-runner-05
#   3. ./scripts/register-runner.sh gitlab-runner-05
# =============================================================================
set -eu

NAME="${1:-gitlab-runner}"
DIR="$(cd "$(dirname "$0")" && pwd)"

if ! docker inspect -f '{{.State.Running}}' "$NAME" >/dev/null 2>&1; then
  echo "ERROR: runner container '$NAME' is not running." >&2
  echo "Add it to docker-compose.yml and 'docker compose up -d $NAME' first." >&2
  exit 1
fi

RUNNER_CONTAINERS="$NAME" exec "$DIR/bootstrap-runners.sh"
