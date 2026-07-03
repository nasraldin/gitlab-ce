#!/bin/sh
# =============================================================================
# GitLab Runner entrypoint wrapper.
#
# On a fresh deploy (make destroy && make up) the runner config volume is empty.
# The `runner-bootstrap` service creates /etc/gitlab-runner/config.toml a few
# minutes later. Without this wrapper the runner process starts immediately and
# logs:
#   ERROR: Failed to load config stat /etc/gitlab-runner/config.toml: no such file
#
# This script waits quietly until bootstrap finishes, then starts the real runner.
# On subsequent restarts the config already exists, so there is no delay.
# =============================================================================
set -eu

CONFIG=/etc/gitlab-runner/config.toml
WAIT_LOG_INTERVAL=30   # seconds between "still waiting" log lines
MAX_WAIT=900           # 15 minutes — first GitLab boot can be slow

log() { printf '[runner-entrypoint] %s\n' "$*"; }

if [ -f "$CONFIG" ] && grep -q '^\[\[runners\]\]' "$CONFIG" 2>/dev/null; then
  log "config found, starting gitlab-runner."
  exec /usr/bin/dumb-init /entrypoint run --user=gitlab-runner --working-directory=/home/gitlab-runner
fi

log "no config yet — waiting for runner-bootstrap to register this container..."
elapsed=0
while [ "$elapsed" -lt "$MAX_WAIT" ]; do
  if [ -f "$CONFIG" ] && grep -q '^\[\[runners\]\]' "$CONFIG" 2>/dev/null; then
    log "config ready after ${elapsed}s, starting gitlab-runner."
    exec /usr/bin/dumb-init /entrypoint run --user=gitlab-runner --working-directory=/home/gitlab-runner
  fi
  if [ $((elapsed % WAIT_LOG_INTERVAL)) -eq 0 ] && [ "$elapsed" -gt 0 ]; then
    log "still waiting for config.toml (${elapsed}s)..."
  fi
  sleep 2
  elapsed=$((elapsed + 2))
done

log "ERROR: config.toml did not appear within ${MAX_WAIT}s."
log "Check: docker logs gitlab-runner-bootstrap"
exit 1
