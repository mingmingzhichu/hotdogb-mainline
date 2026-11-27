# LCDB 寄存器来源

`qcom-lcdb-regulator.c` 里的寄存器偏移、电压编码、boost 头寸算法都不是猜的，全部来自原厂
内核驱动和原厂 DTS，下载位置（2026-11-27 取的）：

```
仓库  https://github.com/OnePlusOSS/android_kernel_oneplus_sm8150
分支  oneplus/SM8150_R_10.0

drivers/regulator/qpnp-lcdb-regulator.c        寄存器定义、上下电流程、电压编码
drivers/regulator/qpnp-labibb-regulator.c      PMI8998 版本，主线那个驱动的原型，仅作对照
Documentation/devicetree/bindings/regulator/qpnp-lcdb-regulator.txt
                                               原来的 DT 属性说明
arch/arm64/boot/dts/qcom/pm8150l.dtsi          lcdb@ec00、ldo/ncp/bst 子节点的写法
arch/arm64/boot/dts/qcom/hotdogb_sm8150.dtsi   原厂把 lcdb 打开的地方
arch/arm64/boot/dts/qcom/dsi-panel-samsung_sofef03f_m_fhd_dsc_cmd.dtsi
                                               面板节点，引用 dsi_panel_pwr_supply
arch/arm64/boot/dts/qcom/sm8150-sde-display.dtsi
                                               dsi_panel_pwr_supply：lab/ibb 的 4.6-6.0V 范围
```

从原厂 `dtbo_a`（`lin/dtbo.img`）反解出来的节点确认了几个数：

- LCDB 的 SPMI 基地址是 **0xec00**
- 子节点 `ldo`/`ncp`/`bst` 的 `regulator-min/max-microvolt` 是范围（4.0–6.0V / 4.7–6.275V），不是定值
- 原厂 supply table 给 `lab`/`ibb` 的都是 **4.6V 起**，`qpnp_lcdb_*_set_voltage()` 取的是
  `min_uV`，所以真机上这两路跑在 4.6V

这些文件本身没有放进来（体积大、且是厂商 GPL 代码，不适合拷进本仓库）；需要对照时重新按上面的
路径下载即可。
