# 2026-11-28 开机失败：release 里的 initramfs 只有 16 字节的 busybox

## 现象

`fastboot boot boot-hotdogb-netboot.img` 后：

- 屏幕一直在滚动刷字，画面花
- 手机上**没有出现 USB 网卡**（Windows 上看不到 172.16.42.x 的接口）
- NBD 服务端日志只有一行 `exporting ...`，**一次连接都没有**

没有 USB gadget、也没有任何 NBD 读写，说明内核在 userspace 之前就停了，问题在 boot.img 里，
不在 rootfs。

## 定位

把 release 的 boot.img（v2 头）拆开，比较两个镜像的 ramdisk：

| 镜像 | ramdisk (gzip) | 解包后 | bin/busybox.static |
|---|---|---|---|
| release `boot-hotdogb-netboot (1).img`（11-28 11:51） | 49,355 B | 146,729 B | **16 B** |
| `new/boot-test.img`（11-27 22:45，能启动） | 1,081,096 B | 2,127,433 B | 1,980,720 B |

那个 16 字节的文件内容是：

```
BUSYBOXDIR=/bin
```

`initramfs/init` 的 shebang 是 `#!/bin/busybox.static sh`。bin/busybox.static 不是 ELF，
`execve` 失败，内核找不到 init，`panic=0` 于是停在 panic 里（屏幕上滚的就是这个），
gadget 自然从未建立。

## 根因

Debian 的 `busybox-static_*.deb` 里有**两个**叫 `busybox` 的文件：

```
     16  usr/share/initramfs-tools/conf-hooks.d/busybox      <- initramfs-tools 的钩子配置
1980720  usr/bin/busybox                                    <- 真正的静态二进制
```

CI 里是这么挑的：

```sh
BB=$(find busybox -type f -name busybox | head -1)
```

`find` 的返回顺序取决于下载解包后文件系统里的目录顺序，`usr/share` 排在 `usr/bin` 前面时
就挑到了那个 16 字节的配置片段。1.37.0-6+b10 的 tar 归档里 `usr/bin/busybox` 在前，
1.38.0-3+b2 两个都在，而 runner 上的目录顺序让 conf-hook 排到了前面 —— 所以这版才炸。

这类失败是静默的：构建全绿，镜像能刷进去，只是永远起不来。

## 修复

1. `busybox-pack` 作业按大小挑，并确认是 aarch64 ELF：

   ```sh
   BB=$(find busybox -type f -name busybox -size +1M | head -1)
   file "$BB" | grep -q 'ARM aarch64'
   ```

2. `busybox` 作业在发布 artifact 前断言里面至少有 1 MB 的 busybox，缺了直接失败。

3. `tools/build_initramfs.sh` 自己校验：大小 > 500 KB、ELF 魔数 `7f454c46`、
   `e_machine = 0xb7`（aarch64）。这样无论谁用什么路径传进来，都不可能再打包出一个
   没有 `/bin/sh` 的 initramfs。

   两个用例都跑过：`BUSYBOXDIR=/bin`（16 B）报
   `busybox is only 16 bytes, that cannot be the binary`；真二进制正常出 1,080,793 B 的 cpio.gz。

## 本地绕过

为了不等 CI，用 release 的内核 + DTB + 11-27 那份验证过的 busybox 重新打了一个
`boot-fixed.img`（47,509,504 B，cmdline 与 release 一致，含 `hotdogb.netboot=1`）。
这是同样的内核和 rootfs，只换掉了坏掉的 initramfs，用来验证 WiFi 链路。
