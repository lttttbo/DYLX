# SPDX-License-Identifier: Apache-2.0
#
# Aggregate OP-TEE build makefile.
# Place this file under op-tee/ beside:
#   build/  optee_os/  optee_client/  optee_test/
#
# Can be used in two ways:
#   1) Included by the original product build system.
#   2) Standalone: make -f optee.mk optee

# Build width. Keep defaults compatible with your original file, but allow override.
COMPILE_NS_USER   ?= 64
COMPILE_NS_KERNEL ?= 64
COMPILE_S_USER    ?= 64
COMPILE_S_KERNEL  ?= 64
ARCH              ?= arm

# Path adaptation: derive OP-TEE root from the physical location of this mk file.
# This fixes the case where TOPDIR no longer points to the old op-tee location.
OPTEE_MK_FILE := $(lastword $(MAKEFILE_LIST))
OPTEE_MK_DIR  := $(patsubst %/,%,$(abspath $(dir $(OPTEE_MK_FILE))))
TOPDIR        ?= $(abspath $(OPTEE_MK_DIR)/..)
TEE_SRC       ?= $(OPTEE_MK_DIR)
ROOT          ?= $(TOPDIR)

# Source directories. Override only if your names differ.
OPTEE_OS_SRC     ?= $(TEE_SRC)/optee_os
OPTEE_CLIENT_SRC ?= $(TEE_SRC)/optee_client
OPTEE_TEST_SRC   ?= $(TEE_SRC)/optee_test
OPTEE_BUILD_DIR  ?= $(TEE_SRC)/build

# Variables used by OP-TEE build.git common files if you decide to include them elsewhere.
OPTEE_OS_PATH     ?= $(OPTEE_OS_SRC)
OPTEE_CLIENT_PATH ?= $(OPTEE_CLIENT_SRC)
OPTEE_TEST_PATH   ?= $(OPTEE_TEST_SRC)

# Platform. Override on command line or in build script, for example OPTEE_PLATFORM=my-board.
OPTEE_PLATFORM    ?= zx-evb
OPTEE_OS_PLATFORM ?= $(OPTEE_PLATFORM)

# Standalone defaults. Product build systems usually define these already.
TARGET_OUT               ?= $(TOPDIR)/out/target
TARGET_OUT_INTERMEDIATES ?= $(TOPDIR)/out/intermediates
DEBUG_IMAGE_OUT          ?= $(TOPDIR)/out/images
DEVICE_PREBUILT_BOOT_IMAGES_DIR ?= $(TOPDIR)/prebuilts
ALGO ?=
DEBUG ?= 0

# Prefer out-of-tree build for the migrated layout. Set false to use optee_*/out in source tree.
ENABLE_OPTEE_OOT_BUILD ?= true

# Cross compiler prefixes. You may provide AARCH64_CROSS_COMPILE/AARCH32_CROSS_COMPILE,
# or legacy CROSS_COMPILE64/CROSS_COMPILE32.
AARCH32_CROSS_COMPILE ?= $(if $(CROSS_COMPILE32),$(CROSS_COMPILE32),arm-linux-gnueabihf-)
AARCH64_CROSS_COMPILE ?= $(if $(CROSS_COMPILE64),$(CROSS_COMPILE64),aarch64-linux-gnu-)
CCACHE ?=

# Keep quotes: this supports values such as CCACHE="ccache ".
CROSS_COMPILE_NS_USER   ?= "$(CCACHE)$(AARCH$(COMPILE_NS_USER)_CROSS_COMPILE)"
CROSS_COMPILE_NS_KERNEL ?= "$(CCACHE)$(AARCH$(COMPILE_NS_KERNEL)_CROSS_COMPILE)"
CROSS_COMPILE_S_USER    ?= "$(CCACHE)$(AARCH$(COMPILE_S_USER)_CROSS_COMPILE)"
CROSS_COMPILE_S_KERNEL  ?= "$(CCACHE)$(AARCH$(COMPILE_S_KERNEL)_CROSS_COMPILE)"

HAS_TEE_SOURCE := $(if $(wildcard $(OPTEE_OS_SRC)/Makefile),yes,no)

