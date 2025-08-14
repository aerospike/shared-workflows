# Minimal build configuration
CC = gcc
CFLAGS = -Wall -O2
TARGET = hi
SOURCE = hi.c

# Single distro/arch to build for (set via environment variables)
DISTRO ?= jammy
ARCH ?= x86_64

# Docker image mapping
DOCKER_IMAGE_jammy = ubuntu:22.04
DOCKER_IMAGE_noble = ubuntu:24.04
DOCKER_IMAGE_focal = ubuntu:20.04
DOCKER_IMAGE_bullseye = debian:11
DOCKER_IMAGE_bookworm = debian:12
DOCKER_IMAGE_el8 = rockylinux:8
DOCKER_IMAGE_el9 = rockylinux:9
DOCKER_IMAGE_amzn2023 = amazonlinux:2023

# Get the Docker image for the current distro
DOCKER_IMAGE = $(DOCKER_IMAGE_$(DISTRO))

# Directories
BUILD_DIR = build

# Default target
all: docker-build

# Build the application locally
build:
	@echo "Building for $(ARCH)..."
	@mkdir -p $(BUILD_DIR)/$(DISTRO)/$(ARCH)
	$(CC) $(CFLAGS) -o $(BUILD_DIR)/$(DISTRO)/$(ARCH)/$(TARGET) $(SOURCE)

# Build in Docker container for the target distro
docker-build:
	@echo "Building for $(DISTRO)-$(ARCH)..."
	@echo "Using Docker image: $(DOCKER_IMAGE)"
	@mkdir -p $(BUILD_DIR)/$(DISTRO)/$(ARCH)
ifeq ($(filter jammy noble focal bullseye bookworm,$(DISTRO)),$(DISTRO))
	docker run --rm -v $(PWD):/workspace -w /workspace $(DOCKER_IMAGE) \
		bash -c 'apt-get update && apt-get install -y build-essential && \
		$(CC) $(CFLAGS) -o $(BUILD_DIR)/$(DISTRO)/$(ARCH)/$(TARGET) $(SOURCE)'
else
	docker run --rm -v $(PWD):/workspace -w /workspace $(DOCKER_IMAGE) \
		bash -c 'yum install -y --allowerasing gcc make && \
		$(CC) $(CFLAGS) -o $(BUILD_DIR)/$(DISTRO)/$(ARCH)/$(TARGET) $(SOURCE)'
endif

# Clean
clean:
	@rm -rf $(BUILD_DIR)

# Show generated binaries
list:
	@echo "Generated binaries:"
	@find $(BUILD_DIR) -name "$(TARGET)" 2>/dev/null | sort || echo "No binaries found"

.PHONY: all build docker-build clean list
