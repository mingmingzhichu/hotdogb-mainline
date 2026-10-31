# 一加 7T (hotdogb) 主线内核：显示 + 触屏支持

给 OnePlus 7T（`hotdogb`，SM8150）主线内核加的两块东西：

1. **显示**：DPU 5.0 + DSI0 + 7nm PHY + 三星 SOFEF03F 面板（1080×2400 AMOLED，DSC 压缩，命令模式）
2. **触屏**：Synaptics S3706（RMI4 协议，I2C）

原厂 dtbo 里这两块的配置都已经反解出来，参数不是猜的：初始化序列、DSC 的 PPS、时序、GPIO 全部来自 `dtbo_a` 里的原厂节点。

---

## 目录

```
patches/    5 个补丁，按顺序 git am 即可
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
| 0001 | `dt-bindings: display: panel: add Samsung SOFEF03F` | 新增 YAML binding |
| 0002 | `drm/panel: add driver for the Samsung SOFEF03F DSC panel` | 新驱动 + Kconfig/Makefile |
| 0003 | `Input: rmi4 - honour the reset-gpios property` | 让 rmi4 真正去拉复位脚 |
| 0004 | `arm64: dts: ...: fix the board compatible` | `hotdobg` → `hotdogb` |
| 0005 | `arm64: dts: ...: enable the display` | DPU/DSI/PHY/面板 + 去掉 simplefb |
| 0006 | `arm64: dts: ...: enable the touchscreen` | i2c17 上的 S3706 |

补丁基于 `Sr-0w/hotdog-linux-bringup` 的 7.0.0 树（`8e126dbc4`）。

**没有包含的东西**（故意的）：

- 早期为了让机器启动起来打的一堆调试/权宜改动 —— `head.S`、clk、dwc3、`init/main.c`、`smp.c`、`timekeeping`、控制台花屏实验等。
- 本地 DTS 里为了迁就 ABL 加的 `qcom,msm-id` / `qcom,board-id`。和显示/触屏无关，而且已经验证过纯主线 DTB 能被 ABL 接受，所以不放进这个系列。

也就是说：**这些补丁是从干净的 HEAD 重新生成的**，不是把工作区整份 diff 打包。`git am` 打上去之后得到的树和本地工作区不是逐字节相同（少了上面那些），但显示/触屏部分一致。

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
scripts/kconfig/merge_config.sh -m .config configs/hotdogb-display-touch.config
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
make -j$(nproc) ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- Image qcom/sm8150-oneplus-hotdogb.dtb
```

配置片段里开了：`DRM_MSM`、`DRM_MSM_DSI`、`DRM_MSM_DSI_7NM_PHY`、`DRM_MSM_KMS_FBDEV`、`DRM_PANEL_SAMSUNG_SOFEF03F`、`RMI4_*`、`I2C_QCOM_GENI`、`REGULATOR_QCOM_LABIBB`。

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

- 6 个补丁在干净的 HEAD worktree 上 `git am` 全部通过，无冲突
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
