/* Test vector for HAMMER2's CRC-32 check, from the CRC-32C (Castagnoli)
 * reference value for the standard "123456789" input.
 *
 * The question this answers: is the core's iscsi_crc32() the Castagnoli
 * polynomial and not the IEEE one that zlib and the kernel's crc32_le()
 * use? The two agree on nothing and both look like a CRC-32, so a volume
 * written with the wrong one reads as corrupt to every other HAMMER2
 * implementation rather than as buggy here.
 *
 * NO GATE IN THIS TREE RUNS IT, AND A GATE IN ANOTHER ONE DOES.
 * iscsi_crc32() arrives with the check algorithms in 0.2 and there is
 * nothing local to link against before then. ArtNix's
 * scripts/test-hammer2-checkalg.sh compiles this file against the FreeBSD
 * port's icrc32.c and greps the output for "Castagnoli ... MATCH", so the
 * exit status AND that line's wording are an interface.
 * doc/README.testing.md carries the contract.
 *
 * Until 2026-08-26 the exit status here accepted EITHER polynomial, which
 * left the one question it exists to ask unanswered while reporting
 * success.
 */
#include <stdio.h>
#include <stdint.h>
#include <string.h>

uint32_t iscsi_crc32(const void *buf, size_t size);

#define CRC32C_123456789	0xe3069283u	/* Castagnoli, what HAMMER2 uses */
#define CRC32_IEEE_123456789	0xcbf43926u	/* zlib and crc32_le(), what it must not be */

int
main(void)
{
	const char *s = "123456789";
	uint32_t got = iscsi_crc32(s, strlen(s));

	printf("iscsi_crc32(\"123456789\") = %08x\n", got);
	if (got == CRC32C_123456789) {
		printf("  CRC-32C (Castagnoli) %08x MATCH\n", CRC32C_123456789);
		return 0;
	}
	if (got == CRC32_IEEE_123456789)
		printf("  FAIL: this is CRC-32 IEEE %08x, not Castagnoli %08x\n",
		       CRC32_IEEE_123456789, CRC32C_123456789);
	else
		printf("  FAIL: expected CRC-32C %08x\n", CRC32C_123456789);

	return 1;
}
