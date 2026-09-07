/*-
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * Copyright (c) 2022-2023 Tomohiro Kusumi <tkusumi@netbsd.org>
 * Copyright (c) 2011-2022 The DragonFly Project.  All rights reserved.
 *
 * This code is derived from software contributed to The DragonFly Project
 * by Matthew Dillon <dillon@dragonflybsd.org>
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 *
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in
 *    the documentation and/or other materials provided with the
 *    distribution.
 * 3. Neither the name of The DragonFly Project nor the names of its
 *    contributors may be used to endorse or promote products derived
 *    from this software without specific, prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 * ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
 * FOR A PARTICULAR PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE
 * COPYRIGHT HOLDERS OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
 * INCIDENTAL, SPECIAL, EXEMPLARY OR CONSEQUENTIAL DAMAGES (INCLUDING,
 * BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED
 * AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
 * OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT
 * OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 */

/*
 * The RB_SCAN family, which DragonFly's tree.h has natively. Taken from
 * the FreeBSD port, unchanged but for `__unused` (3 sites) and the scan
 * bookkeeping below. See sys/cdefs.h.
 *
 * XXX Linux: a scan holds the node it will visit next across each
 * callback, and the flush's callback releases the parent's core
 * spinlock while it locks the child, so another task can remove and
 * free that next node in the meantime.  DragonFly's tree.h keeps the
 * scans in progress on the tree head and its RB_REMOVE moves any scan
 * whose next node is the one being removed, which is what the core's
 * "any item may be deleted while the scan is in progress" relies on.
 * FreeBSD's tree.h, vendored here, has no such list, and the FreeBSD
 * port never needed one because it does not write.  The head, RB_INIT
 * and RB_REMOVE are DragonFly's here, over the vendored tree, and the
 * static initializer, unused in this tree, stays FreeBSD's: the list is kept under the lock its owner holds around every
 * scan and removal, the core spinlock, as DragonFly keeps it.  Found
 * by a flush walking into a freed chain on a Nix closure copy,
 * doc/README.status.md has the trace.
 */

#ifndef _FS_HAMMER2_RB_H_
#define _FS_HAMMER2_RB_H_

/* prototype */
#define RB_SCAN_INFO(name, type)					\
struct name##_scan_info {						\
	struct name##_scan_info *link;					\
	struct type	*node;						\
}

#undef RB_HEAD
#define RB_HEAD(name, type)						\
RB_SCAN_INFO(name, type);						\
struct name {								\
	struct type *rbh_root;						\
	struct name##_scan_info *rbh_inprog;	/* scans in progress */	\
}

#undef RB_INIT
#define RB_INIT(root) do {						\
	(root)->rbh_root = NULL;					\
	(root)->rbh_inprog = NULL;					\
} while (0)

#define RB_INPROG(head)		((head)->rbh_inprog)

/*
 * The removal DragonFly's tree.h generates, over the vendored one: a
 * scan about to visit the node being removed is moved past it first.
 */
#undef RB_REMOVE
#define RB_REMOVE(name, head, elm) do {					\
	struct name##_scan_info *__inprog;				\
									\
	for (__inprog = RB_INPROG(head); __inprog;			\
	    __inprog = __inprog->link) {				\
		if (__inprog->node == (elm))				\
			__inprog->node = RB_NEXT(name, head, elm);	\
	}								\
	name##_RB_REMOVE(head, elm);					\
} while (0)

#define RB_PROTOTYPE_SCAN(name, type, field)				\
	_RB_PROTOTYPE_SCAN(name, type, field,)

#define RB_PROTOTYPE_SCAN_STATIC(name, type, field)			\
	_RB_PROTOTYPE_SCAN(name, type, field, __always_unused static)

#define _RB_PROTOTYPE_SCAN(name, type, field, STORQUAL)			\
STORQUAL int name##_RB_SCAN(struct name *, int (*)(struct type *, void *),\
			int (*)(struct type *, void *), void *)

/* generate */
#define RB_GENERATE_SCAN(name, type, field)				\
	_RB_GENERATE_SCAN(name, type, field,)

#define RB_GENERATE_SCAN_STATIC(name, type, field)			\
	_RB_GENERATE_SCAN(name, type, field, __always_unused static)

#define _RB_GENERATE_SCAN(name, type, field, STORQUAL)			\
/*									\
 * Issue a callback for all matching items.  The scan function must	\
 * return < 0 for items below the desired range, 0 for items within	\
 * the range, and > 0 for items beyond the range.   Any item may be	\
 * deleted while the scan is in progress.				\
 */									\
static int								\
name##_SCANCMP_ALL(struct type *type __always_unused, void *data __always_unused)	\
{									\
	return (0);							\
}									\
									\
/* XXX Linux: DragonFly's, the scan taken off the head's list. */	\
static __inline void							\
name##_scan_info_done(struct name##_scan_info *scan, struct name *head)	\
{									\
	struct name##_scan_info **infopp;				\
									\
	infopp = &RB_INPROG(head);					\
	while (*infopp != scan)						\
		infopp = &(*infopp)->link;				\
	*infopp = scan->link;						\
}									\
									\
static __inline int							\
_##name##_RB_SCAN(struct name *head,					\
		int (*scancmp)(struct type *, void *),			\
		int (*callback)(struct type *, void *),			\
		void *data)						\
{									\
	struct name##_scan_info info;					\
	struct type *best;						\
	struct type *tmp;						\
	int count;							\
	int comp;							\
									\
	if (scancmp == NULL)						\
		scancmp = name##_SCANCMP_ALL;				\
									\
	/*								\
	 * Locate the first element.					\
	 */								\
	tmp = BSD_RB_ROOT(head);						\
	best = NULL;							\
	while (tmp) {							\
		comp = scancmp(tmp, data);				\
		if (comp < 0) {						\
			tmp = RB_RIGHT(tmp, field);			\
		} else if (comp > 0) {					\
			tmp = RB_LEFT(tmp, field);			\
		} else {						\
			best = tmp;					\
			if (RB_LEFT(tmp, field) == NULL)		\
				break;					\
			tmp = RB_LEFT(tmp, field);			\
		}							\
	}								\
	count = 0;							\
	if (best) {							\
		info.node = RB_NEXT(name, head, best);			\
		info.link = RB_INPROG(head);	/* XXX Linux: see above */\
		RB_INPROG(head) = &info;					\
		while ((comp = callback(best, data)) >= 0) {		\
			count += comp;					\
			best = info.node;				\
			if (best == NULL || scancmp(best, data) != 0)	\
				break;					\
			info.node = RB_NEXT(name, head, best);		\
		}							\
		name##_scan_info_done(&info, head);			\
		if (comp < 0)	/* error or termination */		\
			count = comp;					\
	}								\
	return (count);							\
}									\
									\
STORQUAL int								\
name##_RB_SCAN(struct name *head,					\
		int (*scancmp)(struct type *, void *),			\
		int (*callback)(struct type *, void *),			\
		void *data)						\
{									\
	return _##name##_RB_SCAN(head, scancmp, callback, data);	\
}

#define RB_SCAN(name, root, cmp, callback, data) 			\
				name##_RB_SCAN(root, cmp, callback, data)

#endif /* !_FS_HAMMER2_RB_H_ */
