/* SPDX-License-Identifier: BSD-3-Clause - stub, see linux/kernel.h */
#ifndef _H2_STUB_HANDSHAKE_H_
#define _H2_STUB_HANDSHAKE_H_
#include <linux/net.h>
/*
 * The shim includes include/net/handshake.h for the cluster link's
 * callers in hammer2_iocom.c and itself calls tls_get_record_type(),
 * transcribed from v7.3 (include/net/handshake.h:45), in
 * hammer2_fp_tlsrec().
 */
unsigned char tls_get_record_type(const struct sock *sk,
    const struct cmsghdr *msg);
#endif
