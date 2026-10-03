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

测试沙箱里五个目录 + 七个环境变量，**真实配置一个都不碰**：

| 变量 | 指向 |
|---|---|
| `PREFIX` | `$BOX/bin` |
| `PI_EXT_DIR` | `$BOX/piext` |
| `CLAUDE_SETTINGS` | `$BOX/claude/settings.json` |
| `QODER_CONFIG_DIR` / `QODER_SETTINGS` | `$BOX/qoder` 及其 `settings.json` |
| `OPENCODE_CONFIG_DIR` / `OPENCODE_TUI_CONFIG` | `$BOX/opencode` 及其 `tui.json` |
| `XDG_CONFIG_HOME` | `$BOX/xdg`（opencode 会把默认全局配置目录叠加进来，T101 必须隔离） |

## 测试用例

| ID | 类别 | 用例 | 期望 |
|---|---|---|---|
| T01 | 参数 | `wren`（无子命令） | exit 2，stderr 含 usage |
| T02 | 参数 | `wren -h` | exit 0，stdout 含 usage 与 `claude/settings.json` |
| T03 | 参数 | `wren bogus` | exit 2，stderr 含 unsupported command |
| T04 | 安装 | `wren install` | `$PREFIX/wren-cc` 是**普通文件**（非软链）、与 `zoo-scripts/wren/wren-cc.py` 逐字节相同、带可执行位 |
| T05 | 安装 | 同上 | `$PI_EXT_DIR/wren-pi.ts` 是普通文件、与 `wren-pi.ts` 逐字节相同 |
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
| T27 | pi | stub 掉 `@earendil-works/pi-tui` 后加载 `wren-pi.ts`，触发 `session_start`，用空 branch 调 `setFooter` 的 `render(120)` | exit 0，恰好 2 行 |
| T28 | pi | branch 含一条 assistant（`input=999_500`） | 行2 含 `↑1.0M`，**不含** `1000K`（与 T05/T06 同款守门） |
| T29 | pi | `getContextUsage()` 返回 `percent=42.5` 一次、返回 `percent=null` 一次 | 前者含 `42.50%/200K`；后者含 `?/200K` 且**不含** `42.5%` |
| T30 | pi | `HOME` 指向临时目录，cwd 分别取该 HOME 下与之外 | HOME 内含 `~/Code/proj`；HOME 外原样显示且不含 `~` |
| T31 | pi | branch 含一条 assistant（`input=1000, cacheRead=1000, cacheWrite=0`） | 行2 含 `CH50.00%`（两位小数；一位的实现在这里失败） |
| T32 | pi | 在同一临时仓库（带上游、ahead=1、改/删/未跟踪各一）里分别跑 `wren-cc.py` 与 `wren-pi.ts`，比对第一行 git 段 | 两侧 git 段逐字相同（如 `main ↑1↓0 +1 ~1 ✱1`） |
| T33 | 安装 | `wren install cc` | `$PREFIX/wren-cc` 已装、`$PI_EXT_DIR/wren-pi.ts` 未装、statusLine 已写 |
| T34 | 安装 | `wren install pi` | `$PI_EXT_DIR/wren-pi.ts` 已装、`$PREFIX/wren-cc` 未装、settings.json 未动、无备份 |
| T35 | 安装 | `wren install claude` | 等价于 `cc` |
| T36 | 安装 | `wren install bogus` | exit 2，两侧目标目录仍空、settings 未变 |
| T37 | 安装 | 设 `CLAUDE_CONFIG_DIR=$BOX/cfg` 后 `install cc` | settings 写进 `$BOX/cfg/settings.json`；沙箱的默认 `~/.claude` 路径未被创建 |
| T38 | pi | detached HEAD / staged rename / 冲突 UU 三个场景里分别跑 `wren-cc.py` 与 `wren-pi.ts` | detached：两侧都无 git 段；rename：两侧一致 `✱2` 且无 `+`；冲突：两侧一致含 `✱` |
| T39 | cc | 同一份 statusline JSON 跑 truecolor / 256 / `NO_COLOR` 三档 | truecolor 含 `38;2;…` 精确码与紫分支码；256 含 `38;5;61/117/212`；`NO_COLOR` 无任何转义 |
| T40 | pi | stub theme 的 `getColorMode` 分别返回 `truecolor` / `256color`，再叠加 `NO_COLOR` | 三档色码与 CC 侧同一张 Dracula 表；`NO_COLOR` 优先于宿主 |
| T41 | cc | transcript 末条 assistant 后跟一条 `compact_boundary`（`current_usage` 为 null） | 行2 含 `CH60.00%` 与 `CP1`，ctx 用 `postTokens`（`25.00%/200K`） |
| T42 | cc | 长路径 + 长分支的仓库 | 路径折叠含 `…` 且中间段消失；分支折叠后可见宽 ≤25 且含 `…`；尾徽标仍在 |
| T43 | pi | 同一仓库跑 `wren-pi.ts` | 分支折叠结果与 T42 的 CC 侧相同（同规则守门） |
| T44 | cc | 全 CJK 路径（全角算 2 格） | 行1 显示宽 ≤80 |
| T45 | cc | 极端 CJK：长中文路径 + 长中文分支 + 10 脏文件，`NO_COLOR` 与 truecolor 各跑一次 | 两次整行显示宽均 ≤80 且剥色后逐字相同（**色档不得影响折叠**；末级截断按码点切会到 88） |
| T46 | pi | 同一极端 CJK 场景跑 `wren-pi.ts`（stub 宽度 80） | 行1 显示宽 ≤80（守宿主兜底 + 显示格切片同构） |
| T47 | qc | 最小合成 payload（`cwd` + `model`）喂 `wren-qc.py` | 恰好 2 行；行1 `"/tmp \| qc"`；行2 `"↑0 ↓0 \| R0 \| Test-Model"`（无中生有的段一概不出现） |
| T48 | qc | transcript 两条 assistant（Σin=3000 / Σout=400）+ 原生 `total_input_tokens=43138`（诱饵） | 行2 含 `↑3K ↓400`，不含 `↑43K` / `↓0`（原生字段是「最近一次请求」，不得当累计） |
| T49 | qc | `used_percentage=22` 一次；缺失（只剩 `total_input_tokens=43138`）一次 | 前者 `22.00%/200K`；后者自算 `21.57%/200K` |
| T50 | qc | transcript 末条 `input=26254, cache_read=24064`（qoder 口径：input 已含 cache） | 行2 含 `CH91.66%` 与 `R24K`，不含 CC 公式值 `CH47.82%` |
| T51 | qc | 末条 `input=1000 < cache_read=3000, cache_creation=1000`（旧版不含 cache 的口径） | 自适应回退 CC 公式：`CH60.00%` |
| T52 | qc | `cache_creation` 为对象形态（`ephemeral_5m/1h`）且 `input < cache_read` | 对象按 5m+1h 求和后走回退公式：`CH42.86%` |
| T53 | qc | transcript 首条时间戳在 9 分钟前一次；只有 `cost.total_duration_ms=3900000`、无 transcript 一次 | 前者行1 含 `qc · 9m` 且行2 无时长；后者不出时长（v6：会话年龄只从 transcript 推算，cost 路径已删） |
| T54 | qc | transcript 含 `runtime-config`（`reasoningEffort=high`）一次；无该记录一次 | 前者行2 含 `Test-Model · high`；后者行2 恰为 `↑0 ↓0 \| R0 \| Test-Model`（真实 payload 无顶层思考字段） |
| T55 | qc | 同一带 git 仓库 + CH + 思考等级的输入跑 truecolor / 256 / `NO_COLOR` | truecolor 含粉/青/灰/紫 `38;2;…` 码且无 256 码；256 含 `38;5;212/61/117/141`；`NO_COLOR` 无任何转义（与 T39/T40 同一张 Dracula 表） |
| T56 | qc | stdin 喂非法 JSON | exit 0，仍出 2 行，模型名降级 `no-model`，行1 含 `\| qc` |
| T57 | qc | 设 `WREN_DEBUG_DUMP` | dump 文件内容与 stdin 原始字节逐字相同（真实 payload 对齐钩子） |
| T58 | qc | transcript：assistant 后跟 `compact_boundary`（`postTokens=50000`），原生 ctx 字段全缺 | 行2 含 `CP1` 与 `25.00%/200K`（ctx 回落链：native → postTokens → 末次请求） |
| T59 | qc | 同一临时 git 仓库分别跑 `wren-cc.py` 与 `wren-qc.py` | 行1 剥宿主徽标后逐字相同（跨实现同构守门，同 T32 思路） |
| T60 | 安装 | `wren install qc` | `$QODER_CONFIG_DIR/wren-qc.py` 是普通文件、与 `wren-qc.py` 逐字节相同、带执行位；settings 的 `statusLine.command` == 该**绝对路径**、`type == command` |
| T61 | 安装 | 预置 cc settings 后 `wren install qc` | 只动 qc 侧：`$PREFIX`/`$PI_EXT_DIR` 空、cc settings 无 `statusLine`、无 `.wren-bak` |
| T62 | 安装 | qoder settings 预置 `model`/`statusLine.padding`/`env` | 顶层键序仍为 `model,statusLine,env`；`padding`/`env.A` 保留；`<settings>.wren-bak` == 安装前原始字节 |
| T63 | 卸载 | install qc 后手工放 `.wren-tmp` 再 `wren uninstall qc` | payload 删、`statusLine` 键删（剩 `model,env`）、`.wren-bak`/`.wren-tmp` 清掉 |
| T64 | 卸载 | install 后把 `statusLine.command` 改成 `someone-else` 再 uninstall qc | 该键原样保留 + stdout 含 `left alone`；自己的 payload 仍被删 |
| T65 | 安装 | 只设 `QODER_CONFIG_DIR=$BOX/qcfg`（不设 `QODER_SETTINGS`）后 `install qc` | payload/`settings.json` 全落 `$BOX/qcfg`；默认 `$BOX/qoder` 目录未被碰 |
| T66 | 安装 | `wren install qoder` | 等价于 `qc`（别名） |
| T67 | 安装 | cc settings 合法、qoder settings 非法 JSON，跑 `wren install`（all） | exit 1；`$PREFIX`/`$PI_EXT_DIR`/qoder 目录均无 payload、两份 settings 均无 `.wren-bak`、cc settings 字节未变（**预检先行守门**） |
| T68 | 安装 | `QODER_CONFIG_DIR` 指向只读目录下的不存在路径（父目录不可创建），跑 `install`（all） | exit 1；`$PREFIX`/`$PI_EXT_DIR` 均空、目标目录未被创建、cc settings 字节未变（**半装缺口守门**：check 探针需向上找存在祖先） |
| T74 | 安装 | 预置旧名 `$PIEXT/wren.ts`（wren 系副本）后 `wren install pi` | 旧文件被删、新目标 `wren-pi.ts` 与 payload 逐字节相同、stdout 含 `migrated`（**v7 改名迁移守门**） |
| T81 | 安装 | 预置旧落点 `$PREFIX/wren-cc`（wren 系副本）后 `wren install cc` | 旧文件被删、新目标 `$CLAUDE_SETTINGS` 同目录的 `wren-cc` 与 payload 逐字节相同、`statusLine.command` 为绝对路径、stdout 含 `migrated`（**v8 落点迁移守门**） |
| T82 | 安装 | 同上但预置的是非 wren 系同名文件 | 该文件原样保留、stderr 含 `not a wren payload`（**只删自己的东西**） |
| T83 | cc/qc | 18 个探针：四档代表值 + **原始 ms 档界** `4999/5000`、`19999/20000/20001`、`59999/60000/60001` + **舍入后真档界 ±10ms**（`4940/4960`、`20490/20510`、`60490/60510`）；抽「紧邻 `TTFT ` 的转义码 + 文本」 | 每条命中期望档色；且 cc 与 qc 的「文本\|色码」逐字相同（**TTFT 四档着色守门**；同时修掉原 `t83_colors` 未定义 → `want` 为空 → `grep -F ""` 恒真的**空转**） |
| T84 | pi | 读 T83 写下的 `(ms, 文本\|色码)` 表逐条重跑 harness（绕开 `run_pi` 的 `NO_COLOR=1`） | 色码**与显示文本**都与 cc/qc 相同（**三侧同值同色守门**；原来对整行 `grep`，ctx% 同色（0.5% 也绿）时会误过，现改为只取 `TTFT ` 段自己的码） |
| T85 | 三侧 | 边界探针：共享值 `4999/5000/19999/20000/20001/20500/59999/60000/60001/60500` 三侧同值同色；`4949/20499/60499` 精确边仅 qc/cc；pi 补 `4700/61000` | 全部命中期望 `code+TTFT 文本`（**判据=显示值 `ttft_secs`：±1ms 边界串同档、.5s 处换档 20499 白/20500 黄、60499 黄/60500 红；注入 `<=`→`<` 或回退原始 ms 判定都会红**） |
| T76 | qc | round1 配对后 round2 只有 user（等待期）→ 追加 round2 两条 assistant 增量续读 | 等待期行2 含 round1 旧值 `TTFT 7.4s`；续读后含 `TTFT 3.1s` 且不含 `TTFT 7.4s`/`TTFT 9.0s`（**turn_first_ts 不清空、比较判开；首片定值守门**） |
| T77 | pi | 次轮 `turn_start` 已发、首片未到（`TTFT_MS='6600,12400'`、`MSG_UPDATES='0|'`）；另跑首轮进行中 | 前者含旧值 `TTFT 6.6s` 且不含 `TTFT 12s`；首轮进行中无任何 `T`（**方案 B：轮中不闪空、不提前显新值**） |
| T78 | pi | `TTFT_MS='6600,12400'`、`MSG_UPDATES='0|0'`（次轮首片已到） | 含 `TTFT 12s` 且不含 `TTFT 6.6s`（**首片落地原子覆盖**） |
| T79 | qc | CH+TTFT 满段（无色宽 61）、`COLUMNS=80`，truecolor / 256 / `NO_COLOR` 三档渲染行2 | 剥色后三档逐字相同且含 `TTFT 7.4s`（**预算串必须无色守门**：混入 ANSI 会让 truecolor 虚高 ~23 格误丢 TTFT——宿主 T 值被吃的历史 bug） |
| T75 | qc | round1 配对完成（7.4s）后 round2 只有 user（等待期）；对照：全新会话无配对记录 | 等待期行2 含旧值 `TTFT 7.4s`；无配对时 TTFT 段隐藏（**ttft_ms 存量制守门**） |
| T69 | pi | harness 发 `turn_start`（时间戳回拨 6.6s/12s/65s）+ `message_update`，另跑一次两次 update | 行2 分别为 `TTFT 6.6s` / `TTFT 12s` / `TTFT 1m05s`；第二个 update 不改写首片时刻（**事件流 TTFT 守门**） |
| T70 | pi | 常规 payload 渲染两行 | 时长在行1 徽标段（`\| pi · <时长>`）、**行2 不再出现时长**（**时长归位守门**） |
| T71 | pi | 时长在、TTFT 缺（不发事件） | 行2 无悬空 `·`/双空格/`· \|`/`\| \|`，状态组只到 `0.50%/200K`（**悬空分隔符守门**） |
| T72 | pi | 长分支仓库下 `WIDTH=55` 与 `WIDTH=120` 各渲染一次 | 窄终端先丢时长（行1 保留 `\| pi`、无 ` · `、宽 ≤ 55）；宽终端时长仍在（**行1 梯子首丢时长守门**） |
| T73 | pi | 富 payload（CH+CP+TTFT+长模型名）下 `WIDTH=90/75/65/55`（阀值随 `TTFT_BUDGET=11` 变：全在 ≥81 / 丢TTFT 69-80 / 丢CH 60-68 / 丢CP ≤59） | 依次丢 `TTFT → CH → CP`；`↑in↓out`/ctx%/模型名四档均保留（**行2 梯子顺序守门**） |
| T77 | pi | harness 发两轮：round1 `turn_start`+首片（6.6s），round2 只发 `turn_start`（首片未到）；另跑一次首轮进行中（从未有已完成轮） | round2 等待期行2 仍含 round1 旧值 `TTFT 6.6s` 且**不含** `TTFT 12s`；首轮进行中则**无 TTFT 段**（**方案 B 守门**：轮进行中不闪空白、不提前显示新值） |
| T78 | pi | harness 发两轮，round2 补上首个 `message_update` | 行2 含 `TTFT 12s` 且**不含** `TTFT 6.6s`（**首片落地原子覆盖守门**） |

