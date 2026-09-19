# 测试

每个工具配一套 shell 测试，跑在临时沙箱里，结果写入 `.test_res/<tool>-test-res.md`。

| 工具 | 用例数 | 运行 |
|------|--------|------|
| `otter` | 25 | `bash .test_scripts/otter-test.sh` |
| `wren` | 67 | `bash .test_scripts/wren-test.sh` |

输出格式：

```
PASS T01 ...
...
Total: 46  Pass: 46  Fail: 0  Skip: 0
```

任一 FAIL → 退出码 1，结果文件 `.test_res/<tool>-test-res.md` 会被覆盖写。

## wren 测试说明

全程在 `mktemp -d` 沙箱里作业：`PREFIX` / `PI_EXT_DIR` / `CLAUDE_SETTINGS` 三个变量把安装目标全部改道，真实的 `/usr/local/bin`、`~/.pi`、`~/.claude` 一个都不碰。T27-T32、T38、T40、T43、T46 还会 stub 掉 `@earendil-works/pi-tui`，用 fixture 驱动 `wren.ts` 的 footer 真实渲染；缺 node（或 node 不支持直接执行 `.ts`）时这几条整体 SKIP。
