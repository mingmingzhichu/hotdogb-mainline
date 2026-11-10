# 一加 7T (hotdogb) 主线内核：显示 + 触屏支持

给 OnePlus 7T（`hotdogb`，SM8150）主线内核加的两块东西：

1. **显示**：DPU 5.0 + DSI0 + 7nm PHY + 三星 SOFEF03F 面板（1080×2400 AMOLED，DSC 压缩，命令模式）
2. **触屏**：Synaptics S3706（RMI4 协议，I2C）

原厂 dtbo 里这两块的配置都已经反解出来，参数不是猜的：初始化序列、DSC 的 PPS、时序、GPIO 全部来自 `dtbo_a` 里的原厂节点。

---

## 目录

```
patches/    按顺序编号的补丁，`git am` 即可
configs/    内核配置片段（merge_config.sh 用）
docs/       实现说明、参数来源、排查方法
reference/  从原厂 dtbo 提取的面板节点原文（数据来源，仅供对照）
firmware/   GPU 需要的三份固件（Adreno 640：SQE / GMU / ZAP），含部署说明
tools/      从原厂节点重新生成面板驱动的脚本
initramfs/  最小 init（串口 gadget + 命令服务），CI 用它打包 boot.img
boot/       32 字节空 DTBO（跑主线前必须刷，见"启动前"）
```

## 补丁清单

| # | 补丁 | 内容 |
|---|---|---|
| 0000 | `arm64: dts: qcom: sm8150: add the OnePlus 7T (hotdogb)` | 板级 DTS、SoC dtsi 的 APR/q6afe/q6asm/q6adm、SLIMbus、sound、MDSS reset、pm8150b charger/fg |
| 0001 | `dt-bindings: display: panel: add Samsung SOFEF03F` | 新增 YAML binding |
| 0002 | `drm/panel: add driver for the Samsung SOFEF03F DSC panel` | 新驱动 + Kconfig/Makefile |
| 0003 | `Input: rmi4 - honour the reset-gpios property` | 让 rmi4 真正去拉复位脚 |
| 0004 | `arm64: dts: ...: display, touch, keys, battery` | 板级 compatible、DPU/DSI/PHY/面板（去掉 simplefb）、i2c17 上的 S3706、音量键、电量计 |
| 0005 | `usb: dwc3: add snps,dma-mask-32bit for 32-bit interconnects` | 用 DT 属性描述 32 位互连，core 按属性设置 DMA mask |
| 0006 | `dt-bindings: sound: add the NXP TFA9874 amplifier` | 新增 YAML binding |
| 0007 | `ASoC: tfa9874: add the NXP TFA9874 speaker amplifier` | 新 codec 驱动 + Kconfig/Makefile |
| 0008 | `arm64: dts: ...: enable audio and the speaker amplifiers` | WCD9340 on SLIMbus、两颗 TFA9874、QUATERNARY_MI2S_RX、声卡 DAI link |
| 0009 | `ASoC: qcom: add the SM8150 machine driver` | SM8150 声卡驱动（SLIMbus 的 WCD9340 + QUATERNARY_MI2S 扬声器） |
| 0010 | `dt-bindings: regulator: qcom,rpmh: document qcom,no-readback` | 新增 YAML 属性说明 |
| 0011 | `regulator: rpmh: allow platforms to skip voltage/state readback` | 固件不交 read 通道时用缓存值，避免 TCS 被占死 |
| 0012 | `arm64: dts: qcom: hotdogb: skip the RPMh regulator readback` | 在 pm8150/pm8150l/pm8009 上打开 `qcom,no-readback` |

补丁基于上游稳定版 `linux-7.3.3`（kernel.org，`linux-7.3.3.tar.xz`）。

**没有包含的东西**（故意的）：

- 早期为了让机器启动起来打的一堆调试/权宜改动 —— `head.S`、clk、dwc3、`init/main.c`、`smp.c`、`timekeeping`、控制台花屏实验等。
- 与显示/触屏/音频/netboot 无关的本地 bring-up 补丁。

也就是说：**这些补丁是从干净的上游 HEAD 重新生成的**，不是把工作区整份 diff 打包。

## 应用