| T80 | 三宿主 | 匹配夹具（743K/117K/R19.6M → CH96.34%、28.42%/1M、CP1、TTFT 12s）下 `COLUMNS/WIDTH=90/81/80/70/65/55` 各跑 cc/qc/pi | 每一档三侧签名（T/C/P）**逐档相同**，且序列为 `TCP TCP -CP -CP --P ---`（**梯子同构守门**；81 是全在的临界点，预算常量差 1 格即暴露） |
| T86 | oc 安装 | 空沙箱 `wren install oc` | `$OPENCODE_CONFIG_DIR/plugins/` 下 `wren-oc.tsx` 与 `wren-oc.ts` 与 payload 逐字节相同；`tui.json` 被创建且 `plugin == ["./plugins/wren-oc.tsx"]` |
| T87 | oc 安装 | 改掉已装副本后重复 `install oc` | spec 只出现一次；copies 刷回 payload（**幂等守门**） |
| T88 | oc 安装 | JSONC 夹具（行注释 + 尾注释 + 自定义键 + 两个其他插件）下 install → uninstall | 注释/键/其他条目全程保留，且卸载后文件与安装前**逐字节相同**（**JSONC 保真守门**：走 json.loads/dump 会吞注释、重排序） |
| T89 | oc 安装 | 只有 `tui.jsonc`（无 `tui.json`），不显式设 `OPENCODE_TUI_CONFIG` | 接管 `tui.jsonc` 且**不新建** `tui.json`（宿主两个文件都读，用户手写的那个优先） |
| T90 | oc 卸载 | 数组里另有其他插件；跑两遍 `uninstall oc` | 只摘自己的 spec、只删自己的两个 payload；其他条目原样；第二遍 exit 0 且提示 `left alone` |
| T91 | oc 卸载 | 人为改掉已装 `wren-oc.tsx` 后卸载 | 被改过的文件保留（`left alone`），但 spec 仍从 `tui.json` 摘掉（**只删自己装的那份**） |
| T92 | oc 安装 | 配置目录 `chmod 555` 后 `install oc` | exit 1，目录零新增文件（**预检先行、不留半装状态**；root 下 SKIP） |
| T93 | oc 安装 | `tui.json` 顶层是数组 / `plugin` 数组未闭合 | exit 1，文件字节未变、payload 未装 |
| T94 | 参数 | `install opencode`（别名）与 `install oc9`（非法） | 别名与 `oc` 等价；非法 target exit 2 + stderr `unsupported target` |
| T95 | 安装 | `install all` → `uninstall all` | 四个宿主全部接线（cc 绝对路径 command、qc 绝对路径 command、pi payload、oc payload + spec），再全部摘干净 |
| T96 | oc 渲染 | 最小夹具（无会话、无 git、无窗口） | 两行；行1 `… \| oc`，行2 `↑0 ↓0 \| R0 \| <model>`（不无中生有） |
| T97 | oc 渲染 | 满配夹具（git 脏 + herdr + 时长 + token/缓存/压缩 + 窗口） + `999_500` 边界夹具 | 行1/行2 与 cc/pi 逐字同构；`999_500` → `1.0M` 且不出现 `1000K` |
| T98 | oc 渲染 | 宽度 120→30 扫描记录各段首次消失的宽度 | 丢序 `TTFT(76) → CH(64) → CP(55)`；`↑in↓out`/`R`/ctx%/模型名在梯子区间内不消失（**梯子顺序守门**） |
| T99 | oc 渲染 | 极端 CJK 路径 + 24 字符中文分支，width=80 | 两行按显示格都不超 80，且行1 保住 `\| oc` 徽标 |
| T100 | oc 渲染 | 11 个 TTFT 探针（含 ±1ms 边界与 `.5s` 换档点） | 「显示值 + 色档」逐条命中；判据是屏幕显示值（`4.9s` 绿 / `5.0s` 白 / `21s` 黄 / `1m01s` 红） |
| T101 | oc 真机 | 沙箱配置下真起 opencode TUI（tmux），读屏 | prompt 框下方那一行左半出现两行 wren 输出（行1 与宿主 `tab agents` 同行且含 `\| oc`，行2 独占一行 `↑0 ↓0 \| R0`）（**唯一直接锁宿主 TUI 插件 API 的用例**：slot 名/replace 透传契约/宽度预算变了会碎；无 opencode 或 tmux 时 SKIP，耗 25s） |
| T102 | oc 安装 | CRLF 行尾的 `tui.json`（6 个 `\r\n`）走 install → uninstall | 6 个 CR 仍在且与安装前**逐字节相同**（**行尾保真守门**：text mode 的 universal newline 会把 `\r\n` 读成 `\n`，一改就整文件换行尾，卸载也回不去；T88 只测 LF 测不出） |
| T103 | oc 安装 | `tui.json` 里 `"plugin"` 是字符串而非数组 | exit 1 + stderr `non-array`，文件字节未变、payload 未装（**预检守门**：不拒的话会追出第二个 `plugin` 键，把用户原值遮蔽；旧实现 payload 已拷完才报错，留半装状态） |
| T104 | oc 安装 | 预置旧名 `plugins/wren-oc-core.ts`（wren 系副本）后 `install oc` | 旧文件被删、新目标 `plugins/wren-oc.ts` 与 payload 逐字节相同、stdout 含 `migrated`（**改名迁移守门**） |
| T105 | oc 渲染 | 空 cwd + 空 model（模型在 oc 侧确实不渲染；空 cwd 是 core 的能力面） | 行1 首段就是 git 组、无悬空分隔符；行2 无尾部 `\| `、无粉色模型段（**去重守门**） |
| T106 | oc 渲染 | 窄预算（49 格，与宿主 usage/快捷键共行后的真实余量） | 行1 级联丢计数/ab 保 herdr；行2 先把 ctx% 换短形 `16%`（位置不变）保住 CH/TTFT，再不够才走梯子（**窄预算守门**：78 列窗格曾把 TTFT/herdr 全挤掉） |
| T107 | cc 窄档 | `COLUMNS` 51/42/36/90 + 四分位矩阵（`current_usage` 原生） | 51：`743K/117K\|◈96.34%\|▄28% ⏱12s\|m · xhigh` 且无 R/CP/两位小数 ctx；42 丢 ⏱；36 再丢 ◈（`117K\|▄28%`）；90 宽档零变化；行1 时长不渲染、herdr 在；▂12/▄37/▆62/█80/█96（**cc 窄档守门**） |
| T108 | pi 窄档 | 同 T107 输入面（harness 驱动：`BRANCH` JSON + `TTFT_MS` + `CTX_USAGE.percent`，新增 `MODEL_NAME` 便于短名探针） | 同 T107 形态断言：51 满配 `743K/117K\|◈96.34%\|▄28% ⏱12s\|m · xhigh`（无 R/CP/小数 ctx/↑↓）；42 丢 ⏱、36 再丢 ◈（`117K\|▄28%`）；**56 宽档边界**（R/↑↓ 原样、无 ⏱/◈，钉「≤55 才切窄」）；90 宽档零变化；行1 herdr 在、`\| pi` 在、无 `· ` 时长；▂▄▆█ 矩阵（**pi 窄档对齐 cc 守门**；非空转已证：narrow 永不触发/丢序反转两类注入均红） |
| T109 | qc 窄档 | 同 T107 输入面（ctx 源换 qc 口径：`used_percentage` 原生 + postTokens 回落；effort 走 runtime-config） | 同 T107 形态断言（55/51 短形满配、42 丢 ⏱、36 丢 ◈、90 宽档零变化、四分位矩阵；行1 `\| qc` 在、无 `· ` 时长）（**qc 窄档对齐 cc 守门**） |
| T110 | 安装 | 裸相对名 env：`CLAUDE_SETTINGS=settings.json`、`OPENCODE_TUI_CONFIG=tui.json`（CWD 落配置）、`QODER_SETTINGS=$BOX/alt/q.json` | 配置与 payload 同目录：cc 在 CWD 且 `$CLAUDE/wren-cc` 不存在、oc payload 在 `./plugins` 且 `$OC/plugins` 不存在、qc 全落 `alt/`（**B-1 分裂落点守门**） |
| T111 | 安装 | tui.json 的 plugin 数组含对象条目 `{"src": "./plugins/wren-oc.tsx"}` | install 仍追加顶层字符串（数组 = `['./plugins/wren-oc.tsx', {…}]`）；uninstall 只删顶层串、对象原样、文件仍合法（**B-4 嵌套误命中守门**） |
| T112 | 安装 | settings/tui.json/qc-settings 皆为 symlink（含悬空）后 `install all` | 三链接仍为 `-L`；真实目标内容已写入 statusLine/plugin（**B-5 symlink 顶掉守门**） |
| T113 | 卸载 | 预置 `statusLine: {type, command, padding: 5}` → install → uninstall | `statusLine` 存活且恰为 `{'padding': 5}`、键序 `model\|statusLine`（**B-6 只摘自家键守门**） |
| T114 | oc | `oneLine`（cc one_line 同字符集）六组样例 ts/py 交叉 + tsx herdr 三段使用 | ts 输出与 python 逐字相同；tsx 三段 grep 到 `oneLine(...)`（**B-2 herdr 压平守门**） |
| T115 | oc | 结构钉：`session_prompt` 兜底分支的裸 Prompt | 白名单 + ref 全透传（**B-3 兜底丢 props 守门**；行为面由 T101 真机 e2e 兜） |
| T121 | qc | 原生 stdin 字段污染四连：`used_percentage:NaN`、`used_percentage:-5`、`current_usage.input_tokens:Infinity`、`total_input_tokens:"500"`（字符串） | NaN/负值/字符串走回落链（a 落 `3.00%/1M`）、Infinity 后 CH 走净化口径 `CH100.00%`（与 cc `_nt` 同构）、无 nan/inf/`-5` 字样、恰好 2 行（**交叉审 Q1/Q2 净化守门**） |
| T122 | qc | `display_name:"Evil\nModel"` + runtime-config `reasoningEffort:"max\nhigh"` 注入 | 输出恰 2 行、`EvilModel`/`maxhigh` 压平在场（**one_line 整删变异存活**：整删后 n=4 红） |
| T123 | qc | transcript assistant 记录 content 含 U+2028（ensure_ascii=False 落盘） | 行2 含 `↑52K`/`R47K`（记录完整解析；**split→splitlines 变异存活**：回退后 `↑0` 红） |
| T124 | qc | `COLUMNS∈{20,10,6}` + 长路径满配 | 恰 2 行、显示宽 ≤COLUMNS；≥20 列时 qc 徽标在场（6 列实绘 4 格为物理极限区只钉结构；**max(4)→max(24) 变异存活**） |
| T125 | qc | 四分位换档值 25/50/75 双源（原生 `used_percentage` + postTokens 回落） | `▄25%`/`▆50%`/`█75%` 六组合全中（**阈值 off-by-one 变异存活**：`<=25` 注入后 25→▂ 红） |
| T127 | qc | cwd=`/tmp/xqc`（折叠后含 qc 子串）+ `COLUMNS=24` 带 herdr；51 列 + 38 格 herdr 同款 | 行1 两场景都含 `\| qc` 徽标段（**徽标保住判定用入选索引非子串守门**：删 rescue 分支变异下 24 列丢徽标红，对齐 cc T126） |
| T128 | qc | 同一 transcript cc 先跑、qc 后跑（同 `WREN_CACHE_DIR`；input=10000/cache_read=8000） | qc 显 `CH80.00%` 不显 `CH44.44%`（**跨宿主缓存键不碰撞守门**：键掺 `qc-` 前缀） |
| T129 | qc | `message.content=""` 的 user + 5s 后 assistant；对照 `content="a"` | 空 content 不显 TTFT、对照显 `TTFT 5.0s`（**空串不开窗守门**，对齐 cc F2） |
| T116 | pi | herdr env 注入：harness 注 `HERDR_TAB_ID=$'t1\nEVIL'`、纯 `\n`、`\n`+WS/PANE 三探针（`env -u` 隔离真实 herdr env） | 换行压平进段（行1 `w9:t1EVIL:p1`）且总行数=2；纯 `\n` 且无他段→herdr 段消失；空段被 `filter(Boolean)` 拆掉无 `::`（**pi herdr env 压平守门**；非空转已证：回退旧代码 n=3 红） |
| T117 | pi | 窄档四分位边界 25/50/75 + 半值 .5 六探针 + cc 交叉（tokens=149000/200000 → 74.5% 精确） | `▄25%`/`▆50%`/`█75%`（边界归上档）；.5 归偶：24.5→▂24、25.5→▄26、49.5→▄50、50.5→▆50、74.5→▆74、75.5→█76；cc 同值 `▆74%`（**pi 半偶舍入守门**；变异已杀：`<50`→`<=50`、roundHalfEven→toFixed(0) 均红） |
| T118 | pi | 预算地板：`WIDTH∈{20,10,6}`（预算 15/5/4）满配夹具 | 逐格钉形 `743K/117K\|▄28%\|`、`743K/`、`743K`（**max(4,W−5) 守门**；变异已杀：max(4)→max(24) 三档全变形红） |
| T119 | pi | 徽标让位夹具：39 格长 herdr 标签 + 51 列（物理极限区） | 行1 `…oo \| pi`（徽标前缀位铁律、herdr 让位）、恰 2 行（**两遍锁定守门**；变异已杀：整删重拼后徽标丢失红） |
| T120 | pi | 模型名/思考注入：`MODEL_NAME=$'evil\nmodel'`+`THINKING=$'high\nx'`、`'anthropic/'`、纯 `\n` 双路 | 压平 `evilmodel · highx` 且 2 行；尾斜杠/压平空→`? · high`，无悬空 `\| ·`；思考压平空→不进段表无尾 ` ·`（**P1/P2 守门**；变异已杀：两处 oneLine 整删、回落整删均红） |

