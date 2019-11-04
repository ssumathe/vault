# release.Makefile allows efficient building of release binaries.
#
# How it works
# ============
# We first build a base image containing external libraries etc. This image is expected
# to change only when we update the version of Go, or one of the other third party
# dependencies it installs. See build/base.Dockerfile.
#
# Based on that base image, every release cycle, we build another base image called the
# static image. This image additionally contains a snapshot of the source code we are
# building, as well as generated static assets, which do not change per target platform.
# (This means the full compiled UI.) See build/static.Dockerfile.
# 
# Using this static base image, we can now build the per-platform binaries.
#
# Notes
# =====
# This is designed to be self-contained enough that we can make use of it without recourse
# to an external Docker registry. This is important for performing builds in CircleCI, where
# we do not want to require additional credentials for pushing to remote registries.
#
# In order to share Docker images between jobs in CircleCI, we cache the images created as
# tarballs, meaning they only need to be rebuilt when something has changed.

# Strict mode shell - See https://fieldnotes.tech/how-to-shell-for-compatible-makefiles
SHELL := /usr/bin/env bash -euo pipefail -c

TOUCH := touch
DATE := date
ifeq ($(shell uname),Darwin)
TOUCH := gtouch
DATE := gdate
endif

# BUILD_CACHE_DIR contains references to intermediate docker images, as well as
# archives created with 'docker save'. In CI, you should share the contents of 
# this directory between jobs.
BUILD_CACHE_DIR ?= .buildcache
# PACKAGE_OUT_ROOT is the root directory where the final packages will be written to.
PACKAGE_OUT_ROOT ?= dist

# BASE_BASE_IMAGE is the underlying image on which the base builder image is built.
BASE_BASE_IMAGE := debian:buster

# COMMIT is the Git commit SHA
COMMIT := $(shell git rev-parse HEAD)


### Non-source build inputs (override these when invoking make to produce alternate binaries).
### See build/package-list.txt and build/package-list.lock, which override these
### per package.

## Standard Go env vars.
GOOS ?= $(shell go env GOOS || echo linux)
GOARCH ?= $(shell go env GOARCH || echo amd64)
CC ?= gcc
CGO_ENABLED ?= 0
GO111MODULE ?= off

# GO_BUILD_TAGS is a comma-separated list of Go build tags, passed to -tags flag of 'go build'.
GO_BUILD_TAGS ?= vault

### Package parameters.

# BINARY_NAME is literally the name of the product's binary file.
BINARY_NAME ?= vault
# PRODUCT_NAME is the top-level name of all editions of this product.
PRODUCT_NAME ?= vault
# BUILD_VERSION is the major/minor/prerelease fields of the version.
BUILD_VERSION ?= 0.0.0
# BUILD_PRERELEASE is the prerelease field of the version. If nonempty, it must begin with a -.
BUILD_PRERELEASE ?= -dev
# EDITION is used to differentiate alternate builds of the same commit, which may differ in
# terms of build tags or other build inputs. EDITION should always form part of the BUNDLE_NAME,
# and if non-empty MUST begin with a +.
EDITION ?=

### Calculated package parameters.

FULL_VERSION := $(BUILD_VERSION)$(BUILD_PRERELEASE)
# BUNDLE_NAME is the name of the release bundle.
BUNDLE_NAME ?= $(PRODUCT_NAME)$(EDITION)
# PACKAGE_NAME is the unique name of a specific build of this product.
PACKAGE_NAME = $(BUNDLE_NAME)_$(FULL_VERSION)_$(GOOS)_$(GOARCH)
# PACKAGE is the zip file containing a specific binary.
PACKAGE := $(PACKAGE_OUT_ROOT)/$(PACKAGE_NAME).zip

### Calculated build inputs.

