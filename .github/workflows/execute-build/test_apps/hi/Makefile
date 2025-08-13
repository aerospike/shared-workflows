# Minimal build configuration
CC = gcc
CFLAGS = -Wall -O2
TARGET = hi
SOURCE = hi.c
VERSION ?= 1.0.0

# Single distro/arch to build for (set via environment variables)
DISTRO ?= jammy
ARCH ?= x86_64
PACKAGE_TYPE ?= deb

# Distro version mapping
DISTRO_VERSION_jammy = 22.04
DISTRO_VERSION_noble = 24.04
DISTRO_VERSION_focal = 20.04
DISTRO_VERSION_bullseye = 11
DISTRO_VERSION_bookworm = 12
DISTRO_VERSION_el8 = el8
DISTRO_VERSION_el9 = el9
DISTRO_VERSION_amzn2023 = amzn2023

# Docker image mapping
DOCKER_IMAGE_jammy = ubuntu:22.04
DOCKER_IMAGE_noble = ubuntu:24.04
DOCKER_IMAGE_focal = ubuntu:20.04
DOCKER_IMAGE_bullseye = debian:11
DOCKER_IMAGE_bookworm = debian:12
DOCKER_IMAGE_el8 = rockylinux:8
DOCKER_IMAGE_el9 = rockylinux:9
DOCKER_IMAGE_amzn2023 = amazonlinux:2023

# Get the version and image for the current distro
DISTRO_VERSION = $(DISTRO_VERSION_$(DISTRO))
DOCKER_IMAGE = $(DOCKER_IMAGE_$(DISTRO))

# Directories
BUILD_DIR = build
PACKAGE_DIR = packages

# FPM options
FPM_OPTS = --verbose --force --maintainer="Aerospike Team" \
           --description="Simple hello world app" \
           --version="$(VERSION)" --vendor="Aerospike" \
           --name="$(TARGET)"

# Default target
all: build package

# Build the application locally
build:
	@echo "Building for $(ARCH)..."
	@mkdir -p $(BUILD_DIR)
	$(CC) $(CFLAGS) -o $(BUILD_DIR)/$(TARGET) $(SOURCE)

# Generate single package locally
package: build
	@echo "Creating $(PACKAGE_TYPE) package for $(DISTRO)-$(ARCH)..."
	@mkdir -p $(PACKAGE_DIR)
ifeq ($(PACKAGE_TYPE),deb)
	fpm -s dir -t deb $(FPM_OPTS) \
		--package="$(PACKAGE_DIR)/$(TARGET)_$(VERSION)_$(DISTRO_VERSION)_$(ARCH).deb" \
		--deb-dist="$(DISTRO)" \
		$(BUILD_DIR)/$(TARGET)=/usr/local/bin/$(TARGET)
else
	fpm -s dir -t rpm $(FPM_OPTS) \
		--package="$(PACKAGE_DIR)/$(TARGET)-$(VERSION)-1.$(DISTRO_VERSION).$(ARCH).rpm" \
		$(BUILD_DIR)/$(TARGET)=/usr/local/bin/$(TARGET)
endif

# Common parts
RVM_SETUP = gpg --keyserver hkp://keyserver.ubuntu.com --recv-keys 409B6B1796C275462A1703113804BB82D39DC0E3 7D2BAF1CF37B13E2069D6956105BD0E739499BDB && \
	curl -sSL https://get.rvm.io | bash -s stable && \
	source /etc/profile.d/rvm.sh && \
	rvm get stable && \
	rvm install ruby --latest && \
	rvm --default use ruby && \
	gem install --no-document fpm && \
	gcc -Wall -O2 -o $(TARGET) $(SOURCE)

# Build in Docker container for the target distro
docker-build:
	@echo "Building $(PACKAGE_TYPE) package for $(DISTRO)-$(ARCH)..."
	@echo "Using Docker image: $(DOCKER_IMAGE)"
	@mkdir -p $(PACKAGE_DIR)
ifeq ($(PACKAGE_TYPE),deb)
	docker run --rm -v $(PWD):/workspace -w /workspace $(DOCKER_IMAGE) \
		bash -c 'apt-get update && apt-get install -y build-essential curl gnupg procps && \
		$(RVM_SETUP) && \
		fpm -s dir -t deb --verbose --force --maintainer="Aerospike Team" --description="Simple hello world app" --version="$(VERSION)" --vendor="Aerospike" --name="$(TARGET)" \
			--package="$(PACKAGE_DIR)/$(TARGET)_$(VERSION)_$(DISTRO_VERSION)_$(ARCH).deb" \
			--deb-dist="$(DISTRO)" \
			$(TARGET)=/usr/local/bin/$(TARGET)'
else
	docker run --rm -v $(PWD):/workspace -w /workspace $(DOCKER_IMAGE) \
		bash -c 'yum install -y gcc make rpm-build redhat-rpm-config tar gzip xz ca-certificates curl which gnupg procps-ng && \
		$(RVM_SETUP) && \
		fpm -s dir -t rpm --verbose --force --maintainer="Aerospike Team" --description="Simple hello world app" --version="$(VERSION)" --vendor="Aerospike" --name="$(TARGET)" \
			--package="$(PACKAGE_DIR)/$(TARGET)-$(VERSION)-1.$(DISTRO_VERSION).$(ARCH).rpm" \
			$(TARGET)=/usr/local/bin/$(TARGET)'
endif

# Clean
clean:
	@rm -rf $(BUILD_DIR) $(PACKAGE_DIR)

# Show generated packages
list:
	@echo "Generated packages:"
	@find $(PACKAGE_DIR) -name "*.deb" -o -name "*.rpm" 2>/dev/null | sort || echo "No packages found"

.PHONY: all build package docker-build deps clean list
