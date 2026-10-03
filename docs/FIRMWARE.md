# Recovering the exact vendor kernel image

The exploit needs the offsets of the kernel the phone is actually running.
The `boot` partition is not readable from `adb shell`, the bootloader is locked
(no fastboot), and for `SDY-AN00 8.0.0.220` no public firmware image could be
found. The image is nevertheless obtainable from HONOR's own OTA servers.

## 1. Find the OTA / firmware CDN

Triggering a check from the phone's updater (`com.hihonor.ouc`) logs its
requests:

```
adb shell am start -a android.settings.SYSTEM_UPDATE_SETTINGS
adb logcat -d | grep -a HnOUC
```

which reveals (host redacted by the app, names recovered from
`/system/app/HnOUC/HnOUC.apk`'s GRS config):

```
https://update.platform.hihonorcloud.com/blversion/v1/version/check
https://update.platform.hihonorcloud.com/sp_ard_common/v2/onestopCheck.action
https://<cdn>.hihonorcdn.com/TDS/data/bl/files/v<id>/f1/full/filelist.xml
```

The CDN host is `update.hihonorcdn.com`. Version ids are enumerable; for this
device the offered update is **v880324/v880325**, and the file list is at

```
https://update.hihonorcdn.com/TDS/data/bl/files/v880324/f1/full/filelist.xml
```

`filelist.xml` gives the package (`update_full_base.zip`),
`<packageType>full</packageType>`, its size and sha256.

## 2. The package is a Virtual-A/B payload

`update_full_base.zip` contains `payload.bin` (Chrome-OS `update_engine`
format) — at zip offset `<payloadOffset>` (828 here) — plus
`payload_properties.txt`. The payload manifest is protobuf; `payload.bin`
starts with `CrAU`, version, `manifest_size` (big-endian u64) and
`metadata_signature_size` (big-endian u32).

For every partition the manifest carries `operations` with a type
(`REPLACE`, `REPLACE_XZ`, `ZERO`, `SOURCE_COPY`, `BROTLI_BSDIFF`, ...),
a data offset/length and destination extents. **A "full" package carries a
full `boot` partition** — exactly what is needed.

Only the boot partitions' bytes are needed, so instead of downloading the
whole 6.6 GB file, fetch the relevant byte range directly:

```sh
# op ranges come from the parsed manifest; zip file offset =
#   payloadOffset + 24 + manifest_size + signature_size + op.data_offset
curl -r <lo>-<hi> -o bootraw.bin \
  https://update.hihonorcdn.com/TDS/data/bl/files/v880324/f1/full/update_full_base.zip
```

then place each decompressed operation at its destination extents to
reconstruct `boot.img` (v4 header, `ANDROID!`).

## 3. Result

The kernel inside that `boot.img` is a gzip'd arm64 Image that reports

```
Linux version 5.10.66-android12-9-ge639f4185278 (build-user@build-host)
  (Android (7284624, based on r416183b) clang version 12.0.5 ...)
  #1 SMP PREEMPT Wed Oct 29 10:08:49 UTC 2025
```

which is **the same kernel the phone boots** (compare `uname -r` and
`/proc/version`). That image is the source of every offset in
`exploit/src/targets/mtk-SDY-AN00_8.0.0.220/target.h`.

The same technique also extracts `lk`, `preloader`, `dtbo`, `tee`, ... —
`lk` (the bootloader) contains the kernel load address constant used for
`P0_KERNEL_PHYS_LOAD` (see [OFFSETS.md](OFFSETS.md)).

## Notes

- The device's current firmware (`8.0.0.220`) full package was not needed: only
  the *boot* partition matters, and the OTA does not change the kernel between
  the current and offered builds (verified by the version string).
- HONOR's CDN throttles long single connections; resume with explicit
  `curl -r <offset>-` (note the payload lives at zip offset 828, so a naive
  `-C -` resume desynchronises by 828 bytes).
