# wren 细节

主 README 只留使用方法，本文收口径、原理与完整清单。

## 宿主差异（cc / pi / qc / oc / agy）

五份 payload 布局同构，段格式、折叠规则、色板都一致（qc / agy 与 oc 的差异拆到下方小节）。剩下几处差异来自宿主本身
（statusline 与 TUI footer 拿数据的路子不同），oc 还多一层形态差异（外部命令 vs 进程内 TUI 插件）：

| 位置 | `wren-cc.py`（Claude Code） | `wren-pi.ts`（pi） | `wren-oc.tsx`（opencode） |
|------|------|------|------|
| 接入形态 | 宿主调外部命令（stdin JSON → stdout 文本） | 宿主加载 TS 扩展，进程内渲染 | 宿主加载 TUI 插件模块，进程内 OpenTUI/Solid JSX |
| 时长 | `cost.total_duration_ms` | footer 装载起的 wall-clock | session 创建时刻 → now（同 qc 的会话年龄口径） |
| TTFT（首片延迟） | transcript 配对：真 user → 首条 assistant（排除 tool_result 回填） | 事件流：`turn_start` → 首个 `message_update`（内存态，扩展重载后下一轮才有值） | 推导：`min(part.time.start) − assistant.time.created`，轮中未落片时读上一轮存量 |
| ctx% | 按 `input + cache_read + cache_creation` 自算（与 CC 官方 `used_percentage` 同式） | 取 `ctx.getContextUsage()`（pi 的定义含 output，压缩后显示 `?`） | 最近一条 assistant 的 `tokens.total` ÷ provider 的 `limit.context` |
| CH 数据源 | `current_usage` 优先，回退 transcript 末条 assistant | `sessionManager` 末条 assistant | session 聚合 tokens + 末条 assistant（公式与 cc/pi 同） |
| 宽度来源 | `COLUMNS` 有则用、无则探测控制终端、兜底 80；窄档默认关（qoder 不给宽度通道，探针实锤）——`WREN_QC_NARROW=1` 显式开后同款窄档（图标短形、丢序同构） | `render(宽度)` 由宿主传入；同款窄档（图标短形 + 丢序同构） | `api.renderer.width`（且逐段自截，宿主 `truncate` 仅兜底）；无窄档（opencode v2 将出，裁定不做） |

CH 公式 cc/pi 两侧一致，都是 `cacheRead / (input + cacheRead + cacheWrite)`，两位小数，压缩后显示旧值
不消失，这点跟 pi 内置 footer 一样。`ccstatusline` 用的是另一个口径
`read / (read + creation)`，只看缓存内部转换率、分母不含 input，属定义差异不是对错，我们取 pi 式。

### qc（Qoder CLI）侧数据源

`wren-qc.py` 与上两列同构，差异主要在数据源（结论来自 qodercli 1.1.57 二进制内嵌
payload 文档 + 构造器静态核对 + 真会话抓包，由 T48-T58 守门）：

| 位置 | 来源 |
|------|------|
| cwd | `workspace.current_dir` 优先，回退 `cwd` |
| ↑in/↓out | transcript 累计。原生 `context_window.total_input_tokens` 是「最近一次请求」的上下文占用（官方文档注明 NOT a session total），`total_output_tokens` 宿主从不发送（1.1.57：调用方不填该字段），都不能当累计 |
| ctx% | 原生 `used_percentage`（整数）优先；缺失回落 `total_input_tokens`（= 当前占用）→ `postTokens` → transcript 末次请求 |
| CH | qoder 的 `usage.input_tokens` 已含 cache → `cacheRead / input`；仅当 `input < cache_read`（旧版口径）回退 cc 公式；`cache_creation` 可能是对象（`ephemeral_5m/1h` 求和） |
| 时长 | transcript 推算的会话年龄（首条记录 ts → now；宿主不发 `total_duration_ms`，v6 起不读 cost） |
| TTFT（首片延迟） | transcript 配对（与 cc 同式）：真 user → 首条 assistant，排除 tool_result 回填；`ttft_ms` 存量制，轮中显示上一轮值不闪烁 |
| 思考等级 | `model.preferences[id].reasoning.effort` ＞ 顶层字段 ＞ transcript 的 `runtime-config` 记录（真实 payload 通常只命中第三级） |

渲染差异一则：qoder 对 statusline 输出按 span 逐段重断言 `\x1b[2m`（Ink dimColor），
同色板观感比 cc/pi 偏暗，属宿主样式。

另有三处降级/工具行为差异：`WREN_DEBUG_DUMP` 写 stdin 原始字节（cc 侧重排 JSON）；
非法 JSON 走空对象降级出两行（cc 侧只出裸 cwd）；模型名去 `" Model"` 后缀归一化。
调试钩子：`WREN_DEBUG_DUMP=<path>` 把 stdin 原始字节落盘（qc / agy 侧；cc 侧同名变量写重排后的 JSON），用于未来 schema 变化时对齐。

