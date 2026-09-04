/* Test vectors for XXH64, the default HAMMER2 block check.
 *
 * The question this answers: is the vendored xxHash stock, and is it
 * called with HAMMER2's seed? A modified algorithm, or the right
 * algorithm under the wrong seed, writes a digest every other HAMMER2
 * implementation reads as corruption. Nothing about the resulting volume
 * looks wrong from inside this port, which is what makes it worth a
 * vector test rather than a self-consistency check.
 *
 * NO GATE IN THIS TREE RUNS IT, AND A GATE IN ANOTHER ONE DOES. There is
 * no xxhash.h here until the check algorithms arrive in 0.2, so nothing
 * local can compile it. Saxum's scripts/test-hammer2-checkalg.sh does:
 * it compiles this file against the FreeBSD port's vendored xxhash and
 * requires both the pass and the negative control. So the exit status,
 * the printed shape and the constants below are an INTERFACE, not this
 * file's private business. doc/README.testing.md carries the contract.
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
 * where HAMMER2 seeds with 0x4D617474446C6C6E. That is "MattDlln" in
 * ASCII, from hammer2_xxhash.h in the FreeBSD port.
 */
#include <stdio.h>
#include <string.h>
#include "xxhash.h"

#define XXH_HAMMER2_SEED	0x4D617474446C6C6EULL

/*
 * FALSIFICATION HOOK, AND THE HEX CASE IS AN INTERFACE. A consumer's
 * negative control has to corrupt an expected value and require the
 * failure, and the one in Saxum's scripts/test-hammer2-checkalg.sh did it
 * by sed-ing the literal below out of this file's text. Rewriting the
 * vectors on 2026-08-26 lowercased that literal, the sed stopped matching,
 * the control compared a file to itself and the gate reported that it was
 * comparing nothing - correctly, and about the wrong repository.
 *
 * So: the literals stay uppercase, and -DXXH_VECTORS_CONTROL corrupts the
 * first expected digest at compile time, which no formatting change can
 * break. Compile twice and require the second to fail.
 */
#ifdef XXH_VECTORS_CONTROL
#define WANT_EMPTY_SEED0	0xEF46DB3751D8E998ULL	/* deliberately wrong */
#else
#define WANT_EMPTY_SEED0	0xEF46DB3751D8E999ULL
#endif

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
		{ "\"\", seed 0",		"",    0, 0,			WANT_EMPTY_SEED0 },
		{ "\"abc\", seed 0",		"abc", 3, 0,			0x44BC2CF5AD770999ULL },
		{ "\"\", HAMMER2 seed",		"",    0, XXH_HAMMER2_SEED,	0x84566AC0F5A0CB84ULL },
		{ "\"abc\", HAMMER2 seed",	"abc", 3, XXH_HAMMER2_SEED,	0x9BA15F8BD2FB8F3EULL },
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
