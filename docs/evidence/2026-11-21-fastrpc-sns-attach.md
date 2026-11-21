# SSC 传感器：FastRPC 反向隧道与 sm8150 的节点形态（2026-11-21）

SLPI 能起、QRTR 上能看到 SSC（service 400），但 `iio-sensor-proxy` 一直拿不到传感器。
链路逐段验下来是三个独立的问题：用户态缺 `hexagonrpcd`、缺 FastRPC 的预留内存，
以及**DTS 的 compute context 形态不对**。前两个已解决，第三个由 `patches/0014` 修。

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

内核侧 fastrpc 本身可用：`CONFIG_QCOM_FASTRPC=m`，SLPI 起来后 `/dev/fastrpc-sdsp` 存在
（`2400000.remoteproc`，`label = "sdsp"`），ADSP 是 `/dev/fastrpc-adsp`。

## 3. 第一层：没有预留内存，attach 时 DSP 拿到没映射的地址

`sm8150.dtsi` 的 sdsp fastrpc 节点没有 `memory-region`，于是：

```
qcom,fastrpc 2400000.remoteproc:...: no reserved DMA memory for FASTRPC
arm-smmu 15000000.iommu: Unhandled context fault: iova=0x1fffff000, cbfrsynra=0x5a1
qcom_q6v5_pas 2400000.remoteproc: fatal error received: EX:kernel:frpck_0_0
```

下游只有一个池（`adsp_region`）：`shared-dma-pool`、16 MB、4 MB 对齐、`reusable`。
把它加进 `reserved-memory` 并挂到 sdsp 之后，`assigned reserved memory node fastrpc-mem`
出现，`/dev/fastrpc-sdsp` 正常，SMMU fault 消失——但 attach 仍然把 SLPI 打崩。

## 4. 第二层（真正的根因）：compute context 必须是 sdm845 的形态

上游唯一让 SLPI 传感器跑通的是 sdm845，它的 fastrpc 节点是：

```dts
label = "sdsp";
qcom,non-secure-domain;
qcom,vmids = <QCOM_SCM_VMID_HLOS QCOM_SCM_VMID_MSS_MSA
              QCOM_SCM_VMID_SSC_Q6 QCOM_SCM_VMID_ADSP_Q6>;
memory-region = <&fastrpc_mem>;
#address-cells = <1>;
#size-cells = <0>;

compute-cb@0 {
	compatible = "qcom,fastrpc-compute-cb";
	reg = <0>;
};
```

关键是**只有一个 compute context bank，而且完全没有 `iommus`**：传感器进程在 SMMU 上是
旁路的，用物理地址访问那块由 hypervisor 分配的池。sm8150 原本给同样的 stream ID 挂了三个
**带翻译**的 context bank（`0x5a1`–`0x5a3`），DSP 第一次访问就落进它不该看到的页表：

```
arm-smmu 15000000.iommu: Unhandled context fault: fsr=0x402, iova=0x1fffff000, cbfrsynra=0x5a1
qcom_q6v5_pas 2400000.remoteproc: fatal error received:
                         EX:sensor_process:0x1:frpck_0_0:0x5b
```

同一颗 SoC（sm8150）在别的设备上有过完全相同的现象和结论，见
[bentlybro: Mainline Linux on the Galaxy Tab S6](https://bentlybro.com/posts/mainline-linux-on-the-galaxy-tab-s6-a-32-byte-field-and-one-line-of-device-tree)。

另外两点容易误判：

- `qcom,vmids` 不能省。7.3.3 的 `fastrpc_rpmsg_probe()` 对 sdsp 会把
  `qcom_scm_assign_mem()` 的返回值当失败处理（6.x 只是忽略），没有 vmids 时报
  `Assign memory protection call failed -22` 并让 probe 失败。DSP 崩过一次之后
  那块内存已经归 DSP 所有，重新 probe 的重复赋值也必然 `-22`，所以这个错误是
  “SLPI 崩过”的后果，不是原因。
- 传感器 PD 确实在 SLPI 上：厂商 DT 的 `qcom,msm-ssc-sensors` 写的是
  `qcom,firmware-name = "slpi"`，`-f /dev/fastrpc-sdsp` 是对的。

## 5. 已经入库的部分

- `patches/0014-arm64-dts-qcom-sm8150-fix-the-SLPI-fastrpc-node.patch`：`fastrpc_mem`
  池（16 MB / 4 MB 对齐 / reusable）+ sdsp 的 `qcom,vmids`、`memory-region`，并把三个
  带 `iommus` 的 compute-cb 换成单个 `compute-cb@0`。
- `tools/build-userspace.sh` 交叉编译 `hexagonrpcd`（`userspace-tools` 产物里的
  `sbin/hexagonrpcd`）。它需要较新的 `<misc/fastrpc.h>`（`struct fastrpc_invoke_args`
  的 `attr` 成员），构建时从内核 v6.17 取该 UAPI 头。
- `tools/hotdogb-sensors.sh` + `hotdogb-sensors.service`：挂 `persist` → 搭 HexagonFS →
  等 `/dev/fastrpc-sdsp` → 起 `hexagonrpcd` → 重启 `iio-sensor-proxy`。
- 服务暂时仍要 `/etc/hotdogb-sensors.enable` 才启动，等真机确认 attach 不再崩溃后
  去掉这个开关。

## 复现

```
$ mount -o ro /dev/disk/by-partlabel/persist /mnt/persist
$ mkdir -p /run/hotdogb-hexagonfs/sensors/registry
$ cp -a /mnt/persist/sensors/registry/registry/. /run/hotdogb-hexagonfs/sensors/registry/
$ chmod -R a+rX /run/hotdogb-hexagonfs
$ ln -s /sys/devices/soc0 /run/hotdogb-hexagonfs/socinfo
$ systemctl start hotdogb-radio                     # SLPI 起来，出现 /dev/fastrpc-sdsp
$ /usr/local/sbin/hexagonrpcd -f /dev/fastrpc-sdsp -d adsp -s -R /run/hotdogb-hexagonfs
$ gdbus call --system -d net.hadess.SensorProxy -o /net/hadess/SensorProxy \
      -m org.freedesktop.DBus.Properties.GetAll net.hadess.SensorProxy
```

`GetAll` 里应出现 `HasAccelerometer=true`、`HasLightSensor=true`；`monitor-sensor --accel`
会打印倾角。
