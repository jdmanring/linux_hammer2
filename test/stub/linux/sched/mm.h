/* Stub of <linux/sched/mm.h>: the NOFS scope the shim's locks enter. */
#ifndef _STUB_LINUX_SCHED_MM_H
#define _STUB_LINUX_SCHED_MM_H
#define PF_MEMALLOC_NOFS 0x00040000
unsigned int memalloc_nofs_save(void);
void memalloc_nofs_restore(unsigned int flags);
#endif
