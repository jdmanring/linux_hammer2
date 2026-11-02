/* SPDX-License-Identifier: BSD-3-Clause - stub, see linux/kernel.h */
#ifndef _H2_STUB_TLS_PROT_H_
#define _H2_STUB_TLS_PROT_H_
/*
 * The record types and alert descriptions hammer2_fp_tlsrec() names,
 * transcribed from include/net/tls_prot.h at v7.3 (:16-24, :37-65).
 */
enum {
	TLS_RECORD_TYPE_ALERT = 21,
	TLS_RECORD_TYPE_HANDSHAKE = 22,
	TLS_RECORD_TYPE_DATA = 23,
};
enum {
	TLS_ALERT_DESC_CLOSE_NOTIFY = 0,
	TLS_ALERT_DESC_USER_CANCELED = 90,
};
#endif
