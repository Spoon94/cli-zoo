# otter 测试用例

> 自动生成于 brainstorm 第 8.1 节，对应实现 `zoo-scripts/otter` 与 `cli-zoo-install.sh` / `cli-zoo-uninstall.sh`。

## 退出码

| 码 | 含义 |
|---|---|
| 0 | 成功 |
| 2 | 参数错误（含互斥、白名单不通过、`-s` 无 `-c`、`-ks` 无参数） |
| 3 | 依赖缺失（tmux 或 `-c` 指定的工具未装） |

## 测试用例

| ID | 类别 | 用例 | 期望 |
|---|---|---|---|
| T01 | 参数 | `otter` 无参数 | exit 2，stderr 含 usage |
| T02 | 参数 | `otter -h` | exit 0，输出帮助 |
| T03 | 参数 | `otter -c claude -ks foo` | exit 2，提示互斥 |
| T04 | 参数 | `otter -c notexist` | exit 2，提示不在白名单 |
| T05 | 参数 | source 脚本后 `sanitize_session "a.b c:d[x]"` | 输出所有非 `[:alnum:]_-` 字符变成 `_` 的形式 |
| T06 | 启动 | `OTTER_NO_ATTACH=1 otter -c claude -s otter_test_A` | session 存在，window claude 含 3 pane |
| T07 | 启动 | T06 后等待 0.5s，左 pane 当前命令含 claude | `tmux list-panes -F '#{pane_current_command}'` 第 1 个匹配 |
| T08 | 启动 | nvim 已装 → 存在 nvim window | `tmux list-windows` 含 `nvim` |
| T09 | 启动 | git 仓库 + lazygit 已装 → 存在 lazygit window | 含 `lazygit` |
| T10 | 启动 | 在临时非 git 目录运行 → 无 lazygit window | 不含 `lazygit` |
| T11 | 复用 | T06 后再次执行同命令 | 不新增 window，window 数不变 |
| T12 | 复用 | T06 后 `tmux kill-window -t "=otter_test_A:claude"`，再次执行同命令 | claude window 被重建（3 pane） |
| T13 | kill | `otter -ks otter_test_A` 在 A 存在时 | session 消失，exit 0 |
| T14 | kill | `otter -ks otter_test_notexist` | exit 0，stderr 含 not found |
| T15 | 安装 | `PREFIX=$tmpdir ./cli-zoo-install.sh otter` | `$tmpdir/otter` 是软链且 readlink 指向 `zoo-scripts/otter` |
| T16 | 安装 | T15 后再次安装 | 旧链被替换，仍指向正确目标 |
| T17 | 卸载 | `PREFIX=$tmpdir ./cli-zoo-uninstall.sh otter` | link 被删 |
| T18 | 卸载 | T17 后再次卸载 | exit 0 |
| T19 | 依赖 | mock claude 不存在（`PATH=$emptydir`）后 `otter -c claude` | exit 3，stderr 含 "claude" 与 "not installed" |
| T20 | 依赖 | source otter 后 `PATH=/empty require_cmd tmux` 单独调用（不走主入口，因为 tmux 缺失也无法做 cleanup） | exit 3，stderr 含 "tmux" 相关提示 |
| T21 | 启动 | mock yazi 不存在，正常执行 T06 | session/3 pane 仍创建成功，右上 pane 当前命令是 shell（不是 yazi） |
| T22 | 参数 | 在 `otter_demo_dir` 目录中执行 `OTTER_NO_ATTACH=1 otter -c claude`（不带 `-s`） | 创建出名为 `otter_demo_dir` 的 session |
| T23 | 参数 | `otter -ks`（不带 session 名） | exit 2，stderr 含 usage |
| T24 | 参数 | `otter -s foo`（有 `-s` 但无 `-c`） | exit 2，stderr 含 usage |
| T25 | 参数 | `otter -s foo -ks bar`（`-s` 与 `-ks` 同现） | exit 2，stderr 含 usage |

## 条件用例（不满足条件时 SKIP，不算 FAIL）

| ID | 跳过条件 |
|---|---|
| T08 | `command -v nvim` 失败 |
| T09 | `command -v lazygit` 失败 或 当前不是 git 仓库 |
| T15-T18 | 测试目录不可写（理论上 `mktemp -d` 不会出问题，仅作兜底） |

## 测试钩子

- `OTTER_NO_ATTACH=1`：跳过 `tmux attach`，仅打印目标 session。
- `PREFIX=...`：将安装/卸载目标改到任意可写目录，避免污染 `/usr/local/bin`。

## 测试脚本结构

- bash，无第三方依赖。自带 `assert_eq` / `assert_contains` / `pass` / `fail` / `skip` 助手。
- 每组用例前后清场：`tmux kill-session -t "=otter_test_<x>" 2>/dev/null || true`。
- 启动类用例统一带 `OTTER_NO_ATTACH=1`，避免阻塞。
- 安装/卸载用例用 `PREFIX=$(mktemp -d)`，全程在用户态。
- 输出格式：
  - 终端：`PASS T06 ...` / `FAIL T07 expected X got Y` / `SKIP T08 ...`
  - 末尾汇总 `Total: N  Pass: x  Fail: y  Skip: z`
  - 任一 FAIL → 退出码 1
  - 同时把整理结果写入 `.test_res/otter-test-res.md`（覆盖写）