```bash
git checkout -b hotdogb-display
git am patches/*.patch
```

或者不用 git：

```bash
for p in patches/*.patch; do patch -p1 < "$p"; done
```

## 编译

```bash
scripts/kconfig/merge_config.sh -m .config \
    configs/hotdogb-display-touch.config configs/hotdogb-audio.config \
    configs/hotdogb-netboot.config
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
make -j$(nproc) ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
    Image qcom/sm8150-oneplus-hotdogb.dtb modules
```

配置片段里开了：`DRM_MSM`、`DRM_MSM_DSI`、`DRM_MSM_DSI_7NM_PHY`、`DRM_MSM_KMS_FBDEV`、`DRM_PANEL_SAMSUNG_SOFEF03F`、`RMI4_*`、`I2C_QCOM_GENI`、`REGULATOR_QCOM_LABIBB`。

显示/触屏全部编进 `vmlinux`（开机就要用）。音频是模块：`SND_SOC_QDSP6`、`SND_SOC_SM8150`、`MFD_WCD934X`、`SND_SOC_WCD934X`、`SND_SOC_TFA9874`、`SLIM_QCOM_NGD_CTRL`、`SOUNDWIRE_QCOM`，`SLIMBUS` 本身编进内核。装模块：

```bash
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- \
    INSTALL_MOD_PATH=/tmp/mods INSTALL_MOD_STRIP=1 modules_install
```

GitHub Actions 会把 stripped 模块树一起打出来（`out/modules.tar.gz` 和 `out/modules/`），方便直接对照本地那套 `load.sh`。

## 启动前

这台机器的原厂 `dtbo_a` 会把 `/soc` 的 `#address-cells`/`#size-cells` 从 `2/2` 改成 `1/1` 却不转换子节点的 `reg`，整棵树错位，DWC3 第一次 DMA 就死锁。所以跑主线必须把 dtbo 换成空 overlay：

```bash
fastboot flash dtbo noop-dtbo.img    # 32 字节空 DTBO
fastboot flash boot boot.img         # 内核 + DTB 打包在 boot 里
```

恢复原厂：`fastboot flash dtbo backup/dtbo_a.img`。

## 状态

- 代码编译通过，DTB 里 `samsung,sofef03f` / `syna,rmi4-i2c` / `regulator-tp-1v8` 都在，`i2c@c80000` 是 okay，simplefb 已移除。
- **画面输出还没在真机上验证过**（镜像刚打出来）。第一次上机重点看 `dmesg | grep -iE 'drm|dsi|dpu'` 和 `/dev/dri`。
- **触屏也没验证过**，重点看 `dmesg | grep -i rmi`、`i2cdetect -y 17` 有没有 `0x20`、`/proc/interrupts` 里有没有中断计数。

## 已知缺口

**面板偏压**。这块屏还要 PM8150L LCDB 出来的 `lab`/`ibb`（±5.5V 左右）。主线有 `qcom-labibb-regulator.c`，但那是给 PMI8998 那代 SPMI PMIC 用的，PM8150L 的 LCDB 是另一套寄存器，目前没人写。所以驱动只建模了 `vddio`，偏压靠启动器留着（连续启动画面机制）。**如果屏幕亮了但全黑，多半就是这个原因**，不是驱动写错了。

要彻底解决得写一个 `qpnp-lcdb` 驱动，那是下一步的事。

**亮度**：走 DSI 的 `set_display_brightness`，没有额外背光芯片。原厂面板节点的亮度曲线（`qcom,mdss-dsi-bl-pmic-control-type` 之类）没搬过来，现在是线性映射，观感可能不对。

## 验证情况

已经做过的：

- 8 个补丁在干净的 HEAD worktree 上 `git am` 全部通过，无冲突
- 打完补丁后的 DTS 里没有 `qcom,msm-id`、也没有 `hotdobg` 这个错拼
- `checkpatch.pl --no-tree --strict`：0 error，只有一条 "MAINTAINERS 是否需要更新" 的提示（面板目录已被 `DRM PANEL DRIVERS` 的 `F: drivers/gpu/drm/panel/` 覆盖，属误报）
- 打完补丁后 `sm8150-oneplus-hotdogb.dtb`、`panel-samsung-sofef03f.o`、`rmi_i2c.o` 都能编译
- 原工作区完整 `Image` 编译通过，DTB 里该有的节点都在

