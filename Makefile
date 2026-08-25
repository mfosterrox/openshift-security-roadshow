# OpenShift Security Roadshow — local Antora preview
# Works with GNU Make 3.81 (macOS) and GNU Make 4.x (gmake)

.DEFAULT_GOAL := help
.DELETE_ON_ERROR:

CONTAINER_NAME     ?= showroom-httpd
CONTAINER_IMAGE    ?= registry.access.redhat.com/ubi9/httpd-24:1-301
PORT               ?= 8080
WWW_DIR            ?= www
PLAYBOOK           ?= default-site.yml
SITE_URL           ?= http://localhost:$(PORT)/index.html
CONTAINER_ENGINE   ?= $(shell command -v podman 2>/dev/null || command -v docker 2>/dev/null)

.PHONY: help build clean serve stop reset

help: ## Show this help
	@echo "OpenShift Security Roadshow"
	@echo ""
	@echo "Available targets:"
	@grep -E '^[a-zA-Z0-9_-]+:.*##' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "The site will be available at: $(SITE_URL)"
	@echo "Override any variable: make serve PORT=9090"

build: clean ## Build the site using Antora
	@echo "Building new site..."
	npx antora --fetch $(PLAYBOOK) --stacktrace
	@echo "Build process complete. Check the $(WWW_DIR) folder for the generated site."
	@echo "To view the site locally, run: make serve"

clean: ## Remove generated site files
	@echo "Removing old site..."
	rm -rf "$(WWW_DIR)"
	mkdir -p "$(WWW_DIR)"
	@echo "Old site removed"

serve: ## Start serving the site (podman or docker)
	@if [ -z "$(CONTAINER_ENGINE)" ]; then \
		echo "error: podman or docker is required to serve the site"; \
		exit 1; \
	fi
	@echo "Starting serve process..."
	-$(CONTAINER_ENGINE) rm -f $(CONTAINER_NAME) >/dev/null 2>&1
	$(CONTAINER_ENGINE) run -d --rm --name $(CONTAINER_NAME) -p $(PORT):$(PORT) \
		-v "$(CURDIR)/$(WWW_DIR):/var/www/html/:z" \
		$(CONTAINER_IMAGE)
	@echo "Serving lab content on $(SITE_URL)"

stop: ## Stop the serving container
	@echo "Stopping serve process..."
	@if [ -z "$(CONTAINER_ENGINE)" ]; then \
		echo "Container engine not found; nothing to stop."; \
		exit 0; \
	fi
	@$(CONTAINER_ENGINE) stop $(CONTAINER_NAME) 2>/dev/null || \
		echo "Container $(CONTAINER_NAME) not running or does not exist"
	@echo "Stopped serve process."

reset: ## Clean, build, and serve (full reset)
	$(MAKE) --no-print-directory stop
	$(MAKE) --no-print-directory build
	$(MAKE) --no-print-directory serve
	@echo ""
	@echo "Reset complete! Site is available at $(SITE_URL)"