### agy（Antigravity CLI）侧数据源

`wren-agy.py` 以 qc 为基底（`workspace.current_dir` 优先、两行输出），数据源改为 agy 的 statusline
payload + Gemini 格式 transcript（结论来自 agy 1.5.13 官方文档 + 真实语料核对 + 真机探针，由 T145-T188 守门）：

| 位置 | 来源 |
|------|------|
| stdin | 带 1s 超时读取（上限 8 MiB）；空/超时回退 `{}`（idle），避免 runner 不关 stdin 时挂死 |
| cwd | `workspace.current_dir` 优先，回退 `cwd`，最后 `os.getcwd()`；经 `_clean_text()` 净化 |
| ↑in/↓out/R | transcript 累计（`PLANNER_RESPONSE` 的 `input_tokens` / `output_tokens` / `cache_read_tokens`）；无 transcript 时回退 payload `context_window.total_input_tokens` / `total_output_tokens`、`current_usage.cache_read_input_tokens` |
| ctx% | 原生 `used_percentage` 优先 → `current_usage`（in+read+write）→ transcript 末次请求；`context_window_size` 缺失时只显示 `xx.xx%`，不猜 200K |
| CH | `current_usage` 的 `cache_read / (input + read + write)` → transcript 末次；**`input_tokens` 不含 cache**（见下） |
| TTFT | 最近一次 `USER_INPUT` → 其后首条 `PLANNER_RESPONSE`（同轮多步不覆盖；`source` 非 `USER_EXPLICIT` 不开窗）。`created_at` 是**秒级精度** → TTFT 量化到 1s（格式沿用 `fmt_ttft`） |
| 时长 | transcript 首条 `created_at` → now；负值/异常不显示（payload 没有时长字段） |
| 压缩 | agy transcript **没有压缩标记** → `compactions` 恒 0，CPn 段不显示 |
| 思考等级 | `model.effort`（`low..max`，仅多档模型有）；缺失不显示 |
| cost | `cost.total_usd` → `total_cost_usd` 回退；中性色；`estimated` 加 `~` 前缀；`subagent_usd>0` 显示 `\| sub:$x`；`(0,0.005)` 显示 `<$0.01` |
| 宽度 | `COLUMNS` → 控制终端（`ctermid`）→ payload `terminal_width` → 80（见下方探针表） |

transcript 是 JSONL，只有 5 种记录：`USER_INPUT`（source=`USER_EXPLICIT`）、
`PLANNER_RESPONSE`（source=`MODEL`，带 token 字段）、`GENERIC` / `SYSTEM_MESSAGE` /
`ERROR_MESSAGE`。

- **token 口径与 Claude 相同，`input_tokens` 不含 cache**。真实会话里
  `cache_read[2]=8256` ≈ `input[0]+cache_read[0]=8272`，后续每轮 `cache_read ≈ 上一轮 input+cache_read`，
  所以 CH 公式 `cache_read/(input+cache_read)` 成立；`↑in`/`R` 按 transcript 累计（与 cc/qc 同口径），payload totals 只作回退。
- **文件形态**：`transcript.jsonl` 是裁剪版（长字段截断，token 字段完整）；
  `chunks/transcript/*.jsonl` 只是同内容副本，不会滚动截断。
- **读取纪律**：缓存键 `agy-<sha1(path)[:16]>.json`，按字节 offset 增量读，与 cc/qc 共用 `$WREN_CACHE_DIR` 也不串味。
  只接受普通文件，目录 / 设备 / FIFO / socket 按空 transcript 处理（`/dev/zero` 不会挂死、FIFO 不会阻塞）。
  单行超过 **8 MiB** 整行跳过、后续行照常聚合；跳过上限 64 MiB，超过则本次停止、offset 不前进。

宽度链（真机三通道实测）：

| 场景 | COLUMNS | payload `terminal_width` | 控制终端列数 |
|------|---------|--------------------------|--------------|
| 全宽 tab（51 列） | 未设置 | 50 | 50 |
| 窄 pane（13 列）首次调用 | 未设置 | **80（陈旧）** | **10（正确）** |
| 同 pane 稳定后 | 未设置 | 10 | 10 |

agy 的 `sh -c` 不导出 `COLUMNS`；payload 的 `terminal_width` 在启动首帧可能是陈旧的 80；
`os.ctermid()` + `os.get_terminal_size` 从第一帧就准。所以探测链把控制终端放在
`terminal_width` **之前**，否则窄 pane 首帧会按 80 列排版、换行错位。

