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

wren 是一个安装器。wren 把两行 statusline（Dracula 配色）装到 4 个宿主：Claude Code、pi、Qoder CLI、opencode。
wren 复制文件副本到宿主。安装完成后，宿主不再依赖本仓库的位置。

```bash
./cli-zoo-install.sh wren        # 第一步：把 wren 装到 $PREFIX
wren install [cc|pi|qc|oc|all]   # 装到宿主。默认 all。幂等。别名：claude、qoder、opencode
wren uninstall [cc|pi|qc|oc|all] # 卸载。默认 all
wren -h                          # 显示帮助
```

![wren statusline preview](./docs/wren-preview.svg)

**宽档样例**（终端宽 ≥ 56 列）：

```
~/Code/cli-zoo | feat/wren-narrow-tier ↑0↓0 | wC:t1:p1 | cc · 1h5m
↑12K ↓3K | R1.2M CH57.14% CP2 | 8.40%/200K TTFT 6.6s | claude-opus-5 · high
```

**窄档样例**（终端宽 ≤ 55 列。移动端 herdr 把 pane 拖成 51 列时触发）：

```
…-zoo | fea…-narrow-tier ↑0↓0 | wC:t1:p1 | cc
12K/3K|◈57.14%|▂8% ⏱6.6s|claude-opus-5 · hi
```

上面两组样例来自同一个会话。wren 在 80 列渲染第一组，在 51 列渲染第二组。

窄档使用 3 类图标：

| 图标 | 含义 |
|------|------|
| `◈` | 缓存命中率（CH）。保留两位小数 |
| `▂` `▄` `▆` `█` | 上下文占用四分位：< 25%、< 50%、< 75%、≥ 75% |
| `⏱` | 首片延迟（TTFT）。窄档不丢弃此段 |

窄档的 4 条规则：

1. wren 不显示 R（缓存读取量）与 CP（压缩次数）。
2. wren 把 in/out 写成短形 `12K/3K`。
3. wren 去掉模型名的 `[1m]` 后缀。wren 缩写思考等级：xhigh→xh、high→hi、medium→med。
4. wren 在窄档不显示行 1 的时长。

两行的段序：

- 行 1：cwd、git 状态、herdr 坐标、宿主徽标、会话时长。
- 行 2：累计 token、缓存读取量、CH、CP、上下文占用、TTFT、模型名、思考等级。

**行 1 放不下时的让位顺序**：时长 → ahead-behind → 分支折叠（6 档：24→20→16→12→8→4）→ cwd 折叠（地板 16→8→4）。
wren 永不丢弃 3 个段：dmg 计数、herdr 坐标、宿主徽标。

**着色**：上下文占用与 TTFT 用突变色档。
TTFT 四档：绿 < 5s、白 5–20s、黄 20–60s、红 > 60s。判据是屏幕显示值。
上下文占用三档：绿 ≤ 70%、黄 70–90%、红 > 90%。

qc 侧同构。qc 侧只有数据源不同。样例来自另一个 workspace 的真会话，所以分支与 pane 编号不同：

```
~/Code/cli-zoo | feat/x ↑0↓0 | wW:t1:p2 | qc · 16m
↑4.5M ↓65K | R4.2M CH98.21% | 15.00%/1M TTFT 4.2s | Qwen3.8-Max · xhigh
```

oc 侧同样两行。wren 把两行渲染在 prompt 框正下方那一行的左半。样例：

```
~/Code/ai_code/cli-zoo | feat/wre…upport_opencode ↑0↓0 ✱6 | wC:t1:p1 | oc · 5h15m      162.4K  ctrl+p commands
↑390K ↓12K | R5.5M CH93.41% | 14.08%/1M TTFT 2.0s
```

oc 侧有 3 点不同：

1. oc 侧不渲染模型名与思考等级。宿主 prompt 框内同一行已有 `agent · model · variant`。
2. oc 侧显示 cwd。wren 行 1 占用宿主原来显示 cwd 的那一格。
3. cc、pi、qc 三个宿主带 cwd 与模型名。这 3 个宿主没有自带信息可用。

窄档在 4 个宿主上不同：

- cc 与 pi：窄档直接生效。
- qc：窄档默认关闭。qoder 宿主不给宽度通道。设置 `WREN_QC_NARROW=1` 打开。
- oc：不做窄档（opencode v2 将发布）。

装完在 pi 里用 `/footer` 切换自定义/内置 footer。

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
