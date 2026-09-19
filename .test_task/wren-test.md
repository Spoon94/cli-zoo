# wren 测试用例

> 对应实现 `zoo-scripts/wren/wren`（安装器）与 `cli-zoo-install.sh` / `cli-zoo-uninstall.sh`。

## 退出码

| 码 | 含义 |
|---|---|
| 0 | 成功（install / uninstall / `-h`） |
| 1 | 写入失败（settings.json 解析失败、目标不可写） |
| 2 | 参数错误（无子命令、未知子命令、未知 target） |
| 3 | 依赖缺失（python3 或 payload 文件） |

## 隔离手段

测试沙箱里四个目录 + 五个环境变量，**真实配置一个都不碰**：

| 变量 | 指向 |
|---|---|
| `PREFIX` | `$BOX/bin` |
| `PI_EXT_DIR` | `$BOX/piext` |
| `CLAUDE_SETTINGS` | `$BOX/claude/settings.json` |
| `QODER_CONFIG_DIR` / `QODER_SETTINGS` | `$BOX/qoder` 及其 `settings.json` |

## 测试用例

| ID | 类别 | 用例 | 期望 |
|---|---|---|---|
| T01 | 参数 | `wren`（无子命令） | exit 2，stderr 含 usage |
| T02 | 参数 | `wren -h` | exit 0，stdout 含 usage 与 `claude/settings.json` |
| T03 | 参数 | `wren bogus` | exit 2，stderr 含 unsupported command |
| T04 | 安装 | `wren install` | `$PREFIX/wren-cc` 是**普通文件**（非软链）、与 `zoo-scripts/wren/wren.py` 逐字节相同、带可执行位 |
| T05 | 安装 | 同上 | `$PI_EXT_DIR/wren.ts` 是普通文件、与 `wren.ts` 逐字节相同 |
| T06 | 安装 | 同上 | settings.json 的 `statusLine.command == "wren-cc"` 且 `type == "command"` |
| T07 | 安装 | settings.json 预置 `model` / `statusLine.padding` / `env` | 顶层键顺序仍为 `model,statusLine,env`；`statusLine.padding` 与 `env.A` 都在（只合并，不整个替换） |
| T08 | 安装 | 承接 T07 | `<settings>.wren-bak` 内容 == 安装前的原始字节 |
| T09 | 安装 | 再跑一次 `wren install` | 备份未被覆盖，仍是最原始那份 |
| T10 | 安装 | settings.json 不存在 | exit 0，文件被创建且含 `statusLine.command == "wren-cc"` |
| T11 | 安装 | settings.json 是非法 JSON | exit 1；文件字节未变、`$PREFIX` 与 `$PI_EXT_DIR` 仍为空、无 `.wren-bak` / `.wren-tmp`（**零副作用**） |
| T12 | 安装 | settings.json 顶层是数组（`[1,2,3]`） | exit 1；文件未变、`$PREFIX` 与 `$PI_EXT_DIR` 为空、无备份与 tmp（与 T11 同强度） |
| T13 | 安装 | 装好后拿真实 statusline JSON 喂 `$PREFIX/wren-cc` | exit 0，输出恰好 2 行，含 `0.18%/200K` 与 `1h5m` |
| T14 | 安装 | `$PI_EXT_DIR/odo.ts`（旧手工副本）事先已存在 | exit 0，stderr 含 `both footers` 警告 |
| T15 | 卸载 | `wren uninstall` | 两份副本都被删 |
| T16 | 卸载 | install 后再 uninstall（settings 里另有 `model` / `env`） | `statusLine` 键被删，顶层键剩 `model,env` |
| T17 | 卸载 | `statusLine.command` 指向 `someone-else` | 该键原样保留，stdout 含 `left alone` |
| T18 | 卸载 | 连续两次 `wren uninstall` | exit 0（幂等） |
| T19 | 卸载 | `$PREFIX/wren-cc` 是别人的文件（内容与 payload 不同） | 该文件保留不动 |
| T20 | 集成 | `PREFIX=$BOX/bin ./cli-zoo-install.sh wren` | exit 0，`$PREFIX/wren` 软链指向 `zoo-scripts/wren/wren` |
| T21 | 集成 | 经 `$PREFIX/wren`（软链入口）执行 install | exit 0，装出的两份副本都与对应 payload 逐字节相同（**验证 `script_dir` 回溯**） |
| T22 | 依赖 | `PATH` 里没有 python3 时 `install cc` | exit 3，stderr 含 `python3`（只装 pi 时不触发，见 T34） |
| T23 | 依赖 | 把安装器单独复制到无 payload 的目录后 install | exit 3，stderr 含 `payload not found` |
| T24 | 安装 | settings 所在目录 `chmod 555` 后 install | exit 1，`$PREFIX` 与 `$PI_EXT_DIR` 仍为空、无备份、stderr 无 `Traceback`（**半装状态守门**） |
| T25 | 安装 | 装好后在 `$PREFIX/wren-cc` 后追加一行再 install；以及原样 install 一次 | 原样那次 stderr **不含** differs；被改过那次含 differs；最终文件恢复为与 payload 相同 |
| T26 | 卸载 | install 后手工放一个 `.wren-tmp`，再 `wren uninstall` | `.wren-bak` 与 `.wren-tmp` 都被清掉；settings.json 里其他键（`model`）仍在 |
| T27 | pi | stub 掉 `@earendil-works/pi-tui` 后加载 `wren.ts`，触发 `session_start`，用空 branch 调 `setFooter` 的 `render(120)` | exit 0，恰好 2 行 |
| T28 | pi | branch 含一条 assistant（`input=999_500`） | 行2 含 `↑1.0M`，**不含** `1000K`（与 T05/T06 同款守门） |
| T29 | pi | `getContextUsage()` 返回 `percent=42.5` 一次、返回 `percent=null` 一次 | 前者含 `42.50%/200K`；后者含 `?/200K` 且**不含** `42.5%` |
| T30 | pi | `HOME` 指向临时目录，cwd 分别取该 HOME 下与之外 | HOME 内含 `~/Code/proj`；HOME 外原样显示且不含 `~` |
| T31 | pi | branch 含一条 assistant（`input=1000, cacheRead=1000, cacheWrite=0`） | 行2 含 `CH50.00%`（两位小数；一位的实现在这里失败） |
| T32 | pi | 在同一临时仓库（带上游、ahead=1、改/删/未跟踪各一）里分别跑 `wren.py` 与 `wren.ts`，比对第一行 git 段 | 两侧 git 段逐字相同（如 `main ↑1↓0 +1 ~1 ✱1`） |
| T33 | 安装 | `wren install cc` | `$PREFIX/wren-cc` 已装、`$PI_EXT_DIR/wren.ts` 未装、statusLine 已写 |
| T34 | 安装 | `wren install pi` | `$PI_EXT_DIR/wren.ts` 已装、`$PREFIX/wren-cc` 未装、settings.json 未动、无备份 |
| T35 | 安装 | `wren install claude` | 等价于 `cc` |
| T36 | 安装 | `wren install bogus` | exit 2，两侧目标目录仍空、settings 未变 |
| T37 | 安装 | 设 `CLAUDE_CONFIG_DIR=$BOX/cfg` 后 `install cc` | settings 写进 `$BOX/cfg/settings.json`；沙箱的默认 `~/.claude` 路径未被创建 |
| T38 | pi | detached HEAD / staged rename / 冲突 UU 三个场景里分别跑 `wren.py` 与 `wren.ts` | detached：两侧都无 git 段；rename：两侧一致 `✱2` 且无 `+`；冲突：两侧一致含 `✱` |
| T39 | cc | 同一份 statusline JSON 跑 truecolor / 256 / `NO_COLOR` 三档 | truecolor 含 `38;2;…` 精确码与紫分支码；256 含 `38;5;61/117/212`；`NO_COLOR` 无任何转义 |
| T40 | pi | stub theme 的 `getColorMode` 分别返回 `truecolor` / `256color`，再叠加 `NO_COLOR` | 三档色码与 CC 侧同一张 Dracula 表；`NO_COLOR` 优先于宿主 |
| T41 | cc | transcript 末条 assistant 后跟一条 `compact_boundary`（`current_usage` 为 null） | 行2 含 `CH60.00%` 与 `CP1`，ctx 用 `postTokens`（`25.00%/200K`） |
| T42 | cc | 长路径 + 长分支的仓库 | 路径折叠含 `…` 且中间段消失；分支折叠后可见宽 ≤25 且含 `…`；尾徽标仍在 |
| T43 | pi | 同一仓库跑 `wren.ts` | 分支折叠结果与 T42 的 CC 侧相同（同规则守门） |
| T44 | cc | 全 CJK 路径（全角算 2 格） | 行1 显示宽 ≤80 |
| T45 | cc | 极端 CJK：长中文路径 + 长中文分支 + 10 脏文件，`NO_COLOR` 与 truecolor 各跑一次 | 两次整行显示宽均 ≤80 且剥色后逐字相同（**色档不得影响折叠**；末级截断按码点切会到 88） |
| T46 | pi | 同一极端 CJK 场景跑 `wren.ts`（stub 宽度 80） | 行1 显示宽 ≤80（守宿主兜底 + 显示格切片同构） |
| T47 | qc | 最小合成 payload（`cwd` + `model`）喂 `wren-qc.py` | 恰好 2 行；行1 `"/tmp \| qc"`；行2 `"↑0 ↓0 \| R0 \| Test-Model"`（无中生有的段一概不出现） |
| T48 | qc | transcript 两条 assistant（Σin=3000 / Σout=400）+ 原生 `total_input_tokens=43138`（诱饵） | 行2 含 `↑3K ↓400`，不含 `↑43K` / `↓0`（原生字段是「最近一次请求」，不得当累计） |
| T49 | qc | `used_percentage=22` 一次；缺失（只剩 `total_input_tokens=43138`）一次 | 前者 `22.00%/200K`；后者自算 `21.57%/200K` |
| T50 | qc | transcript 末条 `input=26254, cache_read=24064`（qoder 口径：input 已含 cache） | 行2 含 `CH91.66%` 与 `R24K`，不含 CC 公式值 `CH47.82%` |
| T51 | qc | 末条 `input=1000 < cache_read=3000, cache_creation=1000`（旧版不含 cache 的口径） | 自适应回退 CC 公式：`CH60.00%` |
| T52 | qc | `cache_creation` 为对象形态（`ephemeral_5m/1h`）且 `input < cache_read` | 对象按 5m+1h 求和后走回退公式：`CH42.86%` |
| T53 | qc | `cost.total_duration_ms=3900000` 一次；无 cost + transcript 首条时间戳在 9 分钟前一次 | 前者 `1h5m`；后者 `9m`（宿主目前不发送该字段，回退路径是常态） |
| T54 | qc | transcript 含 `runtime-config`（`reasoningEffort=high`）一次；无该记录一次 | 前者行2 含 `Test-Model · high`；后者行2 恰为 `↑0 ↓0 \| R0 \| Test-Model`（真实 payload 无顶层思考字段） |
| T55 | qc | 同一带 git 仓库 + CH + 思考等级的输入跑 truecolor / 256 / `NO_COLOR` | truecolor 含粉/青/灰/紫 `38;2;…` 码且无 256 码；256 含 `38;5;212/61/117/141`；`NO_COLOR` 无任何转义（与 T39/T40 同一张 Dracula 表） |
| T56 | qc | stdin 喂非法 JSON | exit 0，仍出 2 行，模型名降级 `no-model`，行1 含 `\| qc` |
| T57 | qc | 设 `WREN_DEBUG_DUMP` | dump 文件内容与 stdin 原始字节逐字相同（真实 payload 对齐钩子） |
| T58 | qc | transcript：assistant 后跟 `compact_boundary`（`postTokens=50000`），原生 ctx 字段全缺 | 行2 含 `CP1` 与 `25.00%/200K`（ctx 回落链：native → postTokens → 末次请求） |
| T59 | qc | 同一临时 git 仓库分别跑 `wren.py` 与 `wren-qc.py` | 行1 剥宿主徽标后逐字相同（跨实现同构守门，同 T32 思路） |
| T60 | 安装 | `wren install qc` | `$QODER_CONFIG_DIR/wren-qc.py` 是普通文件、与 `wren-qc.py` 逐字节相同、带执行位；settings 的 `statusLine.command` == 该**绝对路径**、`type == command` |
| T61 | 安装 | 预置 cc settings 后 `wren install qc` | 只动 qc 侧：`$PREFIX`/`$PI_EXT_DIR` 空、cc settings 无 `statusLine`、无 `.wren-bak` |
| T62 | 安装 | qoder settings 预置 `model`/`statusLine.padding`/`env` | 顶层键序仍为 `model,statusLine,env`；`padding`/`env.A` 保留；`<settings>.wren-bak` == 安装前原始字节 |
| T63 | 卸载 | install qc 后手工放 `.wren-tmp` 再 `wren uninstall qc` | payload 删、`statusLine` 键删（剩 `model,env`）、`.wren-bak`/`.wren-tmp` 清掉 |
| T64 | 卸载 | install 后把 `statusLine.command` 改成 `someone-else` 再 uninstall qc | 该键原样保留 + stdout 含 `left alone`；自己的 payload 仍被删 |
| T65 | 安装 | 只设 `QODER_CONFIG_DIR=$BOX/qcfg`（不设 `QODER_SETTINGS`）后 `install qc` | payload/`settings.json` 全落 `$BOX/qcfg`；默认 `$BOX/qoder` 目录未被碰 |
| T66 | 安装 | `wren install qoder` | 等价于 `qc`（别名） |
| T67 | 安装 | cc settings 合法、qoder settings 非法 JSON，跑 `wren install`（all） | exit 1；`$PREFIX`/`$PI_EXT_DIR`/qoder 目录均无 payload、两份 settings 均无 `.wren-bak`、cc settings 字节未变（**预检先行守门**） |
| T68 | 安装 | `QODER_CONFIG_DIR` 指向只读目录下的不存在路径（父目录不可创建），跑 `install`（all） | exit 1；`$PREFIX`/`$PI_EXT_DIR` 均空、目标目录未被创建、cc settings 字节未变（**半装缺口守门**：check 探针需向上找存在祖先） |

