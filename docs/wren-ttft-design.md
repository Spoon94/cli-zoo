# wren TTFT 设计（feat/ttft_support）


> **勘误（七轮深度审核后实测序）**：行1 让位序现为「时长 → ahead-behind → 分支六档 → cwd 地板」——§4 的「时长首丢」在新穷举实现（决策 2 定稿：with_ab 提到 floor 外）下已成立；§1.1-1 相关段落以 wren-cc.py 当前注释为准。

三宿主 statusline 增加 TTFT 段。本文是定案记录 + 实现规格，CR 用。

## 1. 定案（不再讨论）

- 两行不动，不加第三行。**时长上移行1 尾**：行1 = `cwd | 分支 | herdr | 徽标 · 时长`（会话级 meta 尾槽，与行1 慢变轴一致；时长是 qc 侧最弱数据，放最易被窄终端截断的槽位，价值-脆弱位对齐）。
- 行2 分组不变：`账本 | 状态 | 身份`。TTFT 归**状态组**（与 ctx% 同刷新周期，都是「最近一轮请求」的属性）；身份组 = `模型 · 思考`（仅尾 ` · ` 保留处）。
- 分隔符（p4 方案）：组间 `|`（comment 灰）；组内空格；仅身份组内用 ` · `。行1 尾 `徽标 · 时长` 同用 ` · `。
- 折叠梯子：**行1** 溢出先丢时长（见 §4），再走现有 path_budget 折叠 + truncate 硬截；**行2** 溢出按序丢弃 **TTFT → CH → CP**（新段先丢）。
- 宽度口径：行1 56–71 格（短时长值组合；时长取 9 格上界再 +2）；行2 由 p4 实测（含 TPS 时 79/84）减 TPS 段推得短值约 74 / 长值约 78，实现期实测回填——80 列下长值组合靠梯子回到界内。

## 1.1 硬约束（p4，实现必须逐条满足）

1. **行1 尾部顺序写死 `| 徽标 · 时长`**，不可调序；且时长是行1 折叠梯子的**首丢项**，但触发点是 cwd 折叠地板：cwd 先走 path_budget 折叠（含时长 9 格预留），仅当折到 16 格地板仍溢出（`rest + 16 > term_w`）才丢时长退裸徽标。常规长路径场景 cwd 折叠即可容纳时长，时长不丢。
2. **可变长字段按上界常量预留预算**，折叠不随数值抖动：TTFT 按 **11 格**（如 `TTFT 99m59s`）、时长按 **9 格**（`dwidth(" · 99h59m")`，含 ` · ` 分隔符 3 格）计入行1 `rest` / 行2 预算。实际值短于上界 → 行偏短但不抖；`fmt_duration` 加钳制 **>99h59m → `99h+`**，永不出界。
3. **qc 时长语义 = transcript 推算的会话年龄**（宿主不发 `total_duration_ms`，`首条记录 ts → now`），不是宿主计的活跃时长；README 写明。

被否方案存档：B（TTFT/TPS 上移行1，污染位置语义 + 挤 path_budget）、C（第三行，qodercli 二进制支持多行但破坏三宿主同构）、D 原版（身份组整组上移，劣化方向挤 cwd）、D 收窄变体（模型·思考上移——较有价值段占了截断首位，方向反了；被「仅时长上移」版取代）、**TPS 全侧砍**（cc 簇含工具循环致速率失真 4.8 vs 28.2；qc 下一条记录同刻写盘会除零；pi 唯一可行但为同构放弃）。

## 2. 语义定义

| 段 | 定义 | 口径 |
|---|---|---|
| TTFT | 用户消息提交 → 该轮**首条落盘** assistant 记录的时间差 | 落盘延迟，不是网络首 token 时刻 |

落盘延迟系统性偏大于真首 token 延迟，**主因是整段 thinking 耗时**（实测中位 13.2s、p90 92.6s），不是写盘节流；thinking 关闭时首块变 text/tool_use（约 31% 回合）——同段语义随 thinking 档位漂移，README 写明。语义已定为落盘口径，属定义不是 bug。README 需写死各宿主公式，防三侧口径漂移被当对错。

## 3. 布局与格式

```
行1: ~/cwd | branch ↑a↓b +增 ~删 ✱改 | ws:tab:pane | cc · 1h5m
行2: ↑in ↓out | R24K CH91.66% CP1 | 21.57%/200K TTFT 6.6s | zap · max
     └──────── 账本 ────────┘   └──── 状态 ────┘   └ 身份 ┘
```

- 状态组 = 现 ctx% 段扩容：`ctx%/win` + 空格 + TTFT。
- 身份组瘦身：只剩 `模型 · 思考`；时长上行1 尾（缺失时整段隐藏，不留悬空 `·`；预算按上界 9 格含分隔符计入行1 `rest`，非实际宽度）。
- 格式：TTFT 写 `TTFT 6.6s`（<10s 一位小数；≥10s 整数；≥60s `TTFT 1m05s`；≥1h `TTFT 1h40m`），上界 11 格（如 `TTFT 99m59s`）。时长沿用 `fmt_duration` 的 `1h5m` 式（与 T53 一致），加钳制 >99h59m → `99h+`。
- 色：TTFT 四档突变（绿 <5s / 白 5-20s / 黄 20-60s / 红 >60s），阈值取自实测分布；不新增色板条目（复用既有 Dracula 名）。

