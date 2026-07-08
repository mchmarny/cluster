# Vars
PROJECT 		:= $(shell basename `git rev-parse --show-toplevel`)
COMMIT          := $(shell git rev-parse --short HEAD)
BRANCH          := $(shell git rev-parse --abbrev-ref HEAD)
REMOTE 		    := $(shell git remote get-url origin)
USER 		    := $(shell git config user.username)
CHANGES         := $(shell git status --porcelain | wc -l | xargs)
SHELL           := bash
.ONESHELL:
.SHELLFLAGS     := -eu -o pipefail -c
.DEFAULT_GOAL   := help

# Versions from .settings.yaml (single source of truth)
TERRAFORM_VERSION ?= $(shell yq -r '.tools.terraform' .settings.yaml 2>/dev/null)
ifeq ($(TERRAFORM_VERSION),)
TERRAFORM_VERSION := 1.15.5
endif
KUBECTL_VERSION ?= $(shell yq -r '.tools.kubectl' .settings.yaml 2>/dev/null)
ifeq ($(KUBECTL_VERSION),)
KUBECTL_VERSION := 1.36.1
endif
AWSCLI_VERSION ?= $(shell yq -r '.tools.awscli' .settings.yaml 2>/dev/null)
ifeq ($(AWSCLI_VERSION),)
AWSCLI_VERSION := 2.34.63
endif
GCLOUD_VERSION ?= $(shell yq -r '.tools.gcloud' .settings.yaml 2>/dev/null)
ifeq ($(GCLOUD_VERSION),)
GCLOUD_VERSION := 569.0.0
endif
AZURECLI_VERSION ?= $(shell yq -r '.tools.azurecli' .settings.yaml 2>/dev/null)
ifeq ($(AZURECLI_VERSION),)
AZURECLI_VERSION := 2.87.0
endif
SCAN_SEVERITY ?= $(shell yq -r '.linting.scan_severity' .settings.yaml 2>/dev/null)
ifeq ($(SCAN_SEVERITY),)
SCAN_SEVERITY := CRITICAL,HIGH
endif
LINT_TIMEOUT ?= $(shell yq -r '.linting.lint_timeout' .settings.yaml 2>/dev/null)
ifeq ($(LINT_TIMEOUT),)
LINT_TIMEOUT := 5m
endif
KIND_NODE_IMAGE ?= $(shell yq -r '.testing.kind_node_image' .settings.yaml 2>/dev/null)
ifeq ($(KIND_NODE_IMAGE),)
KIND_NODE_IMAGE := kindest/node:v1.36.1
endif

# Tools
TF ?= terraform
TFLINT ?= tflint
TRIVY ?= trivy

# Functions
define list_tf_dirs
git ls-files '*.tf' | xargs -n1 dirname | sort -u
endef
TF_DIRS := $(shell $(list_tf_dirs))

# Commands

.PHONY: info
info: ## Prints the current project info
	@echo "Project:"
	@echo "  name:              $(PROJECT)"
	@echo "  commit:            $(COMMIT)"
	@echo "  branch:            $(BRANCH)"
	@echo "  remote:            $(REMOTE)"
	@echo "  user:              $(USER)"
	@echo "  changes:           $(CHANGES)"
	@echo "Settings (.settings.yaml):"
	@echo "  terraform:         $(TERRAFORM_VERSION)"
	@echo "  kubectl:           $(KUBECTL_VERSION)"
	@echo "  awscli:            $(AWSCLI_VERSION)"
	@echo "  gcloud:            $(GCLOUD_VERSION)"
	@echo "  azurecli:          $(AZURECLI_VERSION)"
	@echo "  kind_node_image:   $(KIND_NODE_IMAGE)"

.PHONY: tools-check
tools-check: ## Verify required tools are installed and show version comparison
	@bash tools/check-tools

.PHONY: dep-check
dep-check: ## Run all dependency checks
	@command -v $(TF) >/dev/null || { echo "Missing '$(TF)'. Install Terraform."; exit 127; }
	@command -v $(TFLINT) >/dev/null || { echo "Missing '$(TFLINT)'. Install tflint."; exit 127; }
	@command -v $(TRIVY) >/dev/null || { echo "Missing '$(TRIVY)'. Install trivy."; exit 127; }

# Terraform Targets

.PHONY: tf-init
tf-init: dep-check ## Initialize Terraform in all directories
	@mkdir -p ~/.terraform.d/plugin-cache
	@for dir in $(TF_DIRS); do \
		echo "Initializing Terraform in $$dir"; \
		$(TF) -chdir=$$dir init -backend=false -input=false -no-color; \
	done

.PHONY: tf-validate
tf-validate: tf-init ## Validate Terraform configuration in all directories
	@echo "Validating Terraform configurations..."
	@FAILED=""; \
	for dir in $(TF_DIRS); do \
		echo "Validating $$dir..."; \
		if ! $(TF) -chdir=$$dir validate -no-color; then \
			if [ -z "$$FAILED" ]; then \
				FAILED="$$dir"; \
			else \
				FAILED="$$FAILED $$dir"; \
			fi; \
		fi; \
	done; \
	if [ -n "$$FAILED" ]; then \
		echo ""; \
		echo "Validation failed in: $$FAILED"; \
		exit 1; \
	fi; \
	echo "All Terraform configurations are valid!"