## 条件用例（不满足条件时 SKIP，不算 FAIL）

| ID | 跳过条件 |
|---|---|
| T24 | 以 root 运行时文件权限不生效（`chmod 555` 仍可写） |
| T68 | 同上（依赖 chmod 555 生效） |
| T92 | 同上（oc 侧只读配置目录探针） |
| T27-T32、T38、T40、T43、T46、T69-T73、T77-T78、T80、T96-T100、T108、T116-T120 | 无 `node`，或 `node` 不支持直接执行 `.ts`（Node 22.6+ 的 type stripping） |
| T101 | 无 `opencode` 或无 `tmux`（真机 e2e） |

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
- **T31 是 pi 侧 CH 位数的守门用例**：必须两位小数，与 `wren-cc.py` 对齐。pi 内置 footer 是一位，
  所以这条同样守的是「有意不跟上游」。
- **T48-T52 是 qc 侧数据源口径的守门用例**：↑in/↓out 必须取 transcript 累计：qoder 原生 `total_input_tokens`
  是「最近一次请求」的上下文占用（官方文档注明 NOT a session total），`total_output_tokens` 宿主从不发送；
  CH 必须按「input 已含 cache」的 qoder 口径 `cr/in`，仅当 `input < cache_read`（旧版口径）才回退 CC 公式。
  这些结论来自对 qodercli 1.1.57 二进制内嵌 payload 文档/构造器的静态核对与真实会话抓包。
