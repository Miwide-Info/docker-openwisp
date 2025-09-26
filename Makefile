# Find documentation in README.md under
# the heading "Makefile Options".

OPENWISP_VERSION = 24.11.1
SHELL := /bin/bash
.SILENT: clean pull start stop

default: compose-build

USER = registry.gitlab.com/openwisp/docker-openwisp
TAG = edge
SKIP_PULL ?= false
SKIP_BUILD ?= false
SKIP_TESTS ?= false
PLATFORMS ?= linux/amd64,linux/arm64
MULTI_ARCH ?= false

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
python-build: build.py
	python build.py change-secret-key

# Create buildx builder for multi-platform builds
setup-buildx:
	if [ "$(MULTI_ARCH)" = "true" ]; then \
		echo "Setting up multi-architecture support..."; \
		docker run --privileged --rm tonistiigi/binfmt --install all; \
		if ! docker buildx ls | grep -q multiarch-builder; then \
			docker buildx create --name multiarch-builder --driver docker-container --use --bootstrap; \
		else \
			docker buildx use multiarch-builder; \
		fi; \
	fi

base-build: setup-buildx
	BUILD_ARGS_FILE=$$(cat .build.env 2>/dev/null); \
	for build_arg in $$BUILD_ARGS_FILE; do \
	    BUILD_ARGS+=" --build-arg $$build_arg"; \
	done; \
	if [ "$(MULTI_ARCH)" = "true" ]; then \
		docker buildx build --platform $(PLATFORMS) --tag openwisp/openwisp-base:intermedia-system \
		             --file ./images/openwisp_base/Dockerfile \
		             --target SYSTEM ./images/; \
		docker buildx build --platform $(PLATFORMS) --tag openwisp/openwisp-base:intermedia-python \
		             --file ./images/openwisp_base/Dockerfile \
		             --target PYTHON ./images/ \
		             $$BUILD_ARGS; \
		docker buildx build --platform $(PLATFORMS) --tag openwisp/openwisp-base:latest \
		             --file ./images/openwisp_base/Dockerfile ./images/ \
		             $$BUILD_ARGS; \
	else \
		docker build --tag openwisp/openwisp-base:intermedia-system \
		             --file ./images/openwisp_base/Dockerfile \
		             --target SYSTEM ./images/; \
		docker build --tag openwisp/openwisp-base:intermedia-python \
		             --file ./images/openwisp_base/Dockerfile \
		             --target PYTHON ./images/ \
		             $$BUILD_ARGS; \
		docker build --tag openwisp/openwisp-base:latest \
		             --file ./images/openwisp_base/Dockerfile ./images/ \
		             $$BUILD_ARGS; \
	fi

nfs-build: setup-buildx
	if [ "$(MULTI_ARCH)" = "true" ]; then \
		docker buildx build --platform $(PLATFORMS) --tag openwisp/openwisp-nfs:latest \
		             --file ./images/openwisp_nfs/Dockerfile ./images/; \
	else \
		docker build --tag openwisp/openwisp-nfs:latest \
		             --file ./images/openwisp_nfs/Dockerfile ./images/; \
	fi

compose-build: base-build
	docker compose build --parallel

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
publish: setup-buildx
	if [[ "$(SKIP_BUILD)" == "false" ]]; then \
		if [ "$(MULTI_ARCH)" = "true" ]; then \
			make multiarch-build; \
		else \
			make compose-build nfs-build; \
		fi; \
	fi
	if [[ "$(SKIP_TESTS)" == "false" ]]; then \
		make runtests; \
	fi
	if [ "$(MULTI_ARCH)" = "true" ]; then \
		# Multi-arch images are built and pushed directly in multiarch-build target \
		echo "Multi-architecture images built and pushed successfully"; \
	else \
		for image in 'openwisp-base' 'openwisp-nfs' 'openwisp-api' 'openwisp-dashboard' \
					 'openwisp-freeradius' 'openwisp-nginx' 'openwisp-openvpn' 'openwisp-postfix' \
					 'openwisp-websocket' ; do \
			# Docker images built locally are tagged "latest" by default. \
			# This script updates the tag of each built image to a user-defined tag \
			# and pushes the newly tagged image to a Docker registry under the user's namespace. \
			docker tag openwisp/$${image}:latest $(USER)/$${image}:$(TAG); \
			docker push $(USER)/$${image}:$(TAG); \
			if [ "$(TAG)" != "latest" ]; then \
				docker rmi $(USER)/$${image}:$(TAG); \
			fi; \
		done; \
	fi