宿主约束（agy 1.5.13 真机探针）：statusline runner 在约 **5.0s** 后 SIGKILL 脚本并计一次失败
（`statusline: command failed: signal: killed (stderr: ) (failure 1/30)`），且超时**从进程创建起算**
（含 `sh` / pyenv shim / 解释器启动，不是从脚本的 `main()` 起算）；失败后立即重跑、无退避；
连续 **30 次**失败自动禁用自定义状态栏（`Statusline disabled after %d consecutive failures.`，
要 `/statusline enable` 才恢复）。**新的触发会静默 SIGKILL 上一条还在跑的命令**（不计失败）——
所以慢一帧不只是丢一帧，还会吃掉进行中的那一帧。

**容灾**：任何路径都必须 rc=0、stderr 为空、恰好两行。`BrokenPipeError` 静默退出；其余 `BaseException`
走 `emit_fallback()`（短 cwd + `agy`，两行、不查 git/网络）；stdout 启动时 best-effort
`reconfigure(encoding="utf-8", errors="replace")`；payload 各字段按类型净化；缓存目录只读/损坏不影响渲染。

**运行时预算（R9）**：硬墙钟 `HARD_LIMIT_S = 3.0`，自**进程创建**起算（不是 `main()` 第一行）——
pyenv shim 那 0.7–1.0s 也计入。进程创建时刻从内核读：

| 平台 | 取法 |
|------|------|
| macOS | `proc_pidinfo(PROC_PIDTBSDINFO)` 尾部的 `pbi_start_tvsec/tvusec`。结构体长度随 macOS 版本变过（SDK 头 128B / `tvsec@112`，Darwin 24 实测 136B / `tvsec@120`），所以**不写死偏移**：在尾部按「像 epoch 秒、后一个 u64 像微秒」的特征找 |
| Linux | `/proc/self/stat` 第 22 字段 `starttime`（comm 可能含空格/括号，取最后一个 `)` 之后切分）与 `/proc/uptime` 相减 |

量不到（时钟跳变/平台不支持）时退回模块 import 时刻，与旧行为等价。

| 常量 | 值 | 说明 |
|------|----|------|
| `HARD_LIMIT_S` | 3.0s | 自进程创建起算的硬墙钟；宿主约 5.0s SIGKILL，留 ~2s 余量 |
| `STDIN_TIMEOUT_S` | 1.0s | stdin 软上限（实际取 `min(1.0, 剩余)`；预算耗尽时不进 select） |
| `GIT_TIMEOUT_S` | 1.5s | 单次 `git status` 软上限（cc/qc 用 3s；agy 的硬杀不允许） |
| `SCAN_BUDGET_S` | 1.0s | transcript 增量扫描软上限；超时 break，offset 只记到完整行尾，下次续读收敛 |
| `REAP_TIMEOUT_S` | 1.0s | 杀 git 整棵树后的回收等待上限（取 `min(1.0, max(0.05, 剩余))`） |
| git 子进程 `alarm` | `int(软超时) + 1`，实际 ≤2s | `_git_child_setup()` 在 exec 前设；父进程被 SIGKILL 后 git 到点自灭（所有 POSIX；Linux 另有 `PR_SET_PDEATHSIG` 更快） |

**看门狗（最关键的一刀）**：`main()` 第一行装 `setitimer(ITIMER_REAL)` / SIGALRM（提前 20ms 到点，
保证比各阶段「取剩余预算当软上限」的 deadline 先到）。到点：屏蔽信号 → `killpg` 杀 git → 记慢日志 →
输出兜底两行 → `os._exit(0)`。SIGKILL 本身拦不住，所以看门狗必须永远抢在宿主 ≈5.0s 之前；
平台没有 `setitimer` / `pthread_sigmask` 时静默跳过，不会因此崩脚本。

**信号**：`SIGTERM`/`SIGHUP`/`SIGINT` 的处理函数第一句就 `pthread_sigmask` 屏蔽后续信号
（宿主关 pane 时连发多次 SIGHUP，重入会多输出两行），再杀 git、兜底两行、rc=0。正常收尾也先屏蔽
信号再输出，`os._exit(0)` 不走解释器收尾——避免 pend 的 SIGALRM 再触发一次兜底。

`WREN_AGY_HARD_LIMIT`（秒）可覆盖硬墙钟并钳在 `[0.2, 4.0]`，非法值回落 3.0；
`WREN_AGY_SCAN_BUDGET`（秒）可覆盖扫描预算并钳在 `[0.01, 5.0]`，非法值回落 1.0（都属测试专用）。
实测最坏路径（管道不关 + git 挂起）约 2.6s；慢启动（shim 2.6s + stdin 不关）在 ≈3.0s 由看门狗收口，
不会再被宿主 SIGKILL。

进程年龄合理性上界 `STARTUP_MAX_S = 60.0`：状态栏进程活不过宿主的约 5 秒，算出超过 60 秒的
年龄只可能是量错了。Linux 侧 `/proc/uptime` 与 `starttime` 的时钟域是否一致（休眠时间是否计入）
随内核版本而异，本项目没有在真实 Linux 上验证过。这道上界是防御性加固：超上界的年龄当作量不到，
预算退回模块 import 时刻（R8 行为），避免万一算错时每帧都判定预算耗尽、只出兜底两行。

