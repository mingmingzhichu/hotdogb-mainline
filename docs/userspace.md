# Debian 用户态：Wi-Fi、传感器、音频

netboot 的根文件系统是 Debian trixie（`tools/build_debian_rootfs.sh`）。
这里记录还需要在 Debian 里补的东西和手动步骤。

## GPU：Freedreno + Turnip

rootfs 预装 Mesa 的 Freedreno（GL/EGL）和 Turnip（Vulkan），以及
`vulkan-tools`：

- `libgl1-mesa-dri`：`freedreno_dri.so`（Adreno 640，a6xx）
- `mesa-vulkan-drivers`：`libvulkan_freedreno.so`（Turnip）
- `mesa-utils`、`vulkan-tools`：`eglinfo`、`vulkaninfo` 方便验证
- `/lib/firmware/qcom/a630_sqe.fw`、`a640_gmu.bin`、
  `sm8150/a640_zap.mbn` 由仓库 `firmware/` 拷入

内核侧 `&gpu`/`&gmu`/`&gpu_zap_shader` 已经 enable。上机验证：

```sh
cat /sys/class/drm/card0/device/gpu_model 2>/dev/null
eglinfo -B 2>/dev/null | head -20
vulkaninfo --summary 2>/dev/null | head -20
```

如果 `vulkaninfo` 找不到设备，先看 `dmesg | grep -i -e msm -e adreno -e zap`。

## 图形界面 / 屏幕键盘

CI 的 rootfs 会装 **Phosh**（比 Plasma Mobile 轻很多，NBD over USB 2.0
的根文件系统下 Plasma 基本不可用）：

- `phosh` + `squeekboard`（屏幕键盘）+ `gnome-console`；
- `greetd` 在 `tty1` 起 `phosh-session`（`/etc/greetd/config.toml`）；
  `phosh-session` 会自己起 dbus 会话，然后 exec `phoc`；
- `zram-tools` 打开 zram swap，缓解 NBD 根文件系统的压力；
- 默认目标改成 `graphical.target`；
- 镜像默认 6 GiB。

起不来时先看 `journalctl -u greetd`、`journalctl -u phoc` 和
`cat /sys/class/drm/card0-DSI-1/status`。

## 已经装进 rootfs

- `wpasupplicant`、`iw`、`wireless-regdb`
- `alsa-ucm-conf`、`alsa-utils`
- `iio-sensor-proxy`
- `rmtfs`、`tqftpserv`
- `hotdogb-audio`（在 `/usr/local/sbin`，设置耳机/听筒/扬声器路由）

## Debian 里没有的包

| 名字 | 用途 | 现状 |
|---|---|---|
| `pd-mapper` | 回答 ADSP/SLPI/MPSS 的 protection-domain 查询 | 未进 Debian；用 pmOS/pmaports 的 `pd-mapper` 源码编译 |
| `libssc` | 传感器 DSP（SSC）的 QMI 客户端 | 未进 Debian；Ubuntu/pmOS 有，需要自己编 |

## 固件从哪来

`modem_a` 是 FAT16（设备上是 `/dev/sde4`），只读挂上即可，不用写：

```sh
mkdir -p /mnt/modem /lib/firmware/qcom/sm8150/oneplus7
mount -t vfat -o ro /dev/sde4 /mnt/modem
cp /mnt/modem/image/wlanmdsp.mbn /lib/firmware/qcom/sm8150/oneplus7/
cp /mnt/modem/image/adsp.*     /lib/firmware/qcom/sm8150/
cp /mnt/modem/image/slpi.*     /lib/firmware/qcom/sm8150/oneplus7/
umount /mnt
```

MPSS 的 `modem.mbn` 也在这个分区；`modem` 的 remoteproc 需要它和
`rmtfs`（EFS 从 `modemst1/2` 拷到 RAM）。

## Wi-Fi（WCN3990）

顺序很重要：MPSS 起来之前必须有 `rmtfs`、`pd-mapper`、`tqftpserv`，否则
MPSS 会 assert，`ath10k` 永远等不到 `ATH10k WLAN firmware service`。