## 条件用例（不满足条件时 SKIP，不算 FAIL）

| ID | 跳过条件 |
|---|---|
| T24 | 以 root 运行时文件权限不生效（`chmod 555` 仍可写） |
| T68 | 同上（依赖 chmod 555 生效） |
| T27-T32、T38、T40、T43、T46 | 无 `node`，或 `node` 不支持直接执行 `.ts`（Node 22.6+ 的 type stripping） |

其余用例只依赖 bash / python3 / coreutils，且全程在用户态临时目录作业。
`python3` 缺失时测试脚本自身 exit 2（前置依赖检查），因为连 settings.json 的断言都做不了。

## 关键断言口径

- **T11/T12/T24 是「零副作用、不留半装状态」的守门用例**：安装器必须在产生任何副作用之前，把配置「读不懂」与「写不进」两类失败都挡掉。
  先建文件后写 settings 的实现会在这三条上留下半成品状态而失败（历史 bug，已修）。
- **T07/T09 是「不破坏用户配置」的守门用例**：只动 `statusLine`、键序保留、备份只写一次。
  整个替换 settings.json 或每次覆盖备份的实现会失败。
  （注意：键与键序保留，但文件整体会被重新序列化，缩进会从用户的 4 空格变 2 空格 ，， 这是已写明的代价。）
