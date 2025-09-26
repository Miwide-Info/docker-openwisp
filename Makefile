# Find documentation in README.md under
# the heading "Makefile Options".

OPENWISP_VERSION = 24.11.1
SHELL := /bin/bash
.SILENT: clean pull start stop

# Multi-architecture support
PLATFORMS ?= linux/amd64,linux/arm64
LOCAL_PLATFORM ?= linux/amd64
BUILDX_BUILDER ?= openwisp-builder

default: compose-build

USER = registry.gitlab.com/openwisp/docker-openwisp
TAG = edge
SKIP_PULL ?= false
SKIP_BUILD ?= false
SKIP_TESTS ?= false

# Pull
pull:
	printf '\e[1;34m%-6s\e[m\n' "Downloading OpenWISP images..."
	for image in 'openwisp-base' 'openwisp-nfs' 'openwisp-api' 'openwisp-dashboard' \
				 'openwisp-freeradius' 'openwisp-nginx' 'openwisp-openvpn' 'openwisp-postfix' \
				 'openwisp-websocket' ; do \
		docker pull --quiet $(USER)/$${image}:$(TAG); \
		docker tag  $(USER)/$${image}:$(TAG) openwisp/$${image}:latest; \
	done

# Build
setup-buildx:
	@docker buildx use default

python-build: build.py
	python build.py change-secret-key

# Local development builds (single architecture, loadable for testing)
base-build: setup-buildx
	BUILD_ARGS_FILE=$$(cat .build.env 2>/dev/null); \
	for build_arg in $$BUILD_ARGS_FILE; do \
	    BUILD_ARGS+=" --build-arg $$build_arg"; \
	done; \
	docker buildx build --platform $(LOCAL_PLATFORM) --tag openwisp/openwisp-base:intermedia-system \
	             --file ./images/openwisp_base/Dockerfile \
	             --target SYSTEM ./images/ --load; \
	docker buildx build --platform $(LOCAL_PLATFORM) --tag openwisp/openwisp-base:intermedia-python \
	             --file ./images/openwisp_base/Dockerfile \
	             --target PYTHON ./images/ \
	             $$BUILD_ARGS --load; \
	docker buildx build --platform $(LOCAL_PLATFORM) --tag openwisp/openwisp-base:latest \
	             --file ./images/openwisp_base/Dockerfile ./images/ \
	             $$BUILD_ARGS --load

# Multi-architecture builds (for publishing to registries)
base-build-multiarch: setup-buildx
	BUILD_ARGS_FILE=$$(cat .build.env 2>/dev/null); \
	for build_arg in $$BUILD_ARGS_FILE; do \
	    BUILD_ARGS+=" --build-arg $$build_arg"; \
	done; \
	printf '\e[1;34m%-6s\e[m\n' "Building multi-arch openwisp-base..."; \
	docker buildx build --platform $(PLATFORMS) --tag $(USER)/openwisp-base:$(TAG) \
	             --file ./images/openwisp_base/Dockerfile ./images/ \
	             $$BUILD_ARGS --push

nfs-build: setup-buildx
	docker buildx build --platform $(LOCAL_PLATFORM) --tag openwisp/openwisp-nfs:latest \
	             --file ./images/openwisp_nfs/Dockerfile ./images/ --load

nfs-build-multiarch: setup-buildx
	printf '\e[1;34m%-6s\e[m\n' "Building multi-arch openwisp-nfs..."; \
	docker buildx build --platform $(PLATFORMS) --tag $(USER)/openwisp-nfs:$(TAG) \
	             --file ./images/openwisp_nfs/Dockerfile ./images/ --push

compose-build: base-build
	docker compose build --parallel

compose-build-multiarch: base-build-multiarch nfs-build-multiarch setup-buildx
	for service in dashboard api websocket nginx freeradius postfix openvpn; do \
		printf '\e[1;34m%-6s\e[m\n' "Building multi-arch openwisp-$${service}..."; \
		docker buildx build --platform $(PLATFORMS) --tag $(USER)/openwisp-$${service}:$(TAG) \
		             --file ./images/openwisp_$${service}/Dockerfile ./images/ --push; \
	done

# Test
runtests: develop-runtests
	docker compose stop

develop-runtests:
	docker compose up -d
	make develop-pythontests

develop-pythontests:
	python3 tests/runtests.py

# Development
develop: compose-build
	docker compose up -d
	docker compose logs -f

# Clean
clean:
	printf '\e[1;34m%-6s\e[m\n' "Removing docker-openwisp..."
	docker compose stop &> /dev/null
	docker compose down --remove-orphans --volumes --rmi all &> /dev/null
	docker compose rm -svf &> /dev/null
	docker rmi --force openwisp/openwisp-base:latest \
				openwisp/openwisp-base:intermedia-system \
				openwisp/openwisp-base:intermedia-python \
				openwisp/openwisp-nfs:latest \
				`docker images -f "dangling=true" -q` \
				`docker images | grep openwisp/docker-openwisp | tr -s ' ' | cut -d ' ' -f 3` &> /dev/null

# Production
start:
	if [ "$(SKIP_PULL)" == "false" ]; then \
		make pull; \
	fi
	printf '\e[1;34m%-6s\e[m\n' "Starting Services..."
	docker --log-level WARNING compose up -d
	printf '\e[1;32m%-6s\e[m\n' "Success: OpenWISP should be available at your dashboard domain in 2 minutes."

stop:
	printf '\e[1;31m%-6s\e[m\n' "Stopping OpenWISP services..."
	docker --log-level ERROR compose stop
	docker --log-level ERROR compose down --remove-orphans
	docker compose down --remove-orphans &> /dev/null

# Publish
publish:
	if [[ "$(SKIP_BUILD)" == "false" ]]; then \
		make compose-build-multiarch; \
	fi
	if [[ "$(SKIP_TESTS)" == "false" ]]; then \
		make runtests; \
	fi

release:
	make publish TAG=latest SKIP_TESTS=true
	make publish TAG=$(OPENWISP_VERSION) SKIP_BUILD=true SKIP_TESTS=true
