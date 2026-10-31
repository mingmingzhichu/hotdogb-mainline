# GPU 固件（Adreno 640）

主线 `msm/adreno` 驱动跑通 GPU 需要的三份固件。

> **版权归 Qualcomm / OnePlus**，这里只用于本机 bring-up 验证，不要再分发。
> 原始来源：设备 `vendor` 分区（super 动态分区里的 `firmware/`），ZAP 取自
> `firmware-oneplus-sm8150` 仓库（和原厂 `.elf` 同尺寸但内容不同，只有这份能在
> 这棵内核上通过 ZAP 加载）。

| 文件 | 目标路径 | 说明 |
|---|---|---|
| `qcom/a630_sqe.fw` | `/lib/firmware/qcom/a630_sqe.fw` | SQE 微码，a630/a640 共用 |
| `qcom/a640_gmu.bin` | `/lib/firmware/qcom/a640_gmu.bin` | GMU 固件 |
| `qcom/sm8150/a640_zap.mbn` | `/lib/firmware/qcom/sm8150/a640_zap.mbn` | ZAP，DT 的 `firmware-name` 指向这里 |

## 部署

```sh
mkdir -p /lib/firmware/qcom/sm8150
cp qcom/a630_sqe.fw          /lib/firmware/qcom/
cp qcom/a640_gmu.bin         /lib/firmware/qcom/
cp qcom/sm8150/a640_zap.mbn  /lib/firmware/qcom/sm8150/
```

## 注意

- `adreno_request_fw()` 只尝试 `qcom/<文件名>` 和 `<文件名>`，**没有按 SoC 分子目录**；
  所以 GMU 必须放在 `qcom/a640_gmu.bin`，放在 `qcom/sm8150/` 下会加载失败。
- ZAP 例外：它用的是 DT 里 `firmware-name` 的完整路径，所以放在
  `qcom/sm8150/a640_zap.mbn`。
- 校验值：

```
a0e1b583f620fabe32729ce367959d1960638663244d7d0cfc21b9a5215a018b  qcom/a630_sqe.fw
3ff0c02708bbe78641db887fa62f3a7f9337934d0c2ce0b961ef7c43172591d2  qcom/a640_gmu.bin
e6b0e70f09757221efa203e409ca5ca9f17551a2052b20adfb995fbae8cf6e5d  qcom/sm8150/a640_zap.mbn
```

## 验证

```sh
head -6 /sys/kernel/debug/dri/0/gpu
#   gpu-initialized: 1
#   revision: 640 (6.4.0.1)
```
