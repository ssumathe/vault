# WARNING: Do not EDIT or MERGE this file, it is generated by 'packagespec lock'.
# config.mk contains constants and derived configuration that applies to
# building both layers and final packages.

# Only include the config once. This means we can include it in the header
# of each makefile, to allow calling them individually and when they call
# each other.
ifneq ($(CONFIG_INCLUDED),YES)
CONFIG_INCLUDED := YES

# Set SHELL to strict mode, in a way compatible with both old and new GNU make.
SHELL := /usr/bin/env bash -euo pipefail -c

REPO_ROOT := $(shell git rev-parse --show-toplevel)

# Set AUTO_INSTALL_TOOLS to YES in CI to have any missing required tools installed
# automatically.
AUTO_INSTALL_TOOLS ?= NO

# CACHE_ROOT is the build cache directory.
CACHE_ROOT ?= .buildcache

CACHE_GITIGNORE := $(CACHE_ROOT)/.gitignore
$(shell [ -f $(CACHE_GITIGNORE) ] || { mkdir -p $(CACHE_ROOT); echo '*' > $(CACHE_GITIGNORE); })

# SPEC is the human-managed description of which packages we are able to build.
SPEC_FILE_PATTERN := packages*.yml
SPEC := $(shell cd $(REPO_ROOT); find . -mindepth 1 -maxdepth 1 -name '$(SPEC_FILE_PATTERN)')
ifneq ($(words $(SPEC)),1)
$(error Found $(words $(SPEC)) $(SPEC_FILE_PATTERN) files, need exactly 1: $(SPEC))
endif

SPEC_FILENAME := $(notdir $(SPEC))
SPEC_MODIFIER := $(SPEC_FILENAME:packages%.yml=%)

# LOCKDIR contains the lockfile and layer files.
LOCKDIR := packages$(SPEC_MODIFIER).lock

# BUILDER_IMAGE_PREFIX is used in generating layers' docker image names.
BUILDER_IMAGE_PREFIX := vault-builder

# LOCK is the generated fully-expanded rendition of SPEC, for use in generating CI
# pipelines and other things.
LOCK := $(LOCKDIR)/pkgs.yml

### Utilities and constants
GIT_EXCLUDE_PREFIX := :(exclude)
# SUM generates the sha1sum of its input.
SUM := sha1sum | cut -d' ' -f1
# QUOTE_LIST wraps a list of space-separated strings in quotes.
QUOTE := $(shell echo "'")
QUOTE_LIST = $(addprefix $(QUOTE),$(addsuffix $(QUOTE),$(1)))
GIT_EXCLUDE_LIST = $(call QUOTE_LIST,$(addprefix $(GIT_EXCLUDE_PREFIX),$(1)))
### End utilities and constants.

# ALWAYS_EXCLUDE_SOURCE prevents source from these directories from taking
# part in the SOURCE_ID, or from being sent to the builder image layers.
# This is important for allowing the head of master to build other commits
# where this build system has not been vendored.
#
# Source in LOCKDIR is encoded as PACKAGE_SPEC_ID and included in paths
# and cache keys. Source in .circleci/ should not do much more than call
# code in the release/ directory, SPEC is the source of LOCKDIR.
ALWAYS_EXCLUDE_SOURCE     := $(SPEC) $(LOCKDIR)/ .circleci/
# ALWAYS_EXCLUD_SOURCE_GIT is git path filter parlance for the above.
ALWAYS_EXCLUDE_SOURCE_GIT := $(call GIT_EXCLUDE_LIST,$(ALWAYS_EXCLUDE_SOURCE))

YQ_PACKAGE_BY_ID = .packages[] | select(.packagespecid == "$(1)")  

# YQ_PACKAGE_PATH is a yq query fragment to select the package PACKAGE_SPEC_ID.
# This may be invalid, check that PACKAGE_SPEC_ID is not empty before use.
YQ_PACKAGE_PATH := $(call YQ_PACKAGE_BY_ID,$(PACKAGE_SPEC_ID))  

