# DEBOS_OPTS can be overridden with:
#     make DEBOS_OPTS=... all
# USE_CONTAINER can be set to yes/no/auto (default: auto)
#     make USE_CONTAINER=yes all    # Force container use
#     make USE_CONTAINER=no all     # Force native debos
# BOARD selects a product profile under boards/ (optional):
#     make BOARD=axon-mini rootfs.tar
#     make BOARD=axon-mini disk-ufs.img
#
# IPv6-only hosts (no IPv4 default route):
#   1) rootfs (no fakemachine, host IPv6):
#        make DOCKER_OPTS="--network host" DISABLE_FAKEMACHINE=yes FORCE_APT_IPV6=yes BOARD=axon-mini rootfs.tar
#   2) disk image (needs KVM fakemachine + host HTTP proxy on :8888 for apt):
#        http_proxy=http://10.0.2.2:8888 make DOCKER_OPTS="--network host" BOARD=axon-mini disk-sdcard.img
#   Avoid sudo make. Use groups docker+kvm (sg docker / sg kvm, or re-login).

# To build large images, the debos resource defaults are not sufficient. These
# provide defaults that work for us as universally as we can manage.
FAKEMACHINE_BACKEND = $(shell [ -c /dev/kvm ] && echo kvm || echo qemu)

# DISABLE_FAKEMACHINE=yes runs mmdebstrap on the host/container network
# (needed for IPv6-only uplinks; fakemachine SLIRP is IPv4-only).
DISABLE_FAKEMACHINE ?= no
ifeq ($(DISABLE_FAKEMACHINE),yes)
FAKEMACHINE_OPTS ?= --disable-fakemachine
else
FAKEMACHINE_OPTS ?= --fakemachine-backend $(FAKEMACHINE_BACKEND)
endif

BOARD ?=
BOARD_CONFIG := scripts/board-config.py
ifeq ($(BOARD),)
BOARD_DEBOS_OPTS :=
else
BOARD_DEBOS_OPTS := $(shell python3 $(BOARD_CONFIG) debos-opts $(BOARD))
endif

# Force apt to use IPv6 (host curl -6 must work). Path is as seen by debos.
FORCE_APT_IPV6 ?= no

EXTRA_DEBOS_OPTS ?=
# When http_proxy is set in the environment, pass it into debos/fakemachine.
# Useful on IPv6-only hosts with a host-side proxy (e.g. http://10.0.2.2:8888).
ifeq ($(http_proxy),)
else
EXTRA_DEBOS_OPTS += -e http_proxy:$(http_proxy) -e https_proxy:$(http_proxy) -e HTTP_PROXY:$(http_proxy) -e HTTPS_PROXY:$(http_proxy)
endif
DEBOS_OPTS := $(FAKEMACHINE_OPTS) --memory 1GiB --scratchsize 6GiB $(BOARD_DEBOS_OPTS) $(EXTRA_DEBOS_OPTS)

# Manual sync path when not using BOARD= (legacy / ad-hoc local debs)
LOCAL_DEB_SRC ?= $(CURDIR)/../deb-packages/axon-mini-qcs6490-deb-packages
LOCAL_DEB_DST := debos-recipes/local-debs

# Container support: auto-detect if debos is available, otherwise use container
USE_CONTAINER ?= auto
CONTAINER_IMAGE ?= ghcr.io/go-debos/debos:latest

ifeq ($(USE_CONTAINER),auto)
	ifdef GITHUB_ACTIONS
		# Disable container in GitHub Actions
		USE_CONTAINER := no
	else
		# Local development: enable container if debos not installed
		USE_CONTAINER := $(shell command -v debos >/dev/null 2>&1 && echo no || echo yes)
	endif
endif

ifeq ($(USE_CONTAINER),yes)
	# Only pass --device /dev/kvm if KVM is available on the host
	KVM_DEVICE := $(if $(wildcard /dev/kvm),--device /dev/kvm)
	# Working directory as seen from inside the container
	DEBOS_WORKDIR := /recipes
	# On IPv6-only / broken Docker DNS hosts, use e.g.:
	#   make DOCKER_OPTS="--network host" BOARD=axon-mini rootfs.tar
	DOCKER_OPTS ?=
	# --disable-fakemachine needs root + privileges inside the container
	ifeq ($(DISABLE_FAKEMACHINE),yes)
	DOCKER_PRIVILEGED := --privileged
	DOCKER_USER := 0
	else
	DOCKER_PRIVILEGED :=
	DOCKER_USER := $(shell id -u)
	endif
	ifeq ($(FORCE_APT_IPV6),yes)
	DEBOS_OPTS += -e APT_CONFIG:$(DEBOS_WORKDIR)/apt-force-ipv6.conf
	endif
	DEBOS_CMD := docker run --rm --interactive --tty \
		$(KVM_DEVICE) \
		$(DOCKER_PRIVILEGED) \
		$(DOCKER_OPTS) \
		--user $(DOCKER_USER) --workdir $(DEBOS_WORKDIR) \
		--mount "type=bind,source=$(CURDIR),destination=$(DEBOS_WORKDIR)" \
		--security-opt label=disable \
		$(CONTAINER_IMAGE) \
		$(DEBOS_OPTS)
