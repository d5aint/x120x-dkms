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

# Run the whole unprivileged shell test suite.
test:
	@for t in tests/*.sh; do echo "== $$t =="; bash "$$t" || exit 1; done

.PHONY: all clean install test
