.PHONY: help build clean serve stop reset

# Container name for serving the site
CONTAINER_NAME := showroom-httpd
CONTAINER_IMAGE := registry.access.redhat.com/ubi9/httpd-24:1-301
PORT := 8080
WWW_DIR := ./www
SITE_URL := http://localhost:$(PORT)/index.html

# Default target
help:
	@echo "OpenShift Security Roadshow - Makefile"
	@echo ""
	@echo "Available targets:"
	@echo "  make build    - Build the site using Antora"
	@echo "  make clean    - Remove generated site files"
	@echo "  make serve    - Start serving the site using podman"
	@echo "  make stop     - Stop the serving container"
	@echo "  make reset    - Clean, build, and serve (full reset)"
	@echo ""
	@echo "The site will be available at: $(SITE_URL)"

# Build the site using Antora
build: clean
	@echo "Building new site..."
	@npx antora --fetch default-site.yml --stacktrace
	@echo "Build process complete. Check the $(WWW_DIR) folder for the generated site."
	@echo "To view the site locally, run: make serve"

# Clean generated site files
clean:
	@echo "Removing old site..."
	@rm -rf $(WWW_DIR)/*
	@echo "Old site removed"

# Start serving the site using podman
serve:
	@echo "Starting serve process..."
	@if podman ps -a --format "{{.Names}}" | grep -q "^$(CONTAINER_NAME)$$"; then \
		echo "Container $(CONTAINER_NAME) already exists. Stopping it first..."; \
		podman stop $(CONTAINER_NAME) || true; \
		podman rm $(CONTAINER_NAME) || true; \
	fi
	@podman run -d --rm --name $(CONTAINER_NAME) -p $(PORT):$(PORT) \
		-v "$$(pwd)/$(WWW_DIR):/var/www/html/:z" \
		$(CONTAINER_IMAGE)
	@echo "Serving lab content on $(SITE_URL)"

# Stop the serving container
stop:
	@echo "Stopping serve process..."
	@podman stop $(CONTAINER_NAME) || echo "Container $(CONTAINER_NAME) not running or does not exist"
	@echo "Stopped serve process."

# Full reset: clean, build, and serve
reset: stop clean build serve
	@echo ""
	@echo "Reset complete! Site is available at $(SITE_URL)"

