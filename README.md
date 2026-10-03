# GhostLock for HONOR 70 Pro (SDY-AN00)

English | [中文](README.zh-CN.md)

A port of the **GhostLock** local-privilege-escalation exploit
(CVE-2026-43499 — a use-after-free in the kernel `rtmutex` `remove_waiter`
path, originally written for the HONOR 80 GT / AGT-AN00) to the
**HONOR 70 Pro (SDY-AN00)**:

| | |
|---|---|
| Device | HONOR 70 Pro, `SDY-AN00`, SoC **MediaTek Dimensity 8000 (MT6895)** |
| Firmware | MagicOS 8.0.0.220 (`C00E220R5P7`), Android 14 |
| Kernel | **5.10.66-android12-9-ge639f4185278** (`#1 SMP PREEMPT Wed Oct 29 10:08:49 UTC 2025`) |
| Result | **temporary root (uid 0) + SELinux permissive + `sig_enforce=0`** — verified on a real device |

The exploit gives a **temporary** root: one run flips the kernel credentials of a
parked helper process and disables the module-signature gate. A reboot restores
everything. It is a research PoC — read the warning below.

## Status

| Part | State |
|---|---|
| GhostLock exploit chain on SDY-AN00 | ✅ **works / verified** (`exploit/`, `release/`) |
| root shell (persistent helper, TCP 34567) | ✅ works |
| boot-persistent wireless adb on port 5555 | ✅ works (see below) |
| KernelSU (`kernelsu.ko` built + loads) | ⚠️ module loads, but **breaks the device** |
| KernelSU as an actual root manager | ❌ **not possible on this kernel** — see [docs/KSU.md](docs/KSU.md) |

**KernelSU blocker in one line:** this HONOR kernel is built **without
`CONFIG_KPROBES`** (`CONFIG_HAVE_KPROBES=y` only), and KernelSU's `Kconfig`
requires `CONFIG_KPROBES` for its kernel hooks. Without it KSU's `execve` hook
returns `ENOSYS` and the whole system stops being able to create processes.
That is a kernel-config limitation, not a build problem — see
[docs/KSU.md](docs/KSU.md) if you want to attack that end.

## Quick start (ready-to-use bundle)

Everything needed is in [`release/`](release/) (`Honor70Pro-GhostLock-release.tar.gz`).
You need a PC with `adb` and the phone connected over wireless debugging.

```sh
# build the bundle (or download it from the GitHub release) and run it
sh release/make-release.sh
tar xzf release/Honor70Pro-GhostLock-release.tar.gz

adb connect <phone-ip>:5555
sh Honor70Pro-GhostLock/setup.sh <phone-ip>:5555

# when it prints ROOT READY, you have a uid-0 shell
adb shell        # (or nc <phone-ip> 34567 for the root shell)
```

The launcher runs the exploit (retrying on the known "miss → reboot" case),
waits for the `chain complete` marker, and reports the result.
`release/payload/` holds the prebuilt `exploit_static` once `make-release.sh`
has run; it is not tracked in git (the binary ships as the release asset).

### Manual

```sh
adb push exploit_static /data/local/tmp/gl_sdy && adb shell chmod 755 /data/local/tmp/gl_sdy
adb shell 'cd /data/local/tmp && nohup env KSU_RUNDIR=/data/local/tmp/glrun \
           /data/local/tmp/gl_sdy > /data/local/tmp/gl.log 2>&1 &'
# wait ~40-90 s, then:  nc <phone-ip> 34567   →  uid=0 shell
```

## Repository layout

```
exploit/    GhostLock PoC source (Android arm64) + build system.
            src/targets/mtk-SDY-AN00_8.0.0.220/target.h is the new device table.
ksu/        KernelSU build scripts + the kernelsu.ko built for this kernel
            (it loads, but see docs/KSU.md for why it cannot be used).
tools/      Device-side helpers: load_ko, kmsg_dumper (sources + aarch64
            binaries), ksud, magiskpolicy, ksu_rules, ksu_loader.tmpl, and the
            root-shell driven loader scripts.
docs/       How the port was made: FIRMWARE.md (getting the kernel image),
            OFFSETS.md (offset derivation), CARRIER.md (stack carrier),
            KSU.md (the CONFIG_KPROBES blocker and what is left to try).
release/    setup.sh (PC-side driver), make-release.sh, README.txt, and the
            prebuilt payload that the GitHub release attaches.
```