git 以**独立会话**（`start_new_session`）启动：超时与进程被 `SIGTERM` / `SIGHUP` / `SIGINT`
打断时都按进程组 `killpg` **整棵杀**（对齐 2026-10-12 测试护栏事故的教训——只杀直接
子进程会漏孤儿）。被打断时先清 git 进程树，再输出兜底两行并 `rc=0`，既不漏进程，
也不以信号死亡（agy 不记一次失败）。Linux 侧另有 `PR_SET_PDEATHSIG`
（`preexec_fn` 里 `prctl(1, SIGKILL)`）：wren 被 SIGKILL 时内核直接带走 git 本体。

**git 自带到期时间（所有 POSIX）**：`preexec_fn` 里、`exec` git 之前
`alarm(int(软超时) + 1)`（1.5s 软超时 → 2s）。定时器跨 `exec` 保留，而被接管过的信号
处置在 `exec` 时恢复默认（终止），所以**宿主 SIGKILL 掉 wren 之后，正在跑的 git 最多再活
约 2 秒就自行终止**，不再成为孤儿。Linux 上 `PR_SET_PDEATHSIG` 会在父进程一死时立即带走
git（比 2 秒更快）。已知边界：`git status` 正常不派生子进程；git 自己 fork 的子孙不继承
这个定时器——父进程活着时由 `killpg` 整棵清掉，父进程死了它们会跑到自然结束。

**启动开销与 shim**：`statusLine.command` 曾是裸脚本路径，靠 `#!/usr/bin/env python3`
起解释器。pyenv 机器上 `python3` 是 `~/.pyenv/shims/python3`，每次刷新都要经
`sh → env → shim(bash) → pyenv-exec(bash) → … → 真解释器`，实测 0.7–1.0s；结合
「新触发杀在跑的命令」，活动期间状态栏根本跑不完。

`wren install agy` 会选一个非 shim 的解释器，把 `command` 写成「优先用、坏了回落」的片段：

```
[ -x '<解释器>' ] && exec '<解释器>' '<脚本绝对路径>'; exec '<脚本绝对路径>'
```

`[ -x ]` 与 `exec` 都是 shell 内建，解释器存在时零额外开销；解释器日后被卸载则自动
回落到脚本 shebang（原行为）。`WREN_AGY_PYTHON` 控制选择：

| 值 | 行为 |
|----|------|
| `off` | 不绕，裸脚本路径（现状） |
| 其它非空 | 当解释器绝对路径用；不存在/未通过健全性检查则告警并按 `auto` 继续（不让安装失败） |
| 未设 / `auto` | `command -v python3` 解析到真解释器（最终目标不是 `#!` 文本）→ 裸路径；解析到 shim/包装脚本 → 在 PATH 各目录（跳过 shim 自己所在目录）与 `/opt/homebrew/bin`、`/usr/local/bin`、`/usr/bin` 里找第一个「最终目标是二进制 + 健全性检查通过」的 `python3` |

健全性检查（5s 上限，后台跑 + 定时 `kill -9` 直接子进程，不在 `$(...)` 里再 fork 子 shell）：
`python3 -c 'import sys, json, subprocess, unicodedata, signal, select; …3.8+ 且 hasattr(signal, "setitimer")…'`。
候选写**目录里的入口路径**（如 `/opt/homebrew/bin/python3`），不解析到 Cellar 深处（brew 升级会换目录），
也不选 `~/.pyenv/versions/…`（会被卸载）。一个都没有时 `log_err` 提示
`可设 WREN_AGY_PYTHON=/path/to/python3 绕开`，继续用裸路径（安装仍 exit 0）。
卸载对 agy 放宽匹配：`command` 等于裸路径，或裸路径以单引号完整路径串出现在片段里都认
（解释器选择会随环境变化，不能只认字符串全等；cc/qc 行为不变）。

**慢运行日志**：`$WREN_CACHE_DIR/agy-slow.log`（默认 `~/.cache/wren/agy-slow.log`；目录不可写时
退到系统临时目录），一行 JSON，最多保留 40 行。字段（不含任何路径/邮箱）：`ts`、`reason`
（`slow` / `watchdog`）、`phase`（`startup`/`stdin`/`scan`/`git`/`render`/`output`）、`since_start`、
`startup`、`stdin`、`scan`、`git`、`py`、`transcript`（0 = payload 没有 `transcript_path`；
1 = 有但不是普通文件；2 = 普通文件）、`git_skipped`、`git_timeout`、`stdin_timeout`、`scan_budget_hit`。
触发条件（任一，正常运行不产生 I/O）：看门狗触发；退出时 `since_start >= 1.5`；`startup >= 1.0`；
任一阶段降级标志。日志失败绝不影响两行输出。

