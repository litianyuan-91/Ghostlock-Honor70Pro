# KernelSU on SDY-AN00: built, loads — and why it still cannot be used

This is the one part of the port that is genuinely stuck. The exploit works;
KernelSU does not, and the reason is a hard, verifiable kernel-configuration
limit rather than a build mistake. Everything below is reproducible from the
device and from Honor's own open-source kernel package for this device.

## What does work

`kernelsu.ko` here is **not** a stock GKI build — GKI struct layouts do not
match Honor's kernel — so it was rebuilt from the device's own kernel source
with the device's exact `/proc/config.gz` (`ksu/build_inner.sh`). With that
build:

- the module **links and loads**: `init_module` returns 0 and the module shows
  up in `/proc/modules`;
- all **203 undefined symbols resolve** through a fake `/proc/kallsyms` — Honor
  strips `commit_creds` from the printed tables (see [OFFSETS.md](OFFSETS.md)),
  so `load_ko` prepends it, then rewrites the `.ko`'s `SHN_UNDEF` entries to
  `SHN_ABS` against that table;
- the `ksud` stages (`post-fs-data`, `services`, `boot-completed`, `install`)
  all exit 0;
- the SELinux policy is injected with `magiskpolicy --live` *before* the load,
  and `ksu/init-bootid.patch` makes the module restore the `boot_id` buffer the
  exploit hijacked.

## The failure

The moment KSU's hooks go live, **every `execve` returns `ENOSYS`** and the
system can no longer spawn processes. The UI freezes ("无法创建新进程" /
"无法创建新进程"), nothing new can start, and only a hard reset recovers it.
Because the kernel is built with `CONFIG_PANIC_ON_OOPS=y`, some intermediate
states reboot on their own first.

## Root cause: `CONFIG_KPROBES` cannot be enabled on this kernel

KernelSU's own `Kconfig` is explicit (`kernel/Kconfig` in the KernelSU tree):

```
config KSU
	tristate "KernelSU function support"
	depends on KPROBES && EXT4_FS
	help
	  Enable kernel-level root privileges on Android System.
	  Requires CONFIG_KPROBES for kernel hooking support.
```

and its arch hook manager includes `<linux/kprobes.h>` and registers probes
(`kernel/hook/syscall_hook_manager.c`, `kernel/hook/arm64/syscall_hook.c`). The
arm64 exec hook is a **kprobe on the exec path**; with no kprobes the hook never
installs correctly and the syscall wrapper returns `-ENOSYS`.

The device's own config (`/proc/config.gz`, i.e. `CONFIG_IKCONFIG_PROC`) does
not contain `CONFIG_KPROBES` at all — not `=y`, not `# ... is not set`; only
`HAVE_`:

```
$ zgrep -i kprobe config.gz
CONFIG_HAVE_KPROBES=y
CONFIG_HAVE_KRETPROBES=y
```

The explanation is in Honor's *own* kernel source — the MagicOS 8.0
open-source package for `SDY-AN00` (`Code_Opensource/kernel`, 5.10.66). Honor
gated `KPROBES` behind their internal debug switch:

`arch/Kconfig`:

```
config KPROBES
	bool "Kprobes"
	depends on MODULES
	depends on HAVE_KPROBES && HONOR_KERNEL_DEBUG
	default y if HONOR_KERNEL_DEBUG
	select KALLSYMS
```

`arch/arm64/Kconfig`:

```
config HONOR_KERNEL_DEBUG
	bool "Use Honor kernel debug mode"
	depends on HONOR_KERNEL
	default n
	help
	  Enable sysrq, dump mode and some deb
```

and the device config says:

```
# CONFIG_HONOR_KERNEL_DEBUG is not set
```

Kconfig does not emit a symbol whose dependencies are unmet, which is exactly
why `KPROBES` is absent from `config.gz` rather than shown as "not set".
`KRETPROBES` is gated behind the same switch (`arch/Kconfig`).

**Consequence:** this cannot be fixed by "rebuilding KSU with the right flags".
On a released production firmware `HONOR_KERNEL_DEBUG=n`, so `KPROBES` is
unreachable by design; and even if a debug kernel were built, its signature
would never match the locked bootloader, so it could not be flashed.

## Paths that remain open

KernelSU-as-a-manager is **not achievable on this kernel as shipped**. KernelSU
is not the only option, though, and the arbitrary kernel read/write the exploit
already provides opens routes that do *not* need kprobes:

1. **APatch / KernelPatch.** Built for exactly this situation: an LKM that
   installs hooks by patching kernel text at runtime (inline hooks +
   `patch_memory`), rather than depending on KPROBES, and it ships its own root
   manager. KernelSU's own `kernel/hook/arm64/patch_memory.c` is a descendant of
   the same idea. This is the most direct route to a GUI root manager.

2. **Install the exec hook by hand.** `hook/arm64/syscall_hook.c` does not
   itself need kprobes — it patches a syscall-table entry and redirects it to
   KSU's dispatcher. The kprobe dependency lives only in
   `syscall_hook_manager.c`'s *registration*. Replacing that registration with a
   direct `ksu_syscall_table[...]` patch — which the module already knows how to
   compute, and which the exploit's primitive can make writable through the
   direct map — would remove the requirement. Untried here.

3. **A userspace root manager over the temporary root.** The exploit yields a
   uid-0 shell that survives until reboot; that is enough to run a small
   `su`/policy daemon with no kernel module at all. It is not KernelSU's
   per-app profile UX, but it is a working root manager for the session.

None of these is implemented in this repository. The port's contribution is a
reliable, offline-reproducible **temporary root** on this device, plus this
written-down, evidence-backed statement of why the obvious next step
(KernelSU) is blocked and where the remaining work would start.

## Reproducing the KernelSU build

The build needs the MagicOS 8.0 open-source kernel tree for `SDY-AN00`
(5.10.66) and the device's `/proc/config.gz`:

```sh
KERNEL_SRC=/path/to/Code_Opensource/kernel \
KSU_DEVICE_CONFIG=/path/to/config.gz \
bash ksu/ksu_ko_build.sh
```

The KernelSU source is pinned to tag **v3.3.0** and three patches are applied
on first run (`init-bootid.patch`, `sepolicy-dyn-len.patch`,
`selinux-hide-backup.patch`). The result is `ksu/.build/kernelsu.ko`, copied
here as `ksu/kernelsu.ko`. `ksu/kernel.config` is the device config used as the
build default. Note that the vendored clang (`clang-r416183b`) can only be run
under `qemu` on an x86_64 host — a native `clang-18`/`aarch64-linux-gnu-gcc`
toolchain is far faster.
