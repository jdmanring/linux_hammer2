/* NEGATIVE CONTROL for test-hammer2-io.sh: included AFTER pagemap.h so the
 * header's own declaration stands and the call site gets a wrong arity. A
 * -D on the command line renames the declaration too and proves nothing. */
#include <linux/pagemap.h>
#undef __filemap_get_folio
#define __filemap_get_folio(m, i, f, g) __filemap_get_folio((m), (i), (f), (g), 0)