# LDFLAGS: These linker commands inject build metadata into the binary.
LDFLAGS += -X github.com/hashicorp/vault/sdk/version.GitCommit="$(COMMIT)"
LDFLAGS += -X github.com/hashicorp/vault/sdk/version.Version="$(BUILD_VERSION)"
LDFLAGS += -X github.com/hashicorp/vault/sdk/version.VersionPrerelease="$(BUILD_PRERELEASE)"

# OUT_DIR tells the Go toolchain where to place the binary.
OUT_DIR := $(PACKAGE_OUT_ROOT)/$(PACKAGE_NAME)
# BUILD_ENV is the list of env vars that are passed through to 'make package' and 'go build'.
BUILD_ENV := \
	GO111MODULE=$(GO111MODULE) \
	GOOS=$(GOOS) \
	GOARCH=$(GOARCH) \
	CC=$(CC) \
	CGO_ENABLED=$(CGO_ENABLED) \
	BUILD_VERSION=$(BUILD_VERSION) \
	BUILD_PRERELEASE=$(BUILD_PRERELEASE)

# BUILD_COMMAND compiles the Go binary.
BUILD_COMMAND := \
	$(BUILD_ENV) go build -v \
	-tags '$(GO_BUILD_TAGS)' \
	-ldflags '$(LDFLAGS)' \
	-o /$(OUT_DIR)/$(BINARY_NAME)

# ARCHIVE_COMMAND creates the package archive from the binary.
ARCHIVE_COMMAND := zip /$(PACKAGE) /$(OUT_DIR)/$(BINARY_NAME)

### Docker run command configuration.

DOCKER_SHELL := /bin/bash -euo pipefail -c
DOCKER_RUN_FLAGS := --rm -v $(CURDIR)/$(OUT_DIR):/$(OUT_DIR)
# DOCKER_RUN_COMMAND ties everything together to build the final package as a
# single docker run invocation.
DOCKER_RUN_COMMAND = docker run $(DOCKER_RUN_FLAGS) $(BUILD_STATIC_IMAGE) $(DOCKER_SHELL) "$(BUILD_COMMAND) && $(ARCHIVE_COMMAND)"

### Docker builder image configuration.

# BASE_SOURCE are the files that dictate the base image.
BASE_SOURCE := build/base.Dockerfile

# UI_DEPS_SOURCE are the files which dictate the UI dependencies.
UI_DEPS_SOURCE := ui/yarn.lock ui/package.json build/ui-deps.Dockerfile

UI_SOURCE := $(shell git ls-files ui/) build/ui.Dockerfile

# SOURCE_ID identifies an exact instance of the contents of all files in SOURCE.
# To efficiently calculate this, we take the shasum of COMMIT plus the output of 'git diff'.
SOURCE_ID := $(shell { echo $(COMMIT); git diff -- . ':(exclude)release.Makefile' ':(exclude).circleci'; } | sha256sum | cut -d' ' -f1)

BASE_CACHE_DIR = $(BUILD_CACHE_DIR)/base/$(BUILD_BASE_SUM)
UI_DEPS_CACHE_DIR = $(BUILD_CACHE_DIR)/ui-deps/$(UI_DEPS_SUM)
UI_CACHE_DIR = $(BUILD_CACHE_DIR)/ui/$(UI_SUM)
STATIC_CACHE_DIR = $(BUILD_CACHE_DIR)/static/$(SOURCE_ID)

# Ensure the image cache dirs exist.
_ := $(shell mkdir -p $(BASE_CACHE_DIR) $(UI_DEPS_CACHE_DIR) $(STATIC_CACHE_DIR))

# SOURCE_LIST is a file containing the list of files in SOURCE.
# We write this to a file as it is too long a list to pass around as CLI args.
SOURCE_LIST := $(STATIC_CACHE_DIR)/source-list
_ := $(shell { git ls-files; git ls-files -o --exclude-standard; } | grep -vF release.Makefile | grep -vF .circleci/ > $(SOURCE_LIST))
# Source includes every file tracked by Git, as well as every new file not in .gitignore.
SOURCE := $(shell cat $(SOURCE_LIST))

