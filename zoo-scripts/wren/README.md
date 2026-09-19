# wren 细节

主 README 只留使用方法，本文收口径、原理与完整清单。

## 宿主差异（cc / pi / qc）

三份 payload 布局同构，段格式、折叠规则、色板都一致。剩下几处差异来自宿主本身
（statusline 与 TUI footer 拿数据的路子不同）：

| 位置 | `wren.py`（Claude Code） | `wren.ts`（pi） |
|------|------|------|
| 时长 | `cost.total_duration_ms` | footer 装载起的 wall-clock |
| ctx% | 按 `input + cache_read + cache_creation` 自算（与 CC 官方 `used_percentage` 同式） | 取 `ctx.getContextUsage()`（pi 的定义含 output，压缩后显示 `?`） |
| CH 数据源 | `current_usage` 优先，回退 transcript 末条 assistant | `sessionManager` 末条 assistant |

CH 公式 cc/pi 两侧一致，都是 `cacheRead / (input + cacheRead + cacheWrite)`，两位小数，压缩后显示旧值
不消失，这点跟 pi 内置 footer 一样。`ccstatusline` 用的是另一个口径
`read / (read + creation)`，只看缓存内部转换率、分母不含 input，属定义差异不是对错，我们取 pi 式。

### qc（Qoder CLI）侧数据源

`wren-qc.py` 与上表两侧同构，差异全部在数据源（结论来自 qodercli 1.1.57 二进制内嵌
payload 文档 + 构造器静态核对 + 真会话抓包，由 T48-T58 守门）：

| 位置 | 来源 |
|------|------|
| cwd | `workspace.current_dir` 优先，回退 `cwd` |
| ↑in/↓out | transcript 累计。原生 `context_window.total_input_tokens` 是「最近一次请求」的上下文占用（官方文档注明 NOT a session total），`total_output_tokens` 宿主从不发送，都不能当累计 |
| ctx% | 原生 `used_percentage`（整数）优先；缺失回落 `total_input_tokens`（= 当前占用）→ `postTokens` → transcript 末次请求 |
| CH | qoder 的 `usage.input_tokens` 已含 cache → `cacheRead / input`；仅当 `input < cache_read`（旧版口径）回退 cc 公式；`cache_creation` 可能是对象（`ephemeral_5m/1h` 求和） |
| 时长 | `cost.total_duration_ms`（宿主目前不发送）→ 回落 transcript 首条时间戳 |
| 思考等级 | transcript 的 `runtime-config` 记录（真实 payload 无顶层字段，顶层 / `model.preferences` 路径仅作兼容保留） |

渲染差异一则：qoder 对 statusline 输出按 span 逐段重断言 `\x1b[2m`（Ink dimColor），
同色板观感比 cc/pi 偏暗，属宿主样式，脚本内补偿 `\x1b[22m` 无效。

调试钩子：`WREN_DEBUG_DUMP=<path>` 把 stdin 原始 payload 落盘，用于未来 schema 变化时对齐。

## 安装器行为

改配置之前会先校验。`settings.json` 解析失败、或它所在目录不可写，都在产生任何副作用之前 exit 1。
写入时只动 `statusLine` 一个键，其余键和它们的顺序原样保留，已有 `statusLine` 是对象时往里合并。
首次安装把原文件留底到 `<settings>.wren-bak`，重复安装不覆盖。落盘是写 `.wren-tmp` 再 `os.replace`。

卸载只删自己的东西。目标链接不是指向本工具 payload 的、`statusLine` 不指向 `wren-cc` 的，只提示
`left alone` 不动。`install` 和 `uninstall` 重复执行都退出 0。

`install cc` 与 `install pi` 各只动一侧，`install qc`（别名 `qoder`）只动 Qoder 侧；只装 pi 时不需要 python3。qc 的 `statusLine.command` 写绝对路径（`$QODER_CONFIG_DIR/wren-qc.py`，与 qoder 官方引导一致）。装机前若目标位置已有内容不同的
同名文件（含软链，解引用后比较），先告警再覆盖。`$PI_EXT_DIR` 里若还留着旧的手工副本 `odo.ts`，
会提示 pi 会把两个 footer 都装上，不会替你删。

qc 侧：`install qc` 拷 payload 到 `$QODER_CONFIG_DIR/wren-qc.py` 并写 `$QODER_SETTINGS`；
卸载反向操作（同样只删自己的东西）。前置校验对所有要写配置的宿主先行：任一 settings
读不懂或写不进，连一个 payload 都不装（T67 守门）。

`wren` 自己经 `cli-zoo-install.sh` 软链到 `$PREFIX` 后，仍能定位同目录的 payload。行 1 尾部有一个
灰字宿主徽标 ` | cc`、` | pi` 或 ` | qc`，同屏开多个 agent 时一眼能区分。

## 环境变量与退出码

