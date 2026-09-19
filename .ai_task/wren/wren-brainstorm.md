# wren 设计文档（brainstorm 输出）

> 把 statusline 装到 Claude Code 与 pi 两个宿主上的安装器。（payload 原名 odo.py / odo.ts，改名见第 10 节。）
> payload 来自 `wren.py`（Claude Code statusline，v4 两行版）与 `wren.ts`（pi 扩展，同一 statusline 的另一实现）。

---

## 1. 命名与职责

`wren`（鹪鹩）：体型极小、不起眼，但鸣声不停，对应 statusline 在后台持续输出会话状态。
短、单数、常见动物英文名（4 字母），与既有 `otter` 同风格。

**wren 是安装器，不是重写。** wren 只负责把 payload 接到位；payload 自身的逻辑除第 9 节记录的三处修复外保持原样：

| 文件 | 角色 |
|---|---|
| `zoo-scripts/wren/wren` | 安装器（本设计的实现对象） |
| `zoo-scripts/wren/wren.py` | payload：Claude Code 侧 statusline，未改 |
| `zoo-scripts/wren/wren.ts` | payload：pi 侧扩展，**改过三处**（见第 9 节的调研结论） |

## 2. 目录结构

```
zoo-scripts/wren/
  wren        安装器（可执行入口）
  wren.py      payload
  wren.ts      payload
```

本仓库此前的约定是「`zoo-scripts/<动物名>` 是单个可执行脚本」。wren 是首个多文件工具，因此
`zoo-scripts/wren` 是**目录**，入口脚本在其内部。`cli-zoo-install.sh` 的 `wren` 分支因此
软链 `zoo-scripts/wren/wren` 而非 `zoo-scripts/wren`。

目录内的 `wren` 与 `wren.py` / `wren.ts` 平级，所以入口被软链出去以后必须能回溯到自己的真实位置才能找到
payload（见第 4 节 `script_dir`）。

## 3. 命令行接口

```
wren install [cc|pi|all]      # 安装（幂等，重复执行覆盖为最新副本）
wren uninstall [cc|pi|all]    # 卸载（只删自己装的那份，被改过的不动）
wren -h                       # 帮助
```

无参数、未知子命令 → usage 到 stderr，exit 2。

target 选择（省略 = all）：

| target | 行为 |
|---|---|
| `all` | 两侧都装 |
| `cc`（别名 `claude`） | 只装 Claude Code 侧 |
| `pi` | 只装 pi 侧 |

只装 pi 时不需要 python3（它只用在合并写 settings.json 的 cc 侧）；未知 target → exit 2 且零副作用。
**实现注意**：target 的归一化不能放在 `$(...)` 里调用，那会跑在子 shell，`exit 2` 只退出子 shell，
主流程拿到空串继续当 `all` 跑。第一版踩过这个坑，改为先归一化进全局 `TARGET` 再分发。T36 守门。

环境变量（既是可配置项，也是测试钩子）：

| 变量 | 默认 | 作用 |
|---|---|---|
| `PREFIX` | `/usr/local/bin` | CC 侧可执行文件目录 |
| `PI_EXT_DIR` | `$HOME/.pi/agent/extensions` | pi 扩展目录 |
| `CLAUDE_SETTINGS` | `$HOME/.claude/settings.json` | 要改的 settings 文件 |

三个变量都可覆盖，所以测试能全程在 `mktemp -d` 内作业，不碰真实的 `/usr/local/bin`、`~/.pi`、`~/.claude`。

退出码（沿用 otter 的约定）：

| 码 | 含义 |
|---|---|
| 0 | 成功 |
| 1 | 写入失败（settings.json 读不懂、目标不可写） |
| 2 | 参数错误 |
| 3 | 依赖缺失（python3，或 payload 文件不存在） |

## 4. install 流程

```
1. require_cmd python3
2. 校验 CLAUDE_SETTINGS：解析 + 目标目录可写性探针，都不落盘
3. CC:  拷 wren.py -> $PREFIX/wren-cc，chmod +x
4. CC:  合并写入 $CLAUDE_SETTINGS 的 statusLine
5. pi:  拷 wren.ts -> $PI_EXT_DIR/wren.ts
6. 若 $PI_EXT_DIR/odo.ts（旧手工副本）已存在 → stderr 警告（pi 会把两个 footer 都装上）
```

### 宿主侧装副本，工具入口是软链（两级刻意不同）

