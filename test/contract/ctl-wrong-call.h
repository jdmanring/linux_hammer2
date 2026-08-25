/* NEGATIVE CONTROL for test-hammer2-io.sh: included AFTER pagemap.h so the
 * header's own declaration stands and the call site gets a wrong arity. A
 * -D on the command line renames the declaration too and proves nothing. */
#include <linux/pagemap.h>
#undef filemap_grab_folio
#define filemap_grab_folio(m, i) filemap_grab_folio((m), (i), 0)
