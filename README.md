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

两侧输出同构（行内布局；行 1 尾徽标区分宿主）：

```
~/Code/cli-zoo | main ↑0↓0 +4 ✱2 | wC:t1:p1 | cc
↑12K ↓3K | R1.2M CH57.14% CP2 | 8.40%/200K | claude-opus-5 · high · 1h5m
```

（Dracula 配色。上图为示意图，真实终端效果更好。）

| 行 | 内容 |
|----|------|
| 行 1 | cwd（`$HOME` 折为 `~`）+ git（分支 / `↑ahead↓behind` / `+增 ~删 ✱改`）+ herdr 位置（`ws:tab:pane`，仅环境变量存在时）+ 宿主徽标 |
| 行 2 | 累计 token（`↑in ↓out`）+ 缓存（`R` 读取量、`CH` 命中率、`CP` 压缩次数）+ 上下文占用（`百分比/窗口`）+ 模型名 · 思考等级 · 时长 |

长路径与长分支按预算折叠（按显示宽算，全角算 2 格），整行出口有硬截断兜底，极端场景也不溢出。
两宿主的取数口径差异、安装器细节（校验、备份、幂等、只删自己的东西）、`wren.ts` 相对 pi 上游的
9 处有意修改、Dracula 色板与降级规则，见 [zoo-scripts/wren/README.md](./zoo-scripts/wren/README.md)。

装完在 pi 里用 `/footer` 切换自定义 footer。

环境变量：

| 变量 | 默认 | 作用 |
|------|------|------|
| `PREFIX` | `/usr/local/bin` | CC 侧可执行文件目录 |
| `PI_EXT_DIR` | `$HOME/.pi/agent/extensions` | pi 扩展目录 |
| `CLAUDE_CONFIG_DIR` | `$HOME/.claude` | Claude Code 配置目录（CC 官方支持的重定向变量，wren 跟随它定位 settings） |
| `CLAUDE_SETTINGS` | `$CLAUDE_CONFIG_DIR/settings.json` | 要改的 settings 文件（显式设置时优先级最高） |

退出码：`0` 成功 / `1` 写入失败 / `2` 参数错误 / `3` 依赖缺失（python3 或 payload）。

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
| `wren` | 46 | `bash .test_scripts/wren-test.sh` |

输出格式：

```
PASS T01 ...
...
Total: 46  Pass: 46  Fail: 0  Skip: 0
```

任一 FAIL → 退出码 1，结果文件 `<tool>-test-res.md` 会被覆盖写。

`wren` 的测试全程在 `mktemp -d` 沙箱里作业：`PREFIX` / `PI_EXT_DIR` / `CLAUDE_SETTINGS` 三个变量把安装目标全部改道，真实的 `/usr/local/bin`、`~/.pi`、`~/.claude` 一个都不碰。T27-T32、T38、T40、T43、T46 还会 stub 掉 `@earendil-works/pi-tui`，用 fixture 驱动 `wren.ts` 的 footer 真实渲染；缺 node（或 node 不支持直接执行 `.ts`）时这几条整体 SKIP。

## 贡献

欢迎 PR 和 Issue：

- 新增工具：把脚本放到 `zoo-scripts/`，在本 README「工具列表」中追加一节，并配套补齐 `cli-zoo-install.sh` / `cli-zoo-uninstall.sh` 的 `case` 分支与测试用例。
- 修复/改进现有工具：建议先在 Issue 中讨论后再提 PR。
- 提交规范：建议遵循 [Conventional Commits](https://www.conventionalcommits.org/)。

## License

[MIT](./LICENSE)
