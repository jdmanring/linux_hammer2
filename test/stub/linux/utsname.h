/* SPDX-License-Identifier: BSD-3-Clause - stub, see linux/kernel.h */
#ifndef _H2_STUB_UTSNAME_H_
#define _H2_STUB_UTSNAME_H_
/*
 * The node name hammer2_iocom.c labels its peer with, transcribed from
 * include/uapi/linux/utsname.h at v7.3 (struct new_utsname, the
 * nodename field at :27 with __NEW_UTS_LEN 64) and include/linux/utsname.h:34.
 */
struct new_utsname {
	char nodename[65];
};
struct new_utsname *init_utsname(void);
#endif
