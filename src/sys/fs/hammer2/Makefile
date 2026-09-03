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
hammer2-y += hammer2_inode.o
hammer2-y += hammer2_vfsops.o

# ../.. is src/sys, which holds the vendored <sys/tree.h> and <sys/queue.h>.
ccflags-y += -I$(src)/../..

# Carried files only, never hammer2_io.c, which is ours. This is the same
# split script/test-syntax.sh makes and for the same reason: a warning about
# DragonFly's own text is not a defect this port may fix in place.
#
# -Wno-implicit-fallthrough: kbuild compiles with -Wimplicit-fallthrough=5,
# which accepts only the `fallthrough` attribute. Upstream marks its switch
# fallthroughs with a /* fall through */ comment, which level 5 does not read.
# Five sites in hammer2_chain.c.
# -Wno-unused-function: kbuild passes -Wunused. Two statics in hammer2_inode.c
# are carried ahead of the write path that calls them.
#
# DEFER(the tree is prepared for submission): both become edits to the carried
# text rather than suppressions, in the single conversion that also settles
# BSD style. Converting either one early splits the core into two dialects,
# which is the outcome doc/README.kernel-style.md exists to prevent.
CARRIED_CFLAGS := -Wno-implicit-fallthrough -Wno-unused-function
$(foreach o,$(filter-out hammer2_io.o,$(hammer2-y)),\
	$(eval CFLAGS_$(o) += $(CARRIED_CFLAGS)))

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
