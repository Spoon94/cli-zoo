# wren 测试结果
执行时间：2026-10-03 16:45:59

| ID | 状态 | 备注 |
|----|------|------|
| T01 | PASS | no args -> exit 2 + usage |
| T02 | PASS | -h prints usage (exit 0) |
| T03 | PASS | unknown subcommand -> exit 2 |
| T04 | PASS | install copies wren-cc.py to $CLAUDE_CONFIG_DIR/wren-cc (regular, exec, byte-identical) |
| T05 | PASS | install copies wren.ts to $PI_EXT_DIR/wren-pi.ts (byte-identical) |
| T06 | PASS | statusLine.command=绝对路径（$CLAUDE/wren-cc） |
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
| T38 | PASS | detached/rename/conflict: sides agree (det=[✱1\|✱1] ren=[main ✱2] conf=[main ✱1]) |
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
| T44 | PASS | CJK path display width 61 <= 80 |
| T45 | PASS | CJK extreme line fits: nc=70 tc=70, color-independent folding |
| T46 | PASS | pi CJK extreme line width 75 <= 80 |
| T47 | PASS | qc minimal payload: 2 lines, qc badge, no invented segments |
| T48 | PASS | qc ↑in/↓out from transcript sums, not native per-request field |
| T49 | PASS | qc ctx%: native used_percentage first, self-computed fallback |
| T50 | PASS | qc CH = cache_read/input_tokens (qoder input already includes cache) |
| T51 | PASS | qc legacy fallback: CC formula when input < cache_read |
| T52 | PASS | qc cache_creation object form summed (5m+1h) in fallback |
| T53 | PASS | qc duration: session age from transcript on line1, cost field not read |
| T54 | PASS | qc thinking from runtime-config record; absent -> segment hidden |
| T55 | PASS | qc Dracula: truecolor/256/NO_COLOR same table as cc/pi |
| T56 | PASS | qc invalid JSON -> degrade to 2 lines, exit 0 |
| T57 | PASS | qc WREN_DEBUG_DUMP captures raw stdin bytes |
| T58 | PASS | qc ctx fallback chain: postTokens after compact_boundary; CP counted |
| T59 | PASS | qc line1 identical to cc after badge strip, short+long branch (/var/…/box43/r59 \| main +1 ✱1 / /var/…/box43/r59 \| feat/ver…-folding-parity +1 ✱1) |
| T60 | PASS | install qc copies payload + writes absolute statusLine |
| T61 | PASS | install qc only touches qc side |
| T62 | PASS | qc install preserves keys/order and backs up original bytes |
| T63 | PASS | uninstall qc removes payload/statusLine/sidecars, keeps rest |
| T64 | PASS | qc uninstall leaves a foreign statusLine alone (payload still ours, removed) |
| T65 | PASS | QODER_CONFIG_DIR honored; default dir untouched |
| T66 | PASS | install qoder is an alias of qc |
| T67 | PASS | invalid qoder settings -> exit 1 before any install (pre-check gate) |
| T68 | PASS | uncreatable qoder parent -> exit 1, zero side effects |
| T69 | PASS | pi TTFT from event stream (3 tiers + first-update-only) |
| T70 | PASS | duration in line1 badge slot, absent from line2 |
| T71 | PASS | no dangling separator when TTFT absent |
| T72 | PASS | line1 ladder drops duration first (43 <= 55, badge kept) |
| T73 | PASS | line2 ladder drop order TTFT -> CH -> CP; core segments never dropped |
| T74 | PASS | install pi migrates legacy wren.ts -> wren-pi.ts |
| T75 | PASS | qc TTFT keeps previous turn value during wait; hidden when never paired |
| T76 | PASS | qc TTFT re-pairs after wait via retained turn_first_ts; first piece wins |
| T77 | PASS | inflight turn keeps last completed TTFT (no flash / no early value) |
| T78 | PASS | first chunk atomically replaces TTFT (TTFT 12s, old value gone) |
| T79 | PASS | qc line2 ladder color-agnostic; TTFT survives truecolor at width 80 |
| T80 | PASS | 3-host line2 ladder identical & ordered (w90/81/80/70/65/60: TCP TCP -CP -CP --P --P) |
| T81 | PASS | install cc migrates legacy $PREFIX/wren-cc, writes absolute command |
| T82 | PASS | foreign $PREFIX/wren-cc left alone |
| T83 | PASS | cc/qc TTFT 4-tier colour: 18 probes (raw-ms + rounded boundaries), text+code identical |
| T84 | PASS | pi TTFT 4-tier colour + display identical to cc/qc, same probe table |
| T85 | PASS | TTFT boundary probes: display-synced tiers, +/-1ms bands same tier, 3-side identical |
| T86 | PASS | install oc: payloads copied + plugin spec written to tui.json |
| T87 | PASS | install oc idempotent: single spec entry, payload refreshed |
| T88 | PASS | JSONC comments/keys/other plugins preserved; uninstall restores bytes |
| T89 | PASS | tui.jsonc taken over when tui.json is absent (no new file) |
| T90 | PASS | uninstall oc removes only our spec/payloads; second run idempotent |
| T91 | PASS | modified oc payload left alone; spec still removed from tui.json |
| T92 | PASS | unwritable opencode config dir -> exit 1, zero side effects |
| T93 | PASS | malformed tui.json -> exit 1, no payload installed, file untouched |
| T94 | PASS | install opencode aliases oc; unknown target -> exit 2 |
| T95 | PASS | install all wires 4 hosts; uninstall all unwires them |
| T96 | PASS | oc minimal payload: 2 lines, oc badge, no invented segments |
| T97 | PASS | oc full payload matches wren layout; 999_500 -> 1.0M |
| T98 | PASS | oc line2 ladder: TTFT(68) -> CH(64) -> CP(55); cores never dropped |
| T99 | PASS | oc CJK extreme: line1=71 line2=58 both <= 80 |
| T100 | PASS | oc TTFT tiers: display-synced 4-tier colour, +/-1ms bands same tier |
| T101 | SKIP | opencode or tmux not available |
| T102 | PASS | CRLF tui.json survives install+uninstall byte-for-byte (6 CR kept) |
| T103 | PASS | non-array plugin value -> exit 1 before payload install, file untouched |
| T104 | PASS | install oc migrates legacy wren-oc-core.ts -> wren-oc.ts |
| T105 | PASS | empty cwd + empty model: no leading/trailing separator, no identity group |
| T106 | PASS | narrow budget swaps ctx% to short form before dropping CH/TTFT |
| T107 | PASS | cc narrow tier: ◈/▂▄▆█/⏱ icons, quartile×color orthogonal, TTFT->CH drop |
| T108 | PASS | pi narrow tier: short-form/◈/▂▄▆█/⏱, CP→TTFT→CH drop, 56 stays wide, quartile matrix |
| T109 | PASS | qc narrow tier mirrors cc: short in/out, ◈/▂▄▆█/⏱, CP->TTFT->CH order, wide untouched |
| T116 | PASS | pi herdr env flattened: newline-injection stays 2 lines, empty segment dropped |
| T117 | PASS | pi narrow quartile boundaries 25/50/75 + banker's rounding (.5->even), cc parity at 74.5% |
| T118 | PASS | pi narrow budget floor max(4,W-5): W=20/10/6 -> exact truncated forms |
| T119 | PASS | pi badge two-pass lock: long herdr yields, badge keeps prefix slot at floor width |
| T120 | FAIL | a(n=3)=[~/Code/cli-zoo \| pi · 0m~↑743K ↓117K \| R19.6M CH96.34% CP1 \| ?/200K TTFT 12s \| evil~model · highx] b=[↑743K ↓117K \| R19.6M CH96.34% CP1 \| ?/200K TTFT 12s \|  · high] c=[ · high] d=[↑743K ↓117K \| R19.6M CH96.34% CP1 \| ?/200K TTFT 12s \| claude-opus-5] |
| T110 | PASS | bare-relative config env keeps payload next to config (cc/oc/qc) |
| T111 | PASS | plugin-array scan matches top-level strings only; uninstall leaves object intact |
| T112 | PASS | symlinked configs resolved, links preserved (incl. dangling) |
| T113 | PASS | uninstall strips only wren-written keys; user subkeys survive |
| T114 | PASS | oc oneLine flattens herdr envs; charset matches cc one_line |
| T115 | PASS | session_prompt fallback passes through props (whitelist + ref) |
| T121 | PASS | native stdin fields sanitized: NaN/str/Infinity fall back, negative pct not rendered |
| T122 | PASS | newline injection in display_name/effort flattened; exactly 2 lines |
| T123 | PASS | U+2028 inside record string does not lose the record (split by \n only) |
| T124 | PASS | extreme narrow (20/10/6 cols): 2 lines, qc badge, width within COLUMNS |
| T125 | PASS | quartile boundaries 25/50/75 pinned on both native and postTokens sources |

汇总：Total 125 / Pass 123 / Fail 1 / Skip 1
