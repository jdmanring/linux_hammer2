KDIR ?= /lib/modules/$(shell uname -r)/build

obj-m += hammer2.o

# One object per line, not a continuation: script/test-inventory.sh reads
# this file a line at a time, so a wrapped list hides every object after
# the first from the check that each .c is compiled into the module.
hammer2-y += hammer2_io.o
hammer2-y += hammer2_admin.o
hammer2-y += hammer2_freemap.o
hammer2-y += hammer2_xops.o
hammer2-y += hammer2_bulkfree.o
hammer2-y += hammer2_chain.o
hammer2-y += hammer2_flush.o
hammer2-y += hammer2_cluster.o
hammer2-y += hammer2_subr.o
hammer2-y += hammer2_ondisk.o

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
