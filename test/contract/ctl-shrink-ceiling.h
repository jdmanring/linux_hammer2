/* POSITIVE CONTROL for the ceiling guard: blkdev.h defines
 * BLK_MAX_BLOCK_SIZE unconditionally inside its THP ifdef, so a -D on the
 * command line is overwritten. Redefine after the header, as a kernel
 * without CONFIG_TRANSPARENT_HUGEPAGE would have it. */
#include <linux/blkdev.h>
#undef BLK_MAX_BLOCK_SIZE
#define BLK_MAX_BLOCK_SIZE PAGE_SIZE