## How the port was made (short version)

1. **Recovered the exact vendor kernel image.** The device's boot partition is
   not readable and no public firmware exists, but the *official OTA* does:
   the HONOR OTA check the device itself performs discloses its package
   (`.../TDS/data/bl/files/v880324/f1/full/update_full_base.zip`). The
   Virtual-A/B `payload.bin` inside it contains a **full `boot` image**, whose
   kernel is byte-for-byte the kernel the phone runs (same version string and
   build date). See [docs/FIRMWARE.md](docs/FIRMWARE.md).
2. **Derived every offset from that image** (`vmlinux-to-elf` for the embedded
   kallsyms + `objdump` disassembly for the struct offsets) and wrote them into
   `exploit/src/targets/mtk-SDY-AN00_8.0.0.220/target.h`. See
   [docs/OFFSETS.md](docs/OFFSETS.md).
3. **Re-derived the kstack carrier geometry.** The original pselect carrier
   lands ~0x88 bytes *above* the stale futex waiter on this kernel and cannot
   reach it; the IPv4 `setsockopt(MCAST_JOIN_SOURCE_GROUP)` `group_source_req`
   copy lands at `S-0x360`, i.e. **shift = 15**, which covers the waiter's ten
   words exactly. See [docs/CARRIER.md](docs/CARRIER.md).
4. Built the exploit as a static aarch64 binary (see
   `exploit/Makefile`, `PROJECT=mtk-SDY-AN00_8.0.0.220`).

## Boot-persistent wireless adb (port 5555)

This device's build has no unprivileged way to enable TCP adb at boot
(`setprop persist.adb.tcp.port` is refused, even as this root). The trick that
works: append the property to the property database directly —
`/data/property/persistent_properties` is a protobuf file
(`repeated {name=1,value=2}`), so appending
`0a1c 0a14 "persist.adb.tcp.port" 1204 "5555"` makes init load
`persist.adb.tcp.port=5555` on every boot. Verified across reboots.

## Why KernelSU does not work here

`kernelsu.ko` **can be built and loaded**: the module resolves all 203 of its
undefined symbols through a fake `/proc/kallsyms` (HONOR strips `commit_creds`
and friends), `init_module` succeeds, and `ksud`'s stages run. But the moment
KSU's hooks are live, every `execve` returns `ENOSYS` and the system is dead.

Root cause: `CONFIG_KPROBES` is **not set** in this kernel's config while
KernelSU requires it. The details, the evidence and the ideas that remain
untried are in [docs/KSU.md](docs/KSU.md) — this is the one piece that is
genuinely stuck, and a good place for someone else to take over.

## Warning

For security research **on your own device** only. Running this tool gives a
process full root and turns SELinux permissive; a failed attempt reboots the
phone (the kernel is built with `CONFIG_PANIC_ON_OOPS=y`, so there is no
"harmless miss"). **USE AT YOUR OWN RISK** — no warranty of any kind. Back up
first. See [LICENSE](LICENSE) (Apache-2.0 for the exploit; the files under
`ksu/` are GPL-2.0).

## Credits

- [CyberMeowfia / IonStack](https://github.com/NebuSec/CyberMeowfia) — the
  upstream PoC this port derives from
- The GhostLock project for HONOR 80 GT (AGT-AN00) — target tables, KSU flow,
  loader design
- [KernelSU](https://github.com/tiann/KernelSU) and
  [Magisk](https://github.com/topjohnwu/Magisk) (`magiskpolicy`)

## License

- `exploit/`, `docs/`, top-level docs: **Apache License 2.0** (see LICENSE),
  same as the upstream PoC.
- `ksu/`: **GPL-2.0** (see `ksu/LICENSE`).
- `tools/magiskpolicy`: GPL-3.0 (unmodified, from Magisk).
