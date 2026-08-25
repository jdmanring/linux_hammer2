KDIR ?= /lib/modules/$(shell uname -r)/build

obj-m += hammer2.o

hammer2-y = hammer2_io.o

# ../.. is src/sys, which holds the vendored <sys/tree.h> and <sys/queue.h>.
ccflags-y += -I$(src)/../..

ifdef HAMMER2_INVARIANTS
ccflags-y += -DHAMMER2_INVARIANTS
endif
ifdef HAMMER2_MALLOC
ccflags-y += -DHAMMER2_MALLOC
endif
ifdef HAMMER2_ATIME
ccflags-y += -DHAMMER2_ATIME
endif

.PHONY: all clean

all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules
clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean
