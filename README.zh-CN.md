[English](README.md) | 中文

# 荣耀 70 Pro (SDY-AN00) 的 GhostLock 移植

把 **GhostLock**（CVE-2026-43499，内核 `rtmutex` `remove_waiter` 路径的 UAF；
最初针对荣耀 80 GT / AGT-AN00）移植到 **荣耀 70 Pro（SDY-AN00）**：

| | |
|---|---|
| 设备 | 荣耀 70 Pro `SDY-AN00`，SoC **联发科天玑 8000（MT6895）** |
| 系统 | MagicOS 8.0.0.220（`C00E220R5P7`），Android 14 |
| 内核 | **5.10.66-android12-9-ge639f4185278**（`#1 SMP PREEMPT Wed Oct 29 10:08:49 UTC 2025`） |
| 结果 | **临时 root（uid 0）+ SELinux permissive + `sig_enforce=0`** —— 真机验证通过 |

这是**临时 root**：一次运行会把一个常驻 helper 进程的内核凭据翻成 root，并关掉
模块签名校验；**重启即复原**。仅供安全研究，务必看下面的警告。

## 现状

| 部分 | 状态 |
|---|---|
| GhostLock 利用链（SDY-AN00） | ✅ **可用 / 已真机验证**（`exploit/`、`release/`） |
| root shell（常驻 helper，TCP 34567） | ✅ 可用 |
| 开机自动 5555 无线调试 | ✅ 可用（见下） |
| KernelSU（已编出 `kernelsu.ko` 并能加载） | ⚠️ 模块能加载，但**会把设备搞死** |
| KernelSU 作为真正的 root 管理器 | ❌ **在这颗内核上不可行**，详见 [docs/KSU.md](docs/KSU.md) |

**KSU 卡点一句话**：这台荣耀内核编译时**没开 `CONFIG_KPROBES`**（只有
`CONFIG_HAVE_KPROBES=y`），而 KernelSU 的 `Kconfig` 明确要求
`CONFIG_KPROBES` 才能做内核 hook。缺了它，KSU 的 `execve` hook 会返回
`ENOSYS`，整个系统就再也起不了新进程。这是内核配置层面的限制，不是编译问题
——想继续啃的话看 [docs/KSU.md](docs/KSU.md)。

## 快速使用（即用包）

一切都在 [`release/`](release/)（`Honor70Pro-GhostLock-release.tar.gz`）里。需要
一台装了 `adb` 的电脑 + 手机开好无线调试。

```sh
# 打包（或直接从 GitHub Release 下载）后运行
sh release/make-release.sh
tar xzf release/Honor70Pro-GhostLock-release.tar.gz

adb connect <手机IP>:5555
sh Honor70Pro-GhostLock/setup.sh <手机IP>:5555
# 打印 READY 后： nc <手机IP> 34567   （uid=0 的 shell）
```

脚本会自动：跑 exploit（遇到已知的"没中→重启"会重试）→ 等 `chain complete`
标记 → 报告结果。
`release/payload/` 里是编好的 `exploit_static`（不进 git，作为 Release 附件发布）。

### 手动

```sh
adb push exploit_static /data/local/tmp/gl_sdy && adb shell chmod 755 /data/local/tmp/gl_sdy
adb shell 'cd /data/local/tmp && nohup env KSU_RUNDIR=/data/local/tmp/glrun \
           /data/local/tmp/gl_sdy > /data/local/tmp/gl.log 2>&1 &'
# 等 40~90 秒，然后  nc <手机IP> 34567   就是 uid=0
```

## 目录结构

```
exploit/    GhostLock 源码（Android arm64）+ 构建系统；
            src/targets/mtk-SDY-AN00_8.0.0.220/target.h 是新机型偏移表
ksu/        KernelSU 构建脚本 + 为本内核编出的 kernelsu.ko（能加载，
            但见 docs/KSU.md 为什么用不了）
tools/      设备端辅助：load_ko / kmsg_dumper（源码 + aarch64 二进制）、
            ksud、magiskpolicy、ksu_rules、ksu_loader.tmpl 及加载脚本
docs/       移植过程：FIRMWARE.md（取内核镜像）、OFFSETS.md（偏移推导）、
            CARRIER.md（栈载具）、KSU.md（CONFIG_KPROBES 卡点与后续思路）
release/    setup.sh（PC 端驱动）、make-release.sh、README.txt，
            以及 GitHub Release 要附带的预编译产物
```

## 移植是怎么做的（简版）

1. **拿到与真机完全一致的内核镜像。** 手机 boot 分区读不了、网上也没有公开固件，
   但**官方 OTA 可以**：设备自己发起的 OTA 检查会暴露包地址
   （`.../TDS/data/bl/files/v880324/f1/full/update_full_base.zip`）。里面的
   Virtual-A/B `payload.bin` 含有**全量 `boot` 镜像**，而那个内核与手机正在运行的
   内核**逐字节同版本**（版本串、编译时间完全一致）。见 [docs/FIRMWARE.md](docs/FIRMWARE.md)。
2. **从镜像里推出全部偏移**（用 `vmlinux-to-elf` 解析内嵌 kallsyms，用 `objdump`
   反汇编取结构体偏移），写入新 target。见 [docs/OFFSETS.md](docs/OFFSETS.md)。
3. **重推栈载具几何。** 原项目的 pselect 载具在这颗内核上落在 stale futex waiter
   **上方约 0x88 字节**，够不到；IPv4 的
   `setsockopt(MCAST_JOIN_SOURCE_GROUP)` 的 `group_source_req` 拷贝落在 `S−0x360`，
   即 **shift = 15**，正好完整覆盖 waiter 的 10 个 word。见 [docs/CARRIER.md](docs/CARRIER.md)。
4. 编成静态 aarch64 二进制（`exploit/Makefile`，`PROJECT=mtk-SDY-AN00_8.0.0.220`）。

## 开机自动 5555 无线调试

这个系统没有免 root 的开机开 TCP adb 手段（`setprop persist.adb.tcp.port` 即使
以这个 root 身份也会被拒）。可用的办法是直接改属性数据库：
`/data/property/persistent_properties` 是 protobuf（`repeated {name=1,value=2}`），
在文件末尾追加一条
`0a1c 0a14 "persist.adb.tcp.port" 1204 "5555"` 即可让 init 每次开机都加载
`persist.adb.tcp.port=5555`。已跨重启验证有效。

## 为什么 KernelSU 在这里不行

`kernelsu.ko` **能编、能加载**：模块通过伪造的 `/proc/kallsyms` 解析了全部 203 个
未定义符号（荣耀把 `commit_creds` 之类名字抹掉了），`init_module` 成功，
`ksud` 各阶段也能跑。但 KSU 的 hook 一生效，**所有 `execve` 都返回 `ENOSYS`**，
系统随即瘫痪。

根因：这颗内核的配置里**没有 `CONFIG_KPROBES`**，而 KernelSU 需要它。
证据、过程以及"还没试完"的思路都写在 [docs/KSU.md](docs/KSU.md)——这是唯一
真正卡住的部分，也是最适合别人接手的地方。

## 警告

仅供在**自己的设备**上做安全研究。运行本工具会给进程完整 root 权限、并把
SELinux 变为宽容模式；失败时手机会重启（内核开了 `CONFIG_PANIC_ON_OOPS=y`，
不存在"无害的失败"）。**使用风险自负**，不提供任何担保，先备份。
见 [LICENSE](LICENSE)（exploit 部分 Apache-2.0；`ksu/` 下为 GPL-2.0）。

## 致谢

- [CyberMeowfia / IonStack](https://github.com/NebuSec/CyberMeowfia)（上游 PoC）
- [GhostLock-H80GT] （https://github.com/yakidango-official/GhostLock-H80GT）
- [KernelSU](https://github.com/tiann/KernelSU)、
  [Magisk](https://github.com/topjohnwu/Magisk)（`magiskpolicy`）

## 许可证

- `exploit/`、`docs/`、顶层文档：**Apache License 2.0**（见 LICENSE），与上游一致。
- `ksu/`：**GPL-2.0**（见 `ksu/LICENSE`）。
- `tools/magiskpolicy`：GPL-3.0（未修改，来自 Magisk）。