ifeq ($(HAS_TEE_SOURCE),yes)

ifeq ($(ENABLE_OPTEE_OOT_BUILD),true)
TARGET_OUT_OPTEE ?= $(TARGET_OUT_INTERMEDIATES)/OPTEE
else
TARGET_OUT_OPTEE ?= $(TEE_SRC)
endif

# Base output directory for OP-TEE components.
TARGET_OUT_OPTEE_OS     ?= $(TARGET_OUT_OPTEE)/optee_os/out/arm
TARGET_OUT_OPTEE_CLIENT ?= $(TARGET_OUT_OPTEE)/optee_client/out
TARGET_OUT_OPTEE_TEST   ?= $(TARGET_OUT_OPTEE)/optee_test/out

# TA devkit/export paths.
OPTEE_TA_TARGET := $(if $(filter 64,$(COMPILE_S_USER)),ta_arm64,ta_arm32)
OPTEE_OS_TA_DEV_KIT_DIR ?= $(TARGET_OUT_OPTEE_OS)/export-$(OPTEE_TA_TARGET)
OPTEE_CLIENT_EXPORT     ?= $(TARGET_OUT_OPTEE_CLIENT)/export/usr
TEEC_EXPORT             ?= $(OPTEE_CLIENT_EXPORT)

# Output binaries / artifacts.
TEE_OS_BIN         ?= $(TARGET_OUT_OPTEE_OS)/core/tee-pager_v2.bin
LIBTEEC_OUT        ?= $(TARGET_OUT_OPTEE_CLIENT)/libteec/libteec.*
TEE_SUPPLICANT_OUT ?= $(TARGET_OUT_OPTEE_CLIENT)/tee-supplicant/tee-supplicant
PLUGIN_OUT         ?= $(TARGET_OUT_OPTEE_TEST)/supp_plugin/*.plugin
TA_OUT             ?= $(TARGET_OUT_OPTEE_TEST)/ta/*/*.ta
CA_OUT             ?= $(TARGET_OUT_OPTEE_TEST)/test_ca/test_ca
XTEST_OUT          ?= $(TARGET_OUT_OPTEE_TEST)/xtest/xtest
ALGO_OUT           ?= $(TARGET_OUT_OPTEE_TEST)/test_algo/test_algo

# Distribution directories.
TEE_BIN_DIST    ?= $(TARGET_OUT)/bin
TEE_LIB_DIST    ?= $(TARGET_OUT)/lib
TEE_TA_DIST     ?= $(TARGET_OUT)/lib/optee_armtz
TEE_PLUGIN_DIST ?= $(TARGET_OUT)/lib/optee_armtz/plugins

ifeq ($(COMPILE_S_KERNEL),64)
OPTEE_CORE_WIDTH_FLAGS := CFG_ARM64_core=y
else
OPTEE_CORE_WIDTH_FLAGS := CFG_ARM64_core=n
endif

OPTEE_OOT_OS_FLAG     := $(if $(filter true,$(ENABLE_OPTEE_OOT_BUILD)),O=$(TARGET_OUT_OPTEE_OS),)
OPTEE_OOT_CLIENT_FLAG := $(if $(filter true,$(ENABLE_OPTEE_OOT_BUILD)),O=$(TARGET_OUT_OPTEE_CLIENT),)
OPTEE_OOT_TEST_FLAG   := $(if $(filter true,$(ENABLE_OPTEE_OOT_BUILD)),O=$(TARGET_OUT_OPTEE_TEST),)

# Build flags. These intentionally do not depend on build/common.mk because the migrated tree
# only needs the three component Makefiles and explicit paths.
OPTEE_OS_COMMON_FLAGS ?= \
	$(OPTEE_OOT_OS_FLAG) \
	PLATFORM=$(OPTEE_PLATFORM) \
	$(OPTEE_CORE_WIDTH_FLAGS) \
	CFG_USER_TA_TARGETS=$(OPTEE_TA_TARGET) \
	CROSS_COMPILE=$(CROSS_COMPILE_S_USER) \
	CROSS_COMPILE_core=$(CROSS_COMPILE_S_KERNEL) \
	CROSS_COMPILE_ta_arm64="$(CCACHE)$(AARCH64_CROSS_COMPILE)" \
	CROSS_COMPILE_ta_arm32="$(CCACHE)$(AARCH32_CROSS_COMPILE)" \
	DEBUG=$(DEBUG)

