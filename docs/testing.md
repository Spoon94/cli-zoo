# 测试

每个工具配一套 shell 测试，跑在临时沙箱里，结果写入 `.test_res/<tool>-test-res.md`。

| 工具 | 用例数 | 运行 |
|------|--------|------|
| `otter` | 25 | `bash .test_scripts/otter-test.sh` |
| `wren` | 190 | `bash .test_scripts/wren-test.sh` |

输出格式：

```
PASS T01 ...
...
Total: 190  Pass: 189  Fail: 0  Skip: 1（T101 需 opencode/tmux 真机）
```

任一 FAIL → 退出码 1，结果文件 `.test_res/<tool>-test-res.md` 会被覆盖写。

## wren 测试说明

全程在 `mktemp -d` 沙箱里作业：`PREFIX` / `PI_EXT_DIR` / `CLAUDE_SETTINGS` / `QODER_CONFIG_DIR` / `QODER_SETTINGS` /
`AGY_CONFIG_DIR` / `AGY_SETTINGS` / `OPENCODE_CONFIG_DIR` / `OPENCODE_TUI_CONFIG` 九个变量把安装目标全部改道，真实的
`/usr/local/bin`、`~/.pi`、`~/.claude`、`~/.qoder`、`~/.gemini/antigravity-cli`、`~/.config/opencode` 一个都不碰。
直接跑 payload 的用例另把 `WREN_CACHE_DIR` 指到沙箱，避免污染真实 `~/.cache/wren`。

- **pi 侧（T27-T32、T38、T40、T43、T46、T69-T73、T77-T78、T80）**：stub 掉 `@earendil-works/pi-tui`，用 fixture 驱动 `wren-pi.ts` 的 footer 真实渲染。
- **agy 侧（T145-T190）**：夹具全部手工脱敏构造（结构同真实 Gemini transcript，content 是占位文本），覆盖宽/窄档精确两行、
  TTFT 语义、时长与时钟异常、payload 回退、增量缓存、transcript 故障矩阵（缺失/空/二进制/半行/截断/毒缓存/非普通文件/超长单行）、
  stdin 容灾（EOF / 管道保持打开 / 非法 UTF-8 / 超 8 MiB）、畸形 payload 矩阵（含 BOM/NaN/Infinity/bidi/ANSI/OSC 注入）、
  文本净化（模型名/effort/cwd/分支名）、token 取整、宽度链（pty 控制终端权重）、C 语言环境编码、长分支 + CJK 路径、非 git cwd、
  运行时预算（git 超时 / 最坏路径 / 扫描时间盒与收敛）、git 超时与信号打断杀整棵树、
  R9 进程创建起算的硬墙钟（慢启动计入预算 / setitimer 看门狗 / 进程创建时刻读数 / 信号重入防抖）、
  R10 收尾路径加固（慢日志线程化不拖住退出 / pid 临时文件原子写 / 40 行轮转 / 进程年龄上界）、
  R11 git 子进程自带到期时间（父进程被 SIGKILL 后孤儿自灭 / 慢但成功的 git 不被误杀）、
  R12 bash 3.2 变量名邻接（静态扫描 / 系统 bash + UTF-8 locale 实跑安装器）、
  安装器解释器选择（绕开 python3 shim / 开关与回落 / 老接线卸载 / R8→R9 升级）与 Python 3.9 兼容、
  agy↔cc 逐字一致性、安装器（enabled 开关/幂等/卸载对称/非法配置零副作用/别名）、性能护栏与缓存键隔离。
  真机 agy 渲染不在单测范围（由人工验收）。
- **oc 侧（T96-T100、T105、T106）**：`wren-oc.ts` 是纯函数（排版核心），node 直接 import 跑，用 fixture 断言两行/梯子/色档/去重/窄预算短形。
  渲染适配层（`wren-oc.tsx`）依赖宿主 JSX 运行时，不在单测范围。
- **oc 真机（T101）**：在沙箱配置下真起 opencode TUI（tmux + 读屏），锁 slot 名/replace 透传契约/宽度预算/`api.state` 形状；轮询等首帧最多 75s（高负载下 opencode 首帧可能 >25s）。
  `OPENCODE_CONFIG_DIR` 与 `XDG_CONFIG_HOME` 都要改道（后者不改的话宿主会把用户真实配置叠加进来，断言恒真）。
  缺 `opencode` 或 `tmux` 时 SKIP，耗时 ~25s。
- 缺 node（或 node 不支持直接执行 `.ts`）时，上述 node 类用例整体 SKIP。

## 超时保护（2026-10-12 事故后加）

背景：`wren install oc` 的 heredoc 曾在「多元素 plugin 数组」上进死循环
（`find_string` 的字面量扫描停在逗号上不前进），测试跑到那条用例就挂住、
不报错、不退出——两个 python 进程 100% CPU 空烧 8 天没人发现。
现在两层防护，挂死一律变成「限时 FAIL」：

| 变量 | 默认 | 作用 |
|------|------|------|
| `WREN_TEST_CMD_TIMEOUT` | 30 | 单条外部命令（`wren` / pi harness）墙钟上限；超时按 124 返回，用例即时 FAIL |
| `WREN_TEST_TOTAL_TIMEOUT` | 1200（wren）/ 900（otter） | 整套上限；到点 watchdog 先把已跑结果落盘（含 FAIL 行）再强杀，绝不静默 |
| `WREN_TEST_RES_FILE` | `.test_res/<tool>-test-res.md` | 结果文件落点（自测 watchdog 时改道，避免踩真实结果） |

配套守门用例：`T141`（八种边界形态下 oc 编辑必须终止）、`T142`（护栏自证——
必须真能掐断 `while :; do :; done`）、`T143`（watchdog 自证——整体超时必须落盘
FAIL 行并非零退出）、`T144`（**杀整棵树**自证——超时必须连子 shell 与孙进程一起
清掉，见下）。任一用例真挂死时，父进程会带 `suspected infinite loop`
写进 stderr，结果文件同时记录「最后完成的用例」。

**超时必须杀整棵树**：`wren` 在 `$(...)` 里 fork 子 shell 跑 heredoc、子 shell 再拉
python。只 `kill -9` 直接子进程的话，子 shell 与 python 孙进程会双双变孤儿继续
自旋——2026-10-12 复现时就漏出 16 个孤儿（9.3 核 × 51 分钟）。`kill_tree` 递归
`pgrep -P` 先杀子孙再杀自身，且杀两遍（兜住遍历途中才 fork 的进程）；`run_limited`、
`run_limited_in`、watchdog 三条超时路径都走它，`T144` 钉住这一行为。