- `cli-zoo-install.sh wren` 装的 `$PREFIX/wren` 是**软链**（与仓库其他工具一致，指向 `zoo-scripts/wren/wren` 入口）。
- `wren install` 装到两个宿主的 `$PREFIX/wren-cc` / `$PI_EXT_DIR/wren.ts` 是**实际文件副本**（`wren-cc` 带可执行位）。

宿主侧用副本的理由：statusline 是 CC 与 pi 的启动依赖，仓库被移走或删掉后必须照常工作。
代价是 payload 更新需重跑 `wren install`，这是安装器的常态语义。两级行为差异在 README 写明。

### 为什么第 2 步要「只读校验 + 可写性探针」

`settings.json` 是用户手写的文件，可能本来就不是合法 JSON；也可能整个目录不可写。
第 2 步在**产生任何副作用之前**把这两类失败挡掉，于是失败时磁盘上什么都没变。

这条是踩坑换来的。第一版是「先建链接再写 settings」，`chmod 555` 目标目录后 install 会留下
`wren-cc` 却在写 settings 时抛 Python traceback，即所谓半装状态。加了探针以后不需要回滚逻辑：
不可写的情况在动手前就失败了。T11/T12（配置读不懂）与 T24（目录不可写）是三条守门用例。

写阶段的 `OSError` 也被包成一行 `wren: cannot write <path>: <原因>`，不再把 traceback 喷到用户脸上。

### settings.json 的合并语义

- 只动 `statusLine` 这一个键，其余键**与其顺序**原样保留（Python dict 保序，`json.dump` 保序写回）
- 已有 `statusLine` 是对象时往里合并，不整个替换（保住用户自己加的 `padding` 之类）
- 文件不存在 → 创建；父目录不存在 → `mkdir -p`
- 解析失败／顶层不是对象 → 一行错误 + exit 1，**绝不覆盖读不懂的文件**
- 备份写到 `<settings>.wren-bak`，**只在不存在时写**，保住的是 wren 介入前的原始状态；重复 install 不覆盖它
- 落盘原子：写 `.wren-tmp` 再 `os.replace`
- **已知代价**：整个文件会被重新序列化，用户的缩进与行内对象布局会被重排（4 空格 → 2 空格）。
  键与键序保留，但字节会变。要让文件保持原样的唯一办法是不写 JSON，那就不叫安装器了

### 覆盖已有文件

目标位置已有同名文件时：内容与 payload 相同 → 静静覆盖（重复 install 的常态，不吵）；
内容不同 → stderr 告警后再覆盖。不默默抹掉别人的东西。T25 守这两个分寸。

### script_dir：回溯入口的真实位置

`wren` 自己会被 `cli-zoo-install.sh` 软链到 `$PREFIX`，`BASH_SOURCE[0]` 指向软链本身。
逐级 `readlink` 解到真实文件，再取所在目录，才能找到同目录的 `wren.py` / `wren.ts`。
相对软链要拼回所在目录。目录用 bash 参数展开 `${f%/*}` 取，不依赖外部 `dirname`
（PATH 极简时 `dirname` 可能不在，会先于 `require_cmd` 报出噪音）。T21 守回溯本身。

## 5. uninstall 流程

```
1. CC:  $PREFIX/wren-cc 与 payload 逐字节相同（或仍是指向 payload 的旧软链）→ 删；否则 not ours; left alone
2. pi:  $PI_EXT_DIR/wren.ts 同上判定
3. CC:  若 statusLine.command == "wren-cc" → 删掉该键；否则 left alone，不动
4. CC:  清掉自己的副产物：`<settings>.wren-bak` 与遗留的 `<settings>.wren-tmp`
```

第 4 步会**丢掉 wren 介入前的 settings 备份**。这是刻意的：那两份文件是 wren 自己建的，
按「只删自己的东西」的语义就该在卸载时一并清掉，否则卸载永远留垃圾。
代价写进了 README 与用例文档：需要回滚到安装前状态的用户，应在卸载前自己留一份。

归属判定用**内容比对**（`cmp -s`）而不是软链指向：现在装的是副本，没有链接可查。
内容一致说明这份就是 wren 装的；被用户改过就一律不动，卸载不该比安装更有破坏力。
同时兼容旧版软链装法留下的 `readlink == payload` 状态。T17/T19 守这两条。

幂等：目标不存在时打印 `does not exist; nothing to do`，exit 0。