写入纪律（R10）：

- **不得拖住退出**：日志在 daemon 线程里写，主线程最多等 `SLOW_LOG_WAIT_S = 0.25s`。
  日志位置是 FIFO、或家目录落在卡死/极慢的文件系统（NFS、被挂起的云同步目录）时，照样先出两行并退出；
  卡住的线程随 `os._exit(0)` 一起消失。线程只在收尾阶段起（git 之前不能有线程——`preexec_fn` 在多线程下不安全）。
- **临时文件 + 原子替换**：写到 `agy-slow.log.<pid>.tmp` 再 `os.replace`，读者只会看到完整的旧文件或
  完整的新文件；进程在写的中途被宿主 SIGKILL 也不会留下半行。带 pid 的临时名避免并发帧互相截断。
- **看门狗路径先出帧后记日志**：`_expire()` 的顺序是屏蔽信号 → 杀 git → 兜底两行 → 记日志（≤0.25s）→
  `os._exit(0)`，日志再慢也不会吞掉输出。
- **阶段耗时照实结算**：看门狗在某个阶段中途触发时，`_close_phase()` 先结算被打断阶段
  （`stdin` / `scan` / `git`）的耗时再记日志——`phase` 说在 git，`git` 字段就不会是 0。

**文本净化**：`model.display_name` / `model.id` / `model.effort` / cwd /
herdr 环境变量 / **git 分支名**统一走 `_clean_text()`——剥除 CSI（`\x1b[…final`）、OSC（`\x1b]…BEL|ST`）
和其它两字符 ESC 序列，去掉 Unicode Cc、bidi 控制符（U+202A–202E / U+2066–2069）、
U+200B，压平 Unicode 行界后 `strip()`；**保留** ZWNJ/ZWJ（U+200C/200D，复杂文字
模型名与路径要用）。所有进入 stdout 的文本字段都先净化，不可信 ESC 不会流出到宿主；
注入的 ESC 也不会影响本进程的着色。正常文本（空格、括号、连字符、CJK）逐字不变。

**token 取整**：transcript 与 payload 回退的 token 计数统一 `int()` 截断
（`output_tokens: 2.0` → `↓2`，`1234.7` → 按 1234 计）；`used_percentage`、cost、
时长、`ttft_ms` 保持原数值/小数语义。

接入形态与 cc/qc 相同：`~/.gemini/antigravity-cli/settings.json` 的 `statusLine` 写
`{type:"command", command:"<绝对路径>/wren-agy.py", enabled:true}`（安装器可能写成上文
的「优先快解释器」片段，`WREN_AGY_PYTHON=off` 时是裸路径）；宿主 `sh -c` 执行，
stdin JSON → stdout 两行，支持多行 + ANSI。`wren install agy` 会把残留的 `enabled:false`
改回 `true`（否则安装形同没装）；`wren uninstall agy` 只摘 wren 写入的 `type`/`command`
和等价缺省的 `enabled:true`，用户的 `padding` / `stack_with_default` / `enabled:false` 保留。
`/statusline` 可切换/删除。

### oc（opencode）侧：进程内插件，不是 statusline 命令

opencode 没有 statusline 命令协议也没有 `statusLine` 配置键，接入形态是 **TUI 插件**：规则拆分不改（`wren-oc.ts` 是排版纯函数，`wren-oc.tsx` 只把它渲成 JSX），
数据全部来自宿主内存里的 `api.state`（Solid store，slot 渲染函数里读即为响应式）。真机结论来自 1.18.33（tmux 读屏）与真会话导出，由 T96-T101 守门。

| 位置 | 来源 |
|------|------|
| cwd | `api.state.path.directory`（家目录用 `os.homedir()` 折叠）；wren 行1 就渲染在宿主底行原本显示 cwd 的那一格（hint 顶掉它） |
| 分支 / ahead-behind / 增删改 | 自己跑 `git status --porcelain=v2 --branch`（15s 轮询 + Solid signal），解析与 cc/pi 同一套；`api.state.vcs.branch` 只能给分支名，没有 ab 与脏文件分类 |
| ↑in/↓out / R | `session.tokens`（宿主维护的会话累计；`input`/`output` 与 per-message 求和等价） |
| CH | 末条 assistant 的 `cache.read / (input + cache.read + cache.write)`（与 cc/pi 同式；无缓存不显示） |
| CP | 会话内 `part.type == "compaction"` 计数（宿主没有现成计数；15s 轮询） |
| ctx% / 窗口 | 末条 `output > 0` 的 assistant 的四项 token 之和（`input`+`output`+`reasoning`+`cache.read`+`cache.write`，与宿主 `usage()` 同口径）÷ `api.state.provider[].models[].limit.context`；窗口未知则整段不显示 |
| TTFT | `min(part.time.start) − assistant.time.created`；轮中未落片时保留上一轮值（与 qc 同步），换会话清空 |
| 时长 | `session.time.created` → now（home 路由无会话，整段不显示） |
| 模型 / 思考等级 | `provider.models[modelID].name`（回退 `modelID`）与末条 assistant 的 `variant`；**oc 侧默认传空串不渲染**：宿主同一行左组已显示 |
| herdr 位置 | `HERDR_WORKSPACE_ID` / `HERDR_TAB_ID` / `HERDR_PANE_ID`（与 pi 同） |

