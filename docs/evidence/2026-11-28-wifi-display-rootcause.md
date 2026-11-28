# 2026-11-28 下午：WiFi 与显示两条线的根因

## 背景

上午把 initramfs 里 16 字节的 busybox 修好后（见 `2026-11-28-boot-img-busybox.md`），
设备终于能启动，MPSS 能起来，但仍有两条线卡住：ath10k 一 probe 整机掉 900E，
以及开机花屏。

## 一、WiFi：`qcom,msa-fixed-perm` 是错误变通

### 现象

`hotdogb-radio.sh wifi` 里 WLFW 已出现，insmod ath10k 后几毫秒整机掉
`QUSB_BULK 900E`。串口（`console=ttyGS0` + COM5）抓到崩溃前完整序列：

```
qmi msa mem region 0 addr 0x8bc00000 size 0x4000 flag 0x1
qmi msa mem region 1 addr 0x8bc04000 size 0x17c000 flag 0x0
qmi msa mem info/ready request completed
qmi chip_id 0x30224 board_id 0xff ...
boot found match for name 'bus=snoc,qmi-board-id=ff'
qmi bdf download request completed
qmi cal report request completed
qcom_q6v5_pas: fatal error received: SFR Init: wdog or kernel error suspected.
```

即：QMI 全部成功，崩溃点在 cal report 之后的 wlan_enable，固件在 copy_engine
断言（CVE-2022-50700 同款签名 `Asserted in copy_engine`）。

### 根因

DTB 里 `qcom,msa-fixed-perm` 让 ath10k 跳过 SCM MSA 权限交接。这个属性是当初用
**7T Pro 固件**时加的（SCM 返回 -EINVAL，见补丁 0004 的旧注释）。换回本机 hotdogb
的 `modem.mbn` 后，SCM 交接本来就能成功，跳过它反而让 WLAN 固件一碰 MSA 窗口就
XPU/SMMU 违例。

### 验证

删掉该属性后（只改 DTB，kernel 不变）：

```
WLFW service present after 0s
wlan0 up after 5s: 82:db:7c:e1:66:56
iw dev wlan0 scan  →  列出 CU_iTV_CS5F / jjjca / kaidishi902 等 AP
```

## 二、花屏：LCDB 挂错 SPMI 地址 + enable 握手超时

### 现象

`mipi-dsi ae94000.dsi.0: deferred probe pending: wait for supplier
/soc@0/spmi@c440000/pmic@4/lcdb@ec00/ibb` —— DSI 一直在等 ibb，屏幕不亮。

### 根因一：LCDB 在 SID 5，不是 4

厂商 DTS（OnePlusOSS SM8150_R_10.0 `pm8150l.dtsi`）里 LCDB 在 `qcom,pm8150l@5`：

```
qcom,pm8150l@5 {
    pm8150l_lcdb: qcom,lcdb@ec00 {
        reg = <0xec00 0x100>;
        interrupts = <0x5 0xec 0x1 IRQ_TYPE_EDGE_RISING>;
```

我们的补丁写到了 `&pm8150l`（= pmic@4，SID 4）。SPMI 仲裁器在
`(sid=4, periph=0xec)` 上没有 APID，`failed to xlate ... rc=-19`，probe 失败，
lab/ibb 没注册。

### 根因二：VREG_OK 握手 poll 太短

挪到 SID 5 后 probe 成功（"LCDB ready: lab 4600mV ibb 4600mV"），但 enable 时：

```
LCDB failed to power up: -110   (ETIMEDOUT)
```

厂商 `qpnp_lcdb_enable()` 的 poll 间隔是 `bst.soft_start_us + ldo.soft_start_us +
ncp.soft_start_us + 三个 vreg_ok_dbc_us`（约 6ms/次 × 10 次 ≈ 60ms），而我们只
20 × 1ms = 20ms。boost + LDO + 电荷泵是串行软启动的，20ms 不够。

### 修复（补丁 0015–0018）

- LCDB 节点挪到 `&spmi_bus > pmic@5`，`interrupts = <0x5 0xec 0x1 ...>`
- `LCDB_ENABLE_POLL_US` 1000 → 5000（20 × 5ms = 100ms）

probe 已验证，enable 路径待下一次上机确认。

## 附带发现

- 串口控制台 `console=ttyGS0,115200` 会把内核启动拖死：115200 bps 同步写 +
  `ignore_loglevel` 让每条日志都阻塞，systemd 卡在 `dev-ttyGS0.device`。诊断时
  改用「tqftpserv -d 走 SSH 流」而非串口。
- 全局 `sync` 循环（每秒一次）在 NBD rootfs 上会打满 I/O，把整机压死。别在
  netboot 环境里跑这类后台任务。
- tqftpserv 在 modem 启动时只缺 `ota_firewall/ruleset` 这个无关文件，其余
  （wlanmdsp、校准）都能正常供上。

## 三、LCDB enable 超时（-110）的进一步诊断（14:30 之后）