## 6. 为什么 pi 侧也由 wren 管

pi 自动加载 `~/.pi/agent/extensions/*.ts`（无需 settings 注册），所以 pi 侧的「安装」就是往那个目录放一份副本。
这件事和 CC 侧的「往 settings.json 写 statusLine」是同一件事的两半：把 statusline 装到这台机器的两个宿主上，
因此合成一个 `wren install`，而不是要求用户分别执行两条命令。

pi 扩展目录里若已有一份 `wren.ts`（例如用户此前手工装的），wren 无法判断它是不是同一份文件，
所以只警告不处理：pi 会把两个 footer 都装上，那属于用户既有配置，不该由安装器擅自删除。

## 7. 测试设计

### 7.1 用例（`.test_task/wren-test.md`）

共 46 条：T01-T03 参数，T04-T14 install（拷入副本、settings 合并、备份、零副作用、装好的 payload
能跑、重复加载警告），T15-T19 uninstall（删副本、删键、外来文件不动、幂等），T20-T21 与
`cli-zoo-install.sh` 的集成，T22-T23 依赖缺失，T24 目录不可写不进半装状态，T25 覆盖外来文件的分寸，
T26 卸载清理副产物，T27-T32 pi 侧渲染与 fmt/ctx%/家目录，T33-T37 分侧安装与 CLAUDE_CONFIG_DIR，
T38-T41 detached/rename/冲突、色档、CH 压缩后语义，T42-T44 折叠与 CJK 宽度，
T45-T46 极端 CJK 整行不溢出且折叠与色档无关（CR 轮 11）。

### 7.2 测试脚本（`.test_scripts/wren-test.sh`）

- bash，无第三方依赖，自带 `pass` / `fail` / `skip` / `record`；断言直接内联 `if` + `grep -qF` / `cmp -s`
- `new_box` 造隔离沙箱：`BIN` / `PIEXT` / `CLAUDE` 三个目录，`PREFIX` / `PI_EXT_DIR` / `CLAUDE_SETTINGS` 全部指进去，
  **真实目录一个都不碰**
- `run_wren` 统一跑命令并把 stdout / stderr / 退出码分开存，便于分别断言
- settings.json 的断言用 `json_field`（`python3 -c` 读 JSON），不靠 grep 文本，避免格式变动导致误判
- 「零副作用」用 `diff` 对比改动前的字节 + 检查目标目录仍为空
- pi 侧（T27-T32）：临时目录里生成 `tui-stub.mjs`（实现 `visibleWidth` / `truncateToWidth`）、
  `loader.mjs`（ESM resolve 钩子把 `@earendil-works/pi-tui` 指到 stub）、`register.mjs`、`harness.mjs`
  （造假 `pi` 对象收集 `session_start` handler 与 `setFooter` 回调，造带 `getContextUsage()` 的假 ctx，
  再用 fixture 驱动 `render()`）。`pi-ai` / `pi-coding-agent` 是 `import type`，type stripping 会抹掉，无需 stub
- 跑 `.ts` 用 `node` 原生 type stripping（Node 22.6+）；先由 `probe.ts` 探测能力，不支持则 T27-T32 整体 SKIP
- 输出：`PASS T01 ...` / `FAIL ...` / `SKIP ...`，末尾 `Total: N  Pass: x  Fail: y  Skip: z`
- 任一 FAIL → 退出码 1；结果覆盖写 `.test_res/wren-test-res.md`

### 7.3 条件跳过

本套用例只依赖 bash / python3 / coreutils，且全部在用户态临时目录作业，因此没有条件跳过项。
`python3` 缺失时直接 exit 2（前置依赖检查），因为连 settings.json 的断言都做不了。

## 8. 执行计划

1. 建 `zoo-scripts/wren/`，把 payload 移进去
2. 写 `zoo-scripts/wren/wren`（第 4/5 节流程）→ 手造沙箱冒烟
3. 补 `cli-zoo-install.sh` / `cli-zoo-uninstall.sh` 的 `wren` 分支（入口在子目录里）
4. 写 `.test_task/wren-test.md` 与 `.test_scripts/wren-test.sh`
5. 跑测试，循环修复至全 PASS，结果落 `.test_res/wren-test-res.md`
6. README 目录索引 +「工具列表」追加 `wren` 一节

## 9. 开源先例对照（2026-09 调研）

对照了三个同类项目写 `settings.json` 的方式，核对我们是否缺课：

