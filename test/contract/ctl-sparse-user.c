/*
 * Negative control for test-syntax.sh's sparse pass: a kernel pointer
 * handed to copy_to_user() compiles clean under both compilers and must
 * be refused by sparse as a different address space, or the pass is
 * blind to the class it exists for.
 */
#include <linux/uaccess.h>

int ctl_sparse_user(void *kp, const void *src);

int
ctl_sparse_user(void *kp, const void *src)
{
	return (copy_to_user(kp, src, 8) ? 1 : 0);
}