形态与降级的五点不同：

- **slot**：v1（1.18.x）没有 statusline 专用 slot，用 `session_prompt` / `home_prompt` 的 **replace 模式**：把宿主自带的 `<api.ui.Prompt>` 原样重渲染（透传 `session_id/visible/disabled/on_submit/ref`），只多传 `hint`——宿主源码里 prompt 框下方那一行的左半是 `props.hint ?? cwd`，给了 hint 就顶掉 cwd，wren 两行落进那一格（多行会把该行撑高一行，不占 transcript）。slot 回调的第一参数是 `{theme}`，契约 props 在**第二参数**。契约意外变化时退回裸 Prompt（不给 hint），输入框仍在。
- **宽度预算（双预算）**：行1 与宿主那一行的右半（usage `162.4K (16%)` + `ctrl+p commands`）共处一行，预算 = 容器宽 − 右半实宽（按宿主 usage 同口径动态算）；行2 独占整行，预算 = 容器宽。行1 放不下时级联丢段（git 计数 → ahead-behind → cwd，分支有 14 格紧凑折叠档）、行2 梯子丢段（TTFT → CH → CP → ctx%，ctx% 有 `16%` 短形兜底）。home 路由的容器宽是 `prompt.max_width`（默认 75），不是终端宽。
- **去重**：oc 侧不渲染模型 · 思考（宿主 prompt 框内左侧同一行已有 `agent · model · variant`）；cwd 恢复显示——wren 行1 正好占了宿主原来显示 cwd 的那一格。其余宿主无此依赖。
- **崩溃隔离**：slot 渲染里抛异常会直接把整个 TUI 打到崩溃页（1.18.33 实测），因此取数与排版全包在 try/catch 里，失败时降级成一行裸 cwd + 徽标。
- **色档**：不做 256 档转换，直接给 RGB 十六进制（`<text fg>`），由宿主/终端决定降档；`NO_COLOR` 非空时逐行单色输出（不靠宿主配合）。
- **相对路径 spec**：payload 拷到 `<tui.json 同目录>/plugins/`，配置里写 `./plugins/wren-oc.tsx`（宿主按声明它的配置文件解析相对路径）。核心与适配层是两个文件，卸载时一并处理。

## 安装器行为

改配置之前会先校验。`settings.json` 解析失败、或它所在目录不可写，都在产生任何副作用之前 exit 1。
写入时只动 `statusLine` 一个键，其余键和它们的顺序原样保留，已有 `statusLine` 是对象时往里合并。
首次安装把原文件留底到 `<settings>.wren-bak`，重复安装不覆盖。落盘是写 `.wren-tmp` 再 `os.replace`。

卸载只删自己的东西。目标链接不是指向本工具 payload 的、`statusLine` 不指向 `wren-cc` 的，只提示
`left alone` 不动。`install` 和 `uninstall` 重复执行都退出 0。

`install cc` 与 `install pi` 各只动一侧，`install qc`（别名 `qoder`）只动 Qoder 侧，`install agy`（别名 `antigravity`）只动 Antigravity 侧，`install oc`（别名 `opencode`）只动 opencode 侧；装 cc/qc/agy/oc 时需要 python3，只装 pi 时不需要。qc 的 `statusLine.command` 写绝对路径（`$QODER_CONFIG_DIR/wren-qc.py`，与 qoder 官方引导一致）。装机前若目标位置已有内容不同的
同名文件（含软链，解引用后比较），先告警再覆盖。`$PI_EXT_DIR` 里若还留着旧的手工副本 `odo.ts`，
会提示 pi 会把两个 footer 都装上，不会替你删。

qc 侧：`install qc` 拷 payload 到 `$QODER_CONFIG_DIR/wren-qc.py` 并写 `$QODER_SETTINGS`；
卸载反向操作（同样只删自己的东西）。前置校验对所有要写配置的宿主先行：任一 settings
读不懂或写不进，连一个 payload 都不装（T67 守门）。