| 行为 | ccstatusline (sirmalloc) | rz1989s/claude-code-statusline | CCometixLine (3.4k★) | wren |
|---|---|---|---|---|
| 尊重 `CLAUDE_CONFIG_DIR` | 是（`getClaudeConfigDir()`） | 否（硬编码 `~/.claude`） | 否（不写 settings） | **是**（T37；本轮补上，此前也是硬编码，这是本次调研抓到的缺陷） |
| 只改 `statusLine` 一个键 | 是（读改写） | 是（`jq '.statusLine = …'`） | 无 | 是（T07） |
| 非法 JSON 处理 | **吞掉并当空对象写回，丢用户其余键** | 移走旧文件再新建（保命但丢内容） | 无 | **拒改 + exit 1 + 零副作用**（T11/T12，比两个先例都保守） |
| 备份 | `.orig` + `.bak` 双份 | 时间戳备份 | 无 | `.wren-bak` 仅首次（T08/T09） |
| 原子写 | 否（直接 writeFile） | mktemp + mv | 无 | 是（`.wren-tmp` + `os.replace`） |
| 失败半装 | 可能 | 可能 | try/catch 全吞 | 预检挡掉（T24） |
| 锁 | 无 | 无 | 无 | 无（与先例持平；settings 由 CC 每次启动读，statusline 安装器写它的竞态窗口先例们也都不处理） |

结论：除 `CLAUDE_CONFIG_DIR`（已修，T37）外，wren 在每一项上都 ≥ 先例；非法 JSON 的处理比两个先例都更保守。

## 9.5 Dracula 主题与折叠（v5/v6，多轮 CR 收敛记录）

**色板与降级**：8 色 Dracula 官方色板，truecolor/256 两档离线预计算（256 档按 pi 宿主 `rgbTo256`
原算法生成，两侧同一张表）。CC 侧 `NO_COLOR` → `COLORTERM∈{truecolor,24bit}` → 256 两级（stdout 非
tty，`isatty()` 不可用）；pi 侧 `theme.getColorMode()` + `NO_COLOR` 优先。ctx% 三档突变（绿 ≤70、黄 70<p≤90、红 >90，pi 内置语义；用户问过渐变，与 CR 轮 8 结论一致维持突变：扫读场景阈值绑动作，
渐变在 60-80% 区间 hue 难分）。**假定深色底**（白底下多色 WCAG <1.5:1，实测数据在 CR 轮 3），
光底需求指向官方 Alucard，不支持。

**宿主徽标（v6）**：行 1 尾 ` | cc` / ` | pi` 灰字。文案弃 `claude`（与模型名 `claude-opus-5` 视觉
打架）取 `cc`/`pi`（复用 `wren install` 目标词汇表）。连带测试影响：跨实现比对（T32/T38）的段提取
须先剥徽标尾（`strip_tag`），CR 轮 8 预言并命中。

**折叠（v6，CR 轮 9 定稿、轮 11 修正）**：预算驱动 `budget = 宽度 − 其余段真实可见宽`（固定 −40
在长分支+多脏文件+herdr 场景下不够，整行可到 88）；逐级降级（头2+尾2 → 头1+尾2 →
尾2 → 尾1 → 末级字符截断），显示宽 ≤ budget 为不变量（截断与分支折叠都按显示格切，不按码点；
宽度一律量无色文本，色档不得影响折叠结果）；无段数门槛（CR 抓的 bug：段少段长的路径
在门槛下完全不折）。分支 >24 折为头 8 + `…` + 尾 15（尾重：等分时头部被 `feature/` 前缀占满；
ticket-in-slug 的启发式被反例否决）；两侧触发条件同用显示宽（此前 py 按格、ts 按码点，13 汉字
分支 cc 折 pi 不折）。宽度来源分宿主：pi `render(width)`、CC `COLUMNS` 或 80 兜底
（stdin JSON 无 width 字段；herdr 内实测 COLUMNS 未设、`get_terminal_size()` 恰退 80）。
出口各做一次显示宽硬截断（pi 宿主 `truncateToWidth`、CC 侧等价 `truncate_display`），公式算偏也不溢出。