# BUILD_BASE_SUM is the ID of the build base dockerfile.
BUILD_BASE_SUM := $(shell { cat $(BASE_SOURCE); echo $(BASE_BASE_IMAGE); } | sha256sum | cut -d' ' -f1)
BUILD_BASE_REPO := vault-builder-base
BUILD_BASE_TAG := $(BUILD_BASE_SUM)
BUILD_BASE_IMAGE := $(BUILD_BASE_REPO):$(BUILD_BASE_TAG)
BUILD_BASE := $(BASE_CACHE_DIR)/$(BUILD_BASE_REPO)_$(BUILD_BASE_TAG)
BUILD_BASE_ARCHIVE := $(BUILD_BASE).tar.gz

# BUILD_UI_DEPS_SUM represents a unique combination of UI_DEPS_SOURCE and the relevant dockerfile.
BUILD_UI_DEPS_SUM := $(shell sha256sum <(cat $(UI_DEPS_SOURCE) build/ui-deps.Dockerfile) | cut -d' ' -f1)
BUILD_UI_DEPS_REPO := vault-builder-ui-deps
BUILD_UI_DEPS_TAG := $(BUILD_UI_DEPS_SUM)
BUILD_UI_DEPS_IMAGE := $(BUILD_UI_DEPS_REPO):$(BUILD_UI_DEPS_TAG)
BUILD_UI_DEPS := $(UI_DEPS_CACHE_DIR)/$(BUILD_UI_DEPS_REPO)_$(BUILD_UI_DEPS_TAG)
BUILD_UI_DEPS_ARCHIVE := $(BUILD_UI_DEPS).tar.gz

# BUILD_UI_SUM represents a unique combination of UI_SOURCE and the relevant dockerfile.
BUILD_UI_SUM := $(shell sha256sum <(cat build/ui-deps.Dockerfile; git log -n1 --format='%H' HEAD '--' ui/; git diff ui/) | cut -d' ' -f1)
BUILD_UI_REPO := vault-builder-ui
BUILD_UI_TAG := $(BUILD_UI_SUM)
BUILD_UI_IMAGE := $(BUILD_UI_REPO):$(BUILD_UI_TAG)
BUILD_UI := $(UI_CACHE_DIR)/$(BUILD_UI_REPO)_$(BUILD_UI_TAG)
BUILD_UI_ARCHIVE := $(BUILD_UI).tar.gz

BUILD_STATIC_REPO := vault-builder-static
BUILD_STATIC_TAG := $(SOURCE_ID)
BUILD_STATIC_IMAGE := $(BUILD_STATIC_REPO):$(BUILD_STATIC_TAG)
BUILD_STATIC := $(STATIC_CACHE_DIR)/$(BUILD_STATIC_REPO)_$(BUILD_STATIC_TAG)
BUILD_STATIC_ARCHIVE := $(BUILD_STATIC).tar.gz

# BASE_SOURCE_ARCHIVE is the archive containing files needed to build the base image.
BASE_SOURCE_ARCHIVE := $(BASE_CACHE_DIR)/base-source_$(BUILD_BASE_SUM)

# UI_DEPS_SOURCE_ARCHIVE is the archive containing files that dictate the UI dependencies.
UI_DEPS_SOURCE_ARCHIVE := $(UI_DEPS_CACHE_DIR)/ui-deps-source_$(BUILD_UI_DEPS_SUM).tar.gz

# UI_DEPS_SOURCE_ARCHIVE is the archive containing files that dictate the UI dependencies.
UI_SOURCE_ARCHIVE := $(UI_CACHE_DIR)/ui-source_$(BUILD_UI_SUM).tar.gz

# SOURCE_ARCHIVE is the name of the file we use as Docker context when
# building the static image.
SOURCE_ARCHIVE := $(STATIC_CACHE_DIR)/source.tar.gz

