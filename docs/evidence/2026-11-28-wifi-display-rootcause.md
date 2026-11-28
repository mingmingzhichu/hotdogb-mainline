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
