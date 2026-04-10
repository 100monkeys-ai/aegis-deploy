.PHONY: setup deploy teardown status networks validate registry-login install-cli aegis shell bootstrap-secrets generate-keys redeploy logs clean

PROFILE ?= development
SCRIPTS := ./scripts
PODS_DIR := ./podman/pods

include profiles/$(PROFILE).conf

# ---- Setup ----
setup:
	@bash $(SCRIPTS)/setup-ubuntu.sh

# ---- Networks ----
networks:
	@bash ./podman/networks/create-networks.sh

# ---- Registry Login ----
registry-login:
	@set -a && . ./.env && set +a && \
	if [ -z "$$GHCR_TOKEN" ]; then \
		echo "ERROR: GHCR_TOKEN is not set in .env — cannot pull private images."; \
		echo "       Set GHCR_USERNAME and GHCR_TOKEN (read:packages PAT) in your .env file."; \
		exit 1; \
	fi && \
	echo "$$GHCR_TOKEN" | podman login ghcr.io --username "$$GHCR_USERNAME" --password-stdin && \
	echo "==> Logged in to ghcr.io as $$GHCR_USERNAME"

# ---- CLI Binary ----
install-cli:
	@bash $(SCRIPTS)/install-aegis-cli.sh

# ---- Deploy ----
deploy: registry-login networks install-cli
	@echo "==> Deploying AEGIS platform (profile: $(PROFILE))"
	@bash $(SCRIPTS)/deploy.sh $(PROFILE)
	@echo "==> Deployment complete"

# ---- Teardown ----
teardown:
	@echo "==> Tearing down AEGIS platform (profile: $(PROFILE))"
	@bash $(SCRIPTS)/teardown.sh $(PROFILE)

# ---- Status ----
status:
	@podman pod ps --format "table {{.Name}}\t{{.Status}}\t{{.Containers}}"

# ---- Validate ----
validate:
	@bash $(SCRIPTS)/validate-stack.sh

# ---- Bootstrap ----
bootstrap-secrets:
	@bash $(SCRIPTS)/bootstrap-openbao.sh

generate-keys:
	@bash $(SCRIPTS)/generate-seal-keys.sh

# ---- Redeploy single pod ----
redeploy: registry-login
	@if [ -z "$(POD)" ]; then echo "Usage: make redeploy POD=core"; exit 1; fi
	@echo "==> Redeploying pod: $(POD)"
	@set -a && . ./.env && set +a && \
	POD_FILE=$$(find $(PODS_DIR)/$(POD) -name "pod-*.yaml" -type f | head -1) && \
	if [ -z "$$POD_FILE" ]; then echo "ERROR: No pod YAML found in $(PODS_DIR)/$(POD)"; exit 1; fi && \
	envsubst < "$$POD_FILE" | podman play kube --network aegis-network --replace - && \
	echo "==> Pod $(POD) redeployed"

# ---- Helpers ----
logs:
	@podman pod logs -f $(POD)

aegis:
	@if [ -z "$(CMD)" ]; then echo "Usage: make aegis CMD=\"agent list\""; exit 1; fi
	@podman exec -it aegis-core-aegis-runtime /usr/local/bin/aegis-runtime $(CMD)

shell:
	@podman exec -it aegis-core-aegis-runtime /bin/bash


clean:
	@bash $(SCRIPTS)/teardown.sh full
	@podman volume prune -f
	@podman network prune -f