.PHONY: tf-fmt
tf-fmt: dep-check ## Check Terraform file formatting (per directory)
	@for dir in $(TF_DIRS); do \
		echo "Checking format of Terraform files in $$dir"; \
		$(TF) fmt -check -diff $$dir; \
	done

.PHONY: tf-lint
tf-lint: dep-check ## Run tflint (per directory)
	@$(TFLINT) --init
	@for dir in $(TF_DIRS); do \
		echo "Running tflint in $$dir"; \
		$(TFLINT) --chdir=$$dir --format compact || true; \
	done

.PHONY: scan
scan: dep-check ## Run trivy security scan
	@$(TRIVY) config . --severity $(SCAN_SEVERITY) --format table --ignorefile .trivyignore --quiet

.PHONY: tf-qualify
tf-qualify: tf-validate tf-lint tf-fmt scan  ## Run all Terraform quality checks

.PHONY: qualify
qualify: go-qualify tf-qualify ## Run all quality checks (Go + Terraform)

# Go Targets

GO ?= go
VERSION ?= $(shell git describe --tags --abbrev=0 2>/dev/null || echo "v0.0.0-dev")

.PHONY: go-test
go-test: ## Run Go unit tests with race detection and coverage
	@$(GO) test -count=1 -race -coverprofile=coverage.out ./...
	@$(GO) tool cover -func=coverage.out | tail -1
	@rm -f coverage.out

.PHONY: go-vet
go-vet: ## Run go vet
	@$(GO) vet ./...

.PHONY: go-fmt
go-fmt: ## Check Go formatting
	@test -z "$$(gofmt -l .)" || { gofmt -l . && exit 1; }

.PHONY: go-lint
go-lint: ## Run golangci-lint
	@golangci-lint run --timeout=$(LINT_TIMEOUT) ./...

.PHONY: go-build
go-build: ## Build the cluster binary
	@$(GO) build -trimpath -ldflags "-s -w -X main.version=$(VERSION) -X main.commit=$(COMMIT)" -o dist/cluster ./cmd/cluster

.PHONY: go-qualify
go-qualify: go-vet go-fmt go-lint go-test go-build ## Run all Go quality checks

.PHONY: e2e
e2e: ## Run end-to-end smoke tests (builds Docker image + validates)
	@./tools/e2e

# Image Build Targets

.PHONY: build-eks
build-eks: ## Build EKS Docker image (mirrors providers, then builds)
	@./tools/mirror eks
	@docker build -f image/eks.dockerfile \
		--build-arg VERSION=$(VERSION) \
		--build-arg COMMIT=$(COMMIT) \
		--build-arg TERRAFORM_VERSION=$(TERRAFORM_VERSION) \
		--build-arg KUBECTL_VERSION=$(KUBECTL_VERSION) \
		--build-arg AWSCLI_VERSION=$(AWSCLI_VERSION) \
		-t cluster-eks:$(VERSION) -t cluster-eks:latest .

.PHONY: build-gke
build-gke: ## Build GKE Docker image (mirrors providers, then builds)
	@./tools/mirror gke
	@docker build -f image/gke.dockerfile \
		--build-arg VERSION=$(VERSION) \
		--build-arg COMMIT=$(COMMIT) \
		--build-arg TERRAFORM_VERSION=$(TERRAFORM_VERSION) \
		--build-arg KUBECTL_VERSION=$(KUBECTL_VERSION) \
		--build-arg GCLOUD_VERSION=$(GCLOUD_VERSION) \
		-t cluster-gke:$(VERSION) -t cluster-gke:latest .

.PHONY: build-aks
build-aks: ## Build AKS Docker image (mirrors providers, then builds)
	@./tools/mirror aks
	@docker build -f image/aks.dockerfile \
		--build-arg VERSION=$(VERSION) \
		--build-arg COMMIT=$(COMMIT) \
		--build-arg TERRAFORM_VERSION=$(TERRAFORM_VERSION) \
		--build-arg KUBECTL_VERSION=$(KUBECTL_VERSION) \
		--build-arg AZURECLI_VERSION=$(AZURECLI_VERSION) \
		-t cluster-aks:$(VERSION) -t cluster-aks:latest .

# Version Bump Targets

CSPS := eks gke aks
BUMP_TYPES := major minor patch

define bump_target
.PHONY: bump-$(1)-$(2)
bump-$(1)-$(2): ## Bump $(1) version for $(2) image
	@./tools/bump $(1) $(2)
endef

$(foreach csp,$(CSPS),$(foreach bump,$(BUMP_TYPES),$(eval $(call bump_target,$(bump),$(csp)))))

help: ## Displays available commands
	@echo "Available make targets:"; \
	grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk \
		'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'; \
	echo ""; \
	echo "Version bump targets (bump-{major|minor|patch}-{csp}):"; \
	for csp in $(CSPS); do \
		for bump in $(BUMP_TYPES); do \
			printf "\033[36m%-30s\033[0m Bump %s version for %s image\n" "bump-$$bump-$$csp" "$$bump" "$$csp"; \
		done; \
	done

