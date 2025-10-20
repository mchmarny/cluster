# Vars
SHELL := bash
.ONESHELL:
.SHELLFLAGS      := -eu -o pipefail -c
.DEFAULT_GOAL    := help
YAML_FILES       := $(shell find . -type f \( -iname "*.yml" -o -iname "*.yaml" \))
SCAN_SEVERITY    := CRITICAL,HIGH

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

.PHONY: check
check: ## Run all checks
	@command -v $(TF) >/dev/null || { echo "Missing '$(TF)'. Install Terraform."; exit 127; }
	@command -v $(TFLINT) >/dev/null || { echo "Missing '$(TFLINT)'. Install tflint."; exit 127; }
	@command -v $(TRIVY) >/dev/null || { echo "Missing '$(TRIVY)'. Install trivy."; exit 127; }

.PHONY: fmt
fmt: check ## Format Terraform files (per directory)
	@for dir in $(TF_DIRS); do \
		echo "Formatting Terraform files in $$dir"; \
		$(TF) fmt $$dir; \
	done

.PHONY: fmt-check
fmt-check: check ## Check Terraform file formatting (per directory)
	@for dir in $(TF_DIRS); do \
		echo "Checking format of Terraform files in $$dir"; \
		$(TF) fmt -check -diff $$dir; \
	done

.PHONY: lint
lint: check ## Run tflint (per directory)
	@$(TFLINT) --init
	@for dir in $(TF_DIRS); do \
		echo "Running tflint in $$dir"; \
		$(TFLINT) --chdir=$$dir --format compact || true; \
	done

.PHONY: scan
scan: check ## Run trivy security scan
	@$(TRIVY) config . --severity $(SCAN_SEVERITY) --format table --ignorefile .trivyignore --quiet

.PHONY: validate ## Run all validation checks
validate: fmt-check lint scan ## Run all validation checks (format, lint, security scan)

help: ## Displays available commands
	@echo "Available make targets:"; \
	grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk \
		'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