agy 侧：`install agy` 拷 payload 到 `$AGY_CONFIG_DIR/wren-agy.py`（默认 `~/.gemini/antigravity-cli/`，
settings 在该目录的 `settings.json`，**不是** `~/.gemini/settings.json`）并写 `$AGY_SETTINGS` 的
`statusLine`（默认绕开 python3 shim，command 是「优先快解释器」片段；`WREN_AGY_PYTHON=off`
回到裸绝对路径，详见上文「启动开销与 shim」），同时确保 `statusLine.enabled = true`
（残留 false 会让安装形同没装）。卸载只摘 `type`/`command` 与等价缺省的 `enabled:true`，
保留用户的 `enabled:false` / `padding` / `stack_with_default`；碎片化的 command 只要含
wren 的裸路径（单引号完整路径串）就认（T160-T163、T181/T182 守门）。

oc 侧：`install oc` 拷两个 payload（`wren-oc.tsx` + `wren-oc.ts`）到 `<tui 配置同目录>/plugins/`，
并在 `tui.json` / `tui.jsonc` 的 `plugin` 数组里加一条 `./plugins/wren-oc.tsx`。因为宿主只把 TUI 插件当 npm 包安装
（`opencode plugin <本地文件>` 会找 `package.json` 而失败），配置是 wren 自己做**文本级定向编辑**：
保留注释与排版，不重新序列化；多行数组插到首元素前一行，行内数组插到 `[` 后，因此卸载能逐字节还原。
未显式设 `OPENCODE_TUI_CONFIG` 时：已存在的 `tui.jsonc` 优先接管（用户手写的那个），两个都没有则新建 `tui.json`。
宿主两个文件都读并分层合并，所以只改其中一个不会跟另一个打架。卸载后可能留下空的 `"plugin": []`（宿主视为无插件）。

`wren` 自己经 `cli-zoo-install.sh` 软链到 `$PREFIX` 后，仍能定位同目录的 payload。行 1 尾部有一个
灰字宿主徽标 ` | cc`、` | pi`、` | qc`、` | agy` 或 ` | oc`，同屏开多个 agent 时一眼能区分。

## 环境变量与退出码

| 变量 | 默认 | 作用 |
|------|------|------|
| `PREFIX` | `/usr/local/bin` | **只用于 `wren` 本体**（`cli-zoo-install.sh` 的软链）；cc payload 落点跟随 settings.json 同目录 |
| `PI_EXT_DIR` | `$HOME/.pi/agent/extensions` | pi 扩展目录 |
| `CLAUDE_CONFIG_DIR` | `$HOME/.claude` | Claude Code 配置目录（CC 官方支持的重定向变量，wren 跟随它定位 settings） |
| `CLAUDE_SETTINGS` | `$CLAUDE_CONFIG_DIR/settings.json` | 要改的 settings 文件（显式设置时优先级最高） |
| `QODER_CONFIG_DIR` | `$HOME/.qoder` | Qoder CLI 配置目录（qoder 官方同名重定向变量，wren 跟随它定位 settings 与 payload 落点） |
| `QODER_SETTINGS` | `$QODER_CONFIG_DIR/settings.json` | qc 侧要改的 settings 文件（显式设置时优先级最高） |
| `AGY_CONFIG_DIR` | `$HOME/.gemini/antigravity-cli` | Antigravity CLI 配置目录（settings 在这里的 `settings.json`，**不是** `~/.gemini/settings.json`） |
| `AGY_SETTINGS` | `$AGY_CONFIG_DIR/settings.json` | agy 侧要改的 settings 文件（显式设置时优先级最高）；payload 落点 = 它同目录的 `wren-agy.py` |
| `WREN_AGY_PYTHON` | `auto` | agy 状态栏解释器：`off` = 裸脚本（走 shebang）；`auto` = 绕开 python3 shim；其它值时当作解释器绝对路径 |
| `WREN_AGY_HARD_LIMIT` | （不设，3.0s） | agy 硬墙钟覆盖（秒，钳在 `[0.2, 4.0]`），测试专用 |
| `OPENCODE_CONFIG_DIR` | `${XDG_CONFIG_HOME:-$HOME/.config}/opencode` | opencode 配置目录（opencode 官方同名重定向变量） |
| `OPENCODE_TUI_CONFIG` | `$OPENCODE_CONFIG_DIR/tui.json`（存在 `tui.jsonc` 时优先接管） | oc 侧要改的 TUI 配置文件；payload 落点 = 它同目录的 `plugins/` |

退出码：`0` 成功 / `1` 写入失败 / `2` 参数错误 / `3` 依赖缺失（python3 或 payload）。
装 cc / qc / agy / oc 都要 python3（cc/qc/agy 用它合并写 settings.json，oc 用它做 JSONC 定向编辑）；只装 pi 不需要。

## `wren-pi.ts` 相对 pi 上游的有意修改

（`wren-cc.py` 未改；括号里是对应的守门用例）