### Phonies section (these allow running individual jobs without knowing the source ID etc).

default: help

help:
	@echo release.Makefile: help text TODO, please refer to comments in release.Makefile.

debug:
	@echo COMMIT='$(COMMIT)'
	@echo SOURCE_ID='$(SOURCE_ID)'
	@echo SOURCE_DIR=$(SOURCE_DIR)
	@echo BUILD_STATIC='$(BUILD_STATIC)'
	@echo SOURCE_ARCHIVE=$(SOURCE_ARCHIVE)
	@echo DOCKER_RUN_COMMAND=$(DOCKER_RUN_COMMAND)
	@echo PACKAGE=$(PACKAGE)
	@echo BUILD_UI_DEPS_SUM=$(BUILD_UI_DEPS_SUM)
	@echo UI_DEPS_SOURCE_ARCHIVE=$(UI_DEPS_SOURCE_ARCHIVE)

base: $(BUILD_BASE)
	@cat $<

base-archive-name:
	@echo $(BUILD_BASE_ARCHIVE)

base-archive: $(BUILD_BASE_ARCHIVE)
	@echo $<

base-restore:
	@echo "==> Restoring image from archive: $(BUILD_BASE_IMAGE)"
	@docker load -i $(BUILD_BASE_ARCHIVE)
	@echo $(BUILD_BASE_IMAGE) > $(BUILD_BASE)

ui-deps: $(BUILD_UI_DEPS)
	@cat $<

ui-deps-archive-name:
	@echo $(BUILD_UI_DEPS_ARCHIVE)

ui-deps-archive: $(BUILD_UI_DEPS_ARCHIVE)
	@echo $<

ui-deps-restore:
	@echo "==> Restoring image from archive: $(BUILD_UI_DEPS_IMAGE)"
	@docker load -i $(BUILD_UI_DEPS_ARCHIVE)
	@echo $(BUILD_UI_DEPS_IMAGE) > $(BUILD_UI_DEPS)

ui: $(BUILD_UI)
	@cat $<

ui-archive-name:
	@echo $(BUILD_UI_ARCHIVE)

ui-archive: $(BUILD_UI_ARCHIVE)
	@echo $<

ui-restore:
	@echo "==> Restoring image from archive: $(BUILD_UI_IMAGE)"
	@docker load -i $(BUILD_UI_ARCHIVE)
	@echo $(BUILD_UI_IMAGE) > $(BUILD_UI)

static: $(BUILD_STATIC)
	@cat $<

static-archive-name:
	@echo $(BUILD_STATIC_ARCHIVE)

static-archive: $(BUILD_STATIC_ARCHIVE)
	@echo $<

static-restore:
	@echo "==> Restoring image from archive: $(BUILD_STATIC_IMAGE)"
	@docker load -i $(BUILD_STATIC_ARCHIVE)
	@echo $(BUILD_STATIC_IMAGE) > $(BUILD_STATIC)

package: $(PACKAGE)
	@echo $<

ui-deps-source-archive: $(UI_DEPS_SOURCE_ARCHIVE)
	@echo $<

ui-source-archive: $(UI_SOURCE_ARCHIVE)
	@echo $<

source-archive: $(SOURCE_ARCHIVE)
	@echo $<

package-list: build/package-list.lock
	@cat $<

package-item:
	@echo "$(BUILD_ENV) make package # $(PACKAGE)" >> build/package-list.lock

# package-list.lock contains a complete command for building a package on each line.
build/package-list.lock: build/package-list.txt release.Makefile
	@echo "==> Re-writing $@"
	@rm -f $@
	@cat build/package-list.txt | while read -r P; do \
		env $$P $(MAKE) -f release.Makefile package-item; \
	done

.PHONY: default help base static package source-archive ui-deps-source-archive package-list

