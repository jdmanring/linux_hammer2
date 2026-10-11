# The CCMS thread lock's state transitions

P3's exit criteria ask for a state-transition matrix with explicit
preconditions and postconditions, a negative transition test, and
lockdep-clean concurrency tests. This document is the first of those: the
transitions of the lock that is carried, written from the shipped
`src/sys/fs/hammer2/hammer2_ccms.c` rather than from the deleted
coherency half, which has no transitions to document.

The coherency half is a separate matter. Its four states and six type
flags are vocabulary, and `ccms_rstate_get()` was to move state between
them; its body is one assignment under `/* XXX */`, so there is no
transition table to write for it. `doc/CCMS_DESIGN.md` records what is
reproducible and what is not.

## The state

A `ccms_cst_t` carries the lock in `count` and `td`, and the grant state
in `state` and `type`. The lock's own state is what this document covers:

| `count` | `td` | meaning |
|---|---|---|
| `< 0` | the holder | exclusive, depth `-count` |
| `0` | `NULL` | unlocked |
| `> 0` | `NULL` | shared, depth `count` |

`upgrade` is a counter of pending upgrades, not a state: while it is
nonzero, no new shared or exclusive lock is granted, and other upgraders
are allowed. `blocked` is a flag that a sleeper is waiting, so the
releaser knows to call `wakeup()`.

The transitions below are the ones the shipped code implements. Each names
its precondition, its postcondition, and what it does to a waiter.

## Acquire

### `ccms_thread_lock(cst, CCMS_STATE_SHARED)`

Precondition: the caller holds no lock on this CST, or holds it
exclusively. Postcondition: `count > 0` and the caller is a shared holder.

- If the caller already holds exclusively, `count` is decremented and the
  call returns without taking the spin. An exclusive holder asking for
  shared stays exclusive, and the depth grows.
- Otherwise the spin is taken. While `count < 0` or `upgrade` is set, the
  caller sleeps with `blocked = 1`. On wake, `count` is incremented and
  `td` is asserted `NULL`.

### `ccms_thread_lock(cst, CCMS_STATE_EXCLUSIVE)`

Precondition: the CST is unlocked and no upgrade is pending.
Postcondition: `count == -1` and `td` is the caller.

- While `count != 0` or `upgrade` is set, the caller sleeps. On wake,
  `count` is set to `-1` and `td` to the caller.

### `ccms_thread_lock_nonblock(cst, state)`

Same preconditions and postconditions as the blocking form, and the same
arms, except that a would-block returns `EBUSY` instead of sleeping. The
return value is the whole difference: `0` on success, `EBUSY` on refusal.

## Release

### `ccms_thread_unlock(cst)`

Precondition: the caller holds the lock, exclusively or shared.
Postcondition: the depth is one less, and the CST is unlocked at depth
zero.

- Exclusive, depth below one: `count` is incremented and the spin is not
  taken.
- Exclusive at depth one: the spin is taken, `count` becomes `0`, `td`
  becomes `NULL`, and a blocked waiter is woken.
- Shared: the spin is taken, `count` is decremented, and a blocked waiter
  is woken when `count` reaches `0`.

The spin is taken by the releaser, not only by the acquirer, which is why
a good-state lock and unlock reads two acquires and two releases in
`test/hammer2-ccms-lock.c`.

## Upgrade and downgrade

### `ccms_thread_lock_upgrade(cst)`

Precondition: the caller holds the lock, exclusively or shared.
Postcondition: the caller holds it exclusively.

- Already exclusive: returns without taking the spin.
- Shared: the spin is taken, `upgrade` is incremented, `count` is
  decremented, and the caller sleeps while `count` is nonzero. On wake,
  `count` is `-1` and `td` is the caller. The return value is the state
  the caller held before, which is what `temp_restore` takes.

### `ccms_thread_lock_downgrade(cst, ostate)`

Precondition: the caller holds exclusively and `ostate` is the state it
held before upgrading. Postcondition: the caller holds `ostate`.

- `ostate == CCMS_STATE_SHARED`: the spin is taken, `upgrade` is
  decremented, `count` becomes `1`, `td` becomes `NULL`, and a blocked
  waiter is woken.
- `ostate == CCMS_STATE_EXCLUSIVE`: nothing to do.

### `ccms_thread_lock_temp_release(cst)` / `temp_restore(cst, ostate)`

Precondition for release: the caller holds the lock. Postcondition: the
caller holds nothing, and the return is the state it held. `temp_restore`
is `ccms_thread_lock(cst, ostate)`, so its precondition is that the CST
is unlocked and no upgrade is pending.

## The negative transitions

Each of these is a call the code refuses, and each is a check in
`test/hammer2-ccms-lock.c`:

| call | precondition violated | what the code does |
|---|---|---|
| `ccms_thread_lock(cst, 7)` | 7 is not a state the function implements | releases the spin, calls `hpanic()`, returns |
| `ccms_thread_lock_nonblock(cst, 7)` | the same | the same, and returns `EBUSY` |
| `ccms_thread_lock_upgrade(cst)` on an unlocked CST | the caller holds nothing | calls `hpanic()` and returns `0` |
| `ccms_thread_unlock(cst)` on an unlocked CST | the caller holds nothing | calls `hpanic()` |

The two bad-state arms are the defect 1.0.6 fixed. Upstream's `panic()`
never returns, so the fall-through after it was unreachable and the spin
came up once; this port's `hpanic()` returns, so the same shape released
the spin twice. Both arms now return, marked `/* XXX Linux: hpanic
returns */`.

## What this document does not cover

- Concurrency. The transitions above are single-threaded readings of the
  code. Whether they hold under concurrent acquirers is a separate
  question, and it is the one the lockdep run on the guest answers. The
  lock's own comment says the code is "in the critical path and highly
  streamlined", which is the constraint any concurrency test has to
  respect.
- The grant state. `state` and `type` are not touched by any function in
  the carried file. `ccms_rstate_get()` was to set `state`, and it is not
  carried.
- The coherency protocol. See `doc/CCMS_DESIGN.md`.