- **`fmt` 补 1000K 守卫**：`999_500~999_999` 显示 `1.0M`。pi 内置的 `formatTokens` 上游同样会渲染 `1000k`，
  `ccstatusline` 与 `wren-cc.py` 都守这条，这里有意不跟上游（T28）。
- **ctx% 改用 `ctx.getContextUsage()`**：不再手算。手算会漏 `cacheWrite`，且压缩后会把压缩前的旧值一直挂着
  改用权威 API 后，压缩后暂不可知时显示 `?`（T29）。
- **家目录折叠改用 `os.homedir()`**：原来的 `/Users/...` 硬编码在 Linux 与自定义 `HOME` 下不生效（T30）。
- **`CH` 改两位小数**：与 `wren-cc.py` 对齐（pi 内置 footer 是一位）（T31）。
- **git 段改为与 `wren-cc.py` 同一套解析**：一次 `git status --porcelain=v2 --branch` 全拿分支 / ahead-behind / 增删改，
  渲染 `↑a↓b +增 ~删 ✱改`。旧的 `⇡a⇣b` 与「porcelain 行数当脏文件数」都不分类、还混进重命名，
  且要跑三次 git 子进程（T32 做跨实现比对）。
- **detached HEAD 判定改由 porcelain 的 `# branch.head` 推导**（`(` 开头即无分支），
  不用 `getGitBranch()` 的返回值：pi 对真 detached 与名为 `detached` 的真分支返回同一字符串，无法区分（T38）。
- **CH 无缓存不显示、压缩后显示旧值**：与 `wren-cc.py` 统一（T41）。
- **行内布局**：删掉右对齐/pad，`·` 分隔，thinking 缺省不显示，与 `wren-cc.py` 逐字同构。
- **长目录/长分支折叠**：预算驱动，逐级降级（头2尾2 → 头1尾2 → 尾2 → 尾1 → 末级字符截断），
  按显示宽计算（全角算 2 格），折叠结果与色档无关；分支 >24 折叠为头 8 + `…` + 尾 15。
  宽度来源分宿主：pi 用 `render(width)`，
  CC 用 `COLUMNS` 有则用、无则 80 兜底（T42/T43/T45/T46）。整行出口再各做一次硬截断
  （pi 的 `truncateToWidth` / CC 侧等价实现），公式算偏也不会溢出。

## Dracula 主题（v5 起，五侧同款色板）

| 元素 | 色 | 色值 |
|------|------|------|
| cwd / 分隔线 / herdr / CP / 宿主徽标 | 注释灰 | `#6272a4` |
| 分支名 | 紫 | `#bd93f9` |
| `+增` | 绿 | `#50fa7b` |
| `~删` | 红 | `#ff5555` |
| `✱改` | 黄 | `#f1fa8c` |
| token / 时长 | 前景白 | `#f8f8f2` |
| CH / 思考等级 | 青 | `#8be9fd` |
| `TTFT` | 绿 <5s、白 5-20s、黄 20-60s、红 >60s | 四档突变（同 ctx% 的哲学，不做渐变）；阈值取自实测分布（中位 13.2s / p90 92.6s）。**判据是屏幕显示值**（<10s 一位小数、≥10s 四舍五入整秒）：`TTFT 20s` 恒白、`TTFT 21s` 起恒黄，避免同值两色 |
| 模型名 | 粉 | `#ff79c6` |
| ctx% | 绿 ≤70、黄 70<p≤90、红 >90 | 三档突变，pi 内置语义；不做渐变 |

降级与开关：

- `NO_COLOR` 非空 → 全部裸文本（测试也用它跑明文断言）。
- CC 侧：`COLORTERM ∈ {truecolor, 24bit}` → truecolor 精确色值；否则 256 色近似。
  statusline 的 stdout 不是 tty，不能拿 `isatty()` 判，只有这两级。qc 与 CC 同判定（同为
  statusline stdout）；真会话实测 truecolor 码原样透传，仅叠加宿主 dim（见上文渲染差异）。
  agy 同判定，真机 truecolor 透传正常。
- pi 侧：色档取 `theme.getColorMode()`（宿主公开 API，主题热切换时随 footer 工厂重求值）；`NO_COLOR` 优先于宿主判定。
- oc 侧：不做 256 档转换，直接给 RGB 十六进制（`<text fg>`），由宿主/终端决定降档；
  因此只有 truecolor 一级（现代终端都能显示），旧终端由宿主自己近似。
- 两档色值都离线预计算硬编码（256 档按 pi 宿主的 `rgbTo256` 算法算好，cc / qc / agy 同一张表）。
- **假定深色终端底色**：Dracula 为暗底设计（白底下黄/前景/绿/青的 WCAG 对比度 <1.5:1 基本不可读），
  光背景需求请用官方 Alucard 色板，此处不支持。
- 已知降级：tmux 默认不透传 `COLORTERM`，tmux 内 CC 侧会落在 256 色档，属预期行为。
