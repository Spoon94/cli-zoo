# cli-zoo

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)
[![GitHub Stars](https://img.shields.io/github/stars/Spoon94/cli-zoo?style=social)](https://github.com/Spoon94/cli-zoo)
[![Shell: Bash](https://img.shields.io/badge/Shell-Bash-1f425f.svg)](#)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](#贡献)

> 个人收藏并整理的命令行小工具集合，按工具拆分目录组织，开箱即用。

每个工具存放在 [`zoo-scripts/<动物名>`](./zoo-scripts) 下（单脚本或多文件目录均可，入口可直接执行），通过仓库根目录的 `cli-zoo-install.sh` 软链到 `$PREFIX`（默认 `/usr/local/bin`）即可全局使用。

## 目录

- [快速开始](#快速开始)
- [工具列表](#工具列表)
  - [otter](#otter)
  - [wren](#wren)
- [安装方式](#安装方式)
- [卸载方式](#卸载方式)
- [测试](#测试)
- [贡献](#贡献)
- [License](#license)

## 快速开始

以安装 `otter` 为例：

```bash
# 1. 克隆本仓库
git clone https://github.com/Spoon94/cli-zoo.git
cd cli-zoo

# 2. 安装 otter 到 /usr/local/bin（可能需要 sudo）
./cli-zoo-install.sh otter

# 3. 验证
otter -h
```

不想动 `/usr/local/bin` 时，可用 `PREFIX` 指定任意可写目录：

```bash
PREFIX=$HOME/bin ./cli-zoo-install.sh otter
```

## 工具列表

### [otter](./zoo-scripts/otter)

用 tmux 把 **AI CLI 工具 + 文件管理器 + 编辑器 + git 客户端** 组合成一套开箱即用的开发会话布局，一条命令进入工作状态。

```bash
otter -c <tool> [-s <session>]   # 启动或复用一个 session
otter -ks <session>              # 杀掉指定 session
otter -h                         # 帮助
```

`-c` 可选值（白名单 `ALLOWED_TOOLS`）：`claude`、`qodercli`、`opencode`。

布局示意（首次启动时创建）：

| Window | 内容 |
|--------|------|
| `$CLI_TOOL`（如 `claude`） | 3 pane：左 = CLI 工具，右上 = yazi（若已装），右下 = 空 shell |
| `nvim`（可选） | 检测到 `nvim` 时执行 `nvim .` |
| `lazygit`（可选） | 当前是 git 仓库且检测到 `lazygit` 时启动 |

特性：

- **白名单工具**：`-c` 取值受 `ALLOWED_TOOLS` 数组保护，初始允许 `claude` / `qodercli` / `opencode`，避免任意 shell 字符串被注入。
- **session 复用**：再次执行 `otter -c claude -s A`，若 `A` 已存在 claude window 则直接 attach；不存在则在 `A` 中新增 claude window。
- **软依赖降级**：`yazi` / `nvim` / `lazygit` 缺失或非 git 仓库时跳过对应步骤，主流程不报错。
- **测试钩子**：`OTTER_NO_ATTACH=1` 跳过 `tmux attach`，方便自动化。


### [wren](./zoo-scripts/wren)

把两行 statusline 装到 Claude Code 与 pi 两个宿主上的安装器。

`wren` 自己不实现 statusline，它负责把同目录下两个 payload **拷到**目标位置（装的是副本，不是指回仓库的软链，装完不依赖本仓库还在原处）：

| payload | 接到哪 |
|---------|--------|
| `wren.py` | `$PREFIX/wren-cc`，并写入 `$CLAUDE_SETTINGS` 的 `statusLine`（Claude Code 侧 statusline；需 python3） |
| `wren.ts` | `$PI_EXT_DIR/wren.ts`，pi 自动加载该目录下的 `.ts`（pi 侧 footer 扩展；无需 python3） |

```bash
./cli-zoo-install.sh wren        # 先把 wren 装到 $PREFIX
wren install                     # 两个宿主都装（幂等；装的是文件副本）
wren install cc                  # 只装 Claude Code 侧（别名 claude）
wren install pi                  # 只装 pi 侧
wren uninstall [cc|pi|all]       # 卸载（默认 all）
wren -h                          # 帮助
```

![wren statusline preview](./docs/wren-preview.svg)

两侧输出同构（行内布局；行 1 尾徽标区分宿主，pi 侧尾徽标为 `pi`）：

```
~/Code/cli-zoo | main ↑0↓0 +4 ✱2 | wC:t1:p1 | cc
↑12K ↓3K | R1.2M CH57.14% CP2 | 8.40%/200K | claude-opus-5 · high · 1h5m
```

（Dracula 配色：cwd/herdr/CP/徽标灰、分支紫、`+`绿 `~`红 `✱`黄、token 白、CH/思考青、模型粉、ctx% 三档变色。详见下方「Dracula 主题」。上图为示意图，真实终端效果更好。）

| 行 | 内容 |
|----|------|
| 行 1 | cwd（`$HOME` 折为 `~`）+ git（分支 / `↑ahead↓behind` / `+增 ~删 ✱改`）+ herdr 位置（`ws:tab:pane`，仅环境变量存在时） |
| 行 2 | 累计 token（`↑in ↓out`）+ 缓存（`R` 读取量、`CH` 命中率、`CP` 压缩次数）+ 上下文占用（`百分比/窗口`）+ 模型名 · 思考等级 · 时长 |

> 两份 payload 布局同构，段格式、折叠规则、色板都一致。剩下几处差异来自宿主本身
> （statusline 与 TUI footer 拿数据的路子不同）：

| 位置 | `wren.py`（Claude Code） | `wren.ts`（pi） |
|------|------|------|
| 缓存写量 `W` | 无此段 | 有（pi 的 usage 语义自带 cacheWrite 展示） |
| 时长 | `cost.total_duration_ms` | footer 装载起的 wall-clock |
| ctx% | 按 `input + cache_read + cache_creation` 自算（与 CC 官方 `used_percentage` 同式） | 取 `ctx.getContextUsage()`（pi 的定义含 output，压缩后显示 `?`） |
| CH 数据源 | `current_usage` 优先，回退 transcript 末条 assistant | `sessionManager` 末条 assistant |

CH 公式两侧一致，都是 `cacheRead / (input + cacheRead + cacheWrite)`，两位小数，压缩后显示旧值
不消失，这点跟 pi 内置 footer 一样。`ccstatusline` 用的是另一个口径
`read / (read + creation)`，只看缓存内部转换率、分母不含 input，属定义差异不是对错，我们取 pi 式。

装完在 pi 里用 `/footer` 切换自定义 footer。

### 安装器行为

改配置之前会先校验。`settings.json` 解析失败、或它所在目录不可写，都在产生任何副作用之前 exit 1。
写入时只动 `statusLine` 一个键，其余键和它们的顺序原样保留，已有 `statusLine` 是对象时往里合并。
首次安装把原文件留底到 `<settings>.wren-bak`，重复安装不覆盖。落盘是写 `.wren-tmp` 再 `os.replace`。

卸载只删自己的东西。目标链接不是指向本工具 payload 的、`statusLine` 不指向 `wren-cc` 的，只提示
`left alone` 不动。`install` 和 `uninstall` 重复执行都退出 0。

`install cc` 与 `install pi` 各只动一侧，只装 pi 时不需要 python3。装机前若目标位置已有内容不同的
同名文件（含软链，解引用后比较），先告警再覆盖。`$PI_EXT_DIR` 里若还留着旧的手工副本 `odo.ts`，
会提示 pi 会把两个 footer 都装上，不会替你删。

`wren` 自己经 `cli-zoo-install.sh` 软链到 `$PREFIX` 后，仍能定位同目录的 payload。行 1 尾部有一个
灰字宿主徽标 ` | cc` 或 ` | pi`，同屏开多个 agent 时一眼能区分。长路径和长分支按预算折叠，规则见
下方「有意修改」末条。

环境变量：

| 变量 | 默认 | 作用 |
|------|------|------|
| `PREFIX` | `/usr/local/bin` | CC 侧可执行文件目录 |
| `PI_EXT_DIR` | `$HOME/.pi/agent/extensions` | pi 扩展目录 |
| `CLAUDE_CONFIG_DIR` | `$HOME/.claude` | Claude Code 配置目录（CC 官方支持的重定向变量，wren 跟随它定位 settings） |
| `CLAUDE_SETTINGS` | `$CLAUDE_CONFIG_DIR/settings.json` | 要改的 settings 文件（显式设置时优先级最高） |

退出码：`0` 成功 / `1` 写入失败 / `2` 参数错误 / `3` 依赖缺失（python3 或 payload）。

`wren.ts` 相对 pi 上游做了这几处修改（`wren.py` 未改），括号里是对应的守门用例：

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
- **长目录/长分支折叠**：预算驱动（宽度−40），逐级降级（头2尾2 → 头1尾2 → 尾2 → 尾1 → 尾段字符截断），
  保证 `len ≤ budget`；分支 >24 折叠为头 8 + `…` + 尾 15。宽度来源分宿主：pi 用 `render(width)`，
  CC 用 `COLUMNS` 有则用、无则 80 兜底（T42/T43）。

#### Dracula 主题（v5 起，两侧同款色板）

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
  statusline 的 stdout 不是 tty，不能拿 `isatty()` 判，只有这两级。
- pi 侧：色档取 `theme.getColorMode()`（宿主公开 API，主题热切换时随 footer 工厂重求值）；`NO_COLOR` 优先于宿主判定。
- 两档色值都离线预计算硬编码（256 档按 pi 宿主的 `rgbTo256` 算法算好，两侧同一张表）。
- **假定深色终端底色**：Dracula 为暗底设计（白底下黄/前景/绿/青的 WCAG 对比度 <1.5:1 基本不可读），
  光背景需求请用官方 Alucard 色板，此处不支持。
- 已知降级：tmux 默认不透传 `COLORTERM`，tmux 内 CC 侧会落在 256 色档，属预期行为。


## 安装方式

```bash
./cli-zoo-install.sh <tool>
```

`<tool>` 可选值：`otter`、`wren`。

| 环境变量 | 默认值 | 说明 |
|----------|--------|------|
| `PREFIX` | `/usr/local/bin` | 软链目标目录。目录不存在时会自动 `mkdir -p`。 |

安装行为：

1. 检查源脚本存在且可执行（必要时 `chmod +x`）。
2. 若目标位置已存在文件或软链，先 `rm -f`。
3. `ln -s <repo>/zoo-scripts/<tool> $PREFIX/<tool>`（wren 因是多文件工具，软链的是目录内的入口脚本 `zoo-scripts/wren/wren`）。

> **wren 的两级安装是刻意的**：`cli-zoo-install.sh` 装的 `$PREFIX/wren` 是**软链**（跟随仓库，改脚本即时生效）；
> 而 `wren install` 装到两个宿主的 `$PREFIX/wren-cc` / `$PI_EXT_DIR/wren.ts` 是**文件副本**（仓库被移走/删除后 statusline 照常工作，更新需重跑 `wren install`）。

写入失败（权限不足）时脚本会提示用 `sudo PREFIX=$PREFIX ./cli-zoo-install.sh <tool>` 重试。

## 卸载方式

```bash
./cli-zoo-uninstall.sh <tool>
```

幂等：目标不存在时直接成功 exit 0。

**先拆线再卸本体**：`wren` 还要先跑一次 `wren uninstall`，否则它会留下 `$PREFIX/wren-cc`、`settings.json` 里的 `statusLine`、以及 pi 扩展目录里的 `wren.ts`：

```bash
wren uninstall              # 拆掉两个宿主的接线
./cli-zoo-uninstall.sh wren # 再摘掉 wren 本体
```

## 测试

每个工具配一套 shell 测试，跑在临时沙箱里，结果写入 `<tool>-test-res.md`。

| 工具 | 用例数 | 运行 |
|------|--------|------|
| `otter` | 25 | `bash .test_scripts/otter-test.sh` |
| `wren` | 44 | `bash .test_scripts/wren-test.sh` |

输出格式：

```
PASS T01 ...
...
Total: 44  Pass: 44  Fail: 0  Skip: 0
```

任一 FAIL → 退出码 1，结果文件 `<tool>-test-res.md` 会被覆盖写。

`wren` 的测试全程在 `mktemp -d` 沙箱里作业：`PREFIX` / `PI_EXT_DIR` / `CLAUDE_SETTINGS` 三个变量把安装目标全部改道，真实的 `/usr/local/bin`、`~/.pi`、`~/.claude` 一个都不碰。T27-T32、T38-T44 还会 stub 掉 `@earendil-works/pi-tui`，用 fixture 驱动 `wren.ts` 的 footer 真实渲染；缺 node（或 node 不支持直接执行 `.ts`）时这几条整体 SKIP。

## 贡献

欢迎 PR 和 Issue：

- 新增工具：把脚本放到 `zoo-scripts/`，在本 README「工具列表」中追加一节，并配套补齐 `cli-zoo-install.sh` / `cli-zoo-uninstall.sh` 的 `case` 分支与测试用例。
- 修复/改进现有工具：建议先在 Issue 中讨论后再提 PR。
- 提交规范：建议遵循 [Conventional Commits](https://www.conventionalcommits.org/)。

## License

[MIT](./LICENSE)
