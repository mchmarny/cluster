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
YAML_FILES      := $(shell find . -type f \( -iname "*.yml" -o -iname "*.yaml" \))
SCAN_SEVERITY   := CRITICAL,HIGH

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

.PHONY: all
all: tf-validate tf-lint tf-fmt scan  ## Run all validation checks (format, lint, security scan, terraform validate)

help: ## Displays available commands
	@echo "Available make targets:"; \
	grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk \
		'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

