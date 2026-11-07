# WCD9340 + TFA9874：听筒和底部扬声器出声（2026-11-07）

## 结论

声卡 `OnePlus 7T` 注册成功，三条输出链路都在真机上出声：

- 耳机：`SLIMBUS_6_RX` → WCD9340 `AIF4_PB` → `RX INT1/2`
- 听筒：`SLIMBUS_6_RX` → `RX INT0_1 MIX1` → `CLSH_DSM_OUT` → `EAR PA`
- 底部扬声器：`QUATERNARY_MI2S_RX`（DAI id 22）→ `i2c@890000` 上的两颗 TFA9874

```
$ cat /proc/asound/cards
 0 [O7T            ]: sm8150 - OnePlus 7T
                      OnePlus 7T

$ dmesg | grep tfa
tfa9874 0-0034: TFA9874 revision 0x0c74 detected on TDM slot 0; amplifier remains disabled
tfa9874 0-0035: TFA9874 revision 0x0c74 detected on TDM slot 1; amplifier remains disabled
tfa9874 0-0034: OxygenOS speaker profile prepared on TDM slot 0; output muted
tfa9874 0-0034: unmuted status0=0017 status1=e2c0 status3=850f temp=0018
tfa9874 0-0035: unmuted status0=0017 status1=e2c2 status3=850f temp=0019
tfa9874 0-0034: pre-mute status0=0016 status1=e2c0 status3=850f temp=001a
```

`sndtool play 5`：`w pos/components` 稳定递增，`wrote 240000 frames`、`drained`，
播放期间 `status0=0x0017`（`PWDN=0`），没有 XRUN。听感确认底部扬声器有输出。

## 硬件位置

| 项目 | 值 |
|---|---|
| 功放 | NXP TFA9874 ×2，I2C 0x34 / 0x35 |
| 总线 | `i2c@890000`（SE4，GPIO51/52），父节点 `geniqup@8c0000` |
| 音频接口 | `QUATERNARY_MI2S_RX`，GPIO137/138/139/140，BCLK 3 072 000 Hz |
| 采样格式 | S24_LE（与 OxygenOS 一致），48 kHz / 2ch |
| 复位 | **不描述**。下面那颗的复位和 FSA4480 enable（GPIO100，低有效）共用 |

## 路由命令

```sh
# 听筒
sndtool set "SLIMBUS_6_RX Audio Mixer MultiMedia1" 1
sndtool set "SLIM RX1 MUX" AIF4_PB
sndtool set "RX INT0_1 MIX1 INP0" RX1
sndtool set "RX INT0_1 INTERP" "RX INT0_1 MIX1"
sndtool set "RX INT0 DEM MUX" CLSH_DSM_OUT
sndtool set "EAR PA Volume" 4

# 底部扬声器
sndtool set "QUAT_MI2S_RX Audio Mixer MultiMedia1" 1
```

## 踩坑

1. **`ASoC: failed to instantiate card -19`**：新加的 `speaker-dai-link` 放在 `&sound`
   的第一个。q6routing 作为 platform 组件被提前 probe，此时 q6afe/q6asm 的 DAI widget
   还不存在，DAPM 路由返回 `-ENODEV`，整张卡注册失败。
   把 speaker link 移到**最后**即可。

2. **I2C 总线号不是 4**。DT 里节点是 `i2c@890000`，但 `i2c4` label 没有对应
   `aliases`，内核动态分配总线号，实测是 `0-0034` / `0-0035`。

3. **XRUN 是假象**。`sndtool` 没设 `sw_params.stop_threshold`（默认 0，`avail>=0`
   恒真），流会立刻 XRUN。设成 buffer 大小后稳定 RUNNING。

4. **复位脚不能照抄原厂**。原厂 DT 给两颗 TFA 各配了一个 reset-gpio，其中 GPIO100
   和 FSA4480 的 enable 共用；主线拉起 TFA 复位会把 Type-C 模拟开关一起动掉。

## 镜像

`boot-hotdogb-spk5.img`（audio7 内核 + 带 TFA 的 DTB + `/mods` 32 个文件）。
