# otter 设计文档（brainstorm 输出）

> 基于 `.ai_task/otter/otter-task.md` 经过 brainstorming 技能逐项澄清后形成的设计稿。
> 已根据审阅意见修订，遗留的有意偏离任务原文之处在第 10 节集中说明。

---

## 1. 目标

一个 bash 脚本 `otter`，用 tmux 把"AI CLI 工具 + 文件管理器 + 编辑器 + git 客户端"组合成一套开箱即用的开发会话布局。一条命令进入工作状态。

## 2. 命令行接口

```
otter -c <tool> [-s <session>]   # 启动或复用一个 session
otter -ks <session>               # 杀掉指定 session
otter -h                          # 帮助
```

约束：
- `-c` 与 `-ks` 互斥，同时给报错退出。
- 不传 `-c` 也不传 `-ks` → 退出码 2，打印 usage。
- `-c` 取值必须在白名单 `ALLOWED_TOOLS` 内（**初始仅 `claude`**），不在则报错退出。
- `-s` 只能在 `-c` 模式下使用，单独出现或与 `-ks` 同现 → exit 2。
- `-s` 缺省取 `basename "$PWD"`，再经 `sanitize_session` 处理（见第 6 节）。

> **关于白名单**：任务第 24 行举例 `-c opencode`，但当前白名单仅 `claude`。这是**有意偏离**——
> 维持白名单可避免把任意 shell 字符串作为命令注入；扩展只需在脚本顶部 `ALLOWED_TOOLS` 数组追加，
> 不需要修改其他逻辑。任务第 24 行示例视为"未来扩展白名单后即可工作"的场景。

退出码：
| 码 | 含义 |
|---|---|
| 0 | 成功 |
| 2 | 参数错误（含互斥、白名单不通过、`-s` 无 `-c`、`-ks` 无参数） |
| 3 | 依赖缺失（tmux 或 `-c` 指定的工具未装） |

## 3. 依赖与检测

**硬依赖（缺失即 exit 3）**：

| 工具 | 检测时机 |
|---|---|
| `tmux` | 入口 main 一进来就检测 |
| `$CLI_TOOL`（`-c` 指定，初始仅 claude） | 解析参数后、操作 tmux 之前 |

**软依赖（缺失则降级）**：

| 工具 | 触发条件 | 缺失行为 |
|---|---|---|
| `yazi` | CLI 窗口右上 pane | 该 pane 留空 shell（不报错） |
| `nvim` | window 2 | 跳过 window 2 |
| `lazygit` | window 3 | 跳过 window 3 |
| git 仓库 | window 3 | 非 git 目录跳过 window 3 |

判定：
- 命令存在：`command -v <tool> >/dev/null 2>&1`
- git 仓库：`git rev-parse --is-inside-work-tree >/dev/null 2>&1`

## 4. 启动 / 复用流程

> **目标精确匹配**：以下所有 `tmux` 命令凡涉及 `-t <session>` 的位置，实际写作 `-t "=<session>"`，
> 避免 `SESSION` 前缀部分匹配到 `SESSIONxxx`。流程图中为可读性省略 `=`，实现时统一带上。

```
1. parse_args → 校验互斥、白名单、tmux 依赖、CLI 工具依赖
2. session 存在？
   ├─ 否 → tmux new-session -d -s SESSION -n CLI_TOOL -c $PWD
   │       build_cli_window
   │       build_nvim_window      (若 nvim 已装)
   │       build_lazygit_window   (若是 git 仓库 且 lazygit 已装)
   │       tmux select-window -t "=SESSION:CLI_TOOL"
   │       attach
   └─ 是 → 同名 CLI_TOOL 窗口存在？
           ├─ 是 → attach
           └─ 否 → tmux new-window -t "=SESSION" -n CLI_TOOL -c $PWD
                   build_cli_window（同样 3-pane 布局）
                   tmux select-window -t "=SESSION:CLI_TOOL"
                   attach
```

**build_cli_window**（3 pane，左 50% / 右上 50% / 右下 50%）：

1. 当前 pane（左）`sleep 0.1` 等待 shell 初始化，然后 `send-keys "$CLI_TOOL" Enter`（避免 send-keys 在 shell 就绪前发送被吞掉）
2. `tmux split-window -h -p 50 -t "=SESSION:CLI_TOOL"` → 右侧 pane → 若 yazi 存在 `sleep 0.1` 后 `send-keys "yazi" Enter`，否则不发键
3. `tmux split-window -v -p 50 -t "=SESSION:CLI_TOOL"`（在右侧再纵切）→ 右下 pane，不发键
4. `tmux select-pane -t "=SESSION:CLI_TOOL.0"` 焦点回左侧 CLI

**build_nvim_window**：`tmux new-window -t "=SESSION" -n nvim -c $PWD "nvim ."`

**build_lazygit_window**：`tmux new-window -t "=SESSION" -n lazygit -c $PWD "lazygit"`