## 4. 折叠梯子

- **行1 梯子**：时长按 9 格上界（含 ` · ` 分隔符）计入 `rest`；预算超界（`path_budget` 已到 16 地板仍溢出）→ **先丢时长**（整段退回裸徽标 `| cc`），再溢出走现有 truncate 硬截。顺序与首丢项写死，见 §1.1-1。
- **行2 梯子**：拼接前按 `dwidth` 预算逐段剔除，不是事后截断：候选段按丢弃优先级 `TTFT → CH → CP`；再溢出走现有 `truncate_display` 硬截兜底。TTFT 的预算宽度同样用上界常量（11 格），数值变化不改变折叠决策。
- 现行 line1/line2 均无段级预算逻辑，需新增「段列表 + 逐段剔」结构（wren-cc.py / wren-pi.ts / wren-qc.py 同构实现）。
- 永不参与剔除：`↑in↓out`、`ctx%/win`、模型名。

## 5. 数据源（已核实部分标注）

### cc（wren-cc.py）

transcript 每条 user/assistant 记录独立 `timestamp`，同轮 assistant 成簇、首条常为 `thinking` 块（实测 `~/.claude/projects`：user 04:18:46.065 → 首条 thinking 04:18:52.682）。

- TTFT = `本轮首条 assistant.ts − 同轮 user.ts`。**「同轮 user」必须排除 tool_result 回填**（`type=user` 但 `content` 是 tool_result 的记录）——否则测到的是工具往返（实测可低至 0.078s）。
- 实现挂在现有增量解析：`accumulate` 增记轮窗口（user_ts、first_ts），写进状态缓存。

### qc（wren-qc.py）

transcript user/assistant 记录**各只有一个 `timestamp`**，无 duration 字段（实测 3 个 session 35 条 usage）。

- TTFT = `assistant.ts − 上一条 user.ts`（同 cc 式，同样排除 tool_result 回填，粒度即落盘）。
- **时长 = transcript 推算的会话年龄**（首条记录 ts → now；宿主不发 `total_duration_ms`），见 §1.1-3。

### pi（wren-pi.ts）

**方案已定（数据源核实）**：`turn_start` + `message_update` 事件在 pi-coding-agent **0.85.1** 类型定义里逐字核实存在。挂事件流计时：

- `turn_start` 记轮首时刻；
- 首个 `message_update` 记首片时刻 → **TTFT = 首片 − turn_start**（事件流真首片，比 cc/qc 的落盘口径更准）。

pi 侧不落盘回放（现 `sessionManager.getBranch()` 只补静态字段），计时状态存扩展内存；与 cc/qc 的口径漂移已知，README 写死。

## 6. 状态缓存与兼容

- cc/qc：`ZERO_STATE` 增 TTFT 及轮窗口原始字段（user_ts、first_ts），落 `~/.cache/wren` 增量缓存；旧缓存文件缺键按默认值（`None`）合并，不失效重建。
- pi：计时状态存扩展内存（事件流），不落盘、不进 transcript 缓存。

## 7. 测试计划

续 T 编号（现至 T67），`.test_task/wren-test.md` + `wren-test.sh` + `.test_res` 同步：

| 项 | 输入 | 断言 |
|---|---|---|
| cc TTFT | user + thinking 首条簇（6.6s） | `TTFT 6.6s` |
| cc TTFT 排回填 | 簇内含 tool_result 回填 user 记录 | 回填不计轮首，TTFT 仍对首条真 user |
| qc TTFT | assistant − user | `T…` |
| pi 事件计时 | harness 扩成可发 `turn_start` + `message_update` 事件 | TTFT 按事件流口径出值 |
| 时长归位 | 常规会话 payload | 时长出现在行1 徽标段、**不在行2** |
| 行1 梯子 | 极窄 `COLUMNS` + 长分支 + 满段 | 先丢时长（退回裸徽标），cwd 折叠其后才触发 |
| 上界不抖动 | 同宽度下 TTFT 1.2s↔TTFT 99m59s、1m↔99h+ 两两对比 | 折叠决策不变（rest/预算用常量） |
| 梯子同构 | 三宿主同输入同 `COLUMNS` | 折叠决策、段序一致（T80：`90/81/80/70/65/55` 六档逐档同签名） |
| 折叠梯子 | 逐级窄 `COLUMNS` | 依次丢 TTFT→CH→CP，`↑in↓out`/ctx%/模型名保留 |
| 悬空分隔符 | 时长缺/在、TTFT 缺/在的部分存在组合 | 无悬空 `·`、无空段、无重复分隔符 |
| EOF 升级 | 旧缓存 offset==EOF 后 transcript 追加新记录 | 旧缓存 offset==EOF 时，TTFT 在收到下一条真 user 消息前保持隐藏（不占位）；追加后出现，且不重扫已消费行 |
| 零态 | transcript 无成对记录 | TTFT/时长全隐藏不占位 |
| 缓存兼容 | 旧格式缓存文件 | 缺键默认值，输出不炸 |

三份 README（主、wren 子、qc 数据源表）增 TTFT 行与 qc 时长语义，各宿主公式写死。

## 8. 风险

- TTFT 含整段 thinking 耗时（中位 13.2s）——定义内，不修；档位漂移已在 §2 记录。
- pi 事件计时依赖 0.85.1 事件名，宿主升级可能改名——README 记版本锚点。