还没做的：真机出图、真机触屏（见上面"状态"）。

## 这个文件夹里没有的东西

`Desktop\test` 下原来那堆东西（16 个 `boot-hotdogb-*.img`、`Image-dbg3x`、initramfs、`backup/` 里的原厂分区、`stock08-*.dtb`、8.47 版逆向报告）**不往 GitHub 放**：

- 全是几百 MB 的构建产物，二进制不进仓库
- 原厂分区备份（`boot_a`/`dtbo_a` 等）是恢复用的，留在本地 `test\backup\`
- 逆向分析报告留在 `test\ABL_XBL_逆向分析与主线内核启动条件.md`

真要发布二进制，走 GitHub Releases，别塞进 git 历史。

## 上传 GitHub 前

1. `0001` 里的 `maintainers:` 已填为 `mingmingzhichu <lihaoyu0717@outlook.com>`，如需改动请同步修改。
2. 所有补丁的 `Signed-off-by` 也是占位符，换成真实姓名和邮箱（DCO 要求）。
3. 跑一遍 `./scripts/checkpatch.pl --strict patches/*.patch`。
4. 想上游的话：面板驱动和 binding 发 dri-devel，rmi4 补丁发 linux-input，DTS 跟着面板驱动一起发（DTS 依赖 binding 和 compatible，得同一个系列）。

## 许可证

补丁里的内核代码（驱动、rmi4、Kconfig）是 `GPL-2.0-only`；binding 是 `GPL-2.0-only OR BSD-2-Clause`；DTS 沿用原文件头，`BSD-3-Clause`。补丁新增和修改的文件里都带 SPDX 头，不用另外加。

## boot.img 的 cmdline

CI 与本地打包用的都是同一条：

```
clk_ignore_unused loglevel=7 panic=0 printk.time=1 ramoops.max_reason=5 log_buf_len=4M
```

- `clk_ignore_unused`：不开这个，没被驱动认领的时钟会在 late init 被关掉，DSI/DPU 会黑屏
- `loglevel=7` + `printk.time=1`：串口/屏幕直接看到完整的引导日志
- `panic=0`：出错时停在现场而不是重启，方便抓 dmesg
- `ramoops.max_reason=5`：保留完整的 ramoops 记录
- `log_buf_len=4M`：环形缓冲区太小会把早期的显示/PCIe 日志冲掉

它在 `.github/workflows/build.yml` 的 `env.CMDS` 里定义，由 `mkbootimg_v2.py --cmdline` 带进
boot 镜像头；本地打包时可以直接改这一条。

## 踩过的坑

## Wi-Fi（WCN3990）

已打通：冷启动后执行一条 `/bin/wifi_up.sh`，`wlan0` 就会出现并可主动扫描。
详见 [`docs/evidence/2026-11-02-wifi-wcn3990.md`](docs/evidence/2026-11-02-wifi-wcn3990.md) 和
[`firmware/README-wifi.md`](firmware/README-wifi.md)。

要点：

- `wlanmdsp.mbn` **必须**取本机 `modem_a` 分区（`image/wlanmdsp.mbn`，4 070 084 B）。用 7T Pro
  固件包里的那份会让 SCM 分配 MSA 内存时报 `-22`，后面 `failed to create WMI vdev 0: -108`。
- **不要**用 `qcom,msa-fixed-perm`：跳过 SCM 分配会让 WLAN 子系统访问未授权内存，整机掉进 EDL。
- MPSS 起之前 `rmtfs` / `pd-mapper` / `tqftpserv` 必须就绪，且 `tqftpserv` 要能创建
  `/var/lib/tqftpserv`（从 `persist` 只读填充），否则 MPSS 不会发布 `ATH10k WLAN firmware service`。
- 还没接 `wpa_supplicant`/DHCP，只能扫；MAC 已从 `persist` 的 `wlan_mac.bin` 设成真实地址
  （`ath10k` 自己取不到，会随机一个）。这些属于用户态，见
  [`docs/deferred-to-userspace.md`](docs/deferred-to-userspace.md)。

## 传感器（SLPI / SSC）

加速度计、陀螺、光感和距离都在 SLPI（传感器 DSP）上。SLPI 固件在 `modem_a` 里
（`slpi.mdt` + 21 个分片，6 MB），`/init` 开机时拷到 `/lib/firmware`，等 pd-mapper 起好后
`echo start` 就能跑起来：

```
$ for r in /sys/class/remoteproc/*; do echo $(cat $r/name) $(cat $r/state); done
slpi running
$ /bin/qrtr-lookup | grep -i sensor
      400       1        0    9    13 Snapdragon Sensor Core service
```

还差用户态 QMI SSC 客户端（Debian 里是 `libssc` + `iio-sensor-proxy`）。
详见 [`docs/evidence/2026-11-04-sensors-slpi.md`](docs/evidence/2026-11-04-sensors-slpi.md)。

GPS 同理：MPSS 起来后 QRTR 上已经有 Location service（QMI 16），差 `gnss-share` 这样的客户端。

## 90 Hz

面板实测跑在 90 Hz：

```
$ /bin/vbltest /dev/dri/card0 3
268 vblanks in 3.008 s = 89.11 Hz
```

`/sys/class/drm/*/modes` 不显示刷新率，debugfs 的 `vblank fps` 是滑动平均（读出来 38，
没有参考价值），所以用 `tools/vbltest.c` 直接等 vblank 计数。详见
[`docs/evidence/2026-11-04-refresh-90hz.md`](docs/evidence/2026-11-04-refresh-90hz.md)。

驱动里只有一个 mode，就是按 90 Hz 算的（1180 × 2416 × 90 = 256.6 MHz），面板用 DCS
`0x60 = 0x10` 跟着切过去，所以 DSI PLL / PHY / DSC 参数与 60 Hz 组完全一致。

## 音频（WCD9340 + TFA9874）

声卡是 `qcom,sm8150-sndcard` + WCD9340（SLIMbus）+ 两颗 TFA9874（I2C SE4，0x34/0x35）。
模块按顺序用 `load.sh` 加载（`snd-soc-tfa9874` 必须在 `snd-soc-sm8150` 之前）。

三条已经出声的链路（都需要先 `sndtool set ...` 配路由）：

- **耳机**：`SLIMBUS_6_RX Audio Mixer MultiMedia1=1`，`SLIM RX1/2 MUX=AIF4_PB`，WCD 的 `RX INT1/2` 接到 `AIF4_PB`。
- **听筒**：`SLIMBUS_6_RX` 不变，`SLIM RX1 MUX=AIF4_PB`、`RX INT0_1 MIX1 INP0=RX1`、
  `RX INT0_1 INTERP=RX INT0_1 MIX1`、`RX INT0 DEM MUX=CLSH_DSM_OUT`、`EAR PA Volume=4`。
- **底部扬声器**：`QUAT_MI2S_RX Audio Mixer MultiMedia1=1`，走 `QUAT_MI2S_RX`（DAI id 22）→
  `i2c@890000` 上的两颗 TFA9874。DT 里**不写 reset-gpios**：下面那颗的复位和 FSA4480 的
  GPIO100 共用，启动器已经把放大器留在可用状态。

实测（`sndtool play`）：TFA 初始化后 `status0=0x0017`，`mute_stream` 里 unmute 成功，
底部扬声器有声；播放结束回到 `pre-mute`，没有 XRUN。

`speaker-dai-link` 必须排在 `&sound` 的**最后**。q6routing 是所有后端共用的 platform
组件，它在 q6afe/q6asm 的 DAI widget 之前 probe 的话，DAPM 路由会以 `-ENODEV` 失败，
整张卡注册不上（现象是 `ASoC: failed to instantiate card -19`）。

## Netboot：从 PC 挂载 rootfs（NBD）

沿用 postmarketOS 的方案：设备端用 USB 网卡，PC 上跑 NBD server 导出 rootfs 镜像，
initramfs 里连上 NBD 后 `switch_root`，不需要写任何分区。

```
设备 172.16.42.1  --USB CDC-NCM-->  PC 172.16.42.2:9999 (nbd-server)
                                        |
                                   rootfs.img (raw ext4)
