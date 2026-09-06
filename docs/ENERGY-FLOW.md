# 能量流向

仪表盘上的充 / 放 / 待机 / 未知，一律来自 `EnergyFlow.classify`（快照入口再经 `BatterySnapshot.classifiedEnergyFlow()`）。它只看当前功率和可选充电标志，**不**跟循环引擎的充电 / 放电阶段绑定。阈值：`EnergyFlow.idlePowerThresholdWatts` = **1.0 W**。

## 两条真实路径

| 方向 | 电能怎么走 | 不要读成 |
|---|---|---|
| **充电** | **插头 / 适配器 → 电池** | 墙上输入瓦数、适配器输出瓦数 |
| **放电** | **电池 → 本机系统负载** | **回馈墙上插头**、反向送电 |

放电文案只写「供给本机 / 系统负载」。即使 `ExternalConnected` 为真、系统正在用适配器，放电也**不**画插头、**不**写回馈电网。概览图：充电是插头→电池；放电是电池→笔记本。

近零且 `isCharging == true` 时，`EnergyFlow.classify` 覆盖为**涓流充电**（仍是插头→电池），不是待机。

## `unknown` 不是真 0 W 待机

兼容字段 `watts` 在捕获失败或缺键时仍可能是 `0`。那不是测到的零功率。

| 情况 | `EnergyFlow.classify` | 含义 |
|---|---|---|
| 快照不可用，或 `wattsIsAvailable == false`（缺瓦数键；兼容 0 仍可能出现） | **unknown** | 没测到功率。禁止画成待机、充电或放电 |
| 功率键齐全，且 `\|W\| < 1.0`，且没有涓流覆盖 | **idle** | 近零待机。含 **真 0 W**（`wattsIsTrueZero`：键齐全且 `\|W\| < 1e-6`） |
| `isCharging == true` 且瓦数 ≤ −1 W | **unknown** | 标志与瓦数冲突 |
| `\|W\| ≥ 1.0` | 充电或放电 | ±1 W 落在充 / 放，不落 unknown |

传入 Bool API 的 `isCharging == false` 只表示「没有涓流覆盖」。缺 `IsCharging` 键时快照映射为 false，**不**当成测到的「未在充电」；流向仍由瓦数决定。缺 `Power Source State` 时 `drawingFrom` 为 `"unknown"`，那是缺键占位，不是电源描述。

历史里缺测瓦数和睡眠缺口不得存成 0 W，也不得按零能量积分。

## 电池瓦数 ≠ 适配器瓦数

`EnergyFlow.classify` 用的是电池侧净功率（IOKit Voltage × InstantAmperage），**不是**适配器输出、协商功率或整机功耗。

- 电池净功率：流向分类与「电池净功率」行。
- 适配器额定瓦数：仅当 `AdapterDetails` / IOPS `Watts` 有独立键时展示；额定 ≠ 瞬时输出。
- 适配器输出 / 协商 / 系统功率：公开 IOKit 键常缺则保持不可用。**禁止**把电池瓦数填进这些槽。

物理插着（`ExternalConnected`）和系统正在用适配器（IOPS Power Source State）是两行，不能互相冒充。

## 真机适配器 HOLD

本页只说明**被动监测**里的流向语义。batt 0.8+ 真机适配器行为仍为 **HOLD**：未做监督真机验收。单元测试、mock、脚本替身**不能**解除 HOLD，也**不得**据此声称设备已接受。本页不填写、不引用任何测试通过数。