- **T17/T19 是「卸载不比安装更有破坏力」的守门用例**：不是自己的东西就不删。
- **T26 是「卸载不留自己的副产物」的守门用例**：`.wren-bak` / `.wren-tmp` 是 wren 自己建的，卸载时一并清掉
  （不含 `~/.cache/wren` 的 transcript 解析缓存，那是运行期产物、卸载不碰）。
  代价：这会丢掉 wren 介入前的原始 settings 备份，需要回滚到安装前状态的用户应在卸载前自行留一份。
- **T21 是 `script_dir` 回溯的守门用例**：入口被软链到 `$PREFIX` 后仍要能找到同目录的 payload。
  用 `$(dirname "$0")` 直接取目录的实现会在这里失败。
- **T24 是「半装状态」的守门用例**：只校验 JSON 可解析、不探目录可写性的实现，会在这里留下 `$PREFIX` 里的半成品。
- **T04/T05/T19 是「装副本而非软链」的守门用例**：改回软链实现会让这三条同时失败。
- **T28 是 pi 侧 fmt 的守门用例**：`999_500` 必须走 `1.0M`。pi 内置的 `formatTokens` 没有这道守卫、
  会渲染 `1000k`，所以这条守的是「有意不跟上游」的行为。
- **T29 是 pi 侧 ctx% 的守门用例**：必须取自 `ctx.getContextUsage()`，且压缩后（`percent: null`）显示 `?`
  而不是把压缩前的旧值一直挂在屏幕上。
