#!/system/bin/sh
# Root-shell driven KSU activation for SDY-AN00 (5.10.66 MTK).
# Runs INSIDE the exploit's root shell (uid=0, u:r:kernel:s0, permissive).
# Freezes Honor's antiroot daemon (hisecd) for the load window so it cannot
# hard-reset / wedge the device, then loads kernelsu.ko and runs ksud.
export PATH=/system/bin:/system/xbin:/vendor/bin:$PATH
RD=/data/local/tmp/glrun_perm
KT=/data/local/tmp/ksu_run_perm
OUT=$KT/ksu_load.log
> $OUT
{
  echo "=== freeze-hisecd KSU load ==="; id; getenforce
  . $RD/ksu_runtime.env
  echo "COMMIT_CRED_RT=$COMMIT_CRED_RT BOOTID_CTL_RT=$BOOTID_CTL_RT BOOTID_BUF_RT=$BOOTID_BUF_RT"
  hp=$(pidof hisecd); [ -n "$hp" ] && kill -STOP $hp && echo "hisecd FROZEN pid=$hp"
  echo 0 > /proc/sys/kernel/kptr_restrict
  { echo "${COMMIT_CRED_RT#0x} T commit_creds"; cat /proc/kallsyms; } > $KT/fake_kallsyms
  mount --bind $KT/fake_kallsyms /proc/kallsyms && echo "fake kallsyms bound"
  $KT/load_ko $KT/kernelsu.ko "allow_shell=1 bootid_ctl=$BOOTID_CTL_RT bootid_buf=$BOOTID_BUF_RT"
  echo "load_ko_rc=$?"
  grep -i kernelsu /proc/modules
  $KT/ksud post-fs-data; echo "post-fs-data rc=$?"
  $KT/ksud services;     echo "services rc=$?"
  $KT/ksud boot-completed; echo "boot-completed rc=$?"
  $KT/ksud install;      echo "install rc=$?"
  dmesg | grep -i 'KernelSU:' | tail -6
  echo "=== KSU active; hisecd left FROZEN on purpose (prevents the antiroot wedge) ==="
  echo KSU_LOAD_DONE
} >> $OUT 2>&1
