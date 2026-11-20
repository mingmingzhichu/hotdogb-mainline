# WCN3990（Wi-Fi）固件


| 文件 | 目标路径 | 来源 | 说明 |
|---|---|---|---|
| `ath10k/WCN3990/hw1.0/firmware-5.bin` | 同左 | Debian `firmware-atheros` | WCN3990 ath10k 固件 |
| `ath10k/WCN3990/hw1.0/board.bin` | 同左 | **本机 `modem_a` 分区**的 `bdwlan.bin` | 设备板级数据；作为 `board-2.bin` 失败时的回退 |
| `qcom/sm8150/oneplus7/wlanmdsp.mbn` | 同左；也复制到 ath10k 目录 | **本机 `modem_a` 分区** | 4 070 084 B，见下 |
| `qcom/sm8150/oneplus7/modem.mdt` + `modem.b*` | 同左 | 本机 `firmware/firmware_mnt` | 本机分片 MPSS；DTS 请求 `.mdt` |
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

本机备份中的 MPSS 是 `modem.mdt` + 分片，而不是经验证的单文件 `modem.mbn`。
内核 DTS 已改为请求 `.mdt`；此格式尚待真机验证。Wi-Fi 启动还需要
`rmtfs`、`pd-mapper`、`tqftpserv` 按顺序运行；仅把固件放进 rootfs 不会自动启动无线栈。
