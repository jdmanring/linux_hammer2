/* Stub of linux/backing-dev.h: what hammer2_os.h reaches for and no more.
 * wb_stat() reads a per-writeback counter; the write reserve counts the
 * device's dirty pages against free space through it. */
#ifndef _LINUX_BACKING_DEV_H
#define _LINUX_BACKING_DEV_H
enum wb_stat_item { WB_RECLAIMABLE, WB_WRITEBACK, WB_DIRTIED, WB_WRITTEN, NR_WB_STAT_ITEMS };
struct bdi_writeback { int stat[NR_WB_STAT_ITEMS]; };
struct backing_dev_info { struct bdi_writeback wb; };
static inline long long wb_stat(struct bdi_writeback *wb, enum wb_stat_item item)
{
	return (wb->stat[item]);
}
#endif