```sh
# 1. EFS / PD 服务（rmtfs 用发行版 unit，自己起会缺 -P -s）
systemctl start rmtfs
# 2. SLPI 先起来，pd-mapper 才有东西可枚举
echo start > /sys/class/remoteproc/remoteproc0/state    # slpi
# 3. PD 表来自固件目录里的 *.jsn，没有它们 pd-mapper 直接退出
mkdir -p /lib/firmware/qcom/sm8150/oneplus7
cp /mnt/modem/image/*.jsn /lib/firmware/qcom/sm8150/oneplus7/
pd-mapper &                 # 需要自己编
# 4. 固件下载服务
mkdir -p /var/lib/tqftpserv
tqftpserv &
# 5. 最后起 MPSS
echo start > /sys/class/remoteproc/remoteprocX/state    # modem
# 6. 加载模块
insmod cfg80211.ko; insmod mac80211.ko; insmod ath.ko
insmod ath10k_core.ko; insmod ath10k_snoc.ko
ip link set wlan0 up
wpa_supplicant -B -i wlan0 -c /etc/wpa_supplicant.conf
dhcpcd wlan0                # 或 NetworkManager
```

`pd-mapper` 只认固件目录里的 `*.jsn`（`adspr/adspua/cdspr/modemr/modemuw/slpir/slpius`），
这些和 `wlanmdsp.mbn` 一起在 `modem_a/image/` 里。没有 `.jsn` 时启动即打印
`no pd maps available` 并退出。

`board-2.bin` 必须用本机的（高通不公开），直接把 `modem_a/image/bdwlan.bin`
当 `board.bin` 放进 `ath10k/WCN3990/hw1.0/` 即可；ath10k 先找 `board-2.bin`，
失败后回退到 `board.bin`，不会做长度校验。网上流传的通用 `board-2.bin`
会报 `invalid length for board ie_id 0`。

注意：**不要**用 `qcom,msa-fixed-perm`，会让整机掉 EDL。
`wlanmdsp.mbn` 必须用本机 `modem_a` 里那份。

模块必须和 Image 同一次构建。若 `insmod` 报 `Invalid parameters`，dmesg 里是
`failed to validate module [x] BTF: -22`，可以用
`aarch64-linux-gnu-objcopy --remove-section .BTF --remove-section .BTF.ext`
去掉模块 BTF 后加载（跳过校验，vermagic 不变）。

## 传感器（SLPI / SSC）

```sh
cp slpi.* /lib/firmware/qcom/sm8150/oneplus7/
echo start > /sys/class/remoteproc/remoteprocX/state   # slpi
iio-sensor-proxy &
```

`iio-sensor-proxy` 已装，但它需要 `libssc` 才能跟 SSC 通信；没有 libssc 时
`/sys/bus/iio` 里不会出现手机传感器。`libssc` 可以从 pmOS/Ubuntu 的源码编译，
装好后传感器会通过 IIO 暴露给 `iio-sensor-proxy`。

## 音频

内核模块不在 rootfs 里（netboot 镜像只带 busybox + init）。需要：

1. 把 `make modules_install INSTALL_MOD_PATH=<rootfs>` 的模块装进 Debian，
   或者把 `.ko` 放到一个目录用 `insmod` 按 `audio-mods/load.sh` 的顺序加载；
2. ADSP 固件按上面的方法拷到 `/lib/firmware/qcom/sm8150/`，`echo start > .../adsp/state`；
3. 声卡出现后：

```sh
hotdogb-audio headphones    # 或 earpiece / speaker
aplay -D hw:0,0 /usr/share/sounds/alsa/Front_Center.wav
```

`hotdogb-audio` 用的控制名和之前 initramfs 里验证过的一致（TFA9874 走
`QUAT_MI2S_RX Audio Mixer MultiMedia1`，耳机走 `SLIMBUS_6_RX` + `AIF4_PB`）。
