# configs/

`hotdogb_defconfig` 是这块板子唯一的内核配置。CI 只跑一次
`make hotdogb_defconfig`，不再 merge 任何片段 —— 早先那三份
`hotdogb-display-touch.config` / `hotdogb-audio.config` / `hotdogb-netboot.config`
已经合进来了，它们想说明的事情留在下面。

文件本身是 `make savedefconfig` 的产物，**不要手改**：里面没出现的符号不是被关掉了，
而是当前配置下 Kconfig 的默认值已经是对的。改配置的流程是

```sh
# 在一块已经配置好的内核树里
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- menuconfig
tools/make_defconfig.sh          # 重新生成 configs/hotdogb_defconfig

# 板上/CI 里就用这一份
cp configs/hotdogb_defconfig arch/arm64/configs/
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- hotdogb_defconfig
```

## 显示 / 触屏

整个 DRM 栈必须是 `=y`：`DRM`、`DRM_KMS_HELPER`、`DRM_MSM`、`DRM_MSM_DSI`、
`DRM_MSM_DSI_7NM_PHY`、`DRM_MSM_KMS_FBDEV`，加上面板
`DRM_PANEL_SAMSUNG_SOFEF03F` 和偏压 `REGULATOR_QCOM_LCDB`。

arm64 的 defconfig 把这些写成 `m`，但 `DRM_MSM=m` 会把隐藏符号 `DRM_KMS_HELPER`
也拉到 `m`；面板驱动是 built-in 的，链接 `vmlinux` 时就找不到
`drm_connector_helper_get_modes_fixed()`。所以要么全 `y`，要么全 `m`，不能混。

触屏是 Synaptics S3706（RMI4）：`RMI4_CORE`、`RMI4_I2C`、`RMI4_F03/F11/F12/F30`、
`INPUT_EVDEV`，总线是 `I2C_QCOM_GENI`（QUPv3 SE17）。

`REGULATOR_QCOM_LABIBB` 保留着（PMI8998 那套 LAB/IBB），这块板用不上，但同目录的
`qcom-lcdb-regulator` 是照着它写的，留着便于对照。

## 音频

WCD9340 走 SLIMbus，两颗 TFA9874 走 QUATERNARY_MI2S。除了 `SLIMBUS=y` 之外全是模块，
由 rootfs 在 ADSP 起来之后按依赖顺序加载：`SND_SOC_QDSP6`、`SND_SOC_SM8150`、
`MFD_WCD934X`、`SND_SOC_WCD934X`、`SND_SOC_TFA9874`、`SLIM_QCOM_NGD_CTRL`、
`SOUNDWIRE_QCOM`。

`SLIMBUS` 内建的原因：控制器是 DTB 里的设备，开机就要存在，codec 只是后面 attach 上去。

## netboot

`CONFIG_BLK_DEV_NBD=y`。根文件系统就在 NBD 上，它比任何模块都早，只能是内建。

USB gadget 那一路同理（`USB_DWC3`、`USB_DWC3_QCOM`、`PHY_QCOM_QMP_USB`、
`USB_CONFIGFS`、`USB_F_NCM`、`USB_GADGET`）：netboot 的链路本身要先能起来。

CI 对这七项逐个断言 `=y`，缺一个直接失败，不会放出一个跑不起来的镜像。

## 其它

- `CONFIG_LOCALVERSION="-sm8150"`：`uname -r` 是 `7.3.3-sm8150`，rootfs 里的模块目录
  `/lib/modules/7.3.3-sm8150` 依赖它，改这个等于让所有模块失配。
- 传感器（SLPI/SSC）、FastRPC、GNSS 都不需要额外符号：走的是 QRTR + 用户态
  （`libssc`、`hexagonrpcd`），内核侧默认值就够。
