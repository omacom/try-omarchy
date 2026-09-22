# Standard two-phase kbuild Makefile. Kbuild sets KERNELRELEASE and takes the
# first branch; DKMS also passes KERNELRELEASE on its make command line, so it
# drives kbuild directly (see MAKE[0] in dkms.conf) rather than through the
# targets below. Those targets serve manual builds, where KVER selects the
# kernel so the build never depends on the builder's running kernel.
ifneq ($(KERNELRELEASE),)
obj-m := try_omarchy_battery.o
try_omarchy_battery-y := try-omarchy-battery.o
else
KVER ?= $(shell uname -r)
KDIR ?= /usr/lib/modules/$(KVER)/build

.PHONY: modules clean

modules:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean
endif
