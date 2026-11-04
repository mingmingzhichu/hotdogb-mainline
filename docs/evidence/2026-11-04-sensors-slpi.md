# 传感器 DSP（SLPI / SSC）起来了（2026-11-04）

## 结论

**SLPI 固件加载成功，传感器服务已经出现在 QRTR 上。** 还差用户态客户端，但内核和固件这一侧
通了。

```
$ for r in /sys/class/remoteproc/*; do echo $(cat $r/name) $(cat $r/state); done
slpi running
modem offline
adsp offline

$ dmesg | grep -i slpi
[    2.439301] init: wlanmdsp 4070084 bytes, slpi 21 fragments
[    4.462542] remoteproc remoteproc0: powering up slpi
[    4.463678] remoteproc remoteproc0: Booting fw image qcom/sm8150/oneplus7/slpi.mdt, size 8380
[    4.583036] remoteproc remoteproc0: remote processor slpi is now up
[    6.587728] init: slpi running

$ /bin/qrtr-lookup | grep -i sensor
      400       1        0    9    13 Snapdragon Sensor Core service
```

## 固件在哪

就在 **`modem_a`** 里，和 `wlanmdsp.mbn` 同一个 FAT16 分区。`/vendor/firmware_mnt` 在 Android
里挂的就是这个分区（`/vendor/etc/fstab.qcom` 里写着
`/dev/block/bootdevice/by-name/modem /vendor/firmware_mnt vfat ro ...`），所以
`slpi.mdt` / `slpi.b00..b20` / `adsp.*` / `cdsp.*` / `venus.*` 全在那儿，共 335 个文件。

不用碰 `super` 里的 vendor 逻辑分区（虽然也能读：`super` 是 LP 格式，`vendor_a` 在
偏移 4551344128、大小 588075008，用 `losetup -o` 就能只读挂上；`tools/lpdump.c` 是为此写的
解析器，留作以后取 vendor 里的东西用）。

SLPI 全套只有 6 MB（`slpi.mdt` 8 KB + 21 个分片），所以由 `/init` 在挂 `modem_a` 时顺手
拷到 `/lib/firmware/qcom/sm8150/oneplus7/`，不占 ramdisk。

## 为什么之前没有

板级 DTS 里 `&remoteproc_slpi` 是 `status = "disabled"`（`sm8150.dtsi` 默认关闭），而且没有
`firmware-name`。只加这两行就够：

```dts
&remoteproc_slpi {
	status = "okay";
	firmware-name = "qcom/sm8150/oneplus7/slpi.mdt";
};
```

启动顺序有要求：**pd-mapper 必须先答出 slpi 的 protection domain**（它读的就是 initramfs 里
`slpir.jsn` 那份 map），所以 `/init` 是在 rmtfs/pd-mapper/tqftpserv 起来之后才
`echo start > .../state`。

## 还差什么

内核侧完了。剩下的是用户态：SSC 是 QMI 服务（service 400），需要一个 QMI SSC 客户端把
传感器枚举出来并导出成 IIO/input。pmOS/Debian 里就是 `libssc` + `iio-sensor-proxy`，不用自己写。

## 顺带：GPS 的门也是开的

GPS 在这颗 SoC 上跑在 MPSS 里，不在 AP。MPSS 起来之后 QRTR 上已经有：

```
       16       2        0    0    83 Location service (~ PDS v2)
```

也就是说 GPS 的硬件路径是通的（这是 Wi-Fi 那套 MPSS 起来后的副产品），差的是用户态 QMI LOC
客户端（`gnss-share` / `libqmi`），同样归 Debian。

## 注意

这次启动用的 DTB 是 **从 `good22.dtb` 反编译后手改的**（只加 slpi 节点），不是源码重编的：
源码工作区的 DTS 比 good22 多两个没验证过的属性（面板 `pinctrl-0`、`qcom,te-source`），
所以沿用验证过的那棵。源码 DTS 里也补了同样的节点，以后重新编译不会丢。
