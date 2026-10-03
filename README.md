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
- [安装与卸载](#安装与卸载)
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

用 tmux 把 AI CLI 工具、文件管理器、编辑器、git 客户端组合成一套开箱即用的开发会话布局，一条命令进入工作状态。

```bash
otter -c <tool> [-s <session>]   # 启动或复用一个 session
otter -ks <session>              # 杀掉指定 session
otter -h                         # 帮助
```

`-c` 可选值（白名单 `ALLOWED_TOOLS`）：`claude`、`qodercli`、`opencode`。布局为左 CLI 工具 + 右上 yazi + 右下空 shell，检测到 `nvim` / `lazygit` 时各开一个 window；软依赖缺失自动降级。


### [wren](./zoo-scripts/wren)

把两行 statusline（Dracula 配色）装到 Claude Code、pi、Qoder CLI 与 opencode 四个宿主上的安装器。装的是文件副本，装完不依赖本仓库还在原处。

```bash
./cli-zoo-install.sh wren        # 先把 wren 装到 $PREFIX
wren install [cc|pi|qc|oc|all]   # 装到宿主（默认 all；幂等；别名：claude / qoder / opencode）
wren uninstall [cc|pi|qc|oc|all] # 卸载（默认 all）
wren -h                          # 帮助
```

![wren statusline preview](./docs/wren-preview.svg)

```
~/Code/cli-zoo | main ↑0↓0 +4 ✱2 | wC:t1:p1 | cc · 1h5m
↑12K ↓3K | R1.2M CH57.14% CP2 | 8.40%/200K TTFT 6.6s | claude-opus-5 · high
```

qc 侧同构，仅数据源不同（另一 workspace 的真会话实测样例，故分支与 pane 编号不同）：

```
~/Code/cli-zoo | feat/x ↑0↓0 | wW:t1:p2 | qc · 16m
↑4.5M ↓65K | R4.2M CH98.21% | 15.00%/1M TTFT 4.2s | Qwen3.8-Max · xhigh
```

opencode 侧同样两行，渲染在 prompt 框正下方那一行的左半（顶掉宿主原本的 cwd；右半是宿主的 `162.4K (16%)  ctrl+p commands`，真会话实测样例）：

```
~/Code/ai_code/cli-zoo | feat/wre…upport_opencode ↑0↓0 ✱6 | wC:t1:p1 | oc · 5h15m      162.4K  ctrl+p commands
↑390K ↓12K | R5.5M CH93.41% | 14.08%/1M TTFT 2.0s
```

oc 侧不渲染模型 · 思考（宿主 prompt 框内左侧同一行已有 `agent · model · variant`）；
cwd 恢复显示——wren 行1 正好占宿主原来显示 cwd 的那一格。其余三宿主（cc/pi/qc）都带 cwd 与模型，
因为那里没有宿主自带信息可依赖。行1 溢出让位序：时长 → ahead-behind → 分支六档折叠
（24→20→16→12→8→4，… 省略中段）→ cwd 折叠（16→8→4 地板）；dmg 计数、herdr 坐标、宿主徽标
永不丢（徽标两遍锁定，物理极限区 ≤~34 列才交硬截）。

行 1 = cwd + git + herdr 位置 + 宿主徽标 · 会话时长；行 2 = 累计 token + 缓存（读取量 / `CH` 命中率 / `CP` 压缩次数）+ 上下文占用 + 首片延迟（`TTFT`）+ 模型 · 思考（oc 侧模型 · 思考跟宿主重复不渲染）。长路径长分支自动折叠不溢出，cc/qc/pi ≤55 列（移动端 herdr 会把 pane 拖成 51 列）进窄档：预算按实绘宽 `COLUMNS−5` 收（宿主缩进与尾部省略号），行2 换图标短形（in/out 去 ↑↓ 与空格 `31.2M/643K`、CH 前缀 ◈ 两位小数、ctx% 四分位块图标 ▂<25 ▄<50 ▆<75 █≥75 + 整数、TTFT 前缀 ⏱），R/CP 不进段表、模型·思考保留、紧分隔 |，丢序 CP → TTFT → CH；oc 无窄档（opencode v2 将出，裁定不做）。`ctx%` 与 `TTFT` 三档/四档突变着色（TTFT：绿 <5s、白 5–20s、黄 20–60s、红 >60s，判据为屏幕显示值）。装完在 pi 里用 `/footer` 切换。

四宿主差异（cc / pi / qc / oc）、安装器细节、`wren-pi.ts` 相对 pi 上游的有意修改、Dracula 色板，见 [zoo-scripts/wren/README.md](./zoo-scripts/wren/README.md)；测试见 [docs/testing.md](./docs/testing.md)。

## 安装与卸载

```bash
./cli-zoo-install.sh <tool>     # <tool> 可选值：otter、wren
./cli-zoo-uninstall.sh <tool>   # 幂等：目标不存在时直接成功 exit 0
```

| 环境变量 | 默认值 | 说明 |
|----------|--------|------|
| `PREFIX` | `/usr/local/bin` | 软链目标目录。目录不存在时会自动 `mkdir -p`。 |

安装时检查源脚本存在且可执行（必要时 `chmod +x`），目标位置已有文件或软链则先 `rm -f`，再 `ln -s <repo>/zoo-scripts/<tool> $PREFIX/<tool>`（wren 因是多文件工具，软链的是目录内的入口脚本 `zoo-scripts/wren/wren`）。写入失败（权限不足）时会提示用 `sudo PREFIX=$PREFIX ./cli-zoo-install.sh <tool>` 重试。

> **wren 的两级安装是刻意的**：`cli-zoo-install.sh` 装的 `$PREFIX/wren` 是**软链**（跟随仓库，改脚本即时生效）；
> 而 `wren install` 装到宿主的 `<settings.json 同目录>/wren-cc` / `$PI_EXT_DIR/wren-pi.ts` / `$QODER_CONFIG_DIR/wren-qc.py` /
> `<tui.json 同目录>/plugins/wren-oc.tsx` 是**文件副本**（仓库被移走/删除后 statusline 照常工作，更新需重跑 `wren install`）。

**wren 卸载要先拆线再卸本体**，否则会留下 `~/.claude/wren-cc`、两份 `settings.json` 里的 `statusLine`、pi 扩展目录里的 `wren-pi.ts`、
`~/.qoder/wren-qc.py`、以及 opencode 的 payload 与 `tui.json` 里的 `plugin` 条目：

```bash
wren uninstall              # 拆掉四个宿主的接线
./cli-zoo-uninstall.sh wren # 再摘掉 wren 本体
```

## 贡献

欢迎 PR 和 Issue：

- 新增工具：把脚本放到 `zoo-scripts/`，在本 README「工具列表」中追加一节，并配套补齐 `cli-zoo-install.sh` / `cli-zoo-uninstall.sh` 的 `case` 分支与测试用例（见 [docs/testing.md](./docs/testing.md)）。
- 修复/改进现有工具：建议先在 Issue 中讨论后再提 PR。
- 提交规范：建议遵循 [Conventional Commits](https://www.conventionalcommits.org/)。

## License

[MIT](./LICENSE)
