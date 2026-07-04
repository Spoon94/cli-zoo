# cli-zoo

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)
[![GitHub Stars](https://img.shields.io/github/stars/Spoon94/cli-zoo?style=social)](https://github.com/Spoon94/cli-zoo)
[![Shell: Bash](https://img.shields.io/badge/Shell-Bash-1f425f.svg)](#)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](#贡献)

> 个人收藏并整理的命令行小工具集合，按工具拆分目录组织，开箱即用。

每个工具都是一个独立 bash 脚本，存放在 [`zoo-scripts/`](./zoo-scripts) 目录下，通过仓库根目录的 `cli-zoo-install.sh` 软链到 `$PREFIX`（默认 `/usr/local/bin`）即可全局使用。

## 目录

- [快速开始](#快速开始)
- [工具列表](#工具列表)
  - [otter](#otter)
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

详细设计见 [`.ai_task/otter/otter-brainstorm.md`](./.ai_task/otter/otter-brainstorm.md)。

## 安装方式

```bash
./cli-zoo-install.sh <tool>
```

| 环境变量 | 默认值 | 说明 |
|----------|--------|------|
| `PREFIX` | `/usr/local/bin` | 软链目标目录。目录不存在时会自动 `mkdir -p`。 |

安装行为：

1. 检查源脚本存在且可执行（必要时 `chmod +x`）。
2. 若目标位置已存在文件或软链，先 `rm -f`。
3. `ln -s <repo>/zoo-scripts/<tool> $PREFIX/<tool>`。

写入失败（权限不足）时脚本会提示用 `sudo PREFIX=$PREFIX ./cli-zoo-install.sh <tool>` 重试。

## 卸载方式

```bash
./cli-zoo-uninstall.sh <tool>
```

幂等：目标不存在时直接成功 exit 0。

## 测试

每个工具的测试用例放在 [`.test_task/`](./.test_task)、可执行测试脚本放在 [`.test_scripts/`](./.test_scripts)、运行结果写入 [`.test_res/`](./.test_res)。

运行 `otter` 的全部 25 个用例：

```bash
bash .test_scripts/otter-test.sh
```

输出格式：

```
PASS T01 ...
...
Total: 25  Pass: 25  Fail: 0  Skip: 0
```

任一 FAIL → 退出码 1，结果文件 `.test_res/otter-test-res.md` 会被覆盖写。

## 贡献

欢迎 PR 和 Issue：

- 新增工具：把脚本放到 `zoo-scripts/`，在本 README "工具列表" 中追加一节，并配套补齐 `cli-zoo-install.sh` / `cli-zoo-uninstall.sh` 的 `case` 分支与测试用例。
- 修复/改进现有工具：建议先在 Issue 中讨论后再提 PR。
- 提交规范：建议遵循 [Conventional Commits](https://www.conventionalcommits.org/)。

## License

[MIT](./LICENSE)