**CH 口径（CR 轮 5-7 定稿）**：公式 `cacheRead / (input + cacheRead + cacheWrite)` 两侧一致
（与 pi 内置逐项同式，`cacheWrite1h` 是计费拆分字段、`cacheWrite` 已含 1h 部分，进分母会重复计数；
aborted 请求 usage 全零天然被 `>0` 条件挡掉，无需 stopReason 过滤）。无缓存不显示（旧版会挂
恒 0 的 CH0.00%）。压缩后显示旧值不消失（pi 内置同语义：ctx% 怕误导走 `?`、CH 描述上次请求效率
不怕旧值）。**ccstatusline 的 `read/(read+creation)` 是另一种定义**（缓存内部转换率，分母不含
input），非对错差异，此处取 pi 式。记录在案防翻案（CR 轮 6 要求）。

## 9.x. 已知遗留（重编号）

### 已修（本轮）

| # | 问题 | 修法 |
|---|---|---|
| 1 | 半装状态：先建链接再写 settings，写失败时留下 `wren-cc` + Python traceback | 第 2 步加只读校验与可写性探针，失败即退出；改写阶段错误为一行 `wren: cannot write ...`。守门用例 T24 |
| 2 | README 声称两份 payload 输出一致 | 改为列出实际差异表（第 3 节/README），不再声称逐字一致 |
| 3 | README 卸载流程漏 `wren uninstall`，照做会留残留 | 卸载一节补齐两步 |
| 4 | 目标位置的外来文件被默默 `rm -f` | 内容不同则先 stderr 告警再覆盖。守门用例 T25 |
| 5 | `script_dir` 依赖外部 `dirname`，PATH 极简时报噪音 | 改用参数展开 `${f%/*}` |
| 6 | 测试脚本 `assert_eq` / `assert_contains` 定义后零调用（死代码） | 删除；断言一律内联 |
| 7 | T12 断言弱于 T11（没查 `$PI_EXT_DIR` 为空、没查无备份） | 补齐到与 T11 同强度 |
| 8 | `uninstall` 不清理自己产生的 `.wren-bak` / `.wren-tmp` | 卸载时一并清掉并打印。守门用例 T26 |
| 9 | `wren.ts` 的 `fmt` 在 `999_500~999_999` 上渲染 `1000K`（pi 上游同款缺陷） | 搬 `wren.py` 的守卫过来。守门用例 T28 |
| 10 | `wren.ts` 手算 ctx%：漏 `cacheWrite`、压缩后挂着旧值、不用 pi 的权威 API | 改用 `ctx.getContextUsage()`，`percent: null` 显示 `?`。守门用例 T29 |
| 11 | `wren.ts` 家目录折叠硬编码 `/Users`，非 macOS 失效 | 改用 `os.homedir()` 前缀折叠。守门用例 T30 |
| 12 | `wren.ts` 的 `CH` 只有一位小数，与 `wren.py` 不一致 | 改两位小数对齐。守门用例 T31 |
| 13 | `wren.ts` 的 git 段与 `wren.py` 不一致：`⇡a⇣b` vs `↑a↓b`；脏文件只数 porcelain 行数、不分类、混入重命名；且跑三次 git 子进程 | 改成与 `wren.py` 同一套单次 porcelain v2 解析，渲染 `↑a↓b +增 ~删 ✱改`；顺带在 pi 侧也消掉 4.4 号坑。守门用例 T32（同仓库跑两个 payload，断言 git 段逐字相同） |

### payload 的调研结论与修改（`wren.ts` 五处）

三条都先做了调研（开源实现 + 宿主自身源码 + 官方文档），再决定改不改，改完各配一条守门用例。

**1. `fmt` 的 1000K：真 bug，已修（T28）**

- pi 内置 `formatTokens`（`dist/modes/interactive/components/footer.js`）自己就有这个坑：
  `<1e6` 走 `Math.round(n/1000)`，`999_500` 渲染成 `1000k`。`wren.ts` 是照抄上游，不是它发明的。
- `sirmalloc/ccstatusline` 的 `src/utils/format-tokens.ts` 显式守这条：提升阈值
  `count >= 10**6 - 500/10**kDecimals`，保证「4 位 K 永不出现」，`999_500` → `1.0M`。
- `wren.py` 已修（`k >= 1000` 分支）。
- 结论：修。两处独立先例都守，且这是纯显示错误，无口径争议。**这是有意不跟 pi 上游的一处。**

**2. ctx% 口径：不是 bug，是宿主语义差异；但 `wren.ts` 的三处偏差已修（T29）**

