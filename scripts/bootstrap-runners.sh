#!/usr/bin/env sh
# =============================================================================
# Idempotent GitLab Runner auto-provisioner.
#
# For every runner container it:
#   1. waits until it is running,
#   2. prunes any runner entries GitLab no longer knows about (verify --delete),
#   3. if the container has no valid runner, mints a modern authentication
#      token via the GitLab API and registers it with the Docker executor +
#      shared S3 (MinIO) cache.
#
# Safe to run repeatedly: already-registered runners are skipped. Runs both as
# the compose `runner-bootstrap` service and from the host (`make runners-provision`).
#
# Requires: the `docker` CLI and access to the Docker socket.
# =============================================================================
set -eu

# When run from the host, load .env for configuration. Inside the bootstrap
# container these come from the compose `environment:` block instead.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/../.env" ]; then
  set -a; . "$SCRIPT_DIR/../.env"; set +a
fi

GITLAB_CONTAINER="${GITLAB_CONTAINER:-gitlab-ce}"
RUNNER_CONTAINERS="${RUNNER_CONTAINERS:-gitlab-runner gitlab-runner-01 gitlab-runner-02 gitlab-runner-03 gitlab-runner-04}"
CI_INTERNAL_URL="${CI_INTERNAL_URL:-http://gitlab:8929}"
NETWORK_NAME="${NETWORK_NAME:-gitlab-ce-net}"
RUNNER_TAGS="${RUNNER_TAGS:-docker,monorepo}"
RUNNER_DEFAULT_IMAGE="${RUNNER_DEFAULT_IMAGE:-docker:27-cli}"
RUNNER_CONCURRENT="${RUNNER_CONCURRENT:-4}"
RUNNER_CACHE_BUCKET="${RUNNER_CACHE_BUCKET:-runner-cache}"
MINIO_ROOT_USER="${MINIO_ROOT_USER:-gitlab-minio}"
MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-ChangeMe_MinioP@ss!}"

TAB="$(printf '\t')"

log() { printf '\033[36m[bootstrap]\033[0m %s\n' "$*"; }

# --- Ruby snippet: create instance runners and print "name<TAB>token" -------
RUBY_MINT='
user = User.find_by(username: "root") || User.admins.first
raise "no admin user found" unless user
names = (ENV["NAMES"] || "").split
tags  = (ENV["TAGS"] || "").split(",").map(&:strip).reject(&:empty?)
names.each do |name|
  params = {
    runner_type: "instance_type",
    description: name,
    tag_list: tags,
    run_untagged: true,
    locked: false,
    access_level: "not_protected"
  }
  res = ::Ci::Runners::CreateRunnerService.new(user: user, params: params).execute
  ok = res.respond_to?(:success?) ? res.success? : true
  next unless ok
  runner = res.respond_to?(:payload) ? res.payload[:runner] : res
  puts "#{name}\t#{runner.token}"
end
'

# --- Wait for GitLab to be healthy ------------------------------------------
log "Waiting for GitLab ($GITLAB_CONTAINER) to be healthy..."
i=0
until [ "$(docker inspect -f '{{.State.Health.Status}}' "$GITLAB_CONTAINER" 2>/dev/null || echo none)" = "healthy" ]; do
  i=$((i + 1))
  [ $((i % 12)) -eq 1 ] && log "  ...still waiting (GitLab first boot can take several minutes)"
  sleep 5
done
log "GitLab reports healthy."

# The container healthcheck can pass before the HTTP stack (Puma + Workhorse +
# Nginx) is serving requests on first boot. Runner registration calls the REST
# API, so gate on the API actually responding (200/401), not just health.
log "Waiting for the GitLab HTTP API to be ready (web + workhorse)..."
i=0
until
  code="$(docker exec "$GITLAB_CONTAINER" curl -s -o /dev/null -w '%{http_code}' "http://localhost:8929/api/v4/version" 2>/dev/null)"
  code="${code:-000}"
  [ "$code" = "200" ] || [ "$code" = "401" ]
do
  i=$((i + 1))
  [ $((i % 6)) -eq 1 ] && log "  ...API not ready yet (last status: $code)"
  sleep 10
done
log "GitLab HTTP API is ready (status $code)."