**attach 行为**：
- 不区分是否在 tmux 内部，统一 `tmux attach -t "=SESSION"`，嵌套场景由 tmux 自身报错。
- 测试钩子：环境变量 `OTTER_NO_ATTACH=1` 时跳过 `tmux attach`，仅打印目标 session。生产无影响。

**复用时新窗口的工作目录**：
向已存在 session 新增 window 时使用 `tmux new-window -c "$PWD"`。如果用户第二次调用 `otter` 时
位于不同目录，新窗口的 cwd 取的是**第二次调用时的 `$PWD`**（不是第一次创建 session 时的目录）。
这是预期行为：otter 的语义是"在当前目录开一套工具"，每个新窗口都应跟随当前目录，更直观。

## 5. kill-session 流程

```
otter -ks <name>
1. tmux has-session -t "=<name>" 2>/dev/null
   ├─ 不存在 → echo "session <name> not found" → exit 0
   └─ 存在   → tmux kill-session -t "=<name>"     → exit 0
```

任务原文未要求区分"不存在"与"已删除"的退出码，统一 0 以便幂等调用。

## 6. 脚本结构（方案 C：函数分层）

文件：`zoo-scripts/otter`

```
ALLOWED_TOOLS=("claude")             # 白名单常量（追加新工具只需改这里）

usage()                               # -h 输出
log_err(msg)                          # 统一 stderr
sanitize_session(raw) → cleaned       # 用 tr -c '[:alnum:]_-' '_' 收紧
require_cmd(cmd)                      # 不存在则 exit 3
has_cmd(cmd) → 0/1                    # 软检测
in_whitelist(tool) → 0/1
session_exists(name) → 0/1
window_exists(session, win) → 0/1
in_git_repo() → 0/1

build_cli_window(session, tool)       # 3-pane 布局
build_nvim_window(session)            # 注：nvim 退出会关闭该 window（new-window 直接挂命令）
build_lazygit_window(session)         # 同上，lazygit 退出关闭 window

cmd_kill_session(name)
cmd_start(tool, session)              # 编排创建/复用 + attach

parse_args "$@"                       # 设 OPT_C / OPT_S / OPT_KS
main "$@"
```

**关键函数实现要点**：

- `sanitize_session(raw)`：`printf %s "$raw" | tr -c '[:alnum:]_-' '_'`
- `has_cmd(cmd)`：`command -v "$1" >/dev/null 2>&1`
- `require_cmd(cmd)`：`has_cmd "$1" || { log_err "$1 is not installed"; exit 3; }`
- `session_exists(name)`：`tmux has-session -t "=$name" 2>/dev/null`（`=` 前缀强制精确匹配）
- `window_exists(session, win)`：`tmux list-windows -t "=$session" -F '#{window_name}' 2>/dev/null | grep -qx "$win"`
- `in_whitelist(tool)`：遍历 `ALLOWED_TOOLS` 数组比对
- `in_git_repo()`：`git rev-parse --is-inside-work-tree >/dev/null 2>&1`

**测试可见性**：脚本结尾用 `if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi`，被 source 时不执行 main，便于单元测试函数。

## 7. 安装 / 卸载脚本

为支持自动化测试，安装目标路径用 `PREFIX` 环境变量覆盖：`${PREFIX:-/usr/local/bin}/otter`。

**`cli-zoo-install.sh`**（仓库根，新文件）：

```
用法: ./cli-zoo-install.sh <tool>
支持 tool: otter

REPO_ROOT=$(cd "$(dirname "$0")" && pwd)
PREFIX=${PREFIX:-/usr/local/bin}
TARGET=$PREFIX/otter
SRC=$REPO_ROOT/zoo-scripts/otter

1. 检查 SRC 存在；若不可执行则 chmod +x
2. [ -e $TARGET ] 或 [ -L $TARGET ] → rm -f $TARGET
3. ln -s $SRC $TARGET
4. echo 成功
```

权限：脚本不主动 sudo；写失败则报错并提示用户用 sudo 重试。

**`cli-zoo-uninstall.sh`**（仓库根，新文件）：

```
用法: ./cli-zoo-uninstall.sh <tool>
支持 tool: otter

PREFIX=${PREFIX:-/usr/local/bin}
TARGET=$PREFIX/otter
[ -e $TARGET ] || [ -L $TARGET ]
  └─ 是 → rm -f $TARGET → 提示成功
  └─ 否 → 提示已不存在 → exit 0
```

未识别 tool 参数 → 报错 exit 2。

## 8. 测试设计

### 8.1 测试用例文档 `.test_task/otter-test.md`

按"参数解析 / 启动 / 复用 / kill / 安装卸载"分组：

