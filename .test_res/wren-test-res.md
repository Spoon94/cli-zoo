# wren 测试结果
执行时间：2026-09-19 17:09:33

| ID | 状态 | 备注 |
|----|------|------|
| T01 | PASS | no args -> exit 2 + usage |
| T02 | PASS | -h prints usage (exit 0) |
| T03 | PASS | unknown subcommand -> exit 2 |
| T04 | PASS | install copies wren.py to $PREFIX/wren-cc (regular, exec, byte-identical) |
| T05 | PASS | install copies wren.ts to $PI_EXT_DIR/wren.ts (byte-identical) |
| T06 | PASS | statusLine.command=wren-cc type=command |
| T07 | PASS | other keys and key order preserved |
| T08 | PASS | backup holds pre-install bytes |
| T09 | PASS | repeat install keeps the original backup |
| T10 | PASS | missing settings.json is created |
| T11 | PASS | invalid JSON -> exit 1, no side effects |
| T12 | PASS | non-object JSON -> exit 1, no side effects |
| T13 | PASS | installed wren-cc renders 2 lines |
| T14 | PASS | warns when legacy odo.ts is already loaded by pi |
| T15 | PASS | uninstall removes both installed copies |
| T16 | PASS | uninstall drops statusLine, keeps the rest |
| T17 | PASS | uninstall leaves a foreign statusLine alone |
| T18 | PASS | uninstall is idempotent |
| T19 | PASS | uninstall does not remove a foreign file |
| T20 | PASS | cli-zoo-install.sh wren links the entry script |
| T21 | PASS | entry via symlink still finds payloads |
| T22 | PASS | missing python3 -> exit 3 |
| T23 | PASS | missing payload -> exit 3 |
| T24 | PASS | unwritable settings dir -> exit 1 before any side effect, no traceback |
| T25 | PASS | quiet when identical, warns when overwriting a modified copy |
| T26 | PASS | uninstall cleans its own .wren-bak / .wren-tmp |
| T27 | PASS | pi footer renders 2 lines |
| T28 | PASS | pi fmt: 999_500 -> 1.0M, no 1000K |
| T29 | PASS | pi ctx% from getContextUsage; null -> ? |
| T30 | PASS | pi cwd collapses $HOME (not hardcoded /Users) |
| T32 | PASS | git segment identical on both sides (main ↑1↓0 +1 ~1 ✱1) |
| T38 | PASS | detached/rename/conflict: sides agree (det=[\|] ren=[main ✱2] conf=[main ✱1]) |
| T31 | PASS | pi CH uses 2 decimals |
| T33 | PASS | install cc only touches CC side |
| T34 | PASS | install pi only touches pi side |
| T35 | PASS | install claude is an alias of cc |
| T37 | PASS | CLAUDE_CONFIG_DIR honored, ~/.claude untouched |
| T36 | PASS | unknown target -> exit 2, no side effects |
| T39 | PASS | cc Dracula: truecolor/256/NO_COLOR three modes |
| T40 | PASS | pi Dracula: getColorMode truecolor/256 + NO_COLOR override |
| T41 | PASS | CH survives compaction (old value, pi-aligned) |
| T42 | PASS | cc folding: path=…/with-a-long-name-that-will-overflow branch=feature/…esting-overflow |
| T43 | PASS | pi branch folding (feature/…esting-overflow) |

汇总：Total 43 / Pass 43 / Fail 0 / Skip 0
