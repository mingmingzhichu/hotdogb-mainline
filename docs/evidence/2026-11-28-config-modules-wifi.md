# 配置、模块与 Wi-Fi 的两次自摆乌龙（2026-11-28）

这一天的三个改动彼此无关，但都指向同一件事：**构建链里的每个环节都要能被验证，而不是被相信。**

## 一、配置合成一份

原来是 `hotdogb_defconfig`（9361 行 `.config`）+ 三份片段，CI 用
`merge_config.sh` 叠上去，再 `olddefconfig`。问题在于：本地看到的
`.config` 和 runner 上解出来的不一定是同一个。

现在只有一份 `configs/hotdogb_defconfig`，1096 行，`make savedefconfig` 的产物。
验证方式是在干净 7.3.3 + 全部补丁的树上跑一遍：

```
单文件 defconfig → make hotdogb_defconfig → 3104 行 CONFIG
旧的三步 merge    → 3104 行 CONFIG
diff               → 完全相同
```

三份片段里的“为什么”搬到了 `configs/README.md`，`tools/make_defconfig.sh`
负责在 `menuconfig` 之后重新生成（不手改）。

顺带消掉三条每次 configure 都刷的警告（`IPV6`/`NETFILTER_NETLINK`/`MULTIPLEXER`
被写成了 `=m`，但它们已经是 bool）。

## 二、ath10k 模块其实是 7.0.0 的

`firmware/wifi-modules/` 里那 5 个“真机验证过”的模块，vermagic 是：

```
7.0.0-sm8150-g8e126dbc4044-dirty SMP preempt mod_unload aarch64
```

内核是 `7.3.3-sm8150`。`insmod` 必然失败，而且脚本当时把 stderr 丢了，
只剩一句 `insmod ath10k_snoc failed`。于是：

- 最近所有 netboot 真机测试里，**ath10k 从来没有被加载过**
- `wlan0` 不出现、`WLFW` 等不到、以及“ath10k probe 之后掉 EDL”这个结论，
  都建立在一个从未发生过的 probe 上

这批文件已删除；CI 现在只装同一次构建的模块，并对镜像里每个 `.ko` 做
`modinfo -F vermagic` 比对，对不上直接失败。

同一时刻的另一个 bug 让 CI 先挂了：那个 job 没有 `actions/checkout`，
`firmware/wifi-modules/` 压根不在工作区里（`cp: cannot stat`）。两个错误叠在
一起，表现出来是“Wi-Fi 不工作”，而不是一条明确的报错。

## 三、7.0 和 7.3.3 的 ath10k 差得很少

既然 probe 从没发生过，重估风险时先看代码。用 `snoc.c` / `qmi.c` 对比：

| 文件 | 变化 |
|---|---|
| `ath10k/snoc.c` | 17 行：`pwrseq_power_on/off` → `pwrseq_enable/disable`；MSA dump 从 `memcpy` 改成 `memcpy_fromio`；新增 `qcom,snoc-host-cap-skip-quirk` 开关 |
| `ath10k/qmi.c` | `ath10k_qmi_host_cap_send_sync()` 可以被 quirk 跳过，其余不变 |

`qcom_scm_assign_mem()` 那段（MSA 权限分配，当年 -22 的来源）一行没动。
所以换回同源模块的驱动行为应该和 7.0.0 那次成功时一致。

## 四、LCDB 补了短路上报

`qcom-lcdb-regulator` 原来只在 enable 时看到 `SC_ERROR` 打一条 warning。
现在 DT 里给了 `interrupts = <0x4 0xec 0x1 IRQ_TYPE_EDGE_RISING>` 之后会注册
线程化中断：

- 读 `INT_RT_STATUS` 确认是 SC 才处理（否则 `IRQ_NONE`）
- 直接下电（`MODULE_EN` 清零 + LDO 强制放电），不做自动重试 —— 自动重试会和
  面板自己的上电时序打架
- 1 秒窗口内超过 3 次就置 `sc_fault`，之后 `enable()` 直接返回 `-EIO`，
  不再给一块明显短路的板子上电

已经编译过、DTB 里能看到该节点，但**没有在真机上触发过短路**，所以这条路径
属于“写好了但没验证”。

## 五、下一步

1. 等 CI 出一次干净的 release（Image 与 modules 同源）
2. 真机按 `hotdogb-radio.sh start → diag → wifi` 走，第一次真正观察 ath10k
   在 7.3.3 上的 probe
3. 如果 probe 又掉 EDL，那就是驱动/SCM 的问题，去比 7.0.0 与 7.3.3 的
   `qcom_scm` 与 SMMU 侧，而不是再换二进制