# --- Determine which runner containers still need registration --------------
NEED=""
for R in $RUNNER_CONTAINERS; do
  # Wait for the runner container to be running.
  j=0
  until [ "$(docker inspect -f '{{.State.Running}}' "$R" 2>/dev/null || echo false)" = "true" ]; do
    j=$((j + 1)); [ "$j" -gt 60 ] && { log "WARN: $R not running, skipping"; break; }
    sleep 2
  done
  [ "$(docker inspect -f '{{.State.Running}}' "$R" 2>/dev/null || echo false)" = "true" ] || continue

  # Prune runner entries GitLab no longer recognizes (e.g. after a data reset).
  docker exec "$R" gitlab-runner verify --delete >/dev/null 2>&1 || true

  count="$(docker exec "$R" sh -c "grep -c '^\[\[runners\]\]' /etc/gitlab-runner/config.toml 2>/dev/null || true")"
  count="${count:-0}"
  if [ "$count" -ge 1 ]; then
    log "$R already registered — skipping."
  else
    NEED="$NEED $R"
  fi
done

NEED="$(printf '%s' "$NEED" | sed 's/^ *//')"
if [ -z "$NEED" ]; then
  log "All runners already provisioned. Nothing to do."
  exit 0
fi
log "Runners to register:$NEED"

# --- Mint one token per runner that needs it (single Rails call) ------------
log "Minting authentication tokens via GitLab API..."
TOKENS=""
attempt=0
while [ "$attempt" -lt 6 ]; do
  attempt=$((attempt + 1))
  TOKENS="$(docker exec -e NAMES="$NEED" -e TAGS="$RUNNER_TAGS" "$GITLAB_CONTAINER" \
    gitlab-rails runner "$RUBY_MINT" 2>/dev/null | tr -d '\r' | grep "$TAB" || true)"
  [ -n "$TOKENS" ] && break
  log "  mint attempt $attempt failed, retrying in 10s..."
  sleep 10
done

if [ -z "$TOKENS" ]; then
  log "ERROR: failed to mint any runner tokens after $attempt attempts."
  exit 1
fi

# --- Register a single runner (with retries against transient API errors) ---
register_one() {
  _name="$1"; _token="$2"; _attempt=0
  while [ "$_attempt" -lt 5 ]; do
    _attempt=$((_attempt + 1))
    if docker exec "$_name" gitlab-runner register --non-interactive \
        --url "$CI_INTERNAL_URL" \
        --token "$_token" \
        --name "$_name" \
        --executor "docker" \
        --docker-image "$RUNNER_DEFAULT_IMAGE" \
        --docker-privileged \
        --docker-volumes "/certs/client" \
        --docker-volumes "/cache" \
        --docker-shm-size 268435456 \
        --docker-network-mode "$NETWORK_NAME" \
        --clone-url "$CI_INTERNAL_URL" \
        --cache-type "s3" \
        --cache-shared \
        --cache-s3-server-address "minio:9000" \
        --cache-s3-bucket-name "$RUNNER_CACHE_BUCKET" \
        --cache-s3-access-key "$MINIO_ROOT_USER" \
        --cache-s3-secret-key "$MINIO_ROOT_PASSWORD" \
        --cache-s3-insecure >/dev/null 2>&1; then
      return 0
    fi
    log "  register $_name failed (attempt $_attempt/5), retrying in 10s..."
    sleep 10
  done
  return 1
}

# --- Register each runner ----------------------------------------------------
printf '%s\n' "$TOKENS" > /tmp/runner_tokens
FAILED=0
while IFS="$TAB" read -r name token; do
  [ -z "${name:-}" ] && continue
  case "${token:-}" in
    glrt-*) : ;;
    *) log "WARN: no/invalid token for ${name:-<?>}, skipping"; FAILED=1; continue ;;
  esac

  log "Registering $name (${token%%.*}…)"
  if ! register_one "$name" "$token"; then
    log "ERROR: could not register $name after retries."
    FAILED=1
    continue
  fi

  # Global concurrency for this runner container.
  docker exec "$name" sh -c "
    cfg=/etc/gitlab-runner/config.toml
    if grep -q '^concurrent' \"\$cfg\"; then
      sed -i 's/^concurrent = .*/concurrent = $RUNNER_CONCURRENT/' \"\$cfg\"
    else
      printf 'concurrent = %s\n' '$RUNNER_CONCURRENT' | cat - \"\$cfg\" > /tmp/cfg && mv /tmp/cfg \"\$cfg\"
    fi
  " >/dev/null 2>&1 || true
  docker restart "$name" >/dev/null
  log "$name registered and reloaded."
done < /tmp/runner_tokens
rm -f /tmp/runner_tokens

if [ "$FAILED" -ne 0 ]; then
  log "Runner provisioning finished WITH ERRORS. Re-run 'make runners-provision' to retry."
  exit 1
fi
log "Runner provisioning complete."