```

构件：

- 内核：`CONFIG_BLK_DEV_NBD=y`（见 `configs/hotdogb-netboot.config`，CI 会合并）
- initramfs：只有 cmdline 带 `hotdogb.netboot=1` 时才启用，普通启动完全不受影响
- 主机：`tools/nbd_server.py`（Windows/Linux 自带 Python 3 即可，不装 nbd-server）
- 镜像：`tools/make_netboot_rootfs.sh` 把任意 rootfs 目录/tar 包做成无分区表的 ext4

设备侧 cmdline 示例：

```
hotdogb.netboot=1 hotdogb.netboot.host=172.16.42.2 hotdogb.netboot.port=9999
```

默认用 CDC-NCM；老一点的 Windows 或需要 RNDIS 时加
`hotdogb.netboot.net=rndis`。

Linux 主机（推荐，避开 Windows 的 NCM 驱动）：

```sh
sudo IFACE=usb0 tools/netboot_host.sh netboot-debian.img
```

脚本会自动找 `cdc_ncm`/`rndis_host`/`cdc_ether` 网卡，设 `172.16.42.2/24`，
然后启动 NBD server。

同一台 Windows 也可以走 WSL2 + usbipd-win，让 Linux 的 `cdc_ncm` 接管设备：

```powershell
usbipd list
usbipd bind --busid <BUSID> --force     # 管理员，一次
usbipd attach --wsl --busid <BUSID>
```

```sh
# WSL2 里
sudo IFACE=enx... tools/netboot_host.sh /mnt/c/.../netboot-debian.img
```

已实测：Windows 自带的 NCM 驱动会在 systemd 启动时重置连接；换 WSL2 的
Linux 驱动后，Debian 正常启动，`systemctl is-system-running` 为 `running`、
`systemctl --failed` 为空。

可选：`hotdogb.netboot.init=/bin/bash`（默认 `/sbin/init`）。
不要依赖内核 cmdline 里的 `init=`：ABL 自己会追加 `init=/init`，所以要用
`hotdogb.netboot.init=` 单独指定。

CI 会同时产出 `boot-hotdogb-netboot.img` 和 `netboot-debian.img.xz`（Debian trixie
arm64，root/root，已配好 `172.16.42.1` 和 `serial-getty@ttyGS0`）。

Windows 主机步骤：

1. `fastboot boot` 之后系统里会出现 “UsbNcm Host Device”（以太网 N）网卡，
   用管理员 PowerShell 设静态地址和防火墙：
   ```powershell
   netsh interface ip set address name="以太网 N" static 172.16.42.2 255.255.255.0
   New-NetFirewallRule -DisplayName "hotdogb nbd" -Direction Inbound `
       -Protocol TCP -LocalPort 9999 -Action Allow -Profile Any
   ```
