# SSC 传感器：缺的是 FastRPC 文件服务与内核支持（2026-11-21）

SLPI 能起、QRTR 上能看到 SSC（service 400），但 `iio-sensor-proxy` 一直拿不到传感器。
这次把链路逐段验完，结论是**两个不同的问题**：用户态缺 `hexagonrpcd`，内核侧 FastRPC
还 attach 不上。

## 1. libssc 的 SUID 查询返回 0 个传感器

`iio-sensor-proxy` 的完整调试日志（`G_MESSAGES_DEBUG=all`）：

```
DEBUG: 19:43:32.558: Polled 'registry' sensor for service availability
DEBUG: 19:43:32.558: Message 768 for sensor ABABABABABABABAB ABABABABABABABAB
DEBUG: 19:43:41.851: 'registry' sensor unavailable, retrying... (6/10)
DEBUG: 19:44:44.861: Releasing SSC QMI client
DEBUG: 19:44:44.870: No sensors or missing kernel drivers for the sensors
```

`768` = `SSC_MSG_RESPONSE_SUID`，`0xABABABABABABABAB` = `SSC_SENSOR_UID_SUID_HIGH/LOW`
（libssc `libssc-client-private.h:51-54`），所以协议交互本身是通的，`0xABAB…` 不是内存垃圾。
`libssc-sensor.c` 里 `suid_msg->n_uid > 0 && data_type == "registry"` 不成立才会重试，
即固件回的注册表是空的。

## 2. 注册表为什么是空的：缺 `hexagonrpcd`

pmOS 的 [Qualcomm Snapdragon Sensor Core](https://wiki.postmarketos.org/wiki/Qualcomm_Snapdragon_Sensor_Core)
文档写得很明确：SLPI 启动时通过 FastRPC 反向隧道读传感器配置和注册表，主机侧的服务端是
`hexagonrpcd`；没有它，`libssc` 拿不到任何传感器（同
[libssc#70](https://codeberg.org/DylanVanAssche/libssc/issues/70)）。

`hexagonrpcd` 需要的 HexagonFS 目录（`-R`）内容全部来自本机 Android 分区：

| HexagonFS 路径 | Android 来源 | 本机状态 |
|---|---|---|
| `sensors/registry` | `/mnt/vendor/persist/sensors/registry/registry` | ✅ `persist`（`/dev/sda2`）可只读挂载，438 个文件、3.5 MB 真实校准数据 |
| `sensors/config` | `/vendor/etc/sensors/config/*.json` | ❌ 在 `super` 动态分区里，未取 |
| `sensors/sns_reg.conf` | `/vendor/etc/sensors/sns_reg_config` | ❌ 同上 |
| `acdb` / `dsp` | `/vendor/etc/acdbdata` / `/vendor/dsp` | ❌ 同上（传感器用不到） |
| `socinfo` | `/sys/devices/soc0` | ✅ |

内核侧没有问题：`CONFIG_QCOM_FASTRPC=m`，SLPI 起来后 `/dev/fastrpc-sdsp` 存在
（`2400000.remoteproc`，`label = "sdsp"`），ADSP 是 `/dev/fastrpc-adsp`。

## 3. 真正的拦路虎：FastRPC attach 把 SLPI 打崩

在 SLPI 健康的状态下（`state = running`）分别试两种 attach：

```
$ hexagonrpcd -f /dev/fastrpc-sdsp -d adsp -s -R ...   # INIT_ATTACH_SNS
Could not attach to FastRPC node: Broken pipe
$ hexagonrpcd -f /dev/fastrpc-sdsp -d adsp -R ...      # INIT_ATTACH
Could not attach to FastRPC node: Broken pipe
```

两次内核都记录了同一类故障：

```
arm-smmu 15000000.iommu: Unhandled context fault: fsr=0x402, iova=0x1fffff000,
                         fsynr=0x5f0001, cbfrsynra=0x5a1, cb=11
qcom_q6v5_pas 2400000.remoteproc: fatal error received:
                         EX:kernel:0x0:frpck_0_0:0x8c:PC=0xb0242928
remoteproc remoteproc0: crash detected in slpi: type fatal error
remoteproc remoteproc0: recovering slpi
```

`0x5a1` 正是 SLPI fastrpc 的 `compute-cb@1` 的 SID（`sm8150.dtsi`），`frpck` 是 DSP 侧的
fastrpc 内核模块；也就是 attach 的 invoke 让 DSP 访问了一块没建立映射的缓冲区，DSP 直接
fatal，随后 remoteproc 把它拉起来。日志里还有一条线索：

```
qcom,fastrpc 2400000.remoteproc:...: no reserved DMA memory for FASTRPC
```

对照 sdm845：`sdm845.dtsi` 里 cdsp 的 fastrpc 节点带 `memory-region = <&fastrpc_mem>`，
而 `fastrpc_mem` 是 `compatible = "shared-dma-pool"`、`alignment = 0x400000`、
`size = 0x1000000`、`reusable` 的池子；`sm8150.dtsi` 的两个 fastrpc 节点
（sdsp / cdsp）**都没有** `memory-region`。所以下一步要做的内核/DTS 工作是：

1. 在 `sm8150.dtsi` 的 `reserved-memory` 里加 `fastrpc_mem`（shared-dma-pool，16 MB，
   4 MB 对齐），并给 sdsp 的 fastrpc 节点加 `memory-region`；
2. 如果 attach 仍然 fault，再确认 DSP 侧是否要求 `sensorspd` 单独的 PD 固件——
   `sensorspd.mbn` 在本机固件目录里不存在（只有 `slpi.*`、`adsp.*`、`modem.*`、`wlanmdsp.mbn`）。

## 4. 已经入库的部分

- `tools/build-userspace.sh` 交叉编译 `hexagonrpcd`（`userspace-tools` 产物里的
  `sbin/hexagonrpcd`）。它需要较新的 `<misc/fastrpc.h>`（`struct fastrpc_invoke_args`
  的 `attr` 成员），构建时从内核 v6.17 取该 UAPI 头。
- `tools/hotdogb-sensors.sh` + `hotdogb-sensors.service`：挂 `persist` → 搭 HexagonFS →
  等 `/dev/fastrpc-sdsp` → 起 `hexagonrpcd` → 重启 `iio-sensor-proxy`。
- 服务**默认关闭**，要 `/etc/hotdogb-sensors.enable` 才允许启动——attach 会让 SLPI
  崩一次，绝不能无人值守地跑。

## 复现

```
$ mount -o ro /dev/sda2 /mnt/persist
$ mkdir -p /run/hotdogb-hexagonfs/sensors/registry
$ cp -a /mnt/persist/sensors/registry/registry/. /run/hotdogb-hexagonfs/sensors/registry/
$ ln -s /sys/devices/soc0 /run/hotdogb-hexagonfs/socinfo
$ systemctl start hotdogb-radio            # SLPI 起来，出现 /dev/fastrpc-sdsp
$ /usr/local/sbin/hexagonrpcd -f /dev/fastrpc-sdsp -d adsp -R /run/hotdogb-hexagonfs
Could not attach to FastRPC node: Broken pipe      # ← 当前卡点
$ tail -6 <(dmesg)
```
