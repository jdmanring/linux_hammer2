/* Test vectors for XXH64, from Cyan4973/xxHash's own xxhsum test data.
 * The question this answers: is HAMMER2's vendored xxHash stock, or has it
 * been modified? A modified check algorithm would silently produce a
 * different on-disk checksum from every other HAMMER2 implementation. */
#include <stdio.h>
#include <string.h>
#include "xxhash.h"

int main(void)
{
	static const char abc[] = "abc";
	unsigned long long got, want;
	int bad = 0;

	struct { const char *d; size_t n; unsigned long long seed, want; } v[] = {
		{ "",    0, 0,          0xEF46DB3751D8E999ULL },
	};
	(void)v;

	got = (unsigned long long)XXH64("", 0, 0);
	want = 0xEF46DB3751D8E999ULL;
	printf("XXH64(\"\", 0, seed=0)      = %016llx  want %016llx  %s\n",
	       got, want, got == want ? "ok" : "MISMATCH");
	bad += (got != want);

	got = (unsigned long long)XXH64(abc, 3, 0);
	printf("XXH64(\"abc\", 3, seed=0)   = %016llx\n", got);

	got = (unsigned long long)XXH64(abc, 3, 0x9E3779B185EBCA87ULL);
	printf("XXH64(\"abc\", 3, seed=P)   = %016llx\n", got);

	return bad;
}