2. 在同一台机器上运行：
   ```
   py tools\nbd_server.py --image netboot.img --bind 172.16.42.2
   ```
3. 设备串口会打印 `netboot: mounted /dev/nbd0, switching root`。

已实测：Windows 10 19044 + CDC-NCM，Alpine minirootfs 从 NBD 启动，
`/dev/nbd0 on / type ext4 (rw)`。

不要用 RNDIS：Windows 10 的 `netrndis.inf` 是 IHV 模板 INF，不匹配
`USB\MS_COMP_RNDIS`，只会得到 `CM_PROB_FAILED_INSTALL`。NCM 的
`usbncm.inf` 明确匹配 `USB\MS_COMP_WINNCM`。

NBD 连接失败时 initramfs 不会退出，串口控制台照常可用，`/tmp/nbd.log` 里有原因。

## dtbo 必须是空的（否则起不来）

`fastboot boot` 时 ABL 也会把 **dtbo 分区**的 overlay 叠到 boot.img 自带的 DTB 上，所以
刷回原厂 dtbo 之后，我们的镜像 `Booting OKAY` 但用户空间永远不起来（COM 口不出现，设备
自己回到 fastboot）。测试前需要：

```sh
fastboot flash dtbo_a noop-dtbo.img
```

收尾回滚再用 `fastboot flash dtbo_a backup/dtbo_a.img`。
