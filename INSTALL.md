# INSTALL

本文件给自动化 agent 读。人类用户请看 [README.md](./README.md)。

## 前置依赖

| 依赖 | 用在哪 | 检查 |
|------|--------|------|
| bash | 安装脚本、测试 | `command -v bash` |
| python3 | wren 的 python payload（`wren-cc.py` / `wren-qc.py`）、opencode 侧 `tui.json(c)` 的 JSONC 定向编辑、wren 测试的 JSON 断言 | `command -v python3` |
| claude | otter 测试 T06+ 前置检查（缺则 otter 测试 exit 2） | `command -v claude` |
| git | otter 布局里的 lazygit window、wren 的 statusline git 段（oc 侧自己跑 `git status`） | `command -v git` |
| node ≥ 22.18（或 23.6） | 仅 wren 测试里依赖 node 的 23 条用例（T27-T32/T38/T40/T43/T46/T69-T73/T77-T78/T80/T96-T100，需不带 flag 直接执行 `.ts` 的版本；22.6-22.17 要显式 flag，probe 不加，会 SKIP）；wren 运行本身不需要 | `node -v`（缺时测试 SKIP，不算 FAIL） |
| opencode | 仅 wren 测试 T101（真机 TUI 读屏；oc payload 运行靠 opencode 自带 bun，不需要外部 node） | `command -v opencode` |
| tmux | otter 全部功能；wren 测试 T101（真机 e2e） | `command -v tmux` |

缺 node 只导致 wren 那 23 条用例 SKIP，缺 opencode 或 tmux 只导致 T101 SKIP，都不算 FAIL；缺 python3 时 wren 测试脚本自身 exit 2，
而 `wren install cc` / `wren install qc` / `wren install oc` 会 exit 3（`wren install pi` 不需要 python3）。

## 安装

```bash
./cli-zoo-install.sh <tool>          # tool ∈ {otter, wren}
```

- 默认软链到 `/usr/local/bin`；不可写或不想动它时用 `PREFIX=$HOME/bin ./cli-zoo-install.sh <tool>`。
- 脚本内部：源在 `zoo-scripts/<tool>`（wren 是多文件工具，软链的是目录内入口 `zoo-scripts/wren/wren`），目标冲突先 `rm -f` 再 `ln -s`。
- 权限不足时按脚本提示 `sudo PREFIX=$PREFIX ./cli-zoo-install.sh <tool>` 重试。

wren 装完本体后还需一步接线（装的是文件副本，幂等）：

```bash
wren install            # 四个宿主都装；或 wren install cc / pi / qc / oc 分侧装（别名 claude / qoder / opencode）
```

该步会写 `$CLAUDE_SETTINGS` 的 `statusLine` 键（只动这一个键，首次自动备份到 `<settings>.wren-bak`），并把 payload 拷到 **settings.json 同目录的 `wren-cc`** 与 `$PI_EXT_DIR/wren-pi.ts`。默认落 `~/.claude/wren-cc` 与 `~/.pi/agent/extensions/wren-pi.ts`，可用 `CLAUDE_SETTINGS` / `PI_EXT_DIR` 改道（改 settings 路径即改 payload 落点）。qc 侧同理：payload 拷到 `$QODER_CONFIG_DIR/wren-qc.py`（默认 `~/.qoder`，可用 `QODER_CONFIG_DIR` / `QODER_SETTINGS` 改道），`statusLine.command` 写该绝对路径。

oc 侧形态不同（opencode 没有 statusline 命令协议）：两个 payload（`wren-oc.tsx` + `wren-oc-core.ts`）拷到 **`<tui 配置同目录>/plugins/`**，
并在 `tui.json` / `tui.jsonc` 的 `plugin` 数组里加一条 `./plugins/wren-oc.tsx`。默认落在 `~/.config/opencode`，
可用 `OPENCODE_CONFIG_DIR`（官方重定向变量）或 `OPENCODE_TUI_CONFIG`（直接指定配置文件；payload 落点跟随它同目录）改道。
写入是文本级定向编辑：注释与排版保留，多行数组插到首元素前一行、行内数组插到 `[` 后，所以卸载能逐字节还原；
未显式设 `OPENCODE_TUI_CONFIG` 时已存在的 `tui.jsonc` 优先接管（两个都没有则新建 `tui.json`）。