- **CC 官方文档**（`code.claude.com/docs/en/statusline`）：`used_percentage` 由
  `input_tokens + cache_creation_input_tokens + cache_read_input_tokens` 算出，**不含 `output_tokens`**，
  并明说手工计算要用同一公式才能对齐。→ **`wren.py` 的公式是对的，未改。**
- **pi 源码** `calculateContextTokens(usage) = usage.totalTokens || input + output + cacheRead + cacheWrite`
  pi 的上下文占用**含 output**；且 `estimateContextTokens` 是「最后一条 assistant 用量 + 其后消息估算」。
  → 两侧不一致是**宿主定义不同**，不应强行统一。早先「`wren.ts` 口径错」的说法不成立。
- 但 `wren.ts` 有三处确实该修，已改用 pi 的权威 API：
  1. 漏 `cacheWrite`（pi 的公式含它）；
  2. 不处理压缩后失效：pi 的 `getContextUsage()` 在有 compaction 且其后无有效 assistant 用量时返回
     `percent: null`（源码注释：「After compaction, the last assistant usage reflects pre-compaction
     context size」），footer 借此显示 `?`；`wren.ts` 手算会把压缩前的旧值一直挂着，
     与 Claude Code 侧第 4.2 节那个坑同类，而 pi 已内置修法；
  3. 更根本：`ctx.getContextUsage()` 本就在扩展 API 上（`core/extensions/types.d.ts`，
     `ExtensionContext.getContextUsage(): ContextUsage | undefined`），无需手算。
- 收益：手算交给宿主，避免与 pi 内置 footer 漂移。

**5. git 段与 `wren.py` 对齐（T32）**

原来两侧不一致，实测：CC 显示 `main ↑0↓0 +5 ✱4`，pi 显示 `main ⇡0⇣0 ✱9`，总数同为 9，
但 pi 只是数 `git status --porcelain` 的行数，不区分未跟踪/删除/修改，还把重命名算进去。

改法：把 `wren.py` 那套解析整段搬过来，单次 `git status --porcelain=v2 --branch`，
`# branch.ab` 取 ahead/behind（去掉 `+`/`-` 前缀），`? ` 计入 `+`，`1 `/`2 `/`u ` 取 XY 状态位
（`A` → `+`、含 `D` → `~`、否则 `✱`），按 `+` `~` `✱` 顺序拼。branch 名仍取 pi 的
`footerData.getGitBranch()`（保留它的 `onBranchChange` 响应性）；detached HEAD 时与 `wren.py` 一样整段不显示。

顺带在 pi 侧也消掉了 4.4 号坑（原本 rev-parse + rev-list + status 三次子进程）。pi 侧 15s 才刷一次，
本来不构成热路径问题，但既然要改就一并统一。

**T32 是跨实现比对**：在同一个临时仓库（带上游、ahead=1、改/删/未跟踪各一）里分别跑 `wren.py` 与
`wren.ts`，断言两侧第一行的 git 段逐字相同，而不是写死一份期望值，这样任何一侧偏离都会被抓到。

**4. `CH` 位数 1 位 → 2 位（T31）**

纯对齐诉求，不是 bug：`wren.py` 用两位小数（`CH57.14%`），`wren.ts` 跟着 pi 内置 footer 用一位
（`CH57.1%`）。同一工具两块屏上同一个指标位数不同，读起来别扭，故统一为两位。
命中率公式两侧本来就一致（`cacheRead / (input + cacheRead + cacheWrite)`，prompt 不含 output）。
**又一处有意不跟上游**（pi 内置 footer 是 `toFixed(1)`）。

**3. 家目录折叠硬编码 `/Users`：真 bug，已修（T30）**

原来用 `/^\/Users\/[^/]+/`，在 Linux（`/home/<user>`）与自定义 `HOME` 下都不折叠，而 `wren.py`
用 `Path.home()` 替换所以两边行为不一致。改为 Node 内建 `os.homedir()` 做前缀折叠。

- pi 另有 `formatCwdForFooter(cwd, home)`，但它只从 `modes/interactive/components/footer.js`
  这个**内部路径**导出，不在包入口；深引内部路径会随版本变动碎掉，故本地实现。
- **已知边界**：若 `$HOME` 本身是软链（如 macOS 的 `/var` → `/private/var`），
  `process.cwd()` 返回解析后的路径，前缀匹配会失配而不折叠。为一次渲染加 `realpathSync` 不划算，
  故不处理；`wren.py` 用 `replace` 同样有这个边界。T30 的夹具因此用解析后的 HOME。

### 仍未处理