| 变量 | 默认 | 作用 |
|------|------|------|
| `PREFIX` | `/usr/local/bin` | CC 侧可执行文件目录 |
| `PI_EXT_DIR` | `$HOME/.pi/agent/extensions` | pi 扩展目录 |
| `CLAUDE_CONFIG_DIR` | `$HOME/.claude` | Claude Code 配置目录（CC 官方支持的重定向变量，wren 跟随它定位 settings） |
| `CLAUDE_SETTINGS` | `$CLAUDE_CONFIG_DIR/settings.json` | 要改的 settings 文件（显式设置时优先级最高） |
| `QODER_CONFIG_DIR` | `$HOME/.qoder` | Qoder CLI 配置目录（qoder 官方同名重定向变量，wren 跟随它定位 settings 与 payload 落点） |
| `QODER_SETTINGS` | `$QODER_CONFIG_DIR/settings.json` | qc 侧要改的 settings 文件（显式设置时优先级最高） |

退出码：`0` 成功 / `1` 写入失败 / `2` 参数错误 / `3` 依赖缺失（python3 或 payload）。

## `wren.ts` 相对 pi 上游的有意修改

（`wren.py` 未改；括号里是对应的守门用例）

- **`fmt` 补 1000K 守卫**：`999_500~999_999` 显示 `1.0M`。pi 内置的 `formatTokens` 上游同样会渲染 `1000k`，
  `ccstatusline` 与 `wren.py` 都守这条，这里有意不跟上游（T28）。
- **ctx% 改用 `ctx.getContextUsage()`**：不再手算。手算会漏 `cacheWrite`，且压缩后会把压缩前的旧值一直挂着
  改用权威 API 后，压缩后暂不可知时显示 `?`（T29）。
- **家目录折叠改用 `os.homedir()`**：原来的 `/Users/...` 硬编码在 Linux 与自定义 `HOME` 下不生效（T30）。
- **`CH` 改两位小数**：与 `wren.py` 对齐（pi 内置 footer 是一位）（T31）。
- **git 段改为与 `wren.py` 同一套解析**：一次 `git status --porcelain=v2 --branch` 全拿分支 / ahead-behind / 增删改，
  渲染 `↑a↓b +增 ~删 ✱改`。旧的 `⇡a⇣b` 与「porcelain 行数当脏文件数」都不分类、还混进重命名，
  且要跑三次 git 子进程（T32 做跨实现比对）。
- **detached HEAD 判定改由 porcelain 的 `# branch.head` 推导**（`(` 开头即无分支），
  不用 `getGitBranch()` 的返回值：pi 对真 detached 与名为 `detached` 的真分支返回同一字符串，无法区分（T38）。
- **CH 无缓存不显示、压缩后显示旧值**：与 `wren.py` 统一（T41）。
- **行内布局**：删掉右对齐/pad，`·` 分隔，thinking 缺省不显示，与 `wren.py` 逐字同构。
- **长目录/长分支折叠**：预算驱动，逐级降级（头2尾2 → 头1尾2 → 尾2 → 尾1 → 末级字符截断），
  按显示宽计算（全角算 2 格），折叠结果与色档无关；分支 >24 折叠为头 8 + `…` + 尾 15。
  宽度来源分宿主：pi 用 `render(width)`，
  CC 用 `COLUMNS` 有则用、无则 80 兜底（T42/T43/T45/T46）。整行出口再各做一次硬截断
  （pi 的 `truncateToWidth` / CC 侧等价实现），公式算偏也不会溢出。

## Dracula 主题（v5 起，三侧同款色板）

| 元素 | 色 | 色值 |
|------|------|------|
| cwd / 分隔线 / herdr / CP / 宿主徽标 | 注释灰 | `#6272a4` |
| 分支名 | 紫 | `#bd93f9` |
| `+增` | 绿 | `#50fa7b` |
| `~删` | 红 | `#ff5555` |
| `✱改` | 黄 | `#f1fa8c` |
| token / 时长 | 前景白 | `#f8f8f2` |
| CH / 思考等级 | 青 | `#8be9fd` |
| 模型名 | 粉 | `#ff79c6` |
| ctx% | 绿 ≤70、黄 70<p≤90、红 >90 | 三档突变，pi 内置语义；不做渐变 |

降级与开关：

- `NO_COLOR` 非空 → 全部裸文本（测试也用它跑明文断言）。
- CC 侧：`COLORTERM ∈ {truecolor, 24bit}` → truecolor 精确色值；否则 256 色近似。
  statusline 的 stdout 不是 tty，不能拿 `isatty()` 判，只有这两级。qc 与 CC 同判定（同为
  statusline stdout）；真会话实测 truecolor 码原样透传，仅叠加宿主 dim（见上文渲染差异）。
- pi 侧：色档取 `theme.getColorMode()`（宿主公开 API，主题热切换时随 footer 工厂重求值）；`NO_COLOR` 优先于宿主判定。
- 两档色值都离线预计算硬编码（256 档按 pi 宿主的 `rgbTo256` 算法算好，两侧同一张表）。
- **假定深色终端底色**：Dracula 为暗底设计（白底下黄/前景/绿/青的 WCAG 对比度 <1.5:1 基本不可读），
  光背景需求请用官方 Alucard 色板，此处不支持。
- 已知降级：tmux 默认不透传 `COLORTERM`，tmux 内 CC 侧会落在 256 色档，属预期行为。