| ID | 类别 | 用例 | 期望 |
|---|---|---|---|
| T01 | 参数 | `otter` 无参数 | exit 2，stderr 含 usage |
| T02 | 参数 | `otter -h` | exit 0，输出帮助 |
| T03 | 参数 | `otter -c claude -ks foo` | exit 2，提示互斥 |
| T04 | 参数 | `otter -c notexist` | exit 2，提示不在白名单 |
| T05 | 参数 | source 脚本后 `sanitize_session "a.b c:d[x]"` | 输出 `a_b_c_d_x_` 形式（所有非 `[:alnum:]_-` 字符变 `_`） |
| T06 | 启动 | `OTTER_NO_ATTACH=1 otter -c claude -s otter_test_A` | session 存在，window claude 含 3 pane |
| T07 | 启动 | T06 后等待 0.5s，左 pane 当前命令含 claude | `tmux list-panes -F '#{pane_current_command}'` 第 1 个匹配（带 sleep 规避竞态） |
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
| T19 | 依赖 | mock claude 不存在（`PATH=$emptydir`）后 `otter -c claude` | exit 3，stderr 含 "claude" 与 "not installed/not found" |
| T20 | 依赖 | source otter 后 `PATH=/empty require_cmd tmux` 单独调用（不走主入口，因为 tmux 缺失也无法做 cleanup） | exit 3，stderr 含 "tmux" 相关提示 |
| T21 | 启动 | mock yazi 不存在，正常执行 T06 | session/3 pane 仍创建成功，右上 pane 当前命令是 shell（不是 yazi） |
| T22 | 参数 | 在 `otter_demo_dir` 目录中执行 `OTTER_NO_ATTACH=1 otter -c claude`（不带 `-s`） | 创建出名为 `otter_demo_dir` 的 session |
| T23 | 参数 | `otter -ks`（不带 session 名） | exit 2，stderr 含 usage |
| T24 | 参数 | `otter -s foo`（有 `-s` 但无 `-c`） | exit 2，stderr 含 usage |
| T25 | 参数 | `otter -s foo -ks bar`（`-s` 与 `-ks` 同现） | exit 2，stderr 含 usage |

**条件用例（不满足条件时 SKIP，不算 FAIL）**：

| ID | 跳过条件 |
|---|---|
| T08 | `command -v nvim` 失败 |
| T09 | `command -v lazygit` 失败 或 当前不是 git 仓库 |
| T15-T18 | 测试目录不可写（理论上 `mktemp -d` 不会出问题，仅作兜底） |

### 8.2 测试脚本 `.test_scripts/otter-test.sh`

- bash 脚本，无第三方依赖，自定义 `assert_eq` / `assert_contains` / `pass` / `fail`。
- 每组用例前后清场：`tmux kill-session -t "=otter_test_<x>" 2>/dev/null || true`，避免污染（统一带 `=` 精确匹配）。
- 启动类用例统一带 `OTTER_NO_ATTACH=1`，避免阻塞。
- 安装/卸载用例用 `PREFIX=$(mktemp -d)`，全程在用户态。
- 输出格式：
  - 终端：`PASS T06 ...` / `FAIL T07 expected X got Y`
  - 末尾汇总 `Total: N  Pass: x  Fail: y  Skip: z`
  - 任一 FAIL → 退出码 1
  - 同时把整理结果写入 `.test_res/otter-test-res.md`（覆盖写）

### 8.3 测试结果文档 `.test_res/otter-test-res.md`

由测试脚本运行后自动生成，结构：

```
# otter 测试结果
执行时间：YYYY-MM-DD HH:MM:SS

| ID | 状态 | 备注 |
|----|------|------|
| T01 | PASS |      |
| T02 | PASS |      |
| ... |      |      |

汇总：Total N / Pass x / Fail y / Skip z
```

## 9. 执行计划

1. 编写 `zoo-scripts/otter` 主脚本（按第 6 节结构）。
2. 编写 `cli-zoo-install.sh` / `cli-zoo-uninstall.sh`，支持 `PREFIX`。
3. 编写 `.test_task/otter-test.md`。
4. 编写 `.test_scripts/otter-test.sh`。
5. 运行测试脚本，结果写入 `.test_res/otter-test-res.md`。
6. 修复测试中暴露的问题，循环至全部 PASS。

## 10. 有意偏离任务原文之处

| # | 任务原文 | 设计选择 | 理由 |
|---|---|---|---|
| 1 | 第 8 行：window 名称固定为 claude/nvim/lazygit | window 1 名 `=$CLI_TOOL`（动态） | 与第 9 行一致，且 `-c opencode` 时叫 `claude` 会令人困惑 |
| 2 | 第 24 行举例 `-c opencode` | 当前白名单仅 `claude` | 安全考量；扩展只需追加 `ALLOWED_TOOLS` 数组 |
| 3 | 第 26 行"提示用户不存在并执行结束" | `-ks` 找不到 session 时 exit 0 | 任务未指定退出码，0 让幂等调用更友好 |
| 4 | 任务文档第 20 行写 `otter-test-task.md`，第 21 行写 `otter-test.md` | 取 `otter-test.md` | 内部矛盾，按第 21 行（更后、更具体）为准 |
| 5 | 任务未提及测试钩子 | 增加 `OTTER_NO_ATTACH=1` 与 `PREFIX` 环境变量 | 让测试可自动化执行，对生产无影响 |