## 验证

```bash
otter -h                                # otter 装好
wren -h                                 # wren 本体装好
bash .test_scripts/otter-test.sh        # expect: Total: 25  Pass: 25
bash .test_scripts/wren-test.sh         # expect: Total: 101  Pass: 101（缺 node 时 23 条 SKIP，缺 opencode/tmux 时 T101 SKIP）
```

wren 装好后可再喂一份 statusline JSON 冒烟：

```bash
printf '{"cwd":"/tmp","model":{"display_name":"m"}}' | NO_COLOR=1 ~/.claude/wren-cc
# expect: 两行输出，行1 以 "| cc" 结尾，exit 0
printf '{"cwd":"/tmp","model":{"display_name":"m"}}' | NO_COLOR=1 python3 zoo-scripts/wren/wren-qc.py
# expect: 两行输出，行1 以 "| qc" 结尾，exit 0
```

oc 侧没有 stdin/stdout 冒烟（是 TUI 插件）：用隔离配置验证接线，或直接看 TUI 底部：

```bash
tmp="$(mktemp -d)"; OPENCODE_CONFIG_DIR="$tmp" OPENCODE_TUI_CONFIG="$tmp/tui.json" wren install oc \
  && grep -q 'wren-oc.tsx' "$tmp/tui.json" && ls "$tmp/plugins"
# expect: 打印 wren-oc.tsx 与 wren-oc-core.ts，exit 0；随后起 opencode，TUI 底部应出现两行（行1 含 "| oc"）
OPENCODE_CONFIG_DIR="$tmp" OPENCODE_TUI_CONFIG="$tmp/tui.json" wren uninstall oc   # 验证完拆掉
```

oc 的排版核心可以不启 TUI 直接用 node 跑：

```bash
P=zoo-scripts/wren/wren-oc-core.ts node -e 'import(process.env.P).then(m=>console.log(m.buildLines({width:120,cwd:"/tmp",home:"/home/u",branch:null,head:"",ab:"",added:0,modified:0,deleted:0,herdr:"",durationMs:null,inputTokens:0,outputTokens:0,cacheRead:0,cacheWrite:0,compactions:0,ctxPercent:null,ctxWindow:0,model:"m",thinking:"",ttftMs:null}).map(l=>l.map(s=>s.text).join("")).join("\n")))'
# expect: 两行，行1 "/tmp | oc"，行2 "↑0 ↓0 | R0 | m"
```

## 卸载

```bash
wren uninstall                          # 先拆四个宿主的接线（幂等）
./cli-zoo-uninstall.sh wren             # 再摘 wren 本体
./cli-zoo-uninstall.sh otter            # otter 直接卸
```

顺序重要：`cli-zoo-uninstall.sh wren` 摘掉 `$PREFIX/wren` 软链后，`wren uninstall` 就没入口了，会留下 `~/.claude/wren-cc`、两份 settings 里的 `statusLine`、`~/.pi/agent/extensions/wren-pi.ts`、`~/.qoder/wren-qc.py`、`~/.config/opencode/plugins/wren-oc.{tsx,core.ts}` 与 `tui.json(c)` 里的 `plugin` 条目。uninstall 只删 wren 自己装的文件；内容被改过的目标会 `left alone` 不动。
oc 侧卸载可能留下空的 `"plugin": []`（宿主视为无插件）——有意取舍：宁可留一个空数组，也不删用户配置里的键。

## 退出码（wren）

`0` 成功 / `1` 写入失败 / `2` 参数错误 / `3` 依赖缺失（python3 或 payload）。
