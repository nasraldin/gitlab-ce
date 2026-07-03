# GitLab CE - convenience commands
# Run `make help` to list available targets.

COMPOSE := docker compose
SERVICE := gitlab

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

.PHONY: config
config: ## Validate & render the compose configuration
	$(COMPOSE) config

.PHONY: pull
pull: ## Pull the latest GitLab CE image
	$(COMPOSE) pull

.PHONY: up
up: ## Start GitLab in the background
	$(COMPOSE) up -d

.PHONY: down
down: ## Stop and remove the containers (data is preserved on host)
	$(COMPOSE) down

.PHONY: restart
restart: ## Restart the GitLab service
	$(COMPOSE) restart $(SERVICE)

.PHONY: logs
logs: ## Follow GitLab logs
	$(COMPOSE) logs -f $(SERVICE)

.PHONY: status
status: ## Show container + health status
	$(COMPOSE) ps

.PHONY: health
health: ## Print the current healthcheck state
	@docker inspect --format '{{.State.Health.Status}}' gitlab-ce 2>/dev/null || echo "not running"

.PHONY: shell
shell: ## Open a shell inside the container
	$(COMPOSE) exec $(SERVICE) /bin/bash

.PHONY: password
password: ## Show the auto-generated initial root password (valid 24h after first boot)
	$(COMPOSE) exec $(SERVICE) cat /etc/gitlab/initial_root_password || true

.PHONY: reconfigure
reconfigure: ## Re-apply gitlab.rb / omnibus configuration
	$(COMPOSE) exec $(SERVICE) gitlab-ctl reconfigure

# --- Runners (fleet: gitlab-runner, gitlab-runner-01..04) ------------------

RUNNERS := gitlab-runner gitlab-runner-01 gitlab-runner-02 gitlab-runner-03 gitlab-runner-04

.PHONY: runners-provision
runners-provision: ## (Re)provision the runner fleet - idempotent, no-op if done
	./scripts/bootstrap-runners.sh

.PHONY: runner-add
runner-add: ## Register one runner container: make runner-add NAME=gitlab-runner-05
	@test -n "$(NAME)" || { echo "Usage: make runner-add NAME=<container>"; exit 1; }
	./scripts/register-runner.sh $(NAME)

.PHONY: runners-unregister
runners-unregister: ## Remove ALL fleet runners from this host and from GitLab
	./scripts/unregister-runner.sh

.PHONY: runners-list
runners-list: ## List runners configured in every runner container
	@for r in $(RUNNERS); do echo "== $$r =="; docker exec $$r gitlab-runner list 2>/dev/null || echo "  (not running)"; done

.PHONY: runners-verify
runners-verify: ## Verify every runner is still online with GitLab
	@for r in $(RUNNERS); do echo "== $$r =="; docker exec $$r gitlab-runner verify 2>/dev/null || echo "  (not running)"; done

.PHONY: runners-logs
runners-logs: ## Follow logs from all runners
	$(COMPOSE) logs -f $(RUNNERS)

.PHONY: bootstrap-logs
bootstrap-logs: ## Show the runner auto-provisioner output
	docker logs -f gitlab-runner-bootstrap

.PHONY: runner-config
runner-config: ## Print the first runner's config.toml
	docker exec gitlab-runner cat /etc/gitlab-runner/config.toml

# --- Registry --------------------------------------------------------------

.PHONY: registry-status
registry-status: ## Check the container registry HTTP endpoint
	@curl -s -o /dev/null -w "registry HTTP %{http_code}\n" http://gitlab.local:5050/v2/ || \
	echo "registry unreachable (did you add 'gitlab.local' to /etc/hosts?)"

# --- MinIO / object storage ------------------------------------------------

.PHONY: minio-buckets
minio-buckets: ## List all MinIO buckets used by this stack
	@docker run --rm --network gitlab-ce-net \
		--env-file .env \
		--entrypoint /bin/sh \
		minio/mc:latest -c 'mc alias set local http://minio:9000 "$$MINIO_ROOT_USER" "$$MINIO_ROOT_PASSWORD" >/dev/null && mc ls local'

.PHONY: minio-provision
minio-provision: ## (Re)create all MinIO buckets (idempotent)
	docker compose up minio-setup

.PHONY: object-store-status
object-store-status: ## Show GitLab object-store config from Omnibus
	$(COMPOSE) exec $(SERVICE) grep -E "object_store|registry\['storage" /etc/gitlab/gitlab.rb | grep -v '^#' | head -20

.PHONY: check
check: ## Run GitLab's built-in environment checks
	$(COMPOSE) exec $(SERVICE) gitlab-rake gitlab:check SANITIZE=true

.PHONY: psql
psql: ## Open a psql shell to the bundled PostgreSQL database
	$(COMPOSE) exec $(SERVICE) gitlab-psql

.PHONY: db-status
db-status: ## Show status of the bundled datastores (PostgreSQL + Redis)
	$(COMPOSE) exec $(SERVICE) gitlab-ctl status postgresql redis

.PHONY: backup
backup: ## Create an application backup (inside the data volume: /var/opt/gitlab/backups)
	$(COMPOSE) exec $(SERVICE) gitlab-backup create

.PHONY: backup-pull
backup-pull: ## Copy backups out of the container into ./backups on the host
	@mkdir -p backups
	docker cp gitlab-ce:/var/opt/gitlab/backups/. ./backups/
	@echo "Backups copied to ./backups"

.PHONY: upgrade
upgrade: pull up ## Pull the newest image and recreate the container

.PHONY: destroy
destroy: ## DANGER: stop and delete containers AND all persisted volumes
	$(COMPOSE) down -v
