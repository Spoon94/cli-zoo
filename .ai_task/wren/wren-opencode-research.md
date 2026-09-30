# wren 支持 opencode 调研

> 调研对象：opencode 能否接入 wren 的两行 statusline。
> 结论基于本机 opencode 1.18.33（`opencode-ai`，npm latest）+ 官方 v2（`@opencode/cli` 2.0.x）文档/类型定义 + tmux 沙箱实测。
> 调研日期：本机 1.18.33 / @opencode/plugin 2.0.19。

## 1. 结论

**可以，v1 已落地**（`wren-oc.tsx` + `wren-oc.ts`，安装器 `wren install oc|opencode`，测试 T86-T101）。

形态与 cc / pi / qc 完全不同：

| | cc / qc | pi | opencode |
|---|---|---|---|
| 接入方式 | 宿主调外部命令，stdin JSON → stdout 文本 | 宿主加载 TS 扩展，进程内渲染 | 宿主加载 **TUI 插件模块**，进程内 JSX 渲染 |
| 配置落点 | `settings.json` 的 `statusLine.command` | `$PI_EXT_DIR/*.ts` 自动加载 | `tui.json(c)` 的 `plugin` 数组（v2 改 `cli.json`） |
| 输出格式 | 终端转义码字符串 | pi-tui 组件 | OpenTUI / SolidJS 组件 |
| 复用现有 payload | `wren-cc.py` 的逻辑可搬，协议不可用 | 逻辑可搬，API 不可用 | 两者都不可用，**需新 payload** |

即：**不能把 `wren-cc.py` 直接接上 opencode**（它没有 statusline 命令协议，也没有 `statusLine` 配置键），
要新增第 4 份 payload（如 `wren-oc.tsx`），把 wren 的取数 + 折叠 + 色板逻辑重写到 opencode 的 TUI 插件 API 上。

## 2. 两代 opencode（同一命令名，两套 API）

opencode 1.x 与 2.x 并不同源共存：v2 用同一 `opencode` 命令，V1 插件在 V2 不运行（官方 migrate-v1 文档明确列出三项破坏性变更之一就是插件 API）。

| 维度 | v1（1.18.33，本机） | v2（2.0.x，`@opencode/cli`） |
|---|---|---|
| TUI 配置 | `tui.json` / `tui.jsonc`（全局 `~/.config/opencode/`，项目 `.opencode/`，分层合并） | 单个全局 `cli.json`（自动迁移） |
| 插件类型包 | `@opencode-ai/plugin/tui` | `@opencode/plugin` |
| 模块形态 | `export default { id, tui(api, options, meta) }` | `Plugin.define({ id, setup(context) })` |
| 注册 slot | `api.slots.register({ slots: { app_bottom() {...} } })`（snake_case） | `context.ui.slot({ append: "prompt.footer.status", render })`（点号路径） |
| slot 清单 | `app` `app_bottom` `home_logo` `home_prompt` `home_prompt_right` `session_prompt` `session_prompt_right` `home_bottom` `home_footer` `sidebar_title` `sidebar_content` `sidebar_footer` | `app` `home.footer` `home.footer.status` `prompt.footer` `prompt.footer.status` `prompt.footer.file` `session.composer.top` `session.panel` `sidebar.content` `sidebar.footer` |
| 状态栏插入点 | **无**，最接近的是 `app_bottom`（活动路由下方、整宽、可多行） | `prompt.footer.status`（追加进内置 footer 行，位于健康指示之后、版本号之前）——真正的 statusline 位 |
| 主题 / 颜色 | `api.theme.current.*`（RGBA 语义色），`api.renderer` 拿宽度 | `context.theme`（语义 token）、`context.themeMode`、`context.renderer` |
| 持久化 / 开关 | `api.kv`、`tui.json` 的 `plugin_enabled`（按插件 id） | `context.storage.store/memory` |

**兼容写法有先例**：本机 `~/.config/opencode/herdr-tui-session.js` 就是一个 `{ id, setup, tui }` 的三键对象，
注释写明「V1 和 V2 暴露不同的 SDK 包，但两个 loader 各取自己的生命周期入口」。wren-oc 可照此做单文件双世代兼容。

## 3. wren 各字段在 opencode 的数据来源

v1 侧全部走 `api.state`（`packages/tui/src/plugin/adapters.tsx` 的 `stateApi()`，底层是 Solid `createStore`，
**在 slot 渲染函数里读即为响应式**，消息更新会自动重渲染）：

