# 不归内核管、留给 Debian 的部分

内核只提供机制，策略和用户态服务应该由发行版提供。下面这些现在是 initramfs 里的权宜做法，
Debian/rootfs 起来之后应该删掉，换成标准做法。

| 事项 | 现在的临时做法 | Debian 里该怎么做 |
|---|---|---|
| MAC 地址 | `wifi_up.sh` 从 `persist` 的 `wlan_mac.bin` 拼出地址再 `ip link set` | udev rule + systemd-networkd 的 `.link`（`MACAddress=`），或 NetworkManager；数据源仍然是 `persist` |
| 关联 / DHCP | 没有，只能扫 | `wpa_supplicant` + NetworkManager（或 iwd）+ DHCP 客户端 |
| 国家码 / `regulatory.db` | 文件缺失，`cfg80211` 退化成 US，5 GHz 大部分信道被禁 | 装 `wireless-regdb`，`iw reg set CN`（或 cmdline `cfg80211.ieee80211_regdom=CN`） |
| `rmtfs` / `pd-mapper` / `tqftpserv` | initramfs 里手写脚本起 | pmOS 现成的包 + service 单元，不需要自己维护 |
| 亮度曲线 / 自动亮度 | 线性映射 | 内核只给原始亮度，曲线放 userspace；或者把原厂曲线搬进面板驱动（二选一） |
| 触摸手势、校准 | 无 | libinput |
| 串口 gadget 控制台 `con` | initramfs 里自建 | 正常 getty / SSH，`con` 删掉 |
| 75 MB 固件每次开机推一遍 LUN | `push_wifi.ps1` | 固件放 `/lib/firmware`（rootfs 里），不再需要 LUN |

## 仍然必须在内核里解决的

- **LCDB 偏压**（PM8150L 的 `qpnp-lcdb`）。现在屏幕能亮是靠 ABL 留下的状态，没有驱动接管；
  彻底断电（拔电池 / EDL）之后大概率就不亮了。
- 亮度曲线如果要精确，改面板驱动。
- `dsi_err_worker: status=…` 和 `msm_dsi_host_cmd_rx:Invalid response cmd` 的日志噪声：
  上游化时顺手改（`DSI_ERR_STATE_ACK` 被定义成 `0x0000`，所以 ACK 错误和"无错误"打印一样），
  不影响使用，不单独修。
