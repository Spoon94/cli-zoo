# 测试

每个工具配一套 shell 测试，跑在临时沙箱里，结果写入 `.test_res/<tool>-test-res.md`。

| 工具 | 用例数 | 运行 |
|------|--------|------|
| `otter` | 25 | `bash .test_scripts/otter-test.sh` |
| `wren` | 104 | `bash .test_scripts/wren-test.sh` |

输出格式：

```
PASS T01 ...
...
Total: 104  Pass: 104  Fail: 0  Skip: 0
```

任一 FAIL → 退出码 1，结果文件 `.test_res/<tool>-test-res.md` 会被覆盖写。

## wren 测试说明

全程在 `mktemp -d` 沙箱里作业：`PREFIX` / `PI_EXT_DIR` / `CLAUDE_SETTINGS` / `QODER_CONFIG_DIR` / `QODER_SETTINGS` /
`OPENCODE_CONFIG_DIR` / `OPENCODE_TUI_CONFIG` 七个变量把安装目标全部改道，真实的 `/usr/local/bin`、`~/.pi`、`~/.claude`、
`~/.qoder`、`~/.config/opencode` 一个都不碰。

- **pi 侧（T27-T32、T38、T40、T43、T46、T69-T73、T77-T78、T80）**：stub 掉 `@earendil-works/pi-tui`，用 fixture 驱动 `wren-pi.ts` 的 footer 真实渲染。
- **oc 侧（T96-T100）**：`wren-oc.ts` 是纯函数（排版核心），node 直接 import 跑，用 fixture 断言两行/梯子/色档。
  渲染适配层（`wren-oc.tsx`）依赖宿主 JSX 运行时，不在单测范围。
- **oc 真机（T101）**：在沙箱配置下真起 opencode TUI（tmux + 读屏），锁 slot 名/模块形态/`api.state` 形状。缺 `opencode` 或 `tmux` 时 SKIP，耗时 ~25s。
- 缺 node（或 node 不支持直接执行 `.ts`）时，上述 node 类用例整体 SKIP。
