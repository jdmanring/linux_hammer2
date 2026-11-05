/*
 * Negative control for test-syntax.sh's sparse pass: an error on a path
 * outside src/.  Once sparse has reported an error it stops reporting its
 * own checks, so an error raised by a kernel header leaves the rest of the
 * file unread; the pass has to fail on this line whatever path carries it.
 */
_Static_assert(0, "an error outside src/ must fail the sparse pass");