- **T30 是 pi 侧家目录折叠的守门用例**：必须用 `os.homedir()`。旧的 `/^\/Users\/[^/]+/` 硬编码在
  Linux 与自定义 HOME 下都不折叠，会在这里失败。
- **T31 是 pi 侧 CH 位数的守门用例**：必须两位小数，与 `wren.py` 对齐。pi 内置 footer 是一位，
  所以这条同样守的是「有意不跟上游」。
- **T48-T52 是 qc 侧数据源口径的守门用例**：↑in/↓out 必须取 transcript 累计：qoder 原生 `total_input_tokens`
  是「最近一次请求」的上下文占用（官方文档注明 NOT a session total），`total_output_tokens` 宿主从不发送；
  CH 必须按「input 已含 cache」的 qoder 口径 `cr/in`，仅当 `input < cache_read`（旧版口径）才回退 CC 公式。
  这些结论来自对 qodercli 1.1.57 二进制内嵌 payload 文档/构造器的静态核对与真实会话抓包。
- **T67 是 qc 侧「零副作用、不留半装状态」的守门用例**：前置校验对所有要写配置的宿主先行，
  任一 settings 读不懂/写不进就一个 payload 都不装（与 T11/T12/T24 同强度，针对 `all` 含 qc 后的新顺序）。
- settings.json 的断言一律走 `json_field`（`python3 -c` 读 JSON），不靠 grep 文本，避免缩进/换行变动导致误判。

## 测试脚本结构

- bash，无第三方依赖，自带 `pass` / `fail` / `skip` / `record`；断言直接内联 `if` + `grep -qF` / `cmp -s` / `diff`。
- `new_box`：每个场景一个全新沙箱（`$TMPROOT/boxN`，内含 `bin` / `piext` / `claude`）。
- `run_wren`：统一调用安装器，stdout / stderr / 退出码分别存到 `$WREN_OUT` / `$WREN_ERR` / `$WREN_EXIT`。
- `json_field <file> <expr>`：用 `python3 -c` 从 settings.json 取值，`expr` 里用 `d` 引用解析结果。
- 退出时 `trap` 清掉整个 `$TMPROOT`。
- 输出格式：
  - 终端：`PASS T04 ...` / `FAIL T05 expected X got Y` / `SKIP ...`
  - 末尾汇总 `Total: N  Pass: x  Fail: y  Skip: z`
  - 任一 FAIL → 退出码 1
  - 同时把整理结果写入 `.test_res/wren-test-res.md`（覆盖写）