else
	# Working directory for native debos
	DEBOS_WORKDIR := $(CURDIR)
	ifeq ($(FORCE_APT_IPV6),yes)
	DEBOS_OPTS += -e APT_CONFIG:$(DEBOS_WORKDIR)/apt-force-ipv6.conf
	endif
	DEBOS_CMD := debos $(DEBOS_OPTS)
endif

# Use http_proxy from the environment, or apt's http_proxy if set, to speed up
# builds.
http_proxy ?= $(shell apt-config dump --format '%v%n' Acquire::http::Proxy)
export http_proxy

.PHONY: all
all: disk-ufs.img disk-sdcard.img

# Generate board overlay snippets and sync local debs from boards/<BOARD>.yaml
.PHONY: prepare-board
prepare-board:
	@test -n "$(BOARD)" || (echo "BOARD= is required (e.g. make BOARD=axon-mini prepare-board)"; exit 1)
	python3 $(BOARD_CONFIG) prepare $(BOARD)

# Copy/refresh .debs into debos-recipes/local-debs/ (BOARD= preferred)
.PHONY: sync-local-debs
sync-local-debs:
ifeq ($(BOARD),)
	@test -d "$(LOCAL_DEB_SRC)" || (echo "Missing LOCAL_DEB_SRC=$(LOCAL_DEB_SRC)"; exit 1)
	@mkdir -p "$(LOCAL_DEB_DST)"
	cp -a "$(LOCAL_DEB_SRC)"/*.deb "$(LOCAL_DEB_DST)"/
	@n=$$(ls "$(LOCAL_DEB_DST)"/linux-image-*.deb 2>/dev/null | wc -l); \
	  if [ "$$n" -ne 1 ]; then \
	    echo "ERROR: expected exactly one linux-image-*.deb in $(LOCAL_DEB_DST), found $$n"; \
	    ls -1 "$(LOCAL_DEB_DST)"/linux-image-*.deb 2>/dev/null || true; \
	    exit 1; \
	  fi
	@echo "Synced local debs into $(LOCAL_DEB_DST):"
	@ls -1 "$(LOCAL_DEB_DST)"/*.deb
else
	$(MAKE) prepare-board BOARD=$(BOARD)
endif

ifeq ($(BOARD),)
ROOTFS_PREREQS :=
else
ROOTFS_PREREQS := prepare-board
endif

rootfs.tar dtbs.tar.gz: debos-recipes/qualcomm-linux-debian-rootfs.yaml $(ROOTFS_PREREQS)
	$(DEBOS_CMD) $<

DISK_UFS_IMAGES := disk-ufs.img \
	disk-ufs.img1 \
	disk-ufs.img2

$(DISK_UFS_IMAGES): debos-recipes/qualcomm-linux-debian-image.yaml rootfs.tar
	$(DEBOS_CMD) $<

DISK_SDCARD_IMAGES := disk-sdcard.img \
	disk-sdcard.img1 \
	disk-sdcard.img2

$(DISK_SDCARD_IMAGES): debos-recipes/qualcomm-linux-debian-image.yaml rootfs.tar
	$(DEBOS_CMD) -t imagetype:sdcard $<

.PHONY: flash
flash: debos-recipes/qualcomm-linux-debian-flash.yaml dtbs.tar.gz
	$(DEBOS_CMD) $<

.PHONY: test
test: disk-ufs.img
	# rootfs/ is a build artifact, so should not be scanned for tests
	py.test-3 --ignore=rootfs

.PHONY: clean
clean:
	rm -f $(DISK_UFS_IMAGES)
	rm -f $(DISK_SDCARD_IMAGES)
	rm -f rootfs.tar
	rm -f dtbs.tar.gz
	rm -f dtb-multidtb.bin
	rm -f dtb-combineddtb.bin
	rm -rf debos-recipes/overlays/generated

.PHONY: clean-debos
clean-debos:
	rm -rf .debos-*