OPTEE_CLIENT_COMMON_FLAGS ?= \
	$(OPTEE_OOT_CLIENT_FLAG) \
	CROSS_COMPILE=$(CROSS_COMPILE_NS_USER)

XTEST_COMMON_FLAGS ?= \
	$(OPTEE_OOT_TEST_FLAG) \
	TA_DEV_KIT_DIR=$(OPTEE_OS_TA_DEV_KIT_DIR) \
	OPTEE_CLIENT_EXPORT=$(OPTEE_CLIENT_EXPORT) \
	TEEC_EXPORT=$(TEEC_EXPORT) \
	CROSS_COMPILE_HOST=$(CROSS_COMPILE_NS_USER) \
	CROSS_COMPILE_TA=$(CROSS_COMPILE_S_USER) \
	CROSS_COMPILE_ta_arm64="$(CCACHE)$(AARCH64_CROSS_COMPILE)" \
	CROSS_COMPILE_ta_arm32="$(CCACHE)$(AARCH32_CROSS_COMPILE)"

.PHONY: FORCE
FORCE:

$(TEE_OS_BIN): FORCE
	@echo "OP-TEE root:       $(TEE_SRC)"
	@echo "OP-TEE platform:   $(OPTEE_PLATFORM)"
	@echo "OP-TEE OOT build:  $(ENABLE_OPTEE_OOT_BUILD)"
	@echo "Building OP-TEE OS..."
	$(MAKE) -C "$(OPTEE_OS_SRC)" $(blverbose) $(OPTEE_OS_COMMON_FLAGS)
	@echo "Building OP-TEE Client..."
	$(MAKE) -C "$(OPTEE_CLIENT_SRC)" $(blverbose) $(OPTEE_CLIENT_COMMON_FLAGS)
	@echo "Building OP-TEE Tests (xtest, TAs, plugins)..."
	$(MAKE) -C "$(OPTEE_TEST_SRC)" $(blverbose) $(XTEST_COMMON_FLAGS)
	@echo "Installing OP-TEE artifacts into $(TARGET_OUT)..."
	@mkdir -p "$(TEE_BIN_DIST)" "$(TEE_LIB_DIST)" "$(TEE_TA_DIST)" "$(TEE_PLUGIN_DIST)"
	@set -e; \
	for f in "$(TEE_SUPPLICANT_OUT)" "$(XTEST_OUT)"; do \
		if [ ! -e "$$f" ]; then echo "ERROR: missing required artifact $$f"; exit 1; fi; \
		cp -f "$$f" "$(TEE_BIN_DIST)/"; \
	done
	@for f in "$(CA_OUT)" "$(ALGO_OUT)"; do \
		if [ -e "$$f" ]; then cp -f "$$f" "$(TEE_BIN_DIST)/"; else echo "WARN: optional artifact not found: $$f"; fi; \
	done
	@set -e; found=0; \
	for f in $(LIBTEEC_OUT); do \
		if [ -e "$$f" ]; then cp -f "$$f" "$(TEE_LIB_DIST)/"; found=1; fi; \
	done; \
	if [ "$$found" -eq 0 ]; then echo "ERROR: no libteec artifacts matched $(LIBTEEC_OUT)"; exit 1; fi
	@set -e; found=0; \
	for f in $(TA_OUT); do \
		if [ -e "$$f" ]; then cp -f "$$f" "$(TEE_TA_DIST)/"; found=1; fi; \
	done; \
	if [ "$$found" -eq 0 ]; then echo "ERROR: no TA artifacts matched $(TA_OUT)"; exit 1; fi
	@for f in $(PLUGIN_OUT); do \
		if [ -e "$$f" ]; then cp -f "$$f" "$(TEE_PLUGIN_DIST)/"; else echo "WARN: optional plugin not found: $$f"; fi; \
	done

