# Makefile for x120x kernel module
#
# Out-of-tree build (development):
#   make
#   sudo insmod src/x120x.ko
#
# DKMS handles production builds automatically.

KVER    ?= $(shell uname -r)
KDIR    ?= /lib/modules/$(KVER)/build
PWD     := $(shell pwd)

all:
	$(MAKE) -C $(KDIR) M=$(PWD)/src modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD)/src clean

install:
	$(MAKE) -C $(KDIR) M=$(PWD)/src modules_install
	depmod -A

# Run the whole unprivileged suite: the shell unit tests plus the
# doc/consistency checks CI enforces, so a CI-only failure can't slip
# past a local `make test`.
test:
	@for t in tests/*.sh; do echo "== $$t =="; bash "$$t" || exit 1; done
	@echo "== tools/check-versions.sh ==";    bash tools/check-versions.sh
	@echo "== tools/check-links.sh ==";       bash tools/check-links.sh
	@echo "== tools/check-layout-tree.sh =="; bash tools/check-layout-tree.sh

.PHONY: all clean install test