# Build all images for multiple architectures and push directly
multiarch-build: setup-buildx
	BUILD_ARGS_FILE=$$(cat .build.env 2>/dev/null); \
	for build_arg in $$BUILD_ARGS_FILE; do \
	    BUILD_ARGS+=" --build-arg $$build_arg"; \
	done; \
	# Build and push base image \
	docker buildx build --platform $(PLATFORMS) \
	             --tag $(USER)/openwisp-base:$(TAG) \
	             --push \
	             --file ./images/openwisp_base/Dockerfile ./images/ \
	             $$BUILD_ARGS; \
	# Build and push NFS image \
	docker buildx build --platform $(PLATFORMS) \
	             --tag $(USER)/openwisp-nfs:$(TAG) \
	             --push \
	             --file ./images/openwisp_nfs/Dockerfile ./images/; \
	# Build and push API image \
	docker buildx build --platform $(PLATFORMS) \
	             --tag $(USER)/openwisp-api:$(TAG) \
	             --push \
	             --build-arg API_APP_PORT=8001 \
	             --file ./images/openwisp_api/Dockerfile ./images/; \
	# Build and push Dashboard image \
	docker buildx build --platform $(PLATFORMS) \
	             --tag $(USER)/openwisp-dashboard:$(TAG) \
	             --push \
	             --build-arg DASHBOARD_APP_PORT=8000 \
	             --file ./images/openwisp_dashboard/Dockerfile ./images/; \
	# Build and push WebSocket image \
	docker buildx build --platform $(PLATFORMS) \
	             --tag $(USER)/openwisp-websocket:$(TAG) \
	             --push \
	             --build-arg WEBSOCKET_APP_PORT=8002 \
	             --file ./images/openwisp_websocket/Dockerfile ./images/; \
	# Build and push FreeRADIUS image \
	docker buildx build --platform $(PLATFORMS) \
	             --tag $(USER)/openwisp-freeradius:$(TAG) \
	             --push \
	             --file ./images/openwisp_freeradius/Dockerfile ./images/; \
	# Build and push Nginx image \
	docker buildx build --platform $(PLATFORMS) \
	             --tag $(USER)/openwisp-nginx:$(TAG) \
	             --push \
	             --file ./images/openwisp_nginx/Dockerfile ./images/; \
	# Build and push OpenVPN image \
	docker buildx build --platform $(PLATFORMS) \
	             --tag $(USER)/openwisp-openvpn:$(TAG) \
	             --push \
	             --file ./images/openwisp_openvpn/Dockerfile ./images/; \
	# Build and push Postfix image \
	docker buildx build --platform $(PLATFORMS) \
	             --tag $(USER)/openwisp-postfix:$(TAG) \
	             --push \
	             --file ./images/openwisp_postfix/Dockerfile ./images/

publish-multiarch:
	make publish MULTI_ARCH=true

release:
	make publish TAG=latest SKIP_TESTS=true
	make publish TAG=$(OPENWISP_VERSION) SKIP_BUILD=true SKIP_TESTS=true

release-multiarch:
	make publish-multiarch TAG=latest SKIP_TESTS=true
	make publish-multiarch TAG=$(OPENWISP_VERSION) SKIP_BUILD=true SKIP_TESTS=true
