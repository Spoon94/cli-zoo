[中文](./INSTALL.zh-CN.md) | [English](./INSTALL.md)

# INSTALL

This file is for automated agents. Human users, see [README.md](./README.md).

## Prerequisites

| Dependency | Used by | Check |
|------|--------|------|
| bash | install scripts, tests | `command -v bash` |
| python3 | wren's python payloads (`wren-cc.py` / `wren-qc.py` / `wren-agy.py`), the targeted JSONC editing of `tui.json(c)` on the opencode side, and the JSON assertions in the wren tests | `command -v python3` |
| claude | prerequisite check for otter tests T06+ (the otter tests exit 2 without it) | `command -v claude` |
| git | the lazygit window in otter's layout, and wren's statusline git segment (the oc side runs `git status` itself) | `command -v git` |
| node ≥ 22.18 (or 23.6) | only the 23 wren test cases that depend on node (T27-T32/T38/T40/T43/T46/T69-T73/T77-T78/T80/T96-T100, T105, T106; versions that execute `.ts` directly without a flag; 22.6-22.17 needs an explicit flag, which the probe does not add, so they SKIP); wren itself does not need it | `node -v` (the tests SKIP when missing, which does not count as FAIL) |
| opencode | only wren test T101 (real-device TUI screen reading; the oc payload runs on opencode's bundled bun and does not need an external node) | `command -v opencode` |
| tmux | all otter features; wren test T101 (real-device e2e) | `command -v tmux` |

A missing node only makes those 23 wren test cases SKIP; a missing opencode or tmux only makes T101 SKIP; neither counts as FAIL. Without python3, the wren test script itself exits 2,
and `wren install cc` / `wren install qc` / `wren install agy` / `wren install oc` exit 3 (`wren install pi` does not need python3).

## Install

```bash
./cli-zoo-install.sh <tool>          # tool ∈ {otter, wren}
```

- Symlinked to `/usr/local/bin` by default; if it is not writable or you would rather not touch it, use `PREFIX=$HOME/bin ./cli-zoo-install.sh <tool>`.
- Inside the script: the source is `zoo-scripts/<tool>` (wren is a multi-file tool, so the symlink points at the entry script inside the directory, `zoo-scripts/wren/wren`); a conflicting target is removed with `rm -f` before `ln -s`.
- On insufficient permission, retry with `sudo PREFIX=$PREFIX ./cli-zoo-install.sh <tool>` as the script prompts.

After installing the wren binary there is one more wiring step (it installs file copies and is idempotent):

```bash
wren install            # install to all five hosts; or install per side with wren install cc / pi / qc / agy / oc (aliases claude / qoder / antigravity / opencode)
```

This step writes the `statusLine` key of `$CLAUDE_SETTINGS` (only that key; it is backed up to `<settings>.wren-bak` on first change) and copies the payload to **`wren-cc` in the same directory as settings.json** and to `$PI_EXT_DIR/wren-pi.ts`. By default they land in `~/.claude/wren-cc` and `~/.pi/agent/extensions/wren-pi.ts`; redirect them with `CLAUDE_SETTINGS` / `PI_EXT_DIR` (changing the settings path changes where the payload lands). The qc side works the same way: the payload is copied to `$QODER_CONFIG_DIR/wren-qc.py` (default `~/.qoder`; redirect with `QODER_CONFIG_DIR` / `QODER_SETTINGS`), and `statusLine.command` is written as that absolute path.

The agy side: the payload is copied to `$AGY_CONFIG_DIR/wren-agy.py` (default `~/.gemini/antigravity-cli/`; redirect with `AGY_CONFIG_DIR` / `AGY_SETTINGS`;
note the settings live in `~/.gemini/antigravity-cli/settings.json`, **not** `~/.gemini/settings.json`), and `statusLine` is written into
`$AGY_SETTINGS` (by default it bypasses the pyenv python3 shim; the command is a "prefer the fast interpreter, fall back if broken" fragment; `WREN_AGY_PYTHON=off` uses the bare absolute path,
see "Startup cost and shims" in `zoo-scripts/wren/README.md` for details). agy has an enable switch, and `wren install agy` makes sure `statusLine.enabled = true`
(a leftover `false` makes the install a no-op); the user's existing sub-keys such as `padding` / `stack_with_default` are preserved. Uninstall removes only the
`type` / `command` written by wren plus the default-equivalent `enabled:true`; `enabled:false` (turned off by the user) is preserved.

The oc side has a different shape (opencode has no statusline command protocol): the two payloads (`wren-oc.tsx` + `wren-oc.ts`) are copied into **`<same directory as the tui config>/plugins/`**,
and one entry `./plugins/wren-oc.tsx` is added to the `plugin` array of `tui.json` / `tui.jsonc`. By default they land in `~/.config/opencode`;
redirect with `OPENCODE_CONFIG_DIR` (the official redirect variable) or `OPENCODE_TUI_CONFIG` (points directly at the config file; the payload lands in the same directory).
The write is a targeted text-level edit: comments and layout are preserved, a multi-line array gets a line inserted before the first element, an inline array gets the entry inserted after `[`, so uninstalling restores it byte for byte;
when `OPENCODE_TUI_CONFIG` is not set explicitly, an existing `tui.jsonc` takes precedence (if neither exists, a new `tui.json` is created).

## Verify

```bash
otter -h                                # otter installed
wren -h                                 # wren binary installed
bash .test_scripts/otter-test.sh        # expect: Total: 25  Pass: 25
bash .test_scripts/wren-test.sh         # expect: Total: 190  Pass: 189  Fail: 0  Skip: 1 (23 SKIP without node, T101 SKIP without opencode/tmux, T183 SKIP without a system python < 3.10)
```

With wren installed you can feed it a statusline JSON as a smoke test:

```bash
printf '{"cwd":"/tmp","model":{"display_name":"m"}}' | NO_COLOR=1 ~/.claude/wren-cc
# expect: two lines of output, line 1 ends with "| cc", exit 0
printf '{"cwd":"/tmp","model":{"display_name":"m"}}' | NO_COLOR=1 python3 zoo-scripts/wren/wren-qc.py
# expect: two lines of output, line 1 ends with "| qc", exit 0
printf '{"cwd":"/tmp","workspace":{"current_dir":"/tmp"},"model":{"display_name":"m"}}' | NO_COLOR=1 python3 zoo-scripts/wren/wren-agy.py
# expect: two lines of output, line 1 ends with "| agy", exit 0
```

The oc side has no stdin/stdout smoke test (it is a TUI plugin): verify the wiring with an isolated config, or just look at the line below the prompt box:

```bash
tmp="$(mktemp -d)"; OPENCODE_CONFIG_DIR="$tmp" OPENCODE_TUI_CONFIG="$tmp/tui.json" wren install oc \
  && grep -q 'wren-oc.tsx' "$tmp/tui.json" && ls "$tmp/plugins"
# expect: prints wren-oc.tsx and wren-oc.ts, exit 0; then start opencode and the left half of the line below the prompt box should show two lines (line 1 contains "| oc")
OPENCODE_CONFIG_DIR="$tmp" OPENCODE_TUI_CONFIG="$tmp/tui.json" wren uninstall oc   # remove after verifying
```

The oc layout core can be run directly with node without starting the TUI:

```bash
P=zoo-scripts/wren/wren-oc.ts node -e 'import(process.env.P).then(m=>console.log(m.buildLines({width:120,cwd:"/tmp",home:"/home/u",branch:null,head:"",ab:"",added:0,modified:0,deleted:0,herdr:"",durationMs:null,inputTokens:0,outputTokens:0,cacheRead:0,cacheWrite:0,compactions:0,ctxPercent:null,ctxWindow:0,model:"m",thinking:"",ttftMs:null}).map(l=>l.map(s=>s.text).join("")).join("\n")))'
# expect: two lines, line 1 "/tmp | oc", line 2 "↑0 ↓0 | R0 | m"
```

## Uninstall

```bash
wren uninstall                          # remove the wiring from the five hosts first (idempotent)
./cli-zoo-uninstall.sh wren             # then remove the wren binary
./cli-zoo-uninstall.sh otter            # otter uninstalls directly
```

The order matters: once `cli-zoo-uninstall.sh wren` removes the `$PREFIX/wren` symlink, `wren uninstall` has no entry point, leaving behind `~/.claude/wren-cc`, the `statusLine` in three settings files, `~/.pi/agent/extensions/wren-pi.ts`, `~/.qoder/wren-qc.py`, `~/.gemini/antigravity-cli/wren-agy.py` and the `statusLine` in its `settings.json`, `~/.config/opencode/plugins/wren-oc.{tsx,core.ts}` and the `plugin` entry in `tui.json(c)`. uninstall removes only the files wren installed itself; targets whose contents were modified are `left alone`.
Uninstalling the oc side may leave an empty `"plugin": []` (the host treats it as no plugins). A deliberate trade-off: leave an empty array rather than delete a key from the user's config.

## Exit codes (wren)

`0` success / `1` write failure / `2` bad arguments / `3` missing dependency (python3 or payload).