- **T88 是 oc 侧 JSONC 保真的守门用例**：`tui.json(c)` 必须做文本级定向编辑（保留注释与排版），
  且卸载后逐字节还原。换回 `json.loads`/`json.dump` 会吞注释、重排序，两条断言同时红。
- **T98/T100 是 oc 侧与 cc/pi 同构的守门用例**：排版核心（`wren-oc.ts`）是纯函数，
  梯子丢序与 TTFT 分档必须与另外三侧同一张表；core 里改掉 `TTFT_BUDGET`/显示值判据都会红。
- **T101 是 oc 侧唯一的真机用例**：stub 只能验排版核心，slot 名、replace 透传契约、宽度预算、`api.state` 形状
  这些宿主契约只有真起 TUI 才能锁住。它跑在沙箱配置上（`OPENCODE_CONFIG_DIR` 改道），不碰用户真实配置；
  `XDG_CONFIG_HOME` 也必须一并改道——opencode 会把默认全局配置目录叠加进来，
  否则用户真实装的同一份 payload 会让断言恒真（测不到沙箱那份）。
  行1 的断言卡「与宿主 `tab agents` 同一行」：证明 wren 落在 prompt 框下方那一行（replace + hint 生效），
  而不是退回 append slot 或 app_bottom。
- **T102/T103 是 JSONC 写路径的守门用例**（均由 oc 侧 CR 抓出）：文本级编辑必须保留行尾（`open(..., newline="")`）
  与拒绝非数组 `"plugin"` 值；任一回归都会在 Windows 编辑过的配置上造成字节破坏或重复键。