## End phonies, targets below are real files.
#
# SOURCE_ARCHIVE is a tarball of all files not ignored by Git.
# We use this as the Docker context rather than relying on .dockerignore or similar, as it is simpler.
# Note that we do not use 'git archive' because we want to include uncommitted modifications
# during development ('git archive' only includes what's committed). Ensuring that we are building
# from a clean tree in CI will be enforced elsewhere.
$(SOURCE_ARCHIVE): | $(SOURCE_LIST) # order-only dep since we always regenerate SOURCE_LIST
	@mkdir -p $$(dirname $@)
	@echo "==> Refreshing source archive."
	@tar czf $@ -T - < $(SOURCE_LIST)

# UI_DEPS_SOURCE_ARCHIVE contains only the files that dictate UI dependencies.
$(UI_DEPS_SOURCE_ARCHIVE): $(UI_DEPS_SOURCE)
	@mkdir -p $$(dirname $@)
	@echo "==> Refreshing ui deps source archive."
	@tar czf $@ $(UI_DEPS_SOURCE)

# UI_SOURCE_ARCHIVE contains only the files that dictate UI dependencies.
$(UI_SOURCE_ARCHIVE): $(UI_SOURCE)
	@mkdir -p $$(dirname $@)
	@echo "==> Refreshing ui source archive."
	@tar czf $@ $(UI_SOURCE)

$(BASE_SOURCE_ARCHIVE): $(BASE_SOURCE)
	@mkdir -p $$(dirname $@)
	@echo "==> Refreshing base source archive."
	@tar czf $@ $<

# BUILD_IMAGE builds a builder base image if necessary.
# First it checks if the image already exists, of if there is an archived
# image available to load. If not, it performs the build itself.
# Parameters:
# 	1: Image name
# 	2: Base image name
# 	3: Dockerfile path
# 	4: Source archive path (for context)
# 	5: Image archive path (to restore image from)
define BUILD_IMAGE
	@if docker inspect $(1) > /dev/null 2>&1; then \
		echo "==> Image already exists, setting marker file: $(1)"; \
	elif [ -f $(5) ]; then \
		echo "==> Restoring image from archive: $(1)"; \
		docker load -i $(5); \
	else \
		echo "==> Building image (this may take some time): $(1)"; \
		docker build --build-arg BASE_IMAGE=$(2) -f $(3) -t $(1) - < $(4); \
	fi; \
	docker inspect -f '{{.Created}}' $(1) > $(@).timestamp 2>/dev/null; \
	$(TOUCH) -m -d $$(cat $(@).timestamp) $(@);
endef

define ENSURE_IMAGE
	mkdir -p $$(dirname $(3)); \
	if { docker inspect -f '{{.Created}}' $(1) > $(3).timestamp 2>/dev/null; }; then \
		echo "==> Image already exists (built on $$(cat $(3).timestamp)), setting marker file: $(1)"; \
		echo $(1) > $(3); \
		$(TOUCH) -m -d $$(cat $(3).timestamp) $(3); \
	elif [ -f $(2) ]; then \
		echo "==> Restoring image from archive: $(1)"; \
		docker load -i $(2); \
		docker inspect -f '{{.Created}}' $(1) > $(3).timestamp 2>/dev/null; \
		$(TOUCH) -m -d $$(cat $(3).timestamp) $(3); \
	elif [ -f $(3) ]; then \
		echo "==> Docker image no longer exists, removing marker file: $(1)"; \
		rm -f $(3); \
	fi
endef

# BUILD_BASE is the base docker image, minus any source code.
$(BUILD_BASE): build/base.Dockerfile | $(BASE_SOURCE_ARCHIVE)
	$(call BUILD_IMAGE,$(BUILD_BASE_IMAGE),$(BASE_BASE_IMAGE),build/base.Dockerfile,$(BASE_SOURCE_ARCHIVE),$(BUILD_BASE_ARCHIVE))