poll 放宽到 100ms 后 enable 仍 -110 超时，加状态 dump 后得到决定性证据：

```
LCDB ready: lab 4600mV, ibb 4600mV, boost headroom 150mV   (probe)
LCDB failed to power up: -110
  STS1=0x00 STS2=0x00 STS3=0x00 STS4=0x00 STS5=0x00 STS6=0x00
  REG_0x10(INT_RT_STATUS)=0x00
  REG_0x46(ENABLE_CTL1)   =0x00
  REG_0x41(BST_VOLTAGE)   =0x00   ← 驱动写了 sel=2，读回 0
  REG_0x4b(BST_ILIM)      =0x00
```

含义：

- `ENABLE_CTL1=0` 说明 probe 时读到的 MODULE_EN 就是 0 —— **ABL 在 netboot 路径下
  没有打开 LCDB**（continuous splash 没有配偏压），驱动必须从零启动它。
- `BST_VOLTAGE=0` 但驱动 write_bst 写了 sel=2、且 regmap 写返回成功 —— **写被静默丢弃**，
  或者地址解码有误。这是当前要定位的点。
- 备选解释：LCDB 外设（periph 0xec）虽能被 SPMI 寻址（读"成功"返回 0），但模块
  本身未上线，寄存器写被硬件忽略。

已加诊断（下一轮编译验证）：读 PMIC TYPE(0x104，应为 0x51) 证明 regmap 通、
打印 base、write_bst 后读回 BST_VOLTAGE、dump 加 0x45/0x71/0x81。

对照检查过、确认无误的：寄存器地址（0x08/0x10/0x41/0x45/0x46/0x71/0x81 与厂商一致）、
电压编码（4600mV→sel=6）、boost 编码（4750mV→sel=2）、headroom=150mV、
base 从 reg=<0xec00> 取、regmap 用 dev_get_regmap(parent)（与 pm8150l-gpio 相同）。

## 四、LCDB enable 超时的最终定位：periph 未启动（时钟门控），依赖 XBL continuous splash

### 决定性证据（真机 DIAG）

读正确的 periph 类型寄存器（offset 0x04，不是 0x00）：

```
DIAG parent=0-05 base=0xec00 TYPE=0x51 SUBTYPE=0x27
  flash_TYPE(0xd304)=0x18   ← flash periph 在线（类型 0x18，与 flash 驱动 FLASH_TYPE_VAL 一致）
  wled_TYPE(0xd804)=0x00    ← wled 未启动
  lcdb_TYPE(0xec04)=0x00    ← LCDB 未启动
  wr0x41(rw=0)=0x00         ← 写 BST_VOLTAGE=0x2A，SPMI 事务"成功"(ACK)，读回 0（写被丢弃）
```

结论：不是整个 SID5 未启动（flash 在线），而是 **per-periph 时钟门控**——flash
时钟开、lcdb/wled 时钟关。写"成功"但读回 0，正是经典时钟门控特征（"a register
write that reaches it changes nothing; the write still completes on the bus"）。

### 根因链

- 正常启动：XBL（不是 ABL）在 continuous splash 阶段初始化 display（framebuffer
  放 0x9C000000，1080×2400），顺带把 LCDB periph 时钟打开并配置好电压/使能。
- netboot（fastboot boot）：XBL 的 display 初始化被跳过，LCDB periph 时钟未开，
  读回 0、写不生效。主线 LCDB 驱动 enable 时写 MODULE_EN 后 poll VREG_OK 永远
  读回 0 → -110 超时。
- 官方主线 LCDB 驱动（Dmitry Baryshkov 2026-10-15 sm8150-display-card 系列）与我们
  驱动逻辑一致，也明确声明依赖 bootloader 使能；换驱动不解决。
- u-boot 补丁（Petr Hodina 2026-10）佐证：pm8150l 的 WLED node on usid 5 "never
  returns CMD_DONE"（Xiaomi Pad 5），同属 SID5 periph 未响应。

### 深挖 XBL：LCDB 初始化走 pmic_settings.bin

- 解包 abl.img（ELF32 + LZMA）得到的 LinuxLoader 里没有 LCDB 字符串 → LCDB 初始化
  不在 ABL，在 XBL。
- xbl.img 是未压缩 ELF64 AArch64（28 个 UEFI DXE 驱动）。含字符串：
  `pmic_settings.bin`、`/pmic/target`、`OPPOPMIC`、
  `# Shengjun.Gou@PSW.MM.Display.LCD.Stability ... for splash logo`。
- 即：XBL 的 PMIC/display 初始化通过外部 `pmic_settings.bin`（寄存器序列）下发，
  LCDB 的"使能 periph + 配置电压"序列很可能在里面。

### 待办

- `pmic_settings.bin` 在设备分区（不在 xbl.img/abl.img），需从设备 dump 后解析
  LCDB 寄存器序列；或反汇编 xbl.img 的 display 初始化找硬编码的 periph 使能写。
- 设备 netboot 反复启动失败（偶发，NBD 限速无关），干扰上机验证，未定位。
