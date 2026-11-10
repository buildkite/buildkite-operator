# Shell recipes fail on errors, including failures inside pipelines.
SHELL = /usr/bin/env bash -o pipefail
.SHELLFLAGS = -ec

HELM ?= helm
HELM_CHART_DIR ?= charts/buildkite-operator
KIND ?= kind

.PHONY: help
help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2 } ' $(MAKEFILE_LIST)

.PHONY: test-helm
test-helm: ## Validate the standalone Helm chart.
	python3 hack/test_deletion_cost.py
	HELM=$(HELM) HELM_CHART_DIR=$(HELM_CHART_DIR) ./hack/test-helm-chart.sh

.PHONY: check-docs
check-docs: ## Check that relative links and heading anchors in the docs resolve.
	python3 hack/test_check_docs.py
	python3 hack/check_docs.py

.PHONY: helm-examples
helm-examples: ## Render each examples/<name>/values.yaml of the standalone chart into rendered.yaml and NOTES.txt.
	@set -eu; \
		for values in $(HELM_CHART_DIR)/examples/*/values.yaml; do \
			dir="$$(dirname "$$values")"; \
			$(HELM) template buildkite $(HELM_CHART_DIR) \
				--namespace buildkite \
				--api-versions keda.sh/v1alpha1/ScaledObject \
				--api-versions keda.sh/v1alpha1/TriggerAuthentication \
				--values "$$values" >"$$dir/rendered.yaml.tmp"; \
			mv "$$dir/rendered.yaml.tmp" "$$dir/rendered.yaml"; \
			$(HELM) install buildkite $(HELM_CHART_DIR) --dry-run=client \
				--namespace buildkite \
				--set keda.validateInstallation=false \
				--values "$$values" >"$$dir/NOTES.txt.tmp"; \
			sed '1,/^NOTES:$$/d' "$$dir/NOTES.txt.tmp" >"$$dir/NOTES.txt"; \
			rm "$$dir/NOTES.txt.tmp"; \
		done; \
		for rendered in $(HELM_CHART_DIR)/examples/*/rendered.yaml $(HELM_CHART_DIR)/examples/*/NOTES.txt; do \
			[ ! -f "$$rendered" ] || [ -f "$$(dirname "$$rendered")/values.yaml" ] || rm "$$rendered"; \
		done

.PHONY: install-hooks
install-hooks: ## Use the repository's Git hooks in .githooks.
	git config core.hooksPath .githooks

.PHONY: test-supervisor
test-supervisor: ## Run the ephemeral-agent supervisor against a real Docker daemon.
	HELM=$(HELM) HELM_CHART_DIR=$(HELM_CHART_DIR) ./hack/test-supervisor.sh

.PHONY: test-step-image
test-step-image: ## Run the step-image bootstrap script against a real Docker daemon.
	HELM=$(HELM) HELM_CHART_DIR=$(HELM_CHART_DIR) ./hack/test-step-image.sh

.PHONY: test-helm-e2e
test-helm-e2e: ## Install and uninstall the standalone chart in a fresh, isolated Kind cluster.
	@set -eu; \
		cluster="buildkite-operator-helm-e2e-$$$$"; \
		kubeconfig="$$(mktemp)"; \
		cleanup() { $(KIND) delete cluster --name "$$cluster" --kubeconfig "$$kubeconfig"; rm -f "$$kubeconfig"; }; \
		trap cleanup EXIT INT TERM; \
		$(KIND) create cluster --name "$$cluster" --kubeconfig "$$kubeconfig"; \
		KUBECONFIG="$$kubeconfig" KUBE_CONTEXT="kind-$$cluster" KIND_CLUSTER="$$cluster" \
			HELM=$(HELM) HELM_CHART_DIR=$(HELM_CHART_DIR) ./hack/test-helm-e2e.sh
