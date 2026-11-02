/* SPDX-License-Identifier: BSD-3-Clause - stub, see linux/kernel.h */
#ifndef _H2_STUB_TLS_H_
#define _H2_STUB_TLS_H_
#include <linux/net.h>
/*
 * What hammer2_fp_tlsrec() uses of include/net/tls.h at v7.3: the
 * KeyUpdate handshake type (:64) and tls_sw_has_ctx_rx() (:414-425), an
 * inline there and a prototype here.
 */
#define TLS_HANDSHAKE_KEYUPDATE	24
_Bool tls_sw_has_ctx_rx(const struct sock *sk);
#endif
