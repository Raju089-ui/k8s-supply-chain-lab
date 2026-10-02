# k8s-supply-chain-lab — end-to-end image supply chain, reproducible locally
#
#   make demo       happy path: build -> scan -> sign -> deploy -> running
#   make demo-fail  unsigned image is rejected by the admission controller
#
# Everything runs on a throwaway kind cluster + local registry. No cloud bill.

SHELL              := /bin/bash
.DEFAULT_GOAL      := help

CLUSTER            ?= supply-chain-lab
REGISTRY           ?= localhost:5001
IMAGE_NAME         ?= supply-chain-demo
APP_VERSION        ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo dev)
IMAGE              := $(REGISTRY)/$(IMAGE_NAME):$(APP_VERSION)
IMAGE_UNSIGNED     := $(REGISTRY)/$(IMAGE_NAME):unsigned
NAMESPACE          ?= demo

COSIGN_KEY         ?= cosign.key
COSIGN_PUB         ?= cosign.pub
# Demo-only passphrase. Real pipelines pull this from Jenkins credentials /
# Key Vault — see docs/jenkins-integration.md.
export COSIGN_PASSWORD ?= lab

TRIVY_SEVERITY     ?= HIGH,CRITICAL

BOLD := \033[1m
DIM  := \033[2m
GRN  := \033[32m
RED  := \033[31m
YLW  := \033[33m
RST  := \033[0m

define step
	@printf "\n$(BOLD)==> %s$(RST)\n" $(1)
endef

## ---------------------------------------------------------------- help ----

.PHONY: help
help: ## Show this help
	@printf "$(BOLD)k8s-supply-chain-lab$(RST)\n\n"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  $(BOLD)%-18s$(RST) %s\n", $$1, $$2}'
	@printf "\n  $(DIM)image: $(IMAGE)$(RST)\n\n"

## ------------------------------------------------------------ preflight ---

.PHONY: preflight
preflight: ## Check that required tools are installed
	$(call step,"Preflight")
	@missing=0; \
	for b in docker kind kubectl cosign trivy; do \
	  if command -v $$b >/dev/null 2>&1; then \
	    printf "  $(GRN)ok$(RST)   %s\n" "$$b"; \
	  else \
	    printf "  $(RED)miss$(RST) %s\n" "$$b"; missing=1; \
	  fi; \
	done; \
	if [ $$missing -ne 0 ]; then \
	  printf "\n  install the missing tools, then re-run. See README.\n"; exit 1; \
	fi

## -------------------------------------------------------------- cluster ---

.PHONY: setup
setup: preflight ## Create kind cluster + local registry + install Kyverno
	$(call step,"Cluster + registry")
	@./scripts/kind-with-registry.sh "$(CLUSTER)" "$(REGISTRY)"
	$(call step,"Installing Kyverno")
	@kubectl apply -f https://github.com/kyverno/kyverno/releases/download/v1.13.2/install.yaml
	@kubectl -n kyverno rollout status deploy/kyverno-admission-controller --timeout=180s
	@kubectl create namespace $(NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	@printf "\n  $(GRN)cluster ready$(RST)\n"

.PHONY: keys
keys: ## Generate a cosign keypair (skipped if one already exists)
	@if [ -f "$(COSIGN_KEY)" ]; then \
	  printf "  $(DIM)keypair already present, skipping$(RST)\n"; \
	else \
	  $(call step,"Generating cosign keypair"); \
	  cosign generate-key-pair; \
	fi

## ---------------------------------------------------------------- build ---

.PHONY: build
build: ## Build and push the application image
	$(call step,"Build $(IMAGE)")
	@docker build --build-arg APP_VERSION=$(APP_VERSION) -t $(IMAGE) .
	@docker push $(IMAGE)

.PHONY: scan
scan: ## Trivy scan — fails the build on HIGH/CRITICAL
	$(call step,"Trivy scan ($(TRIVY_SEVERITY))")
	@trivy image \
	  --severity $(TRIVY_SEVERITY) \
	  --ignore-unfixed \
	  --exit-code 1 \
	  --format table \
	  $(IMAGE)
	@printf "  $(GRN)no blocking vulnerabilities$(RST)\n"

.PHONY: sbom
sbom: ## Generate a CycloneDX SBOM and attach it to the image
	$(call step,"SBOM")
	@trivy image --format cyclonedx --output sbom.cdx.json $(IMAGE)
	@cosign attach sbom --sbom sbom.cdx.json $(IMAGE) || true
	@printf "  wrote sbom.cdx.json\n"

.PHONY: sign
sign: keys ## Sign the image with cosign
	$(call step,"Sign")
	@cosign sign --yes --key $(COSIGN_KEY) $(IMAGE)

.PHONY: verify
verify: ## Verify the signature locally (what the cluster will also do)
	$(call step,"Verify")
	@cosign verify --key $(COSIGN_PUB) $(IMAGE) >/dev/null \
	  && printf "  $(GRN)signature valid$(RST)\n"

## --------------------------------------------------------------- policy ---

.PHONY: policy
policy: ## Install Kyverno policies (signature, non-root, limits, no :latest)
	$(call step,"Installing policies")
	@./scripts/render-verify-policy.sh "$(COSIGN_PUB)" "$(REGISTRY)" \
	  > /tmp/verify-image-signature.rendered.yaml
	@kubectl apply -f /tmp/verify-image-signature.rendered.yaml
	@kubectl apply -f policies/
	@sleep 3
	@kubectl get cpol

## --------------------------------------------------------------- deploy ---

.PHONY: deploy
deploy: ## Deploy the signed image
	$(call step,"Deploy signed image")
	@sed -e "s|IMAGE_PLACEHOLDER|$(IMAGE)|g" manifests/deployment.yaml \
	  | kubectl -n $(NAMESPACE) apply -f -
	@kubectl -n $(NAMESPACE) apply -f manifests/service.yaml
	@kubectl -n $(NAMESPACE) rollout status deploy/supply-chain-demo --timeout=90s
	@printf "\n  $(GRN)deployed — admission controller accepted the signed image$(RST)\n"

.PHONY: deploy-unsigned
deploy-unsigned: ## Push an UNSIGNED image and try to deploy it (expected to fail)
	$(call step,"Building an unsigned image")
	@docker build --build-arg APP_VERSION=unsigned -t $(IMAGE_UNSIGNED) .
	@docker push $(IMAGE_UNSIGNED)
	$(call step,"Attempting to deploy it")
	@if sed -e "s|IMAGE_PLACEHOLDER|$(IMAGE_UNSIGNED)|g" \
	        -e "s|supply-chain-demo|supply-chain-demo-unsigned|g" \
	        manifests/deployment.yaml | kubectl -n $(NAMESPACE) apply -f - 2>/tmp/denial.txt; then \
	  printf "\n  $(RED)PROBLEM: the unsigned image was admitted. Policy is not enforcing.$(RST)\n"; \
	  exit 1; \
	else \
	  printf "\n  $(GRN)blocked, as intended:$(RST)\n\n"; \
	  sed 's/^/    /' /tmp/denial.txt; \
	fi

## ----------------------------------------------------------------- demo ---

.PHONY: demo
demo: setup policy build scan sign verify deploy ## Full happy path
	@printf "\n$(BOLD)$(GRN)Chain complete:$(RST) build -> scan -> sign -> verify -> admit\n"
	@printf "  try: make port-forward\n\n"

.PHONY: demo-fail
demo-fail: deploy-unsigned ## Prove an unsigned image cannot get in
	@printf "\n$(BOLD)$(GRN)Gate held.$(RST) Unsigned image rejected at admission.\n\n"

.PHONY: port-forward
port-forward: ## Expose the app on localhost:8080
	@printf "  http://localhost:8080  (ctrl-c to stop)\n"
	@kubectl -n $(NAMESPACE) port-forward svc/supply-chain-demo 8080:80

## ---------------------------------------------------------------- clean ---

.PHONY: clean
clean: ## Delete the kind cluster and the local registry
	$(call step,"Teardown")
	@kind delete cluster --name $(CLUSTER) || true
	@docker rm -f kind-registry || true
	@rm -f sbom.cdx.json /tmp/denial.txt
	@printf "  gone\n"