# QUERY_LOCK is a macro to query the lock file.
QUERY_LOCK = cd $(REPO_ROOT); yq -r '$(1)' < $(LOCK)

QUERY_SPEC = cd $(REPO_ROOT); yq -r '$(1)' < $(SPEC)

# QUERY_PACKAGESPEC queries the package according to the current PACKAGE_SPEC_ID.
QUERY_PACKAGESPEC = $(call QUERY_LOCK,$(YQ_PACKAGE_PATH) | $(1))
QUERY_PACKAGESPEC_BY_ID = $(call QUERY_LOCK,$(call YQ_PACKAGE_PATH_BY_ID,$(1)) | $(2))

ifeq ($(PACKAGE_SOURCE_ID),)
# Even though layers may have different Git revisions, based on the latest
# revision of their source, we always want to
# honour either HEAD or the specified PRODUCT_REVISION for compiling the
# final binaries, as this revision is the one picked by a human to form
# the release, and may be baked into the binaries produced.
ifeq ($(PRODUCT_REVISION),)
# If PRODUCT_REVISION is empty (the default) we are concerned with building the
# current work tree, regardless of whether it is dirty or not. For local builds
# this is more convenient and more likely expected behaviour than having to commit
# just to perform a new build.
#
# Determine the PACKAGE_SOURCE_ID.
#
# Dirty package builds should never be cached because their PACKAGE_SOURCE_ID
# is not unique to the code, it just reflects the last commit ID in the git log
# prefixed with dirty_.
GIT_REF := HEAD
ALLOW_DIRTY ?= YES
PRODUCT_REVISION_NICE_NAME := <current-workdir>
DIRTY := $(shell cd $(REPO_ROOT); git diff --exit-code $(GIT_REF) -- $(ALWAYS_EXCLUDE_SOURCE_GIT) > /dev/null 2>&1 || echo "dirty_")
# Note we used to suffix the GIT_REF with '^{}' in order to traverse tags down
# to individual commits, in case the GIT_REF is an annotated tag. However this
# makes build output confusing in case a tag ref is used rather than a commit ref.
# Therefore we now allow building tag refs, even though this means sometimes we might
# be building the same source with two different source IDs, and potentially wasting
# some potential cache hits. The tradeoff in terms of ease of use seems worth it for
# now, but this could be revisited later.
# The original of the line below was:
# 
#   PACKAGE_SOURCE_ID := $(DIRTY)$(shell git rev-parse --verify '$(GIT_REF)^{commit}')
#
PACKAGE_SOURCE_ID := $(DIRTY)$(shell git rev-parse --verify '$(GIT_REF)')

else

# PRODUCT_REVISION is non-empty so treat it as a git commit ref and pull files
# directly from git rather than the work tree.
GIT_REF := $(PRODUCT_REVISION)
ALLOW_DIRTY := NO
PRODUCT_REVISION_NICE_NAME := $(PRODUCT_REVISION)
PACKAGE_SOURCE_ID := $(shell if COMMIT=$$(git rev-parse --verify '$(PRODUCT_REVISION)^{commit}'); then echo $$COMMIT; else echo FAILED; fi)

ifeq ($(PACKAGE_SOURCE_ID),FAILED)
$(error Unable to find git ref "$(PRODUCT_REVISION)", do you need to 'git fetch' it?)
endif

endif
endif

export PRODUCT_REVISION GIT_REF ALLOW_DIRTY PACKAGE_SOURCE_ID

