/* SPDX-License-Identifier: BSD-3-Clause
 *
 * STUB. Not the Linux kernel header; see kernel.h in this directory.
 * The one call the shim makes, transcribed from include/linux/pagemap.h
 * at v7.3-rc1, and PAGE_SHIFT as x86-64 defines it.
 */
#ifndef _H2_STUB_PAGEMAP_H_
#define _H2_STUB_PAGEMAP_H_

#ifndef PAGE_SHIFT
#define PAGE_SHIFT	12
#endif

struct address_space;
void mapping_set_folio_min_order(struct address_space *mapping, unsigned int min);
void mapping_set_folio_order_range(struct address_space *mapping, unsigned int min, unsigned int max);

#endif
