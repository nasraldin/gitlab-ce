#!/usr/bin/env sh
# =============================================================================
# Create all MinIO buckets used by this stack (idempotent).
#
#   - GitLab object storage (artifacts, LFS, uploads, packages, registry, …)
#   - GitLab Runner distributed cache
# =============================================================================
set -eu

MINIO_ENDPOINT="${MINIO_ENDPOINT:-http://minio:9000}"
MINIO_ROOT_USER="${MINIO_ROOT_USER:-gitlab-minio}"
MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-ChangeMe_MinioP@ss!}"

# GitLab Rails object-store buckets
GITLAB_OBJECT_BUCKET_ARTIFACTS="${GITLAB_OBJECT_BUCKET_ARTIFACTS:-gitlab-artifacts}"
GITLAB_OBJECT_BUCKET_LFS="${GITLAB_OBJECT_BUCKET_LFS:-gitlab-lfs}"
GITLAB_OBJECT_BUCKET_UPLOADS="${GITLAB_OBJECT_BUCKET_UPLOADS:-gitlab-uploads}"
GITLAB_OBJECT_BUCKET_PACKAGES="${GITLAB_OBJECT_BUCKET_PACKAGES:-gitlab-packages}"
GITLAB_OBJECT_BUCKET_DEPENDENCY_PROXY="${GITLAB_OBJECT_BUCKET_DEPENDENCY_PROXY:-gitlab-dependency-proxy}"
GITLAB_OBJECT_BUCKET_TERRAFORM_STATE="${GITLAB_OBJECT_BUCKET_TERRAFORM_STATE:-gitlab-terraform-state}"
GITLAB_OBJECT_BUCKET_CI_SECURE_FILES="${GITLAB_OBJECT_BUCKET_CI_SECURE_FILES:-gitlab-ci-secure-files}"
GITLAB_OBJECT_BUCKET_PAGES="${GITLAB_OBJECT_BUCKET_PAGES:-gitlab-pages}"
GITLAB_OBJECT_BUCKET_EXTERNAL_DIFFS="${GITLAB_OBJECT_BUCKET_EXTERNAL_DIFFS:-gitlab-external-diffs}"

# Container Registry (separate from Rails object_store)
GITLAB_OBJECT_BUCKET_REGISTRY="${GITLAB_OBJECT_BUCKET_REGISTRY:-gitlab-registry}"

# Runner distributed cache
RUNNER_CACHE_BUCKET="${RUNNER_CACHE_BUCKET:-runner-cache}"

log() { printf '[minio-setup] %s\n' "$*"; }

log "Waiting for MinIO at $MINIO_ENDPOINT ..."
until mc alias set local "$MINIO_ENDPOINT" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null 2>&1; do
  sleep 2
done
log "MinIO is ready."

for bucket in \
  "$GITLAB_OBJECT_BUCKET_ARTIFACTS" \
  "$GITLAB_OBJECT_BUCKET_LFS" \
  "$GITLAB_OBJECT_BUCKET_UPLOADS" \
  "$GITLAB_OBJECT_BUCKET_PACKAGES" \
  "$GITLAB_OBJECT_BUCKET_DEPENDENCY_PROXY" \
  "$GITLAB_OBJECT_BUCKET_TERRAFORM_STATE" \
  "$GITLAB_OBJECT_BUCKET_CI_SECURE_FILES" \
  "$GITLAB_OBJECT_BUCKET_PAGES" \
  "$GITLAB_OBJECT_BUCKET_EXTERNAL_DIFFS" \
  "$GITLAB_OBJECT_BUCKET_REGISTRY" \
  "$RUNNER_CACHE_BUCKET"
do
  mc mb --ignore-existing "local/$bucket"
  log "bucket '$bucket' ready"
done

log "All buckets provisioned."
