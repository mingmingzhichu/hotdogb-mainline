# WCN3990（Wi-Fi）固件


| 文件 | 目标路径 | 来源 | 说明 |
|---|---|---|---|
| `ath10k/WCN3990/hw1.0/firmware-5.bin` | 同左 | Debian `firmware-atheros` | WCN3990 ath10k 固件 |
| `ath10k/WCN3990/hw1.0/board.bin` | 同左 | **本机 `modem_a` 分区**的 `bdwlan.bin` | 设备板级数据；作为 `board-2.bin` 失败时的回退 |
| `qcom/sm8150/oneplus7/wlanmdsp.mbn` | 同左；也复制到 ath10k 目录 | **本机 `modem_a` 分区** | 4 070 084 B，见下 |
| `qcom/sm8150/oneplus7/modem.mbn` | 同左 | 7T Pro `firmware-oneplus-hotdog`（MPSS.HE.1.0.c11.1-00007） | **DTS 请求此单文件**；唯一真机验证可用的 MPSS |
| `qcom/sm8150/oneplus7/modem.mdt` + `modem.b*` | 同左 | 本机 `firmware/firmware_mnt` | 本机分片 MPSS；保留作对照，实机会每 ~40 s crash-loop |
| `qcom/sm8150/oneplus7/*.jsn` | 同左 | 本机 `firmware/firmware_mnt` | pd-mapper protection-domain 映射 |
| `qcom/sm8150/adsp.mdt` + `adsp.b*` | 同左 | 本机 `firmware/firmware_mnt` | ADSP 固件 |
| `qcom/sm8150/oneplus7/slpi.mdt` + `slpi.b*` | 同左 | 本机 `firmware/firmware_mnt` | SLPI 固件 |

## `wlanmdsp.mbn` 必须用本机的

`modem_a` 是 **FAT16**，固件在 `image/` 下（分片格式 `modem.mdt` + `modem.b00…b31`，
另有完整的 `image/wlanmdsp.mbn`）。`/init` 会只读挂载它并把这个文件拷到
`/lib/firmware/qcom/sm8150/oneplus7/`。

用 7T Pro 固件包里的那份（4 079 872 B）会让 ath10k 的 SCM 分配失败：

```
ath10k_snoc 18800000.wifi: failed to assign msa map permissions: -22
```

换成同型号的之后就正常。**不要**用 `qcom,msa-fixed-perm` 绕过：跳过分配会让 WLAN 子系统
访问未授权内存，整机直接进 EDL（9008）。

校验值（本机）：

```
52afd2afba7d40333158f93778cdbfff  wlanmdsp.mbn  (4070084 B)
```

## Rootfs 构建

`tools/build_debian_rootfs.sh` 从 Debian `non-free-firmware` 安装
`firmware-atheros`，提供 `firmware-5.bin` 等通用文件。脚本默认从项目内
`firmware/firmware_mnt/` 读取本机 modem、WLAN、ADSP、SLPI 固件；也可用
`HOTDOGB_FIRMWARE_BACKUP` 指定另一个包含 `firmware_mnt/` 的目录。
设备专用固件目录由 `.gitignore` 排除，不会随 Git 分发；公开 CI 不含这些文件。

MPSS 用经验证的单文件 `modem.mbn`（7T Pro，`bfaac8c1…`，75 959 184 B）。
本机 `modem_a` 里的分片 `modem.mdt` + `modem.b*` 虽然也打包进 rootfs 作对照，但
2026-11-27 真机验证：DTS 指向 `.mdt` 时 MPSS 每 ~40 s `crash detected ... recovering`，
QRTR 上没有任何服务，ath10k 无从加载。DTS 与构建脚本现已改回 `.mbn`。
Wi-Fi 启动还需要 `rmtfs`、`pd-mapper`、`tqftpserv` 按顺序运行；仅把固件放进
rootfs 不会自动启动无线栈。

## 预置的运行时数据（2026-11-26）

三个服务要用的设备专用数据过去是运行时从 UFS 分区拷的，netboot 路径下
`/dev/disk/by-partlabel` 不可靠、persist 也没挂，导致 MPSS 发布不了 WLFW
服务、ath10k 一直等。现在把它们一次性 dump 出来打包进 rootfs：

| 目录 | 来源 | rootfs 目标 |
|---|---|---|
| `firmware/persist-wlan/` | `persist` 的 `wlan_mac.bin`、`bdwlan.bin`、`wlan/*` | `/var/lib/tqftpserv/` |
| `firmware/rmtfs-efs/` | `modemst1/2`、`fsg`、`fsc` 分区镜像 | `/var/lib/hotdogb/rmtfs/{modem_fs1,modem_fs2,modem_fsg,modem_fsc}` |
| `firmware/wifi-board/board-2.bin` | 真机验证过的板级数据 | `ath10k/WCN3990/hw1.0/board-2.bin`（覆盖 Debian 通用包） |

`hotdogb-radio.sh` 据此把 EFS 副本复制到 tmpfs，用可写方式起 `rmtfs -o <dir>`
（systemd 的 `-P -r` 是只读的，调制解调器同步 NV 时会失败）。这些目录和
`firmware_mnt/` 一样随仓库分发，CI 构建也会把完整 Wi-Fi 数据打进 rootfs。

## 模块必须和 Image 同一次构建（2026-11-28）

rootfs 里不能放“别处编好的” ath10k `.ko`。曾经有一版 `firmware/wifi-modules/`，
是从 7.0.0 那次 bring-up 里挑出来的 5 个“验证过”的模块，CI 拿它覆盖内核自己
编出来的那份，结果在 7.3.3 上 `insmod` 直接失败：

```
ath10k_snoc: version magic '7.0.0-sm8150-g8e126dbc4044-dirty SMP preempt mod_unload aarch64'
             should be '7.3.3-sm8150 SMP preempt mod_unload aarch64'
```

模块其实一个都没加载上，`wlan0` 当然永远不出现，而日志里只有一句
`insmod ath10k_snoc failed`。那批文件已经删掉；现在 CI 只装
`kernel-out/modules.tar.gz` 里的模块，并在 `Integrate kernel modules` 那一步对
镜像里每个 `.ko` 做 `modinfo -F vermagic` 比对，对不上就直接失败。

结论：Wi-Fi 驱动的问题只能在驱动里解决，换二进制绕不过去。
