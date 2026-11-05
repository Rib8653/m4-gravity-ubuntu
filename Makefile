# Gravity Linux (M4 Mac mini) on Ubuntu 26.04 LTS
#
#   make sources      fetch every pinned input
#   make kernel       Gravity kernel -> linux-image/linux-headers .debs
#   make bootloader   m1n1 (stage 1 + stage 2) -> gravity-bootloader .deb
#   make uboot        U-Boot apple_m1 + Gravity patches -> u-boot-gravity-apple .deb
#   make mesa         Gravity Mesa with Ubuntu's packaging (arm64 only)
#   make platform     Ubuntu glue packages (initramfs, update-m1n1, firmware, ...)
#   make debs         all of the above
#   make image        FLAVOR=ubuntu|kubuntu|server root filesystem + partition images (root)
#   make installer    FLAVORS="ubuntu ..." BASE_URL=... zip + installer_data.json
#   make check        lint and unit tests (no build)

FLAVOR ?= ubuntu
FLAVORS ?= $(FLAVOR)
export FLAVOR FLAVORS

.PHONY: all sources kernel kernel-config bootloader uboot mesa platform debs image installer check clean distclean

all: debs image installer

sources:
	scripts/fetch-sources.sh all

kernel:
	scripts/build-kernel.sh

kernel-config:
	KERNEL_CONFIG_ONLY=1 scripts/build-kernel.sh

bootloader:
	scripts/build-bootloader.sh

uboot:
	scripts/build-uboot.sh

mesa:
	scripts/build-mesa.sh

platform:
	scripts/build-platform.sh

debs: kernel bootloader uboot mesa platform

image:
	scripts/build-image.sh

installer:
	scripts/package-installer.sh

check:
	tests/run.sh

clean:
	rm -rf work/build work/image-*

distclean:
	rm -rf work out