# REQ_TOOLS detects availability of a set of tools, and optionally auto-installs them.
define REQ_TOOLS
GROUP_NAME := $(1)
INSTALL_TOOL := $(2)
INSTALL_COMMAND := $(3)
TOOLS := $(4)
TOOL_INSTALL_LOG := $(REPO_ROOT)/$(CACHE_ROOT)/tool-install-$$(GROUP_NAME).log
_ := $$(shell mkdir -p $$(dir $$(TOOL_INSTALL_LOG)))
INSTALL_TOOL_AVAILABLE := $$(shell command -v $$(INSTALL_TOOL) > /dev/null 2>&1 && echo YES)
ATTEMPT_AUTO_INSTALL := NO
ifeq ($$(INSTALL_TOOL_AVAILABLE),YES)
ifeq ($$(AUTO_INSTALL_TOOLS),YES)
ATTEMPT_AUTO_INSTALL := YES
endif
endif
MISSING_PACKAGES := $$(shell \
	for T in $$(TOOLS); do \
		BIN=$$$$(echo $$$$T | cut -d':' -f1); \
	if ! command -v $$$$BIN > /dev/null 2>&1; then \
		echo $$$$T | cut -d':' -f2; \
	fi; \
	done | sort | uniq)
ifneq ($$(MISSING_PACKAGES),)
ifneq ($$(ATTEMPT_AUTO_INSTALL),YES)
$$(error You are missing required tools, please run '$$(INSTALL_COMMAND) $$(MISSING_PACKAGES)'.)
else
RESULT := $$(shell $$(INSTALL_COMMAND) $$(MISSING_PACKAGES) && echo OK > $$(TOOL_INSTALL_LOG))
ifneq ($$(shell cat $$(TOOL_INSTALL_LOG)),OK)
$$(info Failed to auto-install packages with command $$(INSTALL_COMMAND) $$(MISSING_PACKAGES))
$$(error $$(shell cat $$(TOOL_INSTALL_LOG)))
else
$$(info $$(TOOL_INSTALL_LOG))
$$(info Installed $$(GROUP_NAME) tools successfully.)
endif
endif
endif
endef

ifeq ($(shell uname),Darwin)
# On Mac, try to install things with homebrew.
BREW_TOOLS := gln:coreutils gtouch:coreutils gstat:coreutils \
	gtar:gnu-tar gfind:findutils jq:jq yq:python-yq
$(eval $(call REQ_TOOLS,brew,brew,brew install,$(BREW_TOOLS)))
else
# If not mac, try to install using apt.
APT_TOOLS := pip3:python3-pip jq:jq column:bsdmainutils
$(eval $(call REQ_TOOLS,apt,apt-get,sudo apt-get update && sudo apt-get install -y,$(APT_TOOLS)))
PIP_TOOLS := yq:yq
$(eval $(call REQ_TOOLS,pip,pip3,pip3 install,$(PIP_TOOLS)))

endif

# We rely on GNU touch, tar and ln.
# On macOS, we assume they are installed as gtouch, gtar, gln by homebrew.
ifeq ($(shell uname),Darwin)
TOUCH := gtouch
TAR := gtar
LN := gln
STAT := gstat
FIND := gfind
else
TOUCH := touch
TAR := tar
LN := ln
STAT := stat
FIND := find
endif

# Read config from the spec.

# PRODUCT_REPO is the official Git repo for this project.
PRODUCT_REPO := $(shell $(call QUERY_SPEC,.config["product-repo"]))

# PRODUCT_REPO_LOCAL is the local clone of this git repo.
PRODUCT_REPO_LOCAL := $(REPO_ROOT)

# PRODUCT_PATH must be unique for every repo.
# A golang-style package path is ideal.
PRODUCT_PATH := $(shell $(call QUERY_SPEC,.config["product-id"]))

# PRODUCT_CIRCLECI_SLUG is the slug of this repo's CircleCI project.
PRODUCT_CIRCLECI_SLUG := $(shell $(call QUERY_SPEC,.config["circleci-project-slug"]))

# PRODUCT_CIRCLECI_HOST is the host configured to build this repo.
PRODUCT_CIRCLECI_HOST := $(shell $(call QUERY_SPEC,.config["circleci-host"]))

# End including config once only.
endif
