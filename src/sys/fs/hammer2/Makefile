KDIR ?= /lib/modules/$(shell uname -r)/build
# A kernel built with clang, which the tailored 7.3.0-rc1-saxum is, with
# thin LTO on top, refuses a module compiled by gcc: kbuild hands the
# module the kernel's own flags and gcc rejects four of them.  Read the
# answer from the tree's config rather than asking the caller to know it.
H2_LLVM := $(if $(filter y,$(shell sed -n 's/^CONFIG_CC_IS_CLANG=//p' $(KDIR)/.config 2>/dev/null)),LLVM=1,)

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
hammer2-y += hammer2_strategy.o
hammer2-y += hammer2_vnops.o

# ../.. is src/sys, which holds the vendored <sys/tree.h> and <sys/queue.h>.
ccflags-y += -I$(src)/../..

# Carried files only, never hammer2_io.c or hammer2_strategy.c, which are ours. This is the same
# split script/test-syntax.sh makes and for the same reason: a warning about
# DragonFly's own text is not a defect this port may fix in place.
#
# -Wno-implicit-fallthrough: kbuild compiles with -Wimplicit-fallthrough=5,
# which accepts only the `fallthrough` attribute. Upstream marks its switch
# fallthroughs with a /* fall through */ comment, which level 5 does not read.
# Five sites in hammer2_chain.c.
# -Wno-unused-function: kbuild passes -Wunused. hammer2_inode_lock_temp_release()
# and _restore() have no caller here and are not expected to gain one: their
# only caller in either upstream is hammer2_igetv(), which this port rewrote
# on iget5_locked(), where the dance they perform has nothing to race against.
# The reasoning is at that rewrite in hammer2_inode.c. They stay because
# deleting two functions from a carried file is a core edit.
#
# DEFER(the tree is prepared for submission): both become edits to the carried
# text rather than suppressions, in the single conversion that also settles
# BSD style. Converting either one early splits the core into two dialects,
# which is the outcome doc/README.kernel-style.md exists to prevent.
CARRIED_CFLAGS := -Wno-implicit-fallthrough -Wno-unused-function
$(foreach o,$(filter-out hammer2_io.o hammer2_strategy.o,$(hammer2-y)),\
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
# The negative control for the mount-time folio-size check: a module built
# with this must refuse every mount, naming the numbers.  Never install it.
ifdef HAMMER2_FOLIO_CONTROL
ccflags-y += -DHAMMER2_FOLIO_CONTROL
endif

.PHONY: all clean

all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) $(H2_LLVM) modules
clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) clean
