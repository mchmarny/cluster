# can be overridden using env vars
CLUSTER_NAME  ?= "demo"
NODE_IMAGE    ?= "kindest/node:v1.32.2"
CONFIG_FILE   ?= "config/config.yaml"

all: help

.PHONY: cluster-up
cluster-up: ## Create a Kubernetes cluster with KinD
	tools/up $(CLUSTER_NAME) $(NODE_IMAGE) $(CONFIG_FILE)

.PHONY: cluster-down
cluster-down: ## Delete a Kubernetes cluster with KinD
	tools/down $(CLUSTER_NAME)

.PHONY: help
help: ## Display available commands
	@echo ""
	@echo "Current Configuration:"
	@echo "  $$\033[36mCLUSTER_NAME\033[0m   $(CLUSTER_NAME)"
	@echo "  $$\033[36mNODE_IMAGE\033[0m     $(NODE_IMAGE)"
	@echo "  $$\033[36mCONFIG_FILE\033[0m    $(CONFIG_FILE)"
	@echo ""
	@echo "Available commands:"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk \
		'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'
