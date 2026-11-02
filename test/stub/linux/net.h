/* SPDX-License-Identifier: BSD-3-Clause - stub, see linux/kernel.h */
#ifndef _H2_STUB_NET_H_
#define _H2_STUB_NET_H_
#include <linux/fs.h>
/*
 * What holdfp() and fp_shutdown() touch of the kernel's socket layer,
 * transcribed from v7.3: struct socket's first two members
 * (include/linux/net.h:160-164, the state and the type), SOCK_STREAM
 * (:108), enum sock_shutdown_cmd (:135-139), sockaddr_storage
 * (include/uapi/linux/socket.h), and the three calls (:310, :403, :404).
 * sock_from_file() returns NULL for a file that is not a socket.  The
 * socket's members past those two are :165-168, up to sk.
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
struct sock;
struct socket {
	socket_state		state;
	short			type;
	unsigned long		flags;
	struct file		*file;
	struct sock		*sk;
};
struct socket *sock_from_file(struct file *file);
/*
 * What hammer2_fp_tlsrec() reads a kTLS record with, from v7.3:
 * struct kvec and iov_iter_kvec() (include/linux/uio.h:18-21, :293),
 * ITER_DEST (:35), struct msghdr's members it sets in their order
 * (include/linux/socket.h:71-95; the stub's iov_iter is opaque storage),
 * struct cmsghdr and CMSG_SPACE (:119-139), MSG_DONTWAIT and MSG_EOR
 * (:325-326), and sock_recvmsg() (include/linux/net.h:307).
 */
struct kvec {
	void	*iov_base;
	size_t	iov_len;
};
struct iov_iter {
	unsigned long	opaque[6];
};
#define ITER_DEST	0
void iov_iter_kvec(struct iov_iter *i, unsigned int direction,
    const struct kvec *kvec, unsigned long nr_segs, size_t count);
struct msghdr {
	void		*msg_name;
	int		msg_namelen;
	int		msg_inq;
	struct iov_iter	msg_iter;
	void		*msg_control;
	unsigned int	msg_flags;
	size_t		msg_controllen;
};
struct cmsghdr {
	size_t	cmsg_len;
	int	cmsg_level;
	int	cmsg_type;
};
#define CMSG_ALIGN(len) (((len) + sizeof(long) - 1) & ~(sizeof(long) - 1))
#define CMSG_SPACE(len) (sizeof(struct cmsghdr) + CMSG_ALIGN(len))
#define MSG_DONTWAIT	0x40
#define MSG_EOR		0x80
int sock_recvmsg(struct socket *sock, struct msghdr *msg, int flags);
int kernel_getpeername(struct socket *sock, struct sockaddr *addr);
int kernel_sock_shutdown(struct socket *sock, enum sock_shutdown_cmd how);
#endif
