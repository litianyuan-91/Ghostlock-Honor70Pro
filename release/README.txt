GhostLock for HONOR 70 Pro (SDY-AN00) — ready-to-use bundle
===========================================================

This is the prebuilt exploit payload. It gives a TEMPORARY root (uid 0) plus
SELinux permissive and sig_enforce=0 for the current boot; a reboot restores
everything. It is a research PoC — run it on your own device only.

Requirements
------------
  * a PC with `adb` in PATH
  * the phone on wireless debugging, reachable as <ip>:<port>
    (this device keeps port 5555 across reboots; see the repository README)
  * the phone running kernel 5.10.66-android12-9-ge639f4185278
    (MagicOS 8.0.0.220)

Usage
-----
  sh setup.sh 192.168.1.30:5555

  setup.sh connects, checks the kernel, stages payload/exploit_static to
  /data/local/tmp/glrun_sdy on the phone, launches it detached, and waits for
  the "chain complete" marker. When it prints ROOT READY:

      nc 192.168.1.30 34567      # uid=0 shell over TCP

  A failed attempt reboots the phone (the kernel has CONFIG_PANIC_ON_OOPS=y,
  so there is no harmless miss). setup.sh notices and retries automatically,
  up to 4 attempts; if it gives up, just run it again.

Contents
--------
  setup.sh                PC-side driver (POSIX sh)
  payload/exploit_static  static aarch64 exploit, built from ../exploit/
  payload/target.h        the offset table this binary was built from

  sha256(payload/exploit_static) =
    488c69cc3f7fc2c83a8a610cbee8f52a5ca890aa3141954fba66774b576c31ee

  Rebuild it yourself with:
    cd exploit && CC=aarch64-linux-gnu-gcc make PROJECT=mtk-SDY-AN00_8.0.0.220 bin
  (reproduces the same exploit_static, sha256 above)

KernelSU
--------
Not included. It is built (see the repository's ksu/ directory) but is NOT
usable on this kernel: the kernel is compiled without CONFIG_KPROBES, which
KernelSU requires, and KSU's exec hook makes every execve return ENOSYS. The
evidence and the paths that remain open are in docs/KSU.md.

Warning
-------
For security research on your own device only. Running this gives a process
full root and turns SELinux permissive; a failed attempt reboots the phone.
USE AT YOUR OWN RISK — no warranty of any kind. Back up first.
