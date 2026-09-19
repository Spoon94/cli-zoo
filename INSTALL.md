# INSTALL

本文件给自动化 agent 读。人类用户请看 [README.md](./README.md)。

## 前置依赖

| 依赖 | 用在哪 | 检查 |
|------|--------|------|
| bash | 安装脚本、测试 | `command -v bash` |
| python3 | wren 的 python payload（`wren.py` / `wren-qc.py`）、wren 测试的 JSON 断言 | `command -v python3` |
| claude | otter 测试 T06+ 前置检查（缺则 otter 测试 exit 2） | `command -v claude` |
| git | otter 布局里的 lazygit window、wren 的 statusline git 段 | `command -v git` |
| node ≥ 22.18（或 23.6） | 仅 wren 测试的 T27-T32/T38/T40/T43/T46（需不带 flag 直接执行 `.ts` 的版本；22.6-22.17 要显式 flag，probe 不加，会 SKIP）；wren 运行本身不需要 | `node -v`（缺时测试 SKIP，不算 FAIL） |
| tmux | otter 全部功能 | `command -v tmux` |

缺 node 只导致 wren 那 10 条用例 SKIP，不算 FAIL；缺 python3 时 wren 测试脚本自身 exit 2，而 `wren install cc` 会 exit 3（`wren install pi` 不需要 python3）。

## 安装

```bash
./cli-zoo-install.sh <tool>          # tool ∈ {otter, wren}
```

- 默认软链到 `/usr/local/bin`；不可写或不想动它时用 `PREFIX=$HOME/bin ./cli-zoo-install.sh <tool>`。
- 脚本内部：源在 `zoo-scripts/<tool>`（wren 是多文件工具，软链的是目录内入口 `zoo-scripts/wren/wren`），目标冲突先 `rm -f` 再 `ln -s`。
- 权限不足时按脚本提示 `sudo PREFIX=$PREFIX ./cli-zoo-install.sh <tool>` 重试。

wren 装完本体后还需一步接线（装的是文件副本，幂等）：

```bash
wren install            # 三个宿主都装；或 wren install cc / pi / qc 分侧装（qc 别名 qoder）
```

该步会写 `$CLAUDE_SETTINGS` 的 `statusLine` 键（只动这一个键，首次自动备份到 `<settings>.wren-bak`），并把 payload 拷到 `$PREFIX/wren-cc` 与 `$PI_EXT_DIR/wren.ts`。目录默认 `$HOME/.claude` 与 `$HOME/.pi/agent/extensions`，可用 `CLAUDE_CONFIG_DIR` / `CLAUDE_SETTINGS` / `PI_EXT_DIR` 改道。qc 侧同理：payload 拷到 `$QODER_CONFIG_DIR/wren-qc.py`（默认 `~/.qoder`，可用 `QODER_CONFIG_DIR` / `QODER_SETTINGS` 改道），`statusLine.command` 写该绝对路径。

## 验证

```bash
otter -h                                # otter 装好
wren -h                                 # wren 本体装好
bash .test_scripts/otter-test.sh        # expect: Total: 25  Pass: 25
bash .test_scripts/wren-test.sh         # expect: Total: 68  Pass: 68（缺 node 时部分 SKIP）
```

wren 装好后可再喂一份 statusline JSON 冒烟：

```bash
printf '{"cwd":"/tmp","model":{"display_name":"m"}}' | NO_COLOR=1 wren-cc
# expect: 两行输出，行1 以 "| cc" 结尾，exit 0（wren-cc 在 PATH，即 $PREFIX 默认 /usr/local/bin）
printf '{"cwd":"/tmp","model":{"display_name":"m"}}' | NO_COLOR=1 python3 zoo-scripts/wren/wren-qc.py
# expect: 两行输出，行1 以 "| qc" 结尾，exit 0
```

## 卸载

```bash
wren uninstall                          # 先拆三个宿主的接线（幂等）
./cli-zoo-uninstall.sh wren             # 再摘 wren 本体
./cli-zoo-uninstall.sh otter            # otter 直接卸
```

顺序重要：`cli-zoo-uninstall.sh wren` 摘掉 `$PREFIX/wren` 软链后，`wren uninstall` 就没入口了，会留下 `$PREFIX/wren-cc`、两份 settings 里的 `statusLine`、`$PI_EXT_DIR/wren.ts`、`$QODER_CONFIG_DIR/wren-qc.py`。uninstall 只删 wren 自己装的文件；内容被改过的目标会 `left alone` 不动。

## 退出码（wren）

`0` 成功 / `1` 写入失败 / `2` 参数错误 / `3` 依赖缺失（python3 或 payload）。