$(BUILD_BASE_ARCHIVE): | $(BUILD_BASE)
	@if [ -f $@ ]; then echo "==> Image archive already exists: $@"; exit 0; fi; \
		mkdir -p $$(dirname $@); \
		echo "==> Exporting docker image archive (this may take some time): $@"; \
		docker save -o $@ $(BUILD_BASE_IMAGE);

# BUILD_UI_DEPS is the base image plus all external UI dependencies.
$(BUILD_UI_DEPS): $(BUILD_BASE) | $(UI_DEPS_SOURCE_ARCHIVE)
	$(call BUILD_IMAGE,$(BUILD_UI_DEPS_IMAGE),$(BUILD_BASE_IMAGE),build/ui-deps.Dockerfile,$(UI_DEPS_SOURCE_ARCHIVE),$(BUILD_UI_DEPS_ARCHIVE))

$(BUILD_UI_DEPS_ARCHIVE): | $(BUILD_UI_DEPS)
	@if [ -f $@ ]; then echo "==> Image archive already exists: $@"; exit 0; fi; \
		mkdir -p $$(dirname $@); \
		echo "==> Exporting docker image archive (this may take some time): $@"; \
		docker save -o $@ $(BUILD_UI_DEPS_IMAGE)

# BUILD_UI is the base image plus the compiled UI.
$(BUILD_UI): $(BUILD_UI_DEPS) | $(UI_SOURCE_ARCHIVE)
	$(call BUILD_IMAGE,$(BUILD_UI_IMAGE),$(BUILD_UI_DEPS_IMAGE),build/ui.Dockerfile,$(UI_SOURCE_ARCHIVE),$(BUILD_UI_ARCHIVE))

$(BUILD_UI_ARCHIVE): | $(BUILD_UI)
	@if [ -f $@ ]; then echo "==> Image archive already exists: $@"; exit 0; fi; \
		mkdir -p $$(dirname $@); \
		echo "==> Exporting docker image archive (this may take some time): $@"; \
		docker save -o $@ $(BUILD_UI_IMAGE)

# BUILD_STATIC is the base docker image, plus source code, with all static files built.
# Static files are code and UI assets that do not differ between platforms.
# We pass SOURCE_ARCHIVE as the context here.
$(BUILD_STATIC): build/static.Dockerfile $(BUILD_UI) | $(SOURCE_ARCHIVE) 
	$(call BUILD_IMAGE,$(BUILD_STATIC_IMAGE),$(BUILD_UI_IMAGE),build/static.Dockerfile,$(SOURCE_ARCHIVE),$(BUILD_STATIC_ARCHIVE))

$(BUILD_STATIC_ARCHIVE): | $(BUILD_STATIC)
	@if [ -f $@ ]; then echo "==> Image archive already exists: $@"; exit 0; fi; \
		mkdir -p $$(dirname $@); \
		echo "==> Exporting docker image archive (this may take some time): $@"; \
		docker save -o $@ $(BUILD_STATIC_IMAGE)

$(PACKAGE): 
	@mkdir -p $$(dirname $@)
	@echo "==> Building package: $@"
	@rm -rf ./$(OUT_DIR)
	@mkdir -p ./$(OUT_DIR)
	$(DOCKER_RUN_COMMAND)

ifndef SUBMAKE
SUBMAKE := YES
export SUBMAKE
_ := $(shell $(call ENSURE_IMAGE,$(BUILD_BASE_IMAGE),$(BUILD_BASE_ARCHIVE),$(BUILD_BASE)))
_ := $(shell $(call ENSURE_IMAGE,$(BUILD_UI_DEPS_IMAGE),$(BUILD_UI_DEPS_ARCHIVE),$(BUILD_UI_DEPS)))
_ := $(shell $(call ENSURE_IMAGE,$(BUILD_UI_IMAGE),$(BUILD_UI_ARCHIVE),$(BUILD_UI)))
_ := $(shell $(call ENSURE_IMAGE,$(BUILD_STATIC_IMAGE),$(BUILD_STATIC_ARCHIVE),$(BUILD_STATIC)))
endif
