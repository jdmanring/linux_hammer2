/* Test vectors for XXH64, the default HAMMER2 block check.
 *
 * The question this answers: is the vendored xxHash stock, and is it
 * called with HAMMER2's seed? A modified algorithm, or the right
 * algorithm under the wrong seed, writes a digest every other HAMMER2
 * implementation reads as corruption. Nothing about the resulting volume
 * looks wrong from inside this port, which is what makes it worth a
 * vector test rather than a self-consistency check.
 *
 * STAGED, RUN BY NOTHING TODAY. There is no xxhash.h in this tree: the
 * check algorithms arrive in 0.2, and until they do there is nothing to
 * compile this against. doc/README.testing.md lists it and
 * script/test-inventory.sh checks that the list still mentions it.
 *
 * The reference values were measured on 2026-08-26 rather than
 * remembered, against xxhsum 0.8.3 (the CLI, for the unseeded pair) and
 * libxxhash 0.8.3 (for the seeded ones, which the CLI cannot produce).
 * Both are Yann Collet's implementation and neither is this port's copy,
 * which is the point of a vector.
 *
 * Two defects until 2026-08-26: two of the three cases printed a digest
 * and asserted nothing, so a wrong value scrolled past as output; and the
 * seeded case used 0x9E3779B185EBCA87, xxHash's own golden-ratio prime,
 * where HAMMER2 seeds with 0x4d617474446c6c6e. That is "MattDlln" in
 * ASCII, from hammer2_xxhash.h in the FreeBSD port.
 */
#include <stdio.h>
#include <string.h>
#include "xxhash.h"

#define XXH_HAMMER2_SEED	0x4d617474446c6c6eULL

int
main(void)
{
	static const struct {
		const char *what;
		const char *data;
		size_t n;
		unsigned long long seed;
		unsigned long long want;
	} v[] = {
		{ "\"\", seed 0",		"",    0, 0,			0xef46db3751d8e999ULL },
		{ "\"abc\", seed 0",		"abc", 3, 0,			0x44bc2cf5ad770999ULL },
		{ "\"\", HAMMER2 seed",		"",    0, XXH_HAMMER2_SEED,	0x84566ac0f5a0cb84ULL },
		{ "\"abc\", HAMMER2 seed",	"abc", 3, XXH_HAMMER2_SEED,	0x9ba15f8bd2fb8f3eULL },
	};
	unsigned long long got;
	int bad = 0;
	size_t i;

	for (i = 0; i < sizeof(v) / sizeof(v[0]); ++i) {
		got = (unsigned long long)XXH64(v[i].data, v[i].n, v[i].seed);
		printf("XXH64(%-22s) = %016llx  want %016llx  %s\n",
		       v[i].what, got, v[i].want,
		       got == v[i].want ? "ok" : "MISMATCH");
		bad += (got != v[i].want);
	}

	return bad != 0;
}