- **T67 是 qc 侧「零副作用、不留半装状态」的守门用例**：前置校验对所有要写配置的宿主先行，
  任一 settings 读不懂/写不进就一个 payload 都不装（与 T11/T12/T24 同强度，针对 `all` 含 qc 后的新顺序）。
- settings.json 的断言一律走 `json_field`（`python3 -c` 读 JSON），不靠 grep 文本，避免缩进/换行变动导致误判。

## 测试脚本结构

- bash，无第三方依赖，自带 `pass` / `fail` / `skip` / `record`；断言直接内联 `if` + `grep -qF` / `cmp -s` / `diff`。
- `new_box`：每个场景一个全新沙箱（`$TMPROOT/boxN`，内含 `bin` / `piext` / `claude` / `qoder` / `opencode`）。
- `run_wren`：统一调用安装器，stdout / stderr / 退出码分别存到 `$WREN_OUT` / `$WREN_ERR` / `$WREN_EXIT`。
- `oc_render <fixture-json>`：用 node 直接跑 `wren-oc.ts`（纯函数，无宿主依赖）。
  每段一行 `L<行号>=<明文>` 与 `T<行号>:<段文本>=<色名>`，断言用 `grep -qxF` 精确比对。
- `json_field <file> <expr>`：用 `python3 -c` 从 settings.json 取值，`expr` 里用 `d` 引用解析结果。
- 退出时 `trap` 清掉整个 `$TMPROOT`。
- 输出格式：
  - 终端：`PASS T04 ...` / `FAIL T05 expected X got Y` / `SKIP ...`
  - 末尾汇总 `Total: N  Pass: x  Fail: y  Skip: z`
  - 任一 FAIL → 退出码 1
  - 同时把整理结果写入 `.test_res/wren-test-res.md`（覆盖写）
