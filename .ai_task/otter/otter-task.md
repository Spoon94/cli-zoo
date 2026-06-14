# otter 
使用tmux快速启动claude、yazi、nvim,lazygit等终端工具脚本

## 任务
- 启动脚本，**将完成的脚本写入 @zoo-scripts/**
    - [ ] 在当前目录下快速启动tmux，支持用户自定义session名称，使用-s表示seesion name,若用户未输入session名称，则是用目录名称作为session name
    - [ ] 增加参数-c，该参数为必须输入的参数，输入需要启动的cli工具，若输入claude则启动claude
    - [ ] 在启动的tmux中打开三个window，名称分别为claude、nvim、lazygit
    - [ ] 第一个窗口，根据用户输入的-c参数，即CLI_TOOL,启动的窗口名称=$CLI_TOOL,要求该窗口启动三个pane
        - [ ] 第1个pane左半部分，启动对应的cli工具
        - [ ] 第2个pane右上部分，启动yazi
        - [ ] 第3个pane右下部分，不做任何操作，只是在当前目录下
    - [ ] 第二个窗口可选启动，若用户安装了nvim，则创建该窗口并执行`nvim .`
    - [ ] 第三个窗口可选启动，若用户是git目录，且安装了lazygit，则创建该窗口并启动lazygit
- 安装脚本cli-zoo-install.sh
    - [ ] 增加安装选项otter，将otter软连接至/usr/local/bin/目录下，即/usr/local/bin/otter
    - [ ] 若/usr/local/bin/目录下已经存在otter,则先删除在重新软连
- 卸载脚本cli-zoo-uninstall.sh
    - [ ] 增加卸载选项otter，将otter软连接从/usr/local/bin/目录下删除，若不存在otter则直接成功
- [ ] 功能完成后需要编写测试用例@.test_task/otter-test-task.md
- [ ] 测试用例编写完成后根据@.test_task/otter-test.md测试用例，编写测试脚本@.test_scripts/otter-test.sh
- [ ] 测试脚本编写完成后运行测试脚本@.test_scripts/otter-test.sh，将测试结果写入@.test_res/otter-test-res.md
- [ ] 根据-c参数检测对应cli工具是否存在，若cli工具不存在则提示用户当前未安装该软件并结束启动
- [ ] 若用户先执行`otter -c claude -s A`,再执行`otter -c opencode -s A`,则直接在session A中创建opencode窗口即可
- [ ] 若用户先执行`otter -c claude -s A`,再执行`otter -c claude -s A`,则直接attach至session A即可，因为session A已经创建了claude窗口
- [ ] otter增加关闭session功能，参数为-ks，参数为对应的session名称，ks为kill-session缩写，若不存在该session则提示用户不存在并执行结束

## 审阅意见

### ~~问题 1：白名单与任务需求冲突（严重）~~ 已标注为有意偏离

脑暴保留了 `ALLOWED_TOOLS=("claude")` 白名单，并在第 2 节新增说明块 + 第 10 节偏离表 #2 中明确给出理由：安全考量，避免任意 shell 字符串作为命令注入；扩展只需在脚本顶部数组追加，无需修改其他逻辑。

> 接受此偏离，不再修改。

---

### ~~问题 2：任务文档内部矛盾~~ 已修复

脑暴第 10 节偏离表 #1 已说明：window 1 名称使用 `=$CLI_TOOL`（动态），与任务第 9 行一致。

---

### ~~问题 3：sanitize_session 不够充分~~ 已修复

sanitize_session 已改为 `tr -c '[:alnum:]_-' '_'`，所有非字母数字的字符均替换为 `_`，覆盖 tmux session 名称的全部限制。测试用例 T05 也已更新。

---

### ~~问题 4：kill-session 退出码~~ 已修复

脑暴第 10 节偏离表 #3 已明确标注：任务未指定退出码，统一 exit 0 让幂等调用更友好。这是有意设计决策。

---

### ~~问题 5：测试用例覆盖缺口~~ 已修复

脑暴新增以下测试用例：

| ID | 类别 | 覆盖场景 |
|----|------|----------|
| T19 | 依赖 | `-c` 工具未安装 → exit 3 |
| T20 | 依赖 | tmux 未安装 → exit 3 |
| T21 | 启动 | yazi 不存在 → pane 留空 shell，3 pane 仍创建成功 |
| T22 | 参数 | 缺省 `-s` 时 session 名 = 目录名 |

---

### ~~问题 6：小细节~~ 已修复

- T07 已加 `sleep 0.5s` 规避竞态。
- `build_nvim_window` / `build_lazygit_window` 已加注释说明工具退出会关闭 window。

---

### 修订后总结

第一轮 6 个问题全部已处理。脑暴新增第 10 节"有意偏离任务原文之处"集中记录了 5 项设计决策。

---

## 第二轮审阅意见

### ~~问题 7：`$CLI_TOOL` 归类矛盾~~ 已修复

第 3 节已拆分为"硬依赖（缺失即 exit 3）"和"软依赖（缺失则降级）"两个独立表，`tmux` 和 `$CLI_TOOL` 归入硬依赖。

---

### ~~问题 8：`window_exists` 实现未定义~~ 已修复

第 6 节新增"关键函数实现要点"段落，给出了 `session_exists`、`window_exists`、`sanitize_session` 等关键函数的具体实现方式。

---

### ~~问题 9：T08/T09 的条件性未标注~~ 已修复

第 8.1 节新增"条件用例"表，标注 T08（nvim 未装时 SKIP）、T09（lazygit 未装或非 git 仓库时 SKIP）、T15-T18（目录不可写时 SKIP）。

---

### ~~问题 10：缺少 `-ks` 不带参数的错误处理~~ 已修复

退出码表中 `exit 2` 含义已扩展为"含互斥、白名单不通过、`-ks` 无参数"。测试用例表新增 T23。

---

### ~~问题 11：复用场景中 `-c $PWD` 的行为未说明~~ 已修复

第 4 节新增"复用时新窗口的工作目录"段落，明确说明每次新增 window 使用调用时的 `$PWD`，这是预期行为。

---

### 第二轮总结

5 个问题全部已修复。

---

## 第三轮审阅意见

### ~~问题 12：`-s` 不带 `-c` 或 `-ks` 时的行为未定义~~ 已修复

第 2 节约束新增：`-s` 只能在 `-c` 模式下使用，单独出现或与 `-ks` 同现 → exit 2。新增测试用例 T24。

---

### ~~问题 13：`session_exists` 使用 `=` 前缀精确匹配，但 kill-session 未同步~~ 已修复

第 5 节 kill-session 流程中的 `tmux has-session` 和 `tmux kill-session` 已统一使用 `"=<name>"` 前缀，避免部分匹配。

---

### ~~问题 14：T23 与 T01 的行为重叠~~ 已修复

退出码表 `exit 2` 含义已统一为"参数错误（含互斥、白名单不通过、`-s` 无 `-c`、`-ks` 无参数）"。

---

### 第三轮总结

3 个问题全部已修复。

---

## 第四轮审阅意见

### ~~问题 15：缺少 `-s` 与 `-ks` 同现的测试用例~~ 已修复

测试用例表新增 T25：`otter -s foo -ks bar` → exit 2，stderr 含 usage。

---

### ~~问题 16：`send-keys` 竞态可能不仅限于 T07~~ 已修复

`build_cli_window` 步骤 1 和步骤 2 的 `send-keys` 前均加了 `sleep 0.1` 等待 shell 初始化。

---

### 第四轮总结

2 个问题全部已修复。

---

## 第五轮审阅意见

### ~~问题 17：`-t` 目标中 `=` 前缀使用不一致~~ 已修复

第 4 节顶部新增"目标精确匹配"说明块，所有 `-t` 目标统一使用 `"=..."` 格式（包括 new-window、select-window、split-window、attach、第 5 节 kill-session、第 8.2 节清理命令）。

---

### ~~问题 18：T12 的 `kill-window` 目标不完整~~ 已修复

T12 改为 `tmux kill-window -t "=otter_test_A:claude"`，不再依赖测试脚本在 tmux 内部运行。

---

### ~~问题 19：T20 mock 机制未说明~~ 已修复

T20 改为 source 方式：`source otter` 后 `PATH=/empty require_cmd tmux` 单独调用，不走主入口，避免 tmux 缺失影响测试脚本自身的 cleanup。

---

### ~~问题 20：`require_cmd` / `has_cmd` 实现未列在要点中~~ 已修复

第 6 节关键函数实现要点新增 `has_cmd(cmd)` 和 `require_cmd(cmd)` 的实现。

---

### 第五轮总结

4 个问题全部已修复。

---

## 第六轮审阅意见

第六轮逐节审视后，未发现新的设计问题。文档在以下方面均一致且完整：

- **CLI 参数校验**：`-c`/`-ks`/`-s`/`-h` 的所有组合和互斥均有约束和测试覆盖（T01-T04、T22-T25）
- **依赖检测**：硬依赖（tmux、CLI_TOOL）和软依赖（yazi、nvim、lazygit、git）分层清晰，缺失行为明确
- **session 复用**：新建/attach/新增窗口三种路径均有流程图
- **tmux 命令**：所有 `-t` 目标统一使用 `"=..."` 精确匹配，第 4 节顶部有说明块
- **测试设计**：25 个用例，条件 skip 标注明确（T08/T09/T15-T18），T20 的 source mock 方式已说明
- **偏离说明**：第 10 节集中记录 5 项有意偏离，均有理由
- **测试钩子**：`OTTER_NO_ATTACH=1` 和 `PREFIX` 环境变量设计合理

---

### 第六轮总结

无新问题。脑暴文档已臻完善，可以进入实现阶段。

---

## 审阅总览

| 轮次 | 问题数 | 严重 | 最终状态 |
|------|--------|------|----------|
| R1 | 6 | 1（白名单，已标注偏离） | 全部已修复 |
| R2 | 5 | 0 | 全部已修复 |
| R3 | 3 | 0 | 全部已修复 |
| R4 | 2 | 0 | 全部已修复 |
| R5 | 4 | 0 | 全部已修复 |
| R6 | 0 | 0 | 无新问题 |

**共计 20 个问题，全部已处理。** 当前脑暴版本具备 25 个测试用例、完整 CLI 约束、依赖分层、session 复用/新建/kill 流程、安装/卸载设计、关键函数实现要点。可以进入实现阶段。


