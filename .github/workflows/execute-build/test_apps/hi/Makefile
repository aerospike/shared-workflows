# Minimal build configuration
CC = gcc
CFLAGS = -Wall -O2
TARGET = hi
SOURCE = hi.c

# Single distro/arch to build for (set via environment variables)
DISTRO ?= jammy
ARCH ?= x86_64
EMULATED ?= false

# Docker image mapping
DOCKER_IMAGE_jammy = ubuntu:22.04
DOCKER_IMAGE_noble = ubuntu:24.04
DOCKER_IMAGE_focal = ubuntu:20.04
DOCKER_IMAGE_bullseye = debian:11
DOCKER_IMAGE_bookworm = debian:12
DOCKER_IMAGE_trixie = debian:13
DOCKER_IMAGE_el8 = rockylinux:8
DOCKER_IMAGE_el9 = rockylinux:9
DOCKER_IMAGE_amzn2023 = amazonlinux:2023

# Get the Docker image for the current distro
DOCKER_IMAGE = $(DOCKER_IMAGE_$(DISTRO))

# Directories
BUILD_DIR = build

# Determine cross-compilation setup
ifeq ($(ARCH),arm64)
    ifeq ($(EMULATED),true)
        # x86_64 runner with emulation - use cross-compiler
        CC = aarch64-linux-gnu-gcc
        # Cross-compiler setup varies by distro
        ifeq ($(filter jammy noble focal,$(DISTRO)),$(DISTRO))
            # Ubuntu family
            CROSS_COMPILE_CMD = apt-get update && apt-get install -y gcc-aarch64-linux-gnu
        else ifeq ($(filter bullseye bookworm trixie,$(DISTRO)),$(DISTRO))
            # Debian family
            CROSS_COMPILE_CMD = apt-get update && apt-get install -y gcc-aarch64-linux-gnu
        else ifeq ($(filter el8 el9 amzn2023,$(DISTRO)),$(DISTRO))
            # RPM family (el8, el9, amzn2023)
            CROSS_COMPILE_CMD = echo "Cross-compilation is not supported for RPM family distributions (el8, el9, amzn2023)"
        else
            echo "ERROR: Unsupported distribution: $(DISTRO)"
            exit 1
        endif
    else
        # Real ARM runner - use native compiler
        CROSS_COMPILE_CMD = echo "Using native ARM compiler"
    endif
else
    # x86_64 builds - no cross-compilation needed
    CROSS_COMPILE_CMD = echo "Using native x86_64 compiler"
endif

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
	@echo "Emulated: $(EMULATED)"
	@mkdir -p $(BUILD_DIR)/$(DISTRO)/$(ARCH)
ifeq ($(filter jammy noble focal bullseye bookworm,$(DISTRO)),$(DISTRO))
	docker run --rm -v $(PWD):/workspace -w /workspace \
		-e ARCH=$(ARCH) -e EMULATED=$(EMULATED) \
		$(DOCKER_IMAGE) \
		bash -c 'apt-get update && apt-get install -y build-essential && \
		if [ "$$ARCH" = "arm64" ] && [ "$$EMULATED" = "true" ]; then \
			CC=aarch64-linux-gnu-gcc; \
			echo "Installing cross-compiler and target libraries..."; \
			apt-get install -y gcc-aarch64-linux-gnu libc6-dev-arm64-cross; \
		else \
			CC=${CC}; \
			echo "Using native compiler"; \
		fi && \
		echo "Using CC: $$CC" && \
		echo "ARCH: $$ARCH, EMULATED: $$EMULATED" && \
		command -v $$CC && \
		$$CC $(CFLAGS) -o $(BUILD_DIR)/$(DISTRO)/$(ARCH)/$(TARGET) $(SOURCE)'
else
	# RPM family - no cross-compilation support
	@if [ "$(ARCH)" = "arm64" ] && [ "$(EMULATED)" = "true" ]; then \
		echo "ERROR: Cross-compilation not supported for RPM distros (el8, el9, amzn2023)"; \
		echo "Use real ARM runners or Debian/Ubuntu distros for ARM64 builds"; \
		exit 1; \
	fi
	docker run --rm -v $(PWD):/workspace -w /workspace \
		-e ARCH=$(ARCH) -e EMULATED=$(EMULATED) \
		$(DOCKER_IMAGE) \
		bash -c 'set -e; \
		if command -v dnf >/dev/null 2>&1; then \
		  dnf -y clean all && dnf -y distro-sync --refresh || dnf -y upgrade --refresh; \
		  dnf -y makecache; \
		  dnf -y install --allowerasing --setopt=install_weak_deps=False gcc glibc-devel make; \
		else \
		  yum -y clean all && yum -y update; \
		  yum -y makecache; \
		  yum -y install --allowerasing gcc glibc-devel make; \
		fi; \
		CC=${CC} && \
		echo "Using CC: $$CC" && \
		echo "ARCH: $$ARCH, EMULATED: $$EMULATED" && \
		command -v $$CC && \
		$$CC --version && \
		$$CC $(CFLAGS) -o $(BUILD_DIR)/$(DISTRO)/$(ARCH)/$(TARGET) $(SOURCE)'
endif
# Clean
clean:
	@rm -rf $(BUILD_DIR)

# Show generated binaries
list:
	@echo "Generated binaries:"
	@find $(BUILD_DIR) -name "$(TARGET)" 2>/dev/null | sort || echo "No binaries found"

.PHONY: all build docker-build clean list
