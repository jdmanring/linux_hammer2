SUBDIRS = src
KDIR ?= /lib/modules/$(shell uname -r)/build

.PHONY: all clean $(SUBDIRS) compile_commands.json

all: $(SUBDIRS)
$(SUBDIRS):
	$(MAKE) -C $@
clean:
	for dir in $(SUBDIRS); do \
		$(MAKE) -C $$dir $@; \
	done
install:
	sudo bash -x ./script/install.sh
uninstall:
	sudo bash -x ./script/uninstall.sh

# A semantic index answers only about the files in this database, so a source
# file added to the module and not to it is invisible rather than reported
# missing, and a stale database under-reports a symbol's callers silently.
# This is phony because the file existing is what makes it stale. The kernel
# of record's own generator reads the .cmd files kbuild leaves, so it needs a
# build to have happened first.
compile_commands.json:
	python3 $(KDIR)/scripts/clang-tools/gen_compile_commands.py \
		-d src/sys/fs/hammer2 -o $@
