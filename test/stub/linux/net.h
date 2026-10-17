/* SPDX-License-Identifier: BSD-3-Clause - stub, see linux/kernel.h */
#ifndef _H2_STUB_NET_H_
#define _H2_STUB_NET_H_
#include <linux/fs.h>
/*
 * What holdfp() and fp_shutdown() touch of the kernel's socket layer,
 * transcribed from v7.3-rc5: struct socket's first two members
 * (include/linux/net.h:160-164, the state and the type), SOCK_STREAM
 * (:108), enum sock_shutdown_cmd (:135-139), sockaddr_storage
 * (include/uapi/linux/socket.h), and the three calls (:310, :403, :404).
 * sock_from_file() returns NULL for a file that is not a socket.
 */
typedef enum {
	SS_FREE = 0,
	SS_UNCONNECTED,
	SS_CONNECTING,
	SS_CONNECTED,
	SS_DISCONNECTING
} socket_state;
enum sock_type {
	SOCK_STREAM	= 1,
};
enum sock_shutdown_cmd {
	SHUT_RD,
	SHUT_WR,
	SHUT_RDWR,
};
struct sockaddr {
	unsigned short	sa_family;
	char		sa_data[14];
};
struct sockaddr_storage {
	unsigned short	ss_family;
	char		__data[126];
};
struct socket {
	socket_state		state;
	short			type;
};
struct socket *sock_from_file(struct file *file);
int kernel_getpeername(struct socket *sock, struct sockaddr *addr);
int kernel_sock_shutdown(struct socket *sock, enum sock_shutdown_cmd how);
#endif