| wren 字段 | v1 数据源 | v2 数据源 |
|---|---|---|
| cwd | `api.state.path.directory` | `context.data.location` |
| 分支 / ahead-behind | `api.state.vcs.branch`（`default_branch` 也有）；ahead-behind 需自己跑 git | `context.data.location.vcs.info()` |
| ↑in ↓out | `api.state.session.get(id).tokens`（会话聚合）或 `session.messages(id)` 逐条累加 | `context.data.session.cost/list/message` |
| R / cacheR / CH | 同上 `tokens.cache.read/write`；`CH = read/(input+read+write)` 口径一致 | 同上 |
| CP（压缩次数） | 需自行从消息里数 `summary`/压缩标记（无现成计数） | 同上 |
| ctx% | `tokens`（含 output）÷ `api.state.provider[..].models[..].limit.context` | `context.data.location.model` |
| 模型 / 思考等级 | `AssistantMessage.modelID`、`variant`、`Session.model` | 同上 |
| 时长 | `session.time.created` → now（或 message 聚合） | 同上 |
| TTFT | 推导：`min(part.time.start) − assistant.time.created`（`api.part(messageID)`）；真实库样本 1789438425235 → 1789438428246 = 3011ms | 同构 |
| +增 ~删 ✱改 | `api.state.session.diff(id)`（file/additions/deletions） | `context.data.session` diff |
| 状态 | `api.state.session.status(id)`：`idle` / `retry` / `busy` | `context.data.session.status` |

真实库（`~/.local/share/opencode/opencode.db` 只读样本）确认字段存在：
`tokens:{total,input,output,reasoning,cache:{read,write}}`、`cost`、`modelID`、`variant?`、`time:{created,completed}`，
part 的 `reasoning`/`text` 带 `time:{start,end}`。

## 4. 本机实测（沙箱，未触碰真实配置）

手段：`OPENCODE_CONFIG_DIR=/tmp/wren-oc-*/config` 隔离配置，tmux 起 TUI，`capture-pane` 读屏。
插件只 import type（编译期擦除），因此**无需 npm 依赖**。

| 用例 | 结果 |
|---|---|
| `tui.json` 里 `"plugin": ["./plugins/wren-smoke.tsx"]` | ✅ 插件加载，`app_bottom` 渲染出一行 |
| 同上改用 `tui.jsonc`（带注释） | ✅ 同样生效（JSONC 可解析） |
| `tui.json` 与 `tui.jsonc` 同时存在、只后者带 plugin | ✅ jsonc 的插件仍加载（分层合并，非互斥） |
| slot 里 `<box flexDirection="column">` 两行 | ✅ 两行都渲染（`app_bottom` 占据 2 行布局） |
| slot 里读 `api.state.vcs.branch` / `path.directory` / `app.version` | ✅ 可读 |
| `opencode plugin ./plugins/x.tsx` 装本地文件插件 | ❌ `Manifest read failed`（按包处理，找 `package.json`）；且会在配置目录生成 package.json + node_modules |

屏幕形态（1.18.33，home 路由）：

```
  Build · Claude Opus · high             ← 内置 prompt footer：agent · model · variant
  tab agents  ctrl+p commands             ← 内置快捷键行
  /private/tmp/wren-oc/proj   1.18.33      ← 内置路径 + 版本
WREN-SMOKE line1 …                        ← 注入的 app_bottom（第 1 行）
WREN-SMOKE line2 …                        ← 注入的 app_bottom（第 2 行）
```

## 5. 落地方案要点（若做）

1. **payload**：新增 `zoo-scripts/wren/wren-oc.tsx`。取数 / 折叠 / Dracula 色板可参考 `wren-pi.ts` 的纯函数部分拆成侧车模块，渲染层重写为 Solid JSX。
2. **安装目标**：payload 副本放 `$OPENCODE_CONFIG_DIR/plugins/`（v1）或 v2 约定目录；`tui.json(c)` 的 `plugin` 数组加一条相对路径。
3. **配置补丁**：必须 JSONC 安全（保留注释）。`opencode plugin` CLI 不能装本地文件，只能自己改；
   官方自身写配置用 `tui.json` + jsonc-parser 定向编辑，可作为对齐目标。存在 `tui.json` 与 `tui.jsonc` 两份时要选已有的那份或同时提示。
4. **卸载**：无 CLI 支持（官方明确「没有 uninstall / list / update 外部插件命令」），要从 `plugin` 数组摘掉条目 + 删 payload，参考 cc/qc 侧「只删自己的东西」策略。
5. **不再需要 python3**（oc 侧只需文本级 JSONC 编辑，或复用 python 但不用）。退出码沿用 0/1/2/3；新增 target `oc`（别名 `opencode`），三宿主 → 四宿主，`all` 语义需同步更新用法文本。
6. **版本分叉**：v1 与 v2 配置文件名、slot 名、模块形态都不同。两条路：(a) 单文件 `{id, tui, setup}` 双世代兼容（herdr 先例）；(b) 只保 v1，v2 到来时再补。

## 6. 限制与风险

