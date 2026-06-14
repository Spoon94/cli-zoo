# otter 代码审阅意见

> 审阅范围：`zoo-scripts/otter`、`cli-zoo-install.sh`、`cli-zoo-uninstall.sh`、`.test_scripts/otter-test.sh`
> 测试结果：25/25 PASS（已实际运行验证）

---

## 整体评价

实现与脑暴设计文档逐项吻合，上一轮 CR 的 3 个问题已全部修复。代码结构清晰、shell 脚本最佳实践到位（`set -u`、`printf` 替代 `echo`、`[[]]`、`command -v`、正确的引号处理）。

---

## 上一轮 CR 问题修复确认

| # | 问题 | 状态 |
|---|------|------|
| 1 | `-c` 接受以 `-` 开头的值 | ✅ 已修复 — `parse_args` 三个分支均增加 `"$2" == -*` 防护 (`otter:168,177,186`) |
| 2 | `cmd_kill_session` 不检查 `tmux kill-session` 退出码 | ✅ 已修复 — 增加 `if ! tmux kill-session` 检查和 `exit 1` (`otter:110-113`) |
| 3 | `tmux new-session` / `new-window` 无错误检查 | ✅ 已修复 — 两处均增加 `if !` 检查和 `exit 1` (`otter:130-133,137-140`) |

---

## 逐文件审阅

### 1. `zoo-scripts/otter`（主脚本）

**无问题。** 逐项核对：

- **CLI 接口**（脑暴 §2）：`-c`/`-s`/`-ks`/`-h` 解析正确，互斥校验、白名单、`-s` 仅配合 `-c`、缺省 session 名 → `basename $PWD` → `sanitize_session`，全部吻合。
- **退出码**（脑暴 §2）：0/2/3 语义正确。
- **依赖分层**（脑暴 §3）：硬依赖 tmux + CLI_TOOL → exit 3；软依赖 yazi/nvim/lazygit → 降级跳过，均用 `command -v` 检测。
- **启动/复用流程**（脑暴 §4）：session 不存在 → `new-session -d`；存在 + window 存在 → attach；存在 + window 不存在 → `new-window` + `build_cli_window`。nvim/lazygit 仅在新建 session 时创建。
- **`build_cli_window`**：3-pane 布局（左 50% / 右上 50% / 右下 50%），`sleep 0.1` 等 shell 就绪，yazi 软检测，焦点回左侧。
- **kill-session**（脑暴 §5）：`has-session` 检查 + `kill-session`，不存在 → exit 0，失败 → exit 1。
- **关键函数**（脑暴 §6）：`sanitize_session`/`has_cmd`/`require_cmd`/`in_whitelist`/`session_exists`/`window_exists`/`in_git_repo` 实现与设计要点一致。
- **`=` 精确匹配**：所有 `-t` 目标统一使用 `"=..."` 格式。
- **source guard**：`${BASH_SOURCE[0]} == "$0"` 正确。

### 2. `cli-zoo-install.sh`

**无问题。** 与脑暴 §7 设计一致：`PREFIX` 环境变量覆盖、`chmod +x` 确保可执行、`rm -f` 替换旧链接、`ln -s` 创建软链、失败时提示 sudo、不支持的 tool → exit 2。

### 3. `cli-zoo-uninstall.sh`

**无问题。** 与脑暴 §7 设计一致：`PREFIX` 覆盖、幂等 `rm -f`、不存在时友好提示、统一 exit 0、不支持的 tool → exit 2。

### 4. `.test_scripts/otter-test.sh`

**无问题。** 25 个用例全部实现：

- 参数类（T01-T05, T22-T25）：覆盖无参数、`-h`、互斥、白名单、`sanitize_session`、缺省 `-s`、`-ks` 无值、`-s` 无 `-c`、`-s` + `-ks` 同现
- 启动类（T06-T10, T21）：覆盖 session/3-pane 创建、pane 命令验证、nvim/lazygit 窗口、非 git 目录、yazi 缺失降级
- 复用类（T11-T12）：覆盖 window 数不变、window 删除后重建
- kill 类（T13-T14）：覆盖存在/不存在 session
- 安装/卸载类（T15-T18）：覆盖安装、重装替换、卸载、幂等卸载
- 依赖类（T19-T20）：覆盖 claude/tmux 缺失

测试基础设施：
- `trap cleanup_all EXIT` 确保 session 清理
- `OTTER_NO_ATTACH=1` 避免阻塞
- `PREFIX=$(mktemp -d)` 用户态安装测试
- stderr 捕获技巧（`2>&1 >/dev/null`）正确
- 条件跳过逻辑正确（T08/T09/T15-T18）
- T19/T21 的 mock PATH 方案合理
- T20 使用 `source` + 独立函数调用避开主入口

---

## 设计吻合度核对

| 脑暴章节 | 核对项 | 状态 |
|----------|--------|------|
| §2 CLI 接口 | `-c`/`-s`/`-ks`/`-h`、互斥、白名单、缺省 session | ✅ |
| §2 退出码 | 0/2/3 语义 | ✅ |
| §3 硬依赖 | tmux + CLI_TOOL → exit 3 | ✅ |
| §3 软依赖 | yazi/nvim/lazygit 降级 | ✅ |
| §4 启动/复用流程 | 新建/attach/新增窗口三条路径 | ✅ |
| §4 build_cli_window | 3-pane 布局、sleep 0.1、焦点 | ✅ |
| §4 复用时新窗口 cwd | 使用调用时 `$PWD` | ✅ |
| §5 kill-session | has-session → kill/not found | ✅ |
| §6 脚本结构 | 全部函数、source guard | ✅ |
| §7 安装/卸载 | PREFIX、chmod、幂等、sudo 提示 | ✅ |
| §8 测试设计 | 25 用例、条件跳过、钩子 | ✅ |
| §10 偏离表 | 5 项有意偏离全部落实 | ✅ |

---

## 总结

| 严重度 | 数量 | 说明 |
|--------|------|------|
| 严重 | 0 | — |
| 中等 | 0 | — |
| 低 | 0 | — |

**结论**：代码与设计文档完全一致，25 个测试用例全部通过，上一轮 CR 问题已全部修复，无新问题。已达到可交付状态。
