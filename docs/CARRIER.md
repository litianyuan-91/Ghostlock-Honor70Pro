# The stack carrier: landing a fake waiter on the stale one

## What a "carrier" is

GhostLock's write primitive is a **stale `rt_mutex_waiter`**. A
`futex_wait_requeue_pi` that returns `EDEADLK` leaves its
`struct rt_mutex_waiter` (0x50 bytes) behind on the task's kernel stack. When a
`sched_setattr` on that task later drives `rt_mutex_adjust_prio_chain`, the walk
follows the `pi_tree_entry.rb_node` pointer it finds at those stack words — i.e.
it dereferences **whatever currently lives there**. If that data is controlled,
the walk's `rb_erase`/`rb_insert` become an arbitrary pointer write.

The *carrier* is the syscall that puts controlled data on the kernel stack at
the right depth. A usable carrier must

1. land exactly on the stale waiter's ten words,
2. copy the user buffer **verbatim** (not rewrite it on syscall return), and
3. be re-issuable, so the plant can be refreshed while another thread (or the
   same thread) fires the `sched_setattr`.

## Carrier 1 — `pselect` fd_sets (upstream, HONOR 80 GT)

Upstream uses `pselect(2)`: `do_select` copies the three `fd_set`s from the
`pselect6` user argument onto the stack, and because the call sleeps *inside*
the syscall the copy stays live. `SLIDE_SHIFT` (in 8-byte words) selects which
copy word maps onto waiter word 0; upstream is `-2`. The two words the shift
cannot place (`global_word < 0`) are made harmless by forcing a Case-1
`rb_erase` (`tree_left = 0`); see `slide.c:prepare_slide_pselect_fdsets`.

This carrier can only reach *downward*: word `w` is placed at waiter word `w`,
so any shift below `-2` would need words the copy does not contain.

## Why the pselect carrier does not fit SDY-AN00

On this kernel the `pselect` fd_set copy lands roughly **0x88 bytes above** the
stale waiter — the `do_select` frame chain is shallower in this build, so the
copy starts *past* the end of the waiter's ten words and no shift can pull it
back. This is a structural mismatch, not a tuning miss: upstream 8.0 targets
simply never control waiter words 0–1, and here the copy does not overlap the
waiter at all.

## Carrier 2 — `setsockopt(MCAST_..._SOURCE_GROUP)` `group_source_req`

`ip_setsockopt` / `do_ipv6_setsockopt` copy a `struct group_source_req` onto the
stack **verbatim** with `_copy_from_user`, and they do it *before* validating
the address families inside it — so a zeroed `ss_family` fails cleanly *after*
the copy has already landed. That makes it an ideal carrier when it happens to
land on the waiter. The struct is

```
struct group_source_req {                 /* 264 bytes = 33 words */
    __u32 gsr_interface;                  /* +0x00  (+4 bytes padding) */
    struct sockaddr_storage gsr_group;    /* +0x08, 128 bytes */
    struct sockaddr_storage gsr_source;   /* +0x88, 128 bytes */
};
```

so it plants 33 controllable qwords — more than the 10 waiter words needed.

The IPv4 and IPv6 stacks have different frame depths, so the copy lands at a
different kstack offset:

| carrier | frame | copy site | landing | shift to waiter |
|---|---|---|---|---|
| IPv4 `ip_setsockopt` | `0x2A0` | `sp + 0x20` | `S − 0x360` | **15** |
| IPv6 `do_ipv6_setsockopt` | — | — | `S − 0x3D8` | 30 (*too deep*) |

`S` is the kstack top of the waiter thread; the stale futex waiter sits at
`S − 0x2E8` (`futex_wait_requeue_pi` frame `0x1B0`, `rt_waiter` at `sp + 0x98`
— see [OFFSETS.md](OFFSETS.md)). For IPv4 the arithmetic is
`(0x360 − 0x2E8) / 8 = 15`, so `gsr[15 + k]` plants waiter word `k`. IPv6 lands
30 words down, leaving only 3 of its 33 words overlapping the waiter — unusable.
Hence the SDY-AN00 target uses:

```c
#define SLIDE_CARRIER_MCAST      1
#define SLIDE_MCAST_OPT_DEFAULT  46     /* MCAST_JOIN_SOURCE_GROUP */
#define SLIDE_MCAST_SHIFT        15
#define SLIDE_MCAST_IPV4_DEFAULT 1
```

### Resident plant and the "fresh handshake"

Unlike `pselect` — which sleeps inside the syscall holding the copy — the
`setsockopt` returns immediately, and the next syscall on that thread rebuilds
frames over the residue. Two mechanisms keep the plant alive long enough for
the fire:

- the waiter thread re-issues the stamp in a loop with a **userspace gap**
  (a `cntvct_el0` spin that makes no syscall; `SLIDE_MCAST_GAP_US`, default
  50 µs), so the copy is resident for a large fraction of wall time; and
- the **same** thread fires `sched_setattr` on itself inside a gap
  ("self-fire"), so both reads of `ghost->lock` during the walk see the planted
  `fake_lock` instead of a `__schedule` residue from a torn mid-syscall plant.

That is why the MCAST carrier fires from the waiter thread itself, whereas the
`pselect` carrier needs a separate consumer thread.

## Runtime knobs (no rebuild required)

| env | default | meaning |
|---|---|---|
| `SLIDE_MCAST_SHIFT` | 15 | landing shift in words; retune per kernel |
| `SLIDE_MCAST_OPT` | 46 | which `MCAST_*` case block to use |
| `SLIDE_MCAST_IPV4` | 1 | `1` = `IPPROTO_IP`, `0` = `IPPROTO_IPV6` |
| `SLIDE_MCAST_ROUNDS` | 300 | stamp rounds before giving up |
| `SLIDE_MCAST_GAP_US` | 50 | userspace resident-gap per round (µs) |
| `SLIDE_SHIFT` | -2 | pselect-carrier shift (ignored when `SLIDE_CARRIER_MCAST`) |

## Retuning on a new kernel

1. Disassemble the two carriers' frames (`futex_wait_requeue_pi`,
   `ip_setsockopt`) and compute the shift as above.
2. If it is not obvious, sweep `SLIDE_MCAST_SHIFT` — but note that **every miss
   reboots the phone** (`CONFIG_PANIC_ON_OOPS=y`). Sweep in one direction and
   watch `gl.log` for `chain complete`.
3. A wrong shift lands `task`/`lock` on `prio`/`deadline`; the walk then runs on
   garbage and oopses (`wake_up_process(NULL)`).