| 项 | 说明 |
|---|---|
| 常驻占行 | `app_bottom` 是布局流内区块，两行 = 每次少 2 行 transcript。与 cc/pi 的 statusline 同级（那两者也占 2 行），不是额外代价；v2 的 `prompt.footer.status` 可以做到不占额外行 |
| v1 无 statusline 位 | 只能挑 `app_bottom`（全局）或 `home_footer`（仅 home，single_winner 会顶掉内置 footer） |
| 信息重复 | 内置 prompt footer 已显示 agent · model · variant 与 ctx 占用；wren 再显示会重复。这是刻意的（目标是四侧逐字同构），要避只能后续加开关 |
| 折叠宽度 | 无 `COLUMNS` 概念，宽度取 `api.renderer.width`（实测可用），核心自己逐段截断，宿主 `truncate` 仅兜底 |
| 主题冲突 | wren 假定深色底 + Dracula 硬编码；oc 侧直接给 RGB 十六进制由宿主决定降档，不跟主题 |
| v2 未覆盖 | 本次不实现 v2（用户拍板）。v2 的 slot 名/模块形态/配置文件都不同，见第 2 节 |
| 提交产物 | 卸载后可能留下空的 `"plugin": []` 键（宿主视为无插件）；这是“宁可多留一个空数组、也不删用户配置结构”的取舍 |

### 实施时踩到的两个坑（写在这里备查）

1. **slot 渲染里抛异常会把整个 TUI 打到崩溃页**（1.18.33 实测：`api.part` 误写成顶层方法那次）。
   所以取数与排版必须整体 try/catch，失败降级成一行裸 cwd + 徽标。
2. **Solid 的组件体只执行一次**：`const rows = lines()` 写在组件体会导致信号/ store 变化后不重渲染
   （表现为 git 段永远不变）。必须把调用放进 JSX 表达式（`{lines().map(...)}`），它才会被包进响应式 effect。

另外：`<span fg>` 在 1.18.33 的 slot 里不生效（文本渲染了、颜色没变），改用
`<box flexDirection="row">` 内一串自带 `fg` 的 `<text>`，逐段着色正常。

## 7. 落地产物（已实现）

| 文件 | 角色 |
|---|---|
| `zoo-scripts/wren/wren-oc.tsx` | TUI 插件适配层：`{ id: "wren.oc", tui }`，注册 `app_bottom` slot；Solid signal + 15s 轮询 git/CP；全部 try/catch 兜底 |
| `zoo-scripts/wren/wren-oc.ts` | 排版纯函数（段列表、折叠梯子、数值口径），无宿主依赖，node 可直接跑 |
| `zoo-scripts/wren/wren` | 新增 target `oc`（别名 `opencode`）：拷 payload、JSONC 定向编辑 `tui.json(c)` 的 `plugin` 数组、卸载只拂自己的 |
| `.test_scripts/wren-test.sh` | T86-T95 安装器（幂等/JSONC 保真/jsonc 接管/只删自己/预检/别名/all 四侧）+ T96-T100 核心渲染（两行/满配/梯子/CJK/TTFT 分档）+ T101 真机 TUI e2e |

实时渲染结果（本机 1.18.33，本仓库真会话）：

```
~/Code/ai_code/cli-zoo | main ↑0↓0 +3 | wC:t1:p1 | oc · 15m
↑17K ↓7 | R20K CH54.46% | 7.19%/262K TTFT 4.3s | claude-opus-5 · high
```

## 8. 证据来源

- 本机二进制 `~/.nvm/.../node_modules/opencode-ai/bin/opencode.exe`（1.18.33）：slot 名、`XDG_CONFIG_HOME` / `OPENCODE_CONFIG_DIR` / `~/.config/opencode/tui.json` 字符串
- `~/.config/opencode/node_modules/@opencode-ai/plugin/dist/tui.d.ts`（1.17.15）：`TuiHostSlotMap`、`TuiPluginApi`、`TuiSlotPlugin`
- `~/.local/share/opencode/opencode.db`（只读）：message/part 真实字段
- GitHub tag `v1.18.33`：`packages/tui/src/plugin/adapters.tsx`（`stateApi()` = Solid store）、`packages/tui/src/context/sync.tsx`（`createStore`）、`packages/opencode/src/plugin/tui/runtime.ts`（`slots.register` 实现）、`packages/opencode/specs/tui-plugins.md`（slot 清单与模式）
- 官方 v2 文档：`opencode.ai/v2/docs/cli/config`（`cli.json`、`mini.footer`）、`/v2/docs/build/plugins/cli`（slot 用法）、`/v2/docs/migrate-v1`（插件 API 破坏性变更）
- npm：`opencode-ai@1.18.33`（latest）、`@opencode/cli` 2.0.x、`@opencode/plugin@2.0.19`（`dist/tui/context.d.ts` 的 `SlotMap`）
- 相关 issue：#23539（状态栏 widget）、#25875（可定制 status line）——均仍为 feature request，说明官方至今没有 cc 式 statusline 命令
- 本机 `~/.config/opencode/herdr-tui-session.js`：v1/v2 双世代模块写法的现成先例
