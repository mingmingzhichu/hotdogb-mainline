# WCN3990（Wi-Fi）固件

> **版权归 Qualcomm / OnePlus**，这里只用于本机 bring-up 验证，不要再分发。

| 文件 | 目标路径 | 来源 | 说明 |
|---|---|---|---|
| `ath10k/WCN3990/hw1.0/firmware-5.bin` | 同左 | linux-firmware | 60 字节的桩文件，内容就是版本号 |
| `ath10k/WCN3990/hw1.0/board-2.bin` | 同左 | `firmware-oneplus-sm8150` | 1 002 336 B，板级数据（BDF）容器 |
| `qcom/sm8150/oneplus7/wlanmdsp.mbn` | 同左 | **本机 `modem_a` 分区** | 4 070 084 B，见下 |
| `qcom/sm8150/oneplus7/modem.mbn` | 同左 | `firmware-oneplus-hotdog` | 75 959 184 B，MPSS 主镜像 |
| `qcom/sm8150/oneplus7/*.jsn` | 同左 | `firmware-oneplus-hotdog` | 与 `modem.mbn` 同目录，缺了 MPSS 起不来 |

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

## 部署

`modem.mbn` + `.jsn` 由 `/bin/wifi_up.sh` 从 USB LUN 拷进去（75 MB，塞不进 initramfs）；
`wlanmdsp.mbn` 由 `/init` 从 `modem_a` 提取；`board-2.bin` / `firmware-5.bin` 也从 LUN 拷。