.PHONY: clean-optee
clean-optee:
	-$(MAKE) -C "$(OPTEE_TEST_SRC)" $(blverbose) $(XTEST_COMMON_FLAGS) clean
	-$(MAKE) -C "$(OPTEE_CLIENT_SRC)" $(blverbose) $(OPTEE_CLIENT_COMMON_FLAGS) clean
	-$(MAKE) -C "$(OPTEE_OS_SRC)" $(blverbose) $(OPTEE_OS_COMMON_FLAGS) clean

.PHONY: print-optee-vars
print-optee-vars:
	@echo "TEE_SRC=$(TEE_SRC)"
	@echo "OPTEE_OS_SRC=$(OPTEE_OS_SRC)"
	@echo "OPTEE_CLIENT_SRC=$(OPTEE_CLIENT_SRC)"
	@echo "OPTEE_TEST_SRC=$(OPTEE_TEST_SRC)"
	@echo "OPTEE_PLATFORM=$(OPTEE_PLATFORM)"
	@echo "ENABLE_OPTEE_OOT_BUILD=$(ENABLE_OPTEE_OOT_BUILD)"
	@echo "TARGET_OUT_OPTEE_OS=$(TARGET_OUT_OPTEE_OS)"
	@echo "TARGET_OUT_OPTEE_CLIENT=$(TARGET_OUT_OPTEE_CLIENT)"
	@echo "TARGET_OUT_OPTEE_TEST=$(TARGET_OUT_OPTEE_TEST)"
	@echo "OPTEE_OS_TA_DEV_KIT_DIR=$(OPTEE_OS_TA_DEV_KIT_DIR)"
	@echo "OPTEE_CLIENT_EXPORT=$(OPTEE_CLIENT_EXPORT)"
	@echo "AARCH64_CROSS_COMPILE=$(AARCH64_CROSS_COMPILE)"
	@echo "AARCH32_CROSS_COMPILE=$(AARCH32_CROSS_COMPILE)"
	@echo "CROSS_COMPILE_NS_USER=$(CROSS_COMPILE_NS_USER)"
	@echo "CROSS_COMPILE_S_USER=$(CROSS_COMPILE_S_USER)"
	@echo "TEE_OS_BIN=$(TEE_OS_BIN)"

else

# No source tree: use prebuilt OP-TEE pager binary.
TEE_OS_BIN ?= $(DEVICE_PREBUILT_BOOT_IMAGES_DIR)/tee-pager_v2.bin

.PHONY: clean-optee print-optee-vars
clean-optee:
	@echo "No OP-TEE source under $(TEE_SRC); nothing to clean."
print-optee-vars:
	@echo "No OP-TEE source under $(TEE_SRC)"
	@echo "TEE_OS_BIN=$(TEE_OS_BIN)"

endif

# Fallback helpers for standalone builds. A product build can provide real versions.
ifeq ($(origin copy_if_exists),undefined)
define copy_if_exists
@mkdir -p "$(dir $(2))"; \
if [ -e "$(1)" ]; then cp -f "$(1)" "$(2)"; else echo "ERROR: missing $(1)"; exit 1; fi
endef
endif

ifeq ($(origin sign_file),undefined)
define sign_file
@echo "WARN: sign_file macro is not defined by the product build; copying unsigned image only."; \
mkdir -p "$(DEBUG_IMAGE_OUT)"; \
cp -f "$(DEBUG_IMAGE_OUT)/$(1)" "$(DEBUG_IMAGE_OUT)/$(2)"
endef
endif

.PHONY: sign_tools
sign_tools:
	@:

.PHONY: optee
optee: $(TEE_OS_BIN) sign_tools
	@echo "Signing/copying tee image..."
	$(call copy_if_exists,$(TEE_OS_BIN),$(DEBUG_IMAGE_OUT)/tee-pager_v2.bin)
	$(call sign_file,tee-pager_v2.bin,tee.img,tee,$(ALGO))
	@echo "Done. tee-pager_v2.bin: $(DEBUG_IMAGE_OUT)/tee-pager_v2.bin"
	@echo "Done. tee.img:          $(DEBUG_IMAGE_OUT)/tee.img"

.PHONY: clean
clean: clean-optee
