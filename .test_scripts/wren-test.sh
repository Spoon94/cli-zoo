#!/usr/bin/env bash
# wren-test.sh - 自动运行 .test_task/wren-test.md 中的 104 个用例。
#
# 用法: bash .test_scripts/wren-test.sh
# 写出: .test_res/wren-test-res.md
#
# 全程在 mktemp -d 里作业：PREFIX / PI_EXT_DIR / CLAUDE_SETTINGS / QODER_CONFIG_DIR /
# QODER_SETTINGS / OPENCODE_CONFIG_DIR / OPENCODE_TUI_CONFIG 七个变量把安装目标全部改道，
# 不会碰到真实的 /usr/local/bin、~/.pi、~/.claude、~/.qoder、~/.config/opencode。

set -u

# 输出可预测：清掉 herdr 定位变量，否则两侧行1 都会多出 " | ws:tab:pane"，
# 断言与 git 段提取都会被带偏
unset HERDR_WORKSPACE_ID HERDR_TAB_ID HERDR_PANE_ID 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WREN="$REPO_ROOT/zoo-scripts/wren/wren"
CC_PAYLOAD="$REPO_ROOT/zoo-scripts/wren/wren-cc.py"
PI_PAYLOAD="$REPO_ROOT/zoo-scripts/wren/wren-pi.ts"
QC_PAYLOAD="$REPO_ROOT/zoo-scripts/wren/wren-qc.py"
OC_PAYLOAD="$REPO_ROOT/zoo-scripts/wren/wren-oc.tsx"
OC_CORE_PAYLOAD="$REPO_ROOT/zoo-scripts/wren/wren-oc.ts"
INSTALL_SH="$REPO_ROOT/cli-zoo-install.sh"
UNINSTALL_SH="$REPO_ROOT/cli-zoo-uninstall.sh"
RES_DIR="$REPO_ROOT/.test_res"
RES_FILE="$RES_DIR/wren-test-res.md"

mkdir -p "$RES_DIR"

# ---------- 结果收集 ----------
declare -a RESULT_ID RESULT_STATUS RESULT_NOTE
TOTAL=0
PASS_N=0
FAIL_N=0
SKIP_N=0

record() {
    local id="$1" status="$2" note="${3:-}"
    RESULT_ID+=("$id")
    RESULT_STATUS+=("$status")
    RESULT_NOTE+=("$note")
    TOTAL=$((TOTAL + 1))
    case "$status" in
        PASS) PASS_N=$((PASS_N + 1)); printf 'PASS %s %s\n' "$id" "$note" ;;
        FAIL) FAIL_N=$((FAIL_N + 1)); printf 'FAIL %s %s\n' "$id" "$note" >&2 ;;
        SKIP) SKIP_N=$((SKIP_N + 1)); printf 'SKIP %s %s\n' "$id" "$note" ;;
    esac
}

pass() { record "$1" PASS "${2:-}"; }
fail() { record "$1" FAIL "${2:-}"; }
skip() { record "$1" SKIP "${2:-}"; }

# ---------- 隔离沙箱 ----------
TMPROOT="$(mktemp -d 2>/dev/null || mktemp -d -t wren)"
cleanup_all() { rm -rf "$TMPROOT"; }
trap cleanup_all EXIT

# 每个场景一个新沙箱：BIN / PIEXT / CLAUDE / QODER 四个目录 + wren 运行环境
new_box() {
    BOX="$TMPROOT/box$((BOX_N += 1))"
    BIN="$BOX/bin"
    PIEXT="$BOX/piext"
    CLAUDE="$BOX/claude"
    SETTINGS="$CLAUDE/settings.json"
    QODER="$BOX/qoder"
    QODER_SETTINGS="$QODER/settings.json"
    OC="$BOX/opencode"
    OCCONF="$OC/tui.json"
    mkdir -p "$BIN" "$PIEXT" "$CLAUDE" "$QODER" "$OC"
}
BOX_N=0
BOX="" BIN="" PIEXT="" CLAUDE="" SETTINGS="" QODER="" QODER_SETTINGS="" OC="" OCCONF=""

# 用沙箱环境调用 wren；输出落 OUT_FILE，退出码进 WREN_EXIT
run_wren() {
    # NO_COLOR=1：旧用例断言的是明文子串，色档统一关掉（带色断言在 T39+ 单独跑）
    env NO_COLOR=1 PREFIX="$BIN" PI_EXT_DIR="$PIEXT" CLAUDE_CONFIG_DIR="$CLAUDE" CLAUDE_SETTINGS="$SETTINGS" \
        QODER_CONFIG_DIR="$QODER" QODER_SETTINGS="$QODER_SETTINGS" \
        OPENCODE_CONFIG_DIR="$OC" OPENCODE_TUI_CONFIG="$OCCONF" \
        "$WREN" "$@" >"$BOX/out.txt" 2>"$BOX/err.txt"
    WREN_EXIT=$?
    WREN_OUT="$(<"$BOX/out.txt")"
    WREN_ERR="$(<"$BOX/err.txt")"
}
WREN_EXIT=0
WREN_OUT=""
WREN_ERR=""

# 行1 尾有 " | cc"/" | pi" 宿主徽标（v6 起），跨实现比对前剥掉
strip_tag() {
    local seg="$1"
    # 行1 尾的时长（v7 起，紧跟在徽标之后）：` · 1h5m` / ` · 16m` / ` · 99h+`
    seg="$(printf '%s' "$seg" | sed -E 's/ · ([0-9]+h[0-9]+m|[0-9]+h\+|[0-9]+m)$//')"
    # 段尾的宿主徽标（v6 起）：无 git/herdr 时整段就是裸徽标，剥完为空
    seg="${seg% | cc}"
    seg="${seg% | pi}"
    seg="${seg% | qc}"
    seg="${seg% | oc}"
    printf '%s' "$seg"
}

json_field() {  # json_field <file> <python-expr on `d`>
    python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
print($2)
" "$1" 2>/dev/null
}

# ---------- 前置依赖 ----------
if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 is required to run this test suite" >&2
    exit 2
fi

for f in "$WREN" "$CC_PAYLOAD" "$PI_PAYLOAD" "$QC_PAYLOAD" "$OC_PAYLOAD" "$OC_CORE_PAYLOAD"; do
    if [[ ! -f "$f" ]]; then
        echo "ERROR: $f not found" >&2
        exit 2
    fi
done
[[ -x "$WREN" ]] || chmod +x "$WREN"

# ============================================================
# T01: 无参数 → exit 2 + usage
# ============================================================
new_box
run_wren
if [[ "$WREN_EXIT" == "2" ]] && printf '%s' "$WREN_ERR" | grep -qi "usage"; then
    pass T01 "no args -> exit 2 + usage"
else
    fail T01 "exit=$WREN_EXIT stderr=[$WREN_ERR]"
fi

# ============================================================
# T02: -h → exit 0 + usage
# ============================================================
new_box
run_wren -h
if [[ "$WREN_EXIT" == "0" ]] \
   && printf '%s' "$WREN_OUT" | grep -qi "usage" \
   && printf '%s' "$WREN_OUT" | grep -qF "claude/settings.json"; then
    pass T02 "-h prints usage (exit 0)"
else
    fail T02 "exit=$WREN_EXIT out=[$WREN_OUT]"
fi

# ============================================================
# T03: 未知子命令 → exit 2 + usage
# ============================================================
new_box
run_wren bogus
if [[ "$WREN_EXIT" == "2" ]] && printf '%s' "$WREN_ERR" | grep -qi "unsupported command"; then
    pass T03 "unknown subcommand -> exit 2"
else
    fail T03 "exit=$WREN_EXIT stderr=[$WREN_ERR]"
fi

# ============================================================
# T04: install → $CLAUDE_CONFIG_DIR/wren-cc 是 wren-cc.py 副本
# ============================================================
new_box
printf '{"model":"opus"}\n' >"$SETTINGS"
run_wren install
target="$CLAUDE/wren-cc"
if [[ "$WREN_EXIT" == "0" && -f "$target" && ! -L "$target" ]] \
   && cmp -s "$target" "$CC_PAYLOAD" && [[ -x "$target" ]]; then
    pass T04 "install copies wren-cc.py to \$CLAUDE_CONFIG_DIR/wren-cc (regular, exec, byte-identical)"
else
    fail T04 "exit=$WREN_EXIT type=$( [[ -L $target ]] && echo symlink || echo other ) exec=$([[ -x $target ]] && echo yes || echo no)"
fi

# ============================================================
# T05: install → $PI_EXT_DIR/wren-pi.ts 是 wren.ts 副本
# ============================================================
pi_target="$PIEXT/wren-pi.ts"
if [[ -f "$pi_target" && ! -L "$pi_target" ]] && cmp -s "$pi_target" "$PI_PAYLOAD"; then
    pass T05 "install copies wren.ts to \$PI_EXT_DIR/wren-pi.ts (byte-identical)"
else
    fail T05 "type=$( [[ -L "$pi_target" ]] && echo symlink || echo other ) expect byte-identical copy"
fi

# ============================================================
# T06: install → settings.json 写入 statusLine
# ============================================================
got="$(json_field "$SETTINGS" 'd["statusLine"]["command"]')"
got_type="$(json_field "$SETTINGS" 'd["statusLine"]["type"]')"
if [[ "$got" == "$CLAUDE/wren-cc" && "$got_type" == "command" ]]; then
    pass T06 "statusLine.command=绝对路径（\$CLAUDE/wren-cc）"
else
    fail T06 "command=[$got] type=[$got_type]"
fi

# ============================================================
# T07: install → 其他键与其顺序原样保留
# ============================================================
new_box
printf '{\n  "model": "opus",\n  "statusLine": { "type": "command", "command": "old-thing", "padding": 0 },\n  "env": {"A": "1"}\n}\n' >"$SETTINGS"
run_wren install
keys="$(json_field "$SETTINGS" '"|".join(d.keys())')"
pad="$(json_field "$SETTINGS" 'd["statusLine"]["padding"]')"
env_a="$(json_field "$SETTINGS" 'd["env"]["A"]')"
if [[ "$keys" == "model|statusLine|env" && "$pad" == "0" && "$env_a" == "1" ]]; then
    pass T07 "other keys and key order preserved"
else
    fail T07 "keys=[$keys] padding=[$pad] env.A=[$env_a]"
fi

# ============================================================
# T08: install → 备份是安装前的原始字节
# ============================================================
bak="$SETTINGS.wren-bak"
if [[ -f "$bak" ]] && diff -q <(printf '{\n  "model": "opus",\n  "statusLine": { "type": "command", "command": "old-thing", "padding": 0 },\n  "env": {"A": "1"}\n}\n') "$bak" >/dev/null; then
    pass T08 "backup holds pre-install bytes"
else
    fail T08 "backup missing or differs: $(cat "$bak" 2>/dev/null)"
fi

# ============================================================
# T09: 再次 install → 不覆盖已有备份（保住最原始状态）
# ============================================================
run_wren install
if diff -q <(printf '{\n  "model": "opus",\n  "statusLine": { "type": "command", "command": "old-thing", "padding": 0 },\n  "env": {"A": "1"}\n}\n') "$bak" >/dev/null; then
    pass T09 "repeat install keeps the original backup"
else
    fail T09 "backup was overwritten: $(cat "$bak")"
fi

# ============================================================
# T10: settings.json 不存在 → 创建之
# ============================================================
new_box
run_wren install
if [[ "$WREN_EXIT" == "0" && -f "$SETTINGS" ]] \
   && [[ "$(json_field "$SETTINGS" 'd["statusLine"]["command"]')" == "$CLAUDE/wren-cc" ]]; then
    pass T10 "missing settings.json is created"
else
    fail T10 "exit=$WREN_EXIT exists=$([[ -f $SETTINGS ]] && echo yes || echo no)"
fi

# ============================================================
# T11: settings.json 非法 JSON → exit 1 且零副作用
# ============================================================
new_box
printf '{ this is not json\n' >"$SETTINGS"
cp "$SETTINGS" "$BOX/before"
run_wren install
if [[ "$WREN_EXIT" == "1" ]] \
   && diff -q "$BOX/before" "$SETTINGS" >/dev/null \
   && [[ -z "$(ls -A "$BIN")" && -z "$(ls -A "$PIEXT")" ]] \
   && [[ ! -e "$SETTINGS.wren-bak" && ! -e "$SETTINGS.wren-tmp" ]]; then
    pass T11 "invalid JSON -> exit 1, no side effects"
else
    fail T11 "exit=$WREN_EXIT bin=[$(ls -A "$BIN")] piext=[$(ls -A "$PIEXT")]"
fi

# ============================================================
# T12: settings.json 顶层不是对象 → exit 1 且零副作用
# ============================================================
new_box
printf '[1, 2, 3]\n' >"$SETTINGS"
cp "$SETTINGS" "$BOX/before"
run_wren install
if [[ "$WREN_EXIT" == "1" ]] \
   && diff -q "$BOX/before" "$SETTINGS" >/dev/null \
   && [[ -z "$(ls -A "$BIN")" && -z "$(ls -A "$PIEXT")" ]] \
   && [[ ! -e "$SETTINGS.wren-bak" && ! -e "$SETTINGS.wren-tmp" ]]; then
    pass T12 "non-object JSON -> exit 1, no side effects"
else
    fail T12 "exit=$WREN_EXIT bin=[$(ls -A "$BIN")] piext=[$(ls -A "$PIEXT")]"
fi

# ============================================================
# T13: 装好的 wren-cc 真的能跑（两行 statusline）
# ============================================================
new_box
run_wren install
payload_json='{"cwd":"/tmp","model":{"display_name":"claude-opus-5"},"context_window":{"current_usage":{"input_tokens":100,"cache_read_input_tokens":200,"cache_creation_input_tokens":50},"context_window_size":200000},"cost":{"total_duration_ms":3900000},"effort":{"level":"high"}}'
printf '%s' "$payload_json" | WREN_CACHE_DIR="$TMPROOT/cccache" "$CLAUDE/wren-cc" >"$BOX/cc.txt" 2>&1
rc=$?
lines=$(awk 'END{printf "%d", NR}' "$BOX/cc.txt")
body="$(<"$BOX/cc.txt")"
if [[ $rc -eq 0 && "$lines" == "2" ]] \
   && printf '%s' "$body" | grep -qF "0.18%/200K" \
   && printf '%s' "$body" | grep -qF "1h5m"; then
    pass T13 "installed wren-cc renders 2 lines"
else
    fail T13 "rc=$rc lines=$lines body=[$body]"
fi

# ============================================================
# T14: pi 扩展目录里已有旧手工副本 odo.ts → 给出重复加载警告
# ============================================================
new_box
: >"$PIEXT/odo.ts"
run_wren install
if [[ "$WREN_EXIT" == "0" ]] && printf '%s' "$WREN_ERR" | grep -qi "both footers"; then
    pass T14 "warns when legacy odo.ts is already loaded by pi"
else
    fail T14 "exit=$WREN_EXIT stderr=[$WREN_ERR]"
fi

# ============================================================
# T15: uninstall → 两份副本都被删
# ============================================================
run_wren uninstall
if [[ "$WREN_EXIT" == "0" ]] \
   && [[ ! -e "$CLAUDE/wren-cc" && ! -L "$CLAUDE/wren-cc" ]] \
   && [[ ! -e "$PIEXT/wren-pi.ts" && ! -L "$PIEXT/wren-pi.ts" ]]; then
    pass T15 "uninstall removes both installed copies"
else
    fail T15 "exit=$WREN_EXIT bin=[$(ls -A "$BIN")] piext=[$(ls -A "$PIEXT")]"
fi

# ============================================================
# T16: uninstall → statusLine 键被删，其他键保留
# ============================================================
new_box
printf '{\n  "model": "opus",\n  "env": {"A": "1"}\n}\n' >"$SETTINGS"
run_wren install
run_wren uninstall
keys="$(json_field "$SETTINGS" '"|".join(d.keys())')"
if [[ "$WREN_EXIT" == "0" && "$keys" == "model|env" ]]; then
    pass T16 "uninstall drops statusLine, keeps the rest"
else
    fail T16 "exit=$WREN_EXIT keys=[$keys]"
fi

# ============================================================
# T17: statusLine 指向别的命令 → 不动的，明确提示
# ============================================================
new_box
printf '{"statusLine":{"type":"command","command":"someone-else"}}\n' >"$SETTINGS"
run_wren uninstall
got="$(json_field "$SETTINGS" 'd["statusLine"]["command"]')"
if [[ "$WREN_EXIT" == "0" && "$got" == "someone-else" ]] \
   && printf '%s' "$WREN_OUT" | grep -qi "left alone"; then
    pass T17 "uninstall leaves a foreign statusLine alone"
else
    fail T17 "exit=$WREN_EXIT command=[$got] out=[$WREN_OUT]"
fi

# ============================================================
# T18: 再次 uninstall → 幂等 exit 0
# ============================================================
new_box
run_wren uninstall
run_wren uninstall
if [[ "$WREN_EXIT" == "0" ]]; then
    pass T18 "uninstall is idempotent"
else
    fail T18 "exit=$WREN_EXIT stderr=[$WREN_ERR]"
fi

# ============================================================
# T19: 目标位置是别人的文件（内容与 payload 不同）→ 不删
# ============================================================
new_box
printf '#!/bin/sh\necho someone-else\n' >"$CLAUDE/wren-cc"
run_wren uninstall
if [[ -f "$CLAUDE/wren-cc" ]] && grep -qF "someone-else" "$CLAUDE/wren-cc"; then
    pass T19 "uninstall does not remove a foreign file"
else
    fail T19 "foreign file gone or changed: [$(cat "$CLAUDE/wren-cc" 2>/dev/null)]"
fi

# ============================================================
# T20: 经 cli-zoo-install.sh 装 wren → $PREFIX/wren 指向工具目录里的入口
# ============================================================
new_box
PREFIX="$BIN" "$INSTALL_SH" wren >/dev/null 2>&1
rc=$?
if [[ $rc -eq 0 && -L "$BIN/wren" ]] && [[ "$(readlink "$BIN/wren")" == "$WREN" ]]; then
    pass T20 "cli-zoo-install.sh wren links the entry script"
else
    fail T20 "rc=$rc link=[$(readlink "$BIN/wren" 2>/dev/null)] expect=[$WREN]"
fi

# ============================================================
# T21: 从软链入口跑 install → 仍能定位到 payload（多文件目录的关键）
# ============================================================
env PREFIX="$BIN" PI_EXT_DIR="$PIEXT" CLAUDE_SETTINGS="$SETTINGS" \
    "$BIN/wren" install >/dev/null 2>&1
rc=$?
if [[ $rc -eq 0 ]] \
   && cmp -s "$CLAUDE/wren-cc" "$CC_PAYLOAD" 2>/dev/null \
   && cmp -s "$PIEXT/wren-pi.ts" "$PI_PAYLOAD" 2>/dev/null; then
    pass T21 "entry via symlink still finds payloads"
else
    fail T21 "rc=$rc cc-identical=$(cmp -s "$CLAUDE/wren-cc" "$CC_PAYLOAD" && echo yes || echo no) pi-identical=$(cmp -s "$PIEXT/wren-pi.ts" "$PI_PAYLOAD" && echo yes || echo no)"
fi

# ============================================================
# T22: python3 缺失 → exit 3
# ============================================================
new_box
printf '{}\n' >"$SETTINGS"
NOPY="$BOX/nopy"
mkdir -p "$NOPY"
out=$(env PATH="$NOPY" PREFIX="$BIN" PI_EXT_DIR="$PIEXT" CLAUDE_SETTINGS="$SETTINGS" \
    OPENCODE_CONFIG_DIR="$OC" OPENCODE_TUI_CONFIG="$OCCONF" \
    /bin/bash "$WREN" install 2>&1 >/dev/null; printf 'EXIT:%s' "$?")
exit_code="${out##*EXIT:}"
stderr_out="${out%EXIT:*}"
if [[ "$exit_code" == "3" ]] && printf '%s' "$stderr_out" | grep -qF "python3"; then
    pass T22 "missing python3 -> exit 3"
else
    fail T22 "exit=$exit_code stderr=[$stderr_out]"
fi

# ============================================================
# T23: payload 缺失 → exit 3
# ============================================================
# 复制一份安装器到临时目录，但不带 payload，模拟仓库被装坏
new_box
FAKE_DIR="$BOX/fakedir"
mkdir -p "$FAKE_DIR"
cp "$WREN" "$FAKE_DIR/wren"
printf '{}\n' >"$SETTINGS"
out=$(env PREFIX="$BIN" PI_EXT_DIR="$PIEXT" CLAUDE_SETTINGS="$SETTINGS" \
    /bin/bash "$FAKE_DIR/wren" install 2>&1 >/dev/null; printf 'EXIT:%s' "$?")
exit_code="${out##*EXIT:}"
stderr_out="${out%EXIT:*}"
if [[ "$exit_code" == "3" ]] && printf '%s' "$stderr_out" | grep -qi "payload not found"; then
    pass T23 "missing payload -> exit 3"
else
    fail T23 "exit=$exit_code stderr=[$stderr_out]"
fi

# ============================================================
# T24: settings 目录不可写 → check 阶段就挡住，零副作用
# （这是「半装状态」的回归守门：曾经会留下 wren-cc 再喷 traceback）
# ============================================================
if [[ "$EUID" -eq 0 ]]; then
    skip T24 "running as root; read-only dir is not enforced"
else
    new_box
    printf '{"model":"opus"}\n' >"$SETTINGS"
    chmod 555 "$CLAUDE"
    run_wren install
    chmod 755 "$CLAUDE"
    if [[ "$WREN_EXIT" == "1" ]] \
       && [[ -z "$(ls -A "$BIN")" && -z "$(ls -A "$PIEXT")" ]] \
       && [[ ! -e "$SETTINGS.wren-bak" ]] \
       && ! printf '%s' "$WREN_ERR" | grep -qF "Traceback"; then
        pass T24 "unwritable settings dir -> exit 1 before any side effect, no traceback"
    else
        fail T24 "exit=$WREN_EXIT bin=[$(ls -A "$BIN")] piext=[$(ls -A "$PIEXT")] err=[$WREN_ERR]"
    fi
fi

# ============================================================
# T25: 覆盖安装时的告警分寸——内容相同不吵，被改过才告警
# ============================================================
new_box
printf '{}\n' >"$SETTINGS"
run_wren install
first_err="$WREN_ERR"
printf '\n# locally patched\n' >>"$CLAUDE/wren-cc"
run_wren install
second_err="$WREN_ERR"
if ! printf '%s' "$first_err" | grep -qi "differs" \
   && printf '%s' "$second_err" | grep -qi "differs" \
   && cmp -s "$CLAUDE/wren-cc" "$CC_PAYLOAD"; then
    pass T25 "quiet when identical, warns when overwriting a modified copy"
else
    fail T25 "first_err=[$first_err] second_err=[$second_err]"
fi

# ============================================================
# T26: uninstall 清掉 wren 自己的副产物（.wren-bak / .wren-tmp）
# ============================================================
new_box
printf '{"model":"opus"}\n' >"$SETTINGS"
run_wren install
: >"$SETTINGS.wren-tmp"          # 模拟写失败可能残留的临时文件
run_wren uninstall
if [[ "$WREN_EXIT" == "0" ]] \
   && [[ ! -e "$SETTINGS.wren-bak" && ! -e "$SETTINGS.wren-tmp" ]] \
   && printf '%s' "$WREN_OUT" | grep -qF "removed" \
   && [[ "$(json_field "$SETTINGS" 'd["model"]')" == "opus" ]]; then
    pass T26 "uninstall cleans its own .wren-bak / .wren-tmp"
else
    fail T26 "exit=$WREN_EXIT claude-dir=[$(ls -A "$CLAUDE")] out=[$WREN_OUT]"
fi

# ============================================================
# pi 侧（zoo-scripts/wren/odo.ts）—— stub 掉 @earendil-works/pi-tui 后真跑 footer 渲染
# ============================================================
WREN_TS="$REPO_ROOT/zoo-scripts/wren/wren-pi.ts"
PI_DIR="$TMPROOT/pi"
mkdir -p "$PI_DIR"

# node 是否支持直接执行 .ts（Node 22.6+ 的 type stripping）
TS_OK=0
if command -v node >/dev/null 2>&1; then
    printf 'const x: number = 1;\nconsole.log("ts-ok", x);\n' >"$PI_DIR/probe.ts"
    node "$PI_DIR/probe.ts" 2>/dev/null | grep -qF "ts-ok 1" && TS_OK=1
fi

# visibleWidth 必须按显示格而非码点：宿主 pi-tui 的真身把 CJK 全角算 2 格、
# 并且剥掉 ANSI（原 stub 用 .length，于是 CJK 断言 TS 侧永远测不出问题，CR 轮 11）
cat >"$PI_DIR/tui-stub.mjs" <<'EOF'
const ANSI = /\x1b\[[0-9;]*m/g;
// East Asian Wide / Fullwidth 的常用区间（与 Python 侧 east_asian_width 在汉字上一致）
const isWide = (cp) =>
  (cp >= 0x1100 && cp <= 0x115f) || (cp >= 0x2e80 && cp <= 0xa4cf) ||
  (cp >= 0xac00 && cp <= 0xd7a3) || (cp >= 0xf900 && cp <= 0xfaff) ||
  (cp >= 0xfe30 && cp <= 0xfe6f) || (cp >= 0xff00 && cp <= 0xff60) ||
  (cp >= 0xffe0 && cp <= 0xffe6) || (cp >= 0x1f300 && cp <= 0x1f64f) ||
  (cp >= 0x20000 && cp <= 0x3fffd);
const cellWidth = (ch) => (isWide(ch.codePointAt(0)) ? 2 : 1);
export const visibleWidth = (s) => {
  let w = 0;
  for (const ch of String(s).replace(ANSI, "")) w += cellWidth(ch);
  return w;
};
export const truncateToWidth = (s, w) => {
  if (visibleWidth(s) <= w) return s;
  let out = "", cur = 0;
  for (const ch of String(s).replace(ANSI, "")) {
    const cw = cellWidth(ch);
    if (cur + cw > w) break;
    out += ch; cur += cw;
  }
  return out;
};
EOF

cat >"$PI_DIR/loader.mjs" <<'EOF'
import { pathToFileURL } from "node:url";
// @earendil-works/pi-tui 只在运行时由 pi 提供，测试用 stub 顶上。
// 两个 import type（pi-ai / pi-coding-agent）会被 type stripping 抹掉，无需 stub。
export async function resolve(spec, ctx, next) {
  if (spec === "@earendil-works/pi-tui") {
    return { url: pathToFileURL(process.env.TUI_STUB).href, shortCircuit: true };
  }
  return next(spec, ctx);
}
EOF

cat >"$PI_DIR/register.mjs" <<'EOF'
import { register } from "node:module";
import { pathToFileURL } from "node:url";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
register(pathToFileURL(join(dirname(fileURLToPath(import.meta.url)), "loader.mjs")).href);
EOF

cat >"$PI_DIR/harness.mjs" <<'EOF'
import { pathToFileURL } from "node:url";

const mod = await import(pathToFileURL(process.env.WREN_TS).href);
const handlers = [];
let footerFactory = null;
const ui = { setFooter: (fn) => { footerFactory = fn; }, notify: () => {} };
const pi = { registerCommand: () => {}, on: (ev, fn) => handlers.push([ev, fn]), ui };
mod.default(pi);

const ctx = {
  sessionManager: { getBranch: () => JSON.parse(process.env.BRANCH || "[]") },
  model: { name: "anthropic/claude-opus-5", contextWindow: Number(process.env.CTX_WINDOW || 200000) },
  thinkingLevel: process.env.THINKING || "high",
  // pi 的权威上下文用量（percent 为 null 表示压缩后暂不可知）
  getContextUsage: () => JSON.parse(process.env.CTX_USAGE || "null"),
  ui,
};
await handlers.find((h) => h[0] === "session_start")[1]({}, ctx);

const theme = {
  fg: (_c, s) => s,
  // Dracula 色档探测点：COLOR_MODE env 控制（"truecolor" | "256color" | "none"）
  getColorMode: () => process.env.COLOR_MODE || "none",
};
const tui = { requestRender: () => {} };
const footerData = {
  getGitBranch: () => process.env.BRANCHNAME || null,
  onBranchChange: () => () => {},
};
// TTFT 事件流（设计 §5 pi 侧）：harness 可发 turn_start / message_update，
// 让 wren-pi.ts 的内存态收到真实事件形状。
// TTFT_MS="a,b"：按顺序模拟多轮，每轮发一个 turn_start，时间戳回拨 a/b ms
//                （用「当前时刻 − N」避免 node 启动耗时污染读数）；
// MSG_UPDATES="x,y|"：用 | 分隔每轮的 update 延迟；某轮为空串 = 该轮不发 update
//                （用来例化「轮进行中、首片未到」这条）。
const fire = (name, event) => {
  const h = handlers.find((x) => x[0] === name);
  if (h) h[1](event, ctx);
};
const ttftTurns = (process.env.TTFT_MS || "").split(",").filter((s) => s !== "");
// 注意用 !== undefined 而非 ||：MSG_UPDATES="" 表示「该轮不发 update」（轮进行中），
// 不能被默认值 "0" 吃掉。
const perTurnUpdates = (process.env.MSG_UPDATES !== undefined ? process.env.MSG_UPDATES : "0").split("|");
for (let i = 0; i < ttftTurns.length; i++) {
  fire("turn_start", {
    type: "turn_start",
    turnIndex: i,
    timestamp: Date.now() - Number(ttftTurns[i]),
  });
  for (const ms of (perTurnUpdates[i] ?? "0").split(",").filter((s) => s !== "")) {
    await new Promise((r) => setTimeout(r, Number(ms)));
    fire("message_update", { type: "message_update", message: {}, assistantMessageEvent: {} });
  }
}
const footer = footerFactory(tui, theme, footerData);
// refreshGit 走 execFile 是异步的，等它落定再渲染（只有 T32 需要）
await new Promise((r) => setTimeout(r, Number(process.env.GIT_WAIT_MS || 0)));
process.stdout.write(footer.render(Number(process.env.WIDTH || 120)).join("\n"));
process.exit(0);
EOF

# run_pi <branch-json> <ctx-usage-json> [extra env assignments] [cwd]
PI_OUT=""
PI_EXIT=0
PI_OUT_FILE="$PI_DIR/out.txt"
run_pi() {
    local branch="$1" usage="$2" extra="${3:-}" where="${4:-$PI_DIR}"
    (cd "$where" && env NO_COLOR=1 BRANCH="$branch" CTX_USAGE="$usage" WREN_TS="$WREN_TS" \
        TUI_STUB="$PI_DIR/tui-stub.mjs" ${extra:+$extra} \
        node --import "$PI_DIR/register.mjs" "$PI_DIR/harness.mjs") >"$PI_OUT_FILE" 2>"$PI_DIR/err.txt"
    PI_EXIT=$?
    PI_OUT="$(<"$PI_OUT_FILE")"
}

# 放在 if 之前：node 缺失路径不引用它，但万一未来有用例挪出 else 分支，
# set -u 不会再因为未初始化而炸（CR 轮 2 指出我上一轮声称挪了、实际仍在 else 内）
USAGE_OK='{"tokens":1000,"contextWindow":200000,"percent":0.5}'

if [[ "$TS_OK" -ne 1 ]]; then
    skip T27 "node with .ts type-stripping not available"
    skip T28 "node with .ts type-stripping not available"
    skip T29 "node with .ts type-stripping not available"
    skip T30 "node with .ts type-stripping not available"
    skip T31 "node with .ts type-stripping not available"
    skip T32 "node with .ts type-stripping not available"
    skip T38 "node with .ts type-stripping not available"
else

    # ========================================================
    # T27: pi footer 渲染出两行
    # ========================================================
    run_pi '[]' "$USAGE_OK"
    pi_lines=$(awk 'END{printf "%d", NR}' "$PI_OUT_FILE")
    if [[ "$PI_EXIT" == "0" ]] && [[ "$pi_lines" == "2" ]]; then
        pass T27 "pi footer renders 2 lines"
    else
        fail T27 "exit=$PI_EXIT lines=$pi_lines err=[$(<"$PI_DIR/err.txt")]"
    fi

    # ========================================================
    # T28: pi 侧 999_500 不得渲染成 1000K（与 CC 侧 T05/T06 同款守门）
    # ========================================================
    run_pi '[{"type":"message","message":{"role":"assistant","usage":{"input":999500,"output":300,"cacheRead":0,"cacheWrite":0}}}]' "$USAGE_OK"
    if [[ "$PI_EXIT" == "0" ]] \
       && printf '%s' "$PI_OUT" | grep -qF "↑1.0M" \
       && ! printf '%s' "$PI_OUT" | grep -qF "1000K"; then
        pass T28 "pi fmt: 999_500 -> 1.0M, no 1000K"
    else
        fail T28 "exit=$PI_EXIT out=[$PI_OUT]"
    fi

    # ========================================================
    # T29: pi 侧 ctx% 取自 ctx.getContextUsage()，percent=null 时显示 ?
    # ========================================================
    run_pi '[]' '{"tokens":85000,"contextWindow":200000,"percent":42.5}'
    with_pct="$PI_OUT"
    run_pi '[]' '{"tokens":null,"contextWindow":200000,"percent":null}'
    with_null="$PI_OUT"
    if printf '%s' "$with_pct" | grep -qF "42.50%/200K" \
       && printf '%s' "$with_null" | grep -qF "?/200K" \
       && ! printf '%s' "$with_null" | grep -qF "42.5%"; then
        pass T29 "pi ctx% from getContextUsage; null -> ?"
    else
        fail T29 "with_pct=[$with_pct] with_null=[$with_null]"
    fi

    # ========================================================
    # T30: pi 侧家目录折叠用 os.homedir()，不再硬编码 /Users
    # ========================================================
    # macOS 的 /var 是指向 /private/var 的软链，而 process.cwd() 返回解析后的路径，
    # 所以夹具也要用解析后的 HOME，否则测的是符号链接而不是折叠逻辑。
    FAKE_HOME="$TMPROOT/fakehome"
    mkdir -p "$FAKE_HOME/Code/proj"
    FAKE_HOME="$(cd "$FAKE_HOME" && pwd -P)"
    OTHER_CWD="$TMPROOT/elsewhere"
    mkdir -p "$OTHER_CWD"
    OTHER_CWD="$(cd "$OTHER_CWD" && pwd -P)"
    run_pi '[]' "$USAGE_OK" "HOME=$FAKE_HOME" "$FAKE_HOME/Code/proj"
    under_home="$(printf '%s' "$PI_OUT" | head -1)"
    run_pi '[]' "$USAGE_OK" "HOME=$FAKE_HOME" "$OTHER_CWD"
    outside="$(printf '%s' "$PI_OUT" | head -1)"
    # HOME 外路径不含 ~（家目录折叠不误伤）；v6 折叠后可能缩为 …/尾段，尾段名必须保留
    if printf '%s' "$under_home" | grep -qF "~/Code/proj" \
       && ! printf '%s' "$outside" | grep -qF "~" \
       && printf '%s' "$outside" | grep -qF "elsewhere"; then
        pass T30 "pi cwd collapses \$HOME (not hardcoded /Users)"
    else
        fail T30 "under_home=[$under_home] outside=[$outside]"
    fi
    # ========================================================
    # T32: 两侧 git 段逐字一致（跨实现比对，不写死期望值）
    # ========================================================
    PI_REPO="$TMPROOT/pi_git"
    PI_REMOTE="$TMPROOT/pi_git_remote"
    mkdir -p "$PI_REPO"
    (
        cd "$PI_REPO" || exit 1
        git -c init.defaultBranch=main init -q
        git config user.email "t@example.com"
        git config user.name "t"
        printf 'a\n' >a.txt; printf 'b\n' >b.txt; printf 'c\n' >c.txt
        git add -A >/dev/null 2>&1
        git commit -q -m init >/dev/null 2>&1
        git init -q --bare "$PI_REMOTE"
        git remote add origin "$PI_REMOTE"
        git push -q -u origin main >/dev/null 2>&1
        # 造出 ahead=1，以及三种脏状态：改 a.txt、删 c.txt、加 new.txt
        printf 'a changed\n' >>a.txt
        git commit -q -am "ahead" >/dev/null 2>&1
        printf 'a again\n' >>a.txt
        rm -f c.txt
        : >new.txt
    ) >/dev/null 2>&1

    # CC 侧：喂同一个 cwd 给 odo.py，取它第一行的 git 段（" | " 之后）
    printf '{"cwd":"%s","model":{"display_name":"claude-opus-5"}}' "$PI_REPO" \
        | NO_COLOR=1 WREN_CACHE_DIR="$TMPROOT/cccache" python3 "$CC_PAYLOAD" >"$PI_DIR/cc1.txt" 2>/dev/null
    cc_line1="$(head -1 "$PI_DIR/cc1.txt")"
    # git 段 = 第一个 " | " 后的整段（含可能的后缀），再剥尾部宿主徽标
    case "$cc_line1" in
        *" | "*) cc_git="$(strip_tag "${cc_line1#* | }")" ;;
        *) cc_git="" ;;
    esac

    # pi 侧：同一个 cwd 跑 harness
    run_pi '[]' "$USAGE_OK" "BRANCHNAME=main GIT_WAIT_MS=1500" "$PI_REPO"
    pi_line1="$(printf '%s' "$PI_OUT" | head -1)"
    pi_git=""
    case "$pi_line1" in
        *" | "*) pi_git="$(strip_tag "${pi_line1#* | }")" ;;
        *) pi_git="" ;;
    esac

    if [[ "$cc_git" == "main ↑1↓0 +1 ~1 ✱1" ]] && [[ "$pi_git" == "$cc_git" ]]; then
        pass T32 "git segment identical on both sides ($pi_git)"
    else
        fail T32 "cc=[$cc_git] pi=[$pi_git] pi_line1=[$pi_line1]"
    fi

    # ========================================================
    # T38: detached HEAD / staged rename / 冲突 UU 三场景的两侧一致性
    # （detached 是 CR 抓出的真分歧：pi 的 getGitBranch() 返回 "detached" 而非 null）
    # ========================================================
    mk_scene_repo() {  # mk_scene_repo <dir> <scene>
        local d="$1" scene="$2"
        mkdir -p "$d"
        (
            cd "$d" || exit 1
            git -c init.defaultBranch=main init -q
            git config user.email t@e.com
            git config user.name t
            printf 'a\n' >a.txt; printf 'b\n' >b.txt
            git add -A >/dev/null 2>&1
            git commit -q -m init >/dev/null 2>&1
            case "$scene" in
                detached) git checkout -q --detach HEAD; printf 'x\n' >>a.txt ;;
                rename)   git mv a.txt c.txt; printf 'y\n' >>b.txt ;;
                conflict)
                    git checkout -q -b side
                    printf 'side\n' >a.txt
                    git commit -q -am side >/dev/null 2>&1
                    git checkout -q main
                    printf 'main\n' >a.txt
                    git commit -q -am main >/dev/null 2>&1
                    git merge side >/dev/null 2>&1 || true
                    ;;
            esac
        ) >/dev/null 2>&1
    }
    # 注意：本函数在 $(...) 里跑，内部 run_pi 对 PI_OUT/PI_EXIT 的赋值发生在子 shell、
    # 不会回传（CR 轮 2 指出）。别在调用后依赖那两个变量；要结果就从本函数的 stdout 拿。
    seg_both() {  # seg_both <repo-dir> <branchname> -> stdout: "cc_seg|pi_seg" 
        local d="$1" bn="$2"
        printf '{"cwd":"%s","model":{"display_name":"m"}}' "$d" \
            | NO_COLOR=1 WREN_CACHE_DIR="$TMPROOT/cccache2" python3 "$CC_PAYLOAD" 2>/dev/null | head -1 >"$PI_DIR/ccx.txt"
        local cc_line pi_line
        cc_line="$(<"$PI_DIR/ccx.txt")"
        run_pi '[]' "$USAGE_OK" "BRANCHNAME=$bn GIT_WAIT_MS=1500" "$d"
        pi_line="$(printf '%s' "$PI_OUT" | head -1)"

        # 提取 " | " 之后的 git 段（剥掉右侧 herdr []，测试沙箱里 herdr 变量已 unset，一般没有）
        local cc_seg="" pi_seg=""
        case "$cc_line" in *" | "*) cc_seg="$(strip_tag "${cc_line#* | }")" ;; esac
        case "$pi_line" in *" | "*) pi_seg="$(strip_tag "${pi_line#* | }")" ;; esac
        # 裸徽标（无 git/herdr 的行1）剥完就是 "cc"/"pi" 本身
        [[ "$cc_seg" == "cc" || "$cc_seg" == "pi" ]] && cc_seg=""
        [[ "$pi_seg" == "cc" || "$pi_seg" == "pi" ]] && pi_seg=""
        printf '%s|%s' "$cc_seg" "$pi_seg"
    }
    R38="$TMPROOT/r38"; mkdir -p "$R38"
    mk_scene_repo "$R38/det" detached
    mk_scene_repo "$R38/ren" rename
    mk_scene_repo "$R38/conf" conflict
    # 正向对照（防「git 整体坏掉也给出空段」的假阴性）：det 仓库先在 main 状态
    # 跑一次（两侧都应显示分支名），再 checkout --detach 进入本场景。
    # 顺序不能反：detached 场景里有未提交改动，先 detach 再 checkout main 会把
    # 改动带回去、污染两个场景的共同状态。
    # mk_scene_repo 已把仓库置于 detached + 工作区改动。正向对照需要真 main：
    # 先丢工作区改动，再从 detached 切回 main 分支（顺序不能反，detached 下
    # checkout main 会把改动带回去）。对照完再重新 detach 并补上改动进入本场景。
    git -C "$R38/det" checkout -q -- . 2>/dev/null
    git -C "$R38/det" checkout -q main 2>/dev/null
    got_det_pos="$(seg_both "$R38/det" main)"
    git -C "$R38/det" checkout -q --detach HEAD 2>/dev/null
    printf 'x\n' >>"$R38/det/a.txt"
    got_det="$(seg_both "$R38/det" detached)"
    got_ren="$(seg_both "$R38/ren" main)"
    got_conf="$(seg_both "$R38/conf" main)"
    # detached：两侧都应没有 git 段（seg 为空）
    det_ok=0
    [[ -z "${got_det%%|*}" && -z "${got_det#*|}" ]] \
        && [[ "${got_det_pos%%|*}" == *"main"* && "${got_det_pos#*|}" == *"main"* ]] && det_ok=1
    # rename：git mv a→c（staged rename 记 ✱）+ b.txt 被改（也记 ✱）→ ✱2；
    # 关键是不出现 +1（staged rename 的 XY 是 R.，不是 A）
    ren_seg="${got_ren%%|*}"
    ren_ok=0
    [[ "$ren_seg" == "${got_ren#*|}" && "$ren_seg" == *"✱2"* && "$ren_seg" != *"+1"* && "$ren_seg" != *"~1"* ]] && ren_ok=1
    # 前置：确认 conflict 场景真处于冲突态（merge 真失败而非静默成功）。
    # 用标记位而不是直接 fail：T38 只允许记录一次结果（CR 轮 3 抓过前置 fail 后
    # 主断言又记一次的双重计数）
    conf_pre=1
    if ! git -C "$R38/conf" ls-files -u >/dev/null 2>&1 || [[ -z "$(git -C "$R38/conf" ls-files -u 2>/dev/null)" ]]; then
        conf_pre=0
    fi
    # 冲突：两侧一致且记 ✱
    conf_seg="${got_conf%%|*}"
    conf_ok=0
    [[ "$conf_seg" == "${got_conf#*|}" && "$conf_seg" == *"✱"* ]] && conf_ok=1
    [[ $conf_pre -eq 0 ]] && conf_ok=0
    if [[ $det_ok -eq 1 && $ren_ok -eq 1 && $conf_ok -eq 1 ]]; then
        pass T38 "detached/rename/conflict: sides agree (det=[$got_det] ren=[$ren_seg] conf=[$conf_seg])"
    else
        fail T38 "det_ok=$det_ok ren_ok=$ren_ok conf_ok=$conf_ok conf_pre=$conf_pre det=[$got_det] ren=[$got_ren] conf=[$got_conf]"
    fi

    # ========================================================
    # T31: pi 侧 CH 两位小数（与 odo.py 对齐；pi 内置 footer 是一位）
    # ========================================================
    # input 1000 + cacheRead 1000 + cacheWrite 0 = prompt 2000
    # CH = 1000/2000 = 50.00%
    run_pi '[{"type":"message","message":{"role":"assistant","usage":{"input":1000,"output":100,"cacheRead":1000,"cacheWrite":0}}}]' "$USAGE_OK"
    if [[ "$PI_EXIT" == "0" ]] && printf '%s' "$PI_OUT" | grep -qF "CH50.00%"; then
        pass T31 "pi CH uses 2 decimals"
    else
        fail T31 "exit=$PI_EXIT out=[$PI_OUT]"
    fi

fi


# ============================================================
# T33: install cc → 只有 CC 侧被装
# ============================================================
new_box
printf '{"model":"opus"}\n' >"$SETTINGS"
run_wren install cc
if [[ "$WREN_EXIT" == "0" ]] \
   && [[ -f "$CLAUDE/wren-cc" && ! -e "$PIEXT/wren-pi.ts" ]] \
   && [[ "$(json_field "$SETTINGS" 'd["statusLine"]["command"]')" == "$CLAUDE/wren-cc" ]]; then
    pass T33 "install cc only touches CC side"
else
    fail T33 "exit=$WREN_EXIT bin=[$(ls -A "$BIN")] piext=[$(ls -A "$PIEXT")]"
fi

# ============================================================
# T34: install pi → 只有 pi 侧被装，settings 不动
# ============================================================
new_box
printf '{"model":"opus"}\n' >"$SETTINGS"
run_wren install pi
if [[ "$WREN_EXIT" == "0" ]] \
   && [[ -f "$PIEXT/wren-pi.ts" && ! -e "$CLAUDE/wren-cc" ]] \
   && [[ "$(json_field "$SETTINGS" 'd.get("statusLine")')" == "None" ]] \
   && [[ ! -e "$SETTINGS.wren-bak" ]]; then
    pass T34 "install pi only touches pi side"
else
    fail T34 "exit=$WREN_EXIT bin=[$(ls -A "$BIN")] piext=[$(ls -A "$PIEXT")] sl=[$(json_field "$SETTINGS" 'd.get("statusLine")')]"
fi

# ============================================================
# T35: install claude 别名 = cc
# ============================================================
new_box
printf '{}\n' >"$SETTINGS"
run_wren install claude
if [[ "$WREN_EXIT" == "0" && -f "$CLAUDE/wren-cc" ]] && [[ ! -e "$PIEXT/wren-pi.ts" ]]; then
    pass T35 "install claude is an alias of cc"
else
    fail T35 "exit=$WREN_EXIT bin=[$(ls -A "$BIN")] piext=[$(ls -A "$PIEXT")]"
fi

# ============================================================
# T37: CLAUDE_CONFIG_DIR 重定向时 settings 写进那边，不碰 ~/.claude
# ============================================================
new_box
CCFG="$BOX/cfg"
mkdir -p "$CCFG"
env PREFIX="$BIN" PI_EXT_DIR="$PIEXT" CLAUDE_CONFIG_DIR="$CCFG" \
    "$WREN" install cc >"$BOX/out.txt" 2>&1
rc=$?
if [[ $rc -eq 0 && -f "$CCFG/settings.json" ]] \
   && [[ "$(python3 -c "import json;print(json.load(open('$CCFG/settings.json'))['statusLine']['command'])" 2>/dev/null)" == "$CCFG/wren-cc" ]] \
   && [[ ! -f "$CLAUDE/settings.json" ]]; then
    pass T37 "CLAUDE_CONFIG_DIR honored, ~/.claude untouched"
else
    fail T37 "rc=$rc cfg_exists=$([[ -f $CCFG/settings.json ]] && echo yes || echo no)"
fi

# ============================================================
# T36: 未知 target → exit 2 且零副作用
# ============================================================
new_box
printf '{"model":"opus"}\n' >"$SETTINGS"
run_wren install bogus
if [[ "$WREN_EXIT" == "2" ]] \
   && [[ -z "$(ls -A "$BIN")" && -z "$(ls -A "$PIEXT")" ]] \
   && [[ "$(json_field "$SETTINGS" 'd["model"]')" == "opus" ]]; then
    pass T36 "unknown target -> exit 2, no side effects"
else
    fail T36 "exit=$WREN_EXIT bin=[$(ls -A "$BIN")] piext=[$(ls -A "$PIEXT")]"
fi

# ============================================================
# T39: CC 侧 Dracula 三色档（带色断言，精确转义字节）
# ============================================================
new_box
CC_IN='{"cwd":"/tmp","model":{"display_name":"claude-opus-5"},"context_window":{"current_usage":{"input_tokens":100,"cache_read_input_tokens":200,"cache_creation_input_tokens":50},"context_window_size":200000},"cost":{"total_duration_ms":3900000},"effort":{"level":"high"}}'
# /tmp 非 git 仓库没有分支名（紫码不出现），粉色模型码是必现锚点；
# 紫码断言用临时 git 仓库的 cwd 单独喂一次
R39="$TMPROOT/r39"; mkdir -p "$R39"
(cd "$R39" && git -c init.defaultBranch=main init -q && git config user.email t@e.com && git config user.name t && : >a.txt && git add -A && git commit -qm i >/dev/null 2>&1)
CC_IN_GIT=$(printf '{"cwd":"%s","model":{"display_name":"claude-opus-5"}}' "$R39")
out_tc=$(printf '%s' "$CC_IN" | COLORTERM=truecolor WREN_CACHE_DIR="$TMPROOT/c39" "$CC_PAYLOAD" 2>/dev/null)
out_256=$(printf '%s' "$CC_IN" | env -u COLORTERM WREN_CACHE_DIR="$TMPROOT/c39" "$CC_PAYLOAD" 2>/dev/null)
out_nc=$(printf '%s' "$CC_IN" | NO_COLOR=1 WREN_CACHE_DIR="$TMPROOT/c39" "$CC_PAYLOAD" 2>/dev/null)
out_git=$(printf '%s' "$CC_IN_GIT" | COLORTERM=truecolor WREN_CACHE_DIR="$TMPROOT/c39" "$CC_PAYLOAD" 2>/dev/null)
t39_ok=1
# truecolor：粉模型码、青思考码、灰分隔码（无 git 的 cwd 下必现）
for code in '38;2;255;121;198' '38;2;139;233;253' '38;2;98;114;164'; do
    printf '%s' "$out_tc" | grep -qF "$code" || t39_ok=0
done
# 紫分支码在 git 仓库 cwd 下必现
printf '%s' "$out_git" | grep -qF '38;2;189;147;249' || t39_ok=0
printf '%s' "$out_git" | grep -qF '38;5;61' && t39_ok=0  # truecolor 档不应出现 256 码
# 256 档：粉→212、灰→61、青→117
for code in '38;5;212' '38;5;61' '38;5;117'; do
    printf '%s' "$out_256" | grep -qF "$code" || t39_ok=0
done
# NO_COLOR：一个转义都没有
printf '%s' "$out_nc" | grep -q $'\x1b\[' && t39_ok=0
# NO_COLOR：一个转义都没有
printf '%s' "$out_nc" | grep -q $'\x1b\[' && t39_ok=0
if [[ $t39_ok -eq 1 ]]; then
    pass T39 "cc Dracula: truecolor/256/NO_COLOR three modes"
else
    fail T39 "tc=[$(printf '%s' "$out_tc" | head -c 120)] 256-miss"
fi

# ============================================================
# T40: pi 侧 getColorMode 两档 + NO_COLOR（stub theme 提供 getColorMode）
# ============================================================
if [[ "$TS_OK" -ne 1 ]]; then
    skip T40 "node with .ts type-stripping not available"
else
    BR='[{"type":"message","message":{"role":"assistant","usage":{"input":1000,"output":100,"cacheRead":1000,"cacheWrite":0}}}]'
    pi_tc=$(env NO_COLOR= COLOR_MODE=truecolor BRANCH="$BR" CTX_USAGE='{"tokens":1000,"contextWindow":200000,"percent":0.5}' \
        WREN_TS="$WREN_TS" TUI_STUB="$PI_DIR/tui-stub.mjs" node --import "$PI_DIR/register.mjs" "$PI_DIR/harness.mjs" 2>/dev/null | head -2 | tail -1)
    pi_256=$(env NO_COLOR= COLOR_MODE=256color BRANCH="$BR" CTX_USAGE='{"tokens":1000,"contextWindow":200000,"percent":0.5}' \
        WREN_TS="$WREN_TS" TUI_STUB="$PI_DIR/tui-stub.mjs" node --import "$PI_DIR/register.mjs" "$PI_DIR/harness.mjs" 2>/dev/null | head -2 | tail -1)
    pi_nc=$(env NO_COLOR=1 COLOR_MODE=truecolor BRANCH="$BR" CTX_USAGE='{"tokens":1000,"contextWindow":200000,"percent":0.5}' \
        WREN_TS="$WREN_TS" TUI_STUB="$PI_DIR/tui-stub.mjs" node --import "$PI_DIR/register.mjs" "$PI_DIR/harness.mjs" 2>/dev/null | head -2 | tail -1)
    t40_ok=1
    # 注意 run_pi 的 NO_COLOR=1 前缀不能复用——这里手动 env 并显式清 NO_COLOR
    printf '%s' "$pi_tc" | grep -qF '38;2;255;121;198' || t40_ok=0
    printf '%s' "$pi_256" | grep -qF '38;5;212' || t40_ok=0
    printf '%s' "$pi_256" | grep -qF '38;2;255;121;198' && t40_ok=0
    printf '%s' "$pi_nc" | grep -q $'\x1b\[' && t40_ok=0
    if [[ $t40_ok -eq 1 ]]; then
        pass T40 "pi Dracula: getColorMode truecolor/256 + NO_COLOR override"
    else
        fail T40 "tc_ok=$(printf '%s' "$pi_tc" | grep -cF '38;2;255;121;198') 256_ok=$(printf '%s' "$pi_256" | grep -cF '38;5;212')"
    fi
fi

# ============================================================
# T41: CH 压缩后显示旧值（与 pi 内置语义对齐；CR 轮 5 裁决）
# ============================================================
new_box
TR41="$BOX/tr41.jsonl"
cat >"$TR41" <<'EOF2'
{"type":"assistant","message":{"usage":{"input_tokens":1000,"output_tokens":100,"cache_read_input_tokens":3000,"cache_creation_input_tokens":1000}}}
{"type":"system","subtype":"compact_boundary","isSidechain":false,"compactMetadata":{"trigger":"manual","postTokens":50000}}
EOF2
printf '{"cwd":"/tmp","model":{"display_name":"m"},"context_window":{"current_usage":null,"context_window_size":200000},"transcript_path":"%s"}' "$TR41" \
    | NO_COLOR=1 WREN_CACHE_DIR="$BOX/cc41" python3 "$CC_PAYLOAD" >"$BOX/ch41.txt" 2>/dev/null
body41="$(<"$BOX/ch41.txt")"
# CH=3000/(1000+3000+1000)=60.00%：current_usage 为 null 时不得消失
if printf '%s' "$body41" | grep -qF "CH60.00%" \
   && printf '%s' "$body41" | grep -qF "CP1" \
   && printf '%s' "$body41" | grep -qF "25.00%/200K"; then
    pass T41 "CH survives compaction (old value, pi-aligned)"
else
    fail T41 "body=[$body41]"
fi

# ============================================================
# T42: 长路径 + 长分支折叠（两侧规则一致：路径保头尾、分支截中段）
# ============================================================
new_box
R42="$BOX/r42"
LONG42="$R42/this-is-a-very/deeply-nested/project-directory/with-a-long-name-that-will-overflow"
mkdir -p "$LONG42"
(cd "$LONG42" && git -c init.defaultBranch=main init -q && git config user.email t@e.com && git config user.name t \
    && : >f && git add -A && git commit -qm i >/dev/null 2>&1 \
    && git checkout -q -b feature/some-extremely-long-branch-name-for-testing-overflow && : >g) >/dev/null 2>&1
# CC 侧
cc42=$(printf '{"cwd":"%s","model":{"display_name":"m"}}' "$LONG42" \
    | NO_COLOR=1 WREN_CACHE_DIR="$BOX/c42" python3 "$CC_PAYLOAD" 2>/dev/null | head -1)
cc_path="$(strip_tag "${cc42%% | *}")"   # 第一个 " | " 前是目录段
cc_git=""
case "$cc42" in *" | "*) cc_git="$(strip_tag "${cc42#* | }")"; cc_git="${cc_git%% *}";; esac
t42_ok=1
# 路径折叠：含 "…" 且不含中间段 "deeply-nested"
printf '%s' "$cc_path" | grep -qF "…" || t42_ok=0
printf '%s' "$cc_path" | grep -qF "deeply-nested" && t42_ok=0
# 分支折叠：≤25 可见字符且含 "…"
if [[ "${#cc_git}" -gt 25 ]] || ! printf '%s' "$cc_git" | grep -qF "…"; then t42_ok=0; fi
# 尾徽标仍在
printf '%s' "$cc42" | grep -qF "| cc" || t42_ok=0
if [[ $t42_ok -eq 1 ]]; then
    pass T42 "cc folding: path=$cc_path branch=$cc_git"
else
    fail T42 "line=[$cc42] path=[$cc_path] branch=[$cc_git]"
fi

# ============================================================
# T43: pi 侧分支折叠（与 CC 同规则）
# ============================================================
if [[ "$TS_OK" -ne 1 ]]; then
    skip T43 "node with .ts type-stripping not available"
else
    pi43=$(cd "$LONG42" && env NO_COLOR=1 BRANCHNAME="feature/some-extremely-long-branch-name-for-testing-overflow" \
        CTX_USAGE="$USAGE_OK" GIT_WAIT_MS=1500 WREN_TS="$WREN_TS" TUI_STUB="$PI_DIR/tui-stub.mjs" \
        node --import "$PI_DIR/register.mjs" "$PI_DIR/harness.mjs" 2>/dev/null | head -1)
    pi_branch=""
    case "$pi43" in *" | "*) pi_branch="$(strip_tag "${pi43#* | }")"; pi_branch="${pi_branch%% *}";; esac
    if [[ "${#pi_branch}" -le 25 ]] && printf '%s' "$pi_branch" | grep -qF "…" \
       && printf '%s' "$pi43" | grep -qF "| pi"; then
        pass T43 "pi branch folding ($pi_branch)"
    else
        fail T43 "line=[$pi43] branch=[$pi_branch]"
    fi
fi

# ============================================================
# T44: CJK 路径的显示宽度（全角算 2 格，CR 轮 10 的宽度口径缺口）
# ============================================================
new_box
CJK44="$BOX/这是一个很长的中文目录名称用来测试显示宽度/子目录"
mkdir -p "$CJK44"
cc44=$(COLUMNS=80 printf '{"cwd":"%s","model":{"display_name":"m"}}' "$CJK44" \
    | NO_COLOR=1 WREN_CACHE_DIR="$BOX/c44" python3 "$CC_PAYLOAD" 2>/dev/null | head -1)
w44=$(python3 -c "
import sys, unicodedata
line = sys.argv[1]
print(sum(2 if unicodedata.east_asian_width(c) in ('W','F') else 1 for c in line))
" "$cc44")
if [[ -n "$cc44" ]] && [[ "$w44" -le 80 ]]; then
    pass T44 "CJK path display width $w44 <= 80"
else
    fail T44 "display width=$w44 line=[$cc44]"
fi

# ============================================================
# T45: 极端 CJK（长中文路径 + 长中文分支）整行不溢出，且折叠结果与色档无关
#      CR 轮 11：末级字符截断按码点切，中文段能切出两倍预算（实测 88 > 80）；
#      且 rest 用上色串量宽 → 色开/色关折出不同结果
# ============================================================
new_box
CJK45="$BOX/中文项目目录名称很长的十六个汉字/另一个很长的中文目录名称十六个汉字/最后一级超长中文目录名称十六个字"
mkdir -p "$CJK45"
(cd "$CJK45" && git -c init.defaultBranch=main init -q && git config user.email t@e.com && git config user.name t \
    && : >f && git add -A && git commit -qm i >/dev/null 2>&1 \
    && git checkout -q -b 二十四字符分支名称测试用abcdefghijklmnop \
    && for i in 1 2 3 4 5 6 7 8 9 10; do : >"d$i"; done) >/dev/null 2>&1
cjk_body() {  # $1.. = env assignments for color mode
    (cd "$CJK45" && env -u NO_COLOR "$@" COLUMNS=80 WREN_CACHE_DIR="$BOX/c45" \
        python3 "$CC_PAYLOAD" <<<"{\"cwd\":\"$CJK45\",\"model\":{\"display_name\":\"m\"}}" 2>/dev/null | head -1)
}
# 剥 ANSI 后同时给出显示宽与明文（带色行里 "| cc" 被转义隔开，明文子串断言必须先剥）
cjk_strip() {
    python3 -c "
import sys, re, unicodedata
line = re.sub(r'\x1b\[[0-9;]*m', '', sys.argv[1])
w = sum(2 if unicodedata.east_asian_width(c) in ('W','F') else 1 for c in line)
print(w)
print(line)
" "$1"
}
cc45_nc="$(cjk_body NO_COLOR=1)"
cc45_tc="$(cjk_body COLORTERM=truecolor)"
nc45="$(cjk_strip "$cc45_nc")"; tc45="$(cjk_strip "$cc45_tc")"
w45_nc="${nc45%%$'\n'*}"; p45_nc="${nc45#*$'\n'}"
w45_tc="${tc45%%$'\n'*}"; p45_tc="${tc45#*$'\n'}"
t45_ok=1
[[ "$w45_nc" -le 80 ]] || t45_ok=0
[[ "$w45_tc" -le 80 ]] || t45_ok=0
printf '%s' "$p45_nc" | grep -qF "| cc" || t45_ok=0
printf '%s' "$p45_tc" | grep -qF "| cc" || t45_ok=0
# 色档只影响转义序列，不得影响折叠结果
[[ "$p45_nc" == "$p45_tc" ]] || t45_ok=0
if [[ $t45_ok -eq 1 ]]; then
    pass T45 "CJK extreme line fits: nc=${w45_nc} tc=${w45_tc}, color-independent folding"
else
    fail T45 "nc=${w45_nc} tc=${w45_tc} nc_line=[$p45_nc] tc_line=[$p45_tc]"
fi

# ============================================================
# T46: pi 侧同一极端场景整行不溢出（宿主 truncateToWidth 兜底 + 折叠按显示格）
# ============================================================
if [[ "$TS_OK" -ne 1 ]]; then
    skip T46 "node with .ts type-stripping not available"
else
    pi46="$(cd "$CJK45" && env NO_COLOR=1 WIDTH=80 BRANCHNAME="二十四字符分支名称测试用abcdefghijklmnop" \
        CTX_USAGE="$USAGE_OK" GIT_WAIT_MS=1500 WREN_TS="$WREN_TS" TUI_STUB="$PI_DIR/tui-stub.mjs" \
        node --import "$PI_DIR/register.mjs" "$PI_DIR/harness.mjs" 2>/dev/null | head -1)"
    w46="$(cjk_strip "$pi46")"; w46="${w46%%$'\n'*}"
    if [[ -n "$pi46" ]] && [[ "$w46" -le 80 ]] && printf '%s' "$pi46" | grep -qF "| pi"; then
        pass T46 "pi CJK extreme line width ${w46} <= 80"
    else
        fail T46 "width=${w46} line=[$pi46]"
    fi
fi

# ============================================================
# qc（wren-qc.py，Qoder CLI statusline）—— 只用合成 payload，
# 不嵌任何真实会话数据（session_id / credits / codebase 一概不出现）。
# 每个用例独立 WREN_CACHE_DIR，transcript 路径互不相同，避免增量解析缓存串味。
# ============================================================

# ============================================================
# T47: qc 最小 payload → 两行 + qc 徽标，无中生有的段不出现
# ============================================================
new_box
printf '{"cwd":"/tmp","model":{"display_name":"Test-Model"}}' \
    | NO_COLOR=1 WREN_CACHE_DIR="$BOX/q47" python3 "$QC_PAYLOAD" >"$BOX/q47.txt" 2>&1
q47_lines=$(awk 'END{printf "%d", NR}' "$BOX/q47.txt")
q47_l1="$(head -1 "$BOX/q47.txt")"; q47_l2="$(tail -1 "$BOX/q47.txt")"
if [[ "$q47_lines" == "2" && "$q47_l1" == "/tmp | qc" && "$q47_l2" == "↑0 ↓0 | R0 | Test-Model" ]]; then
    pass T47 "qc minimal payload: 2 lines, qc badge, no invented segments"
else
    fail T47 "lines=$q47_lines l1=[$q47_l1] l2=[$q47_l2]"
fi

# ============================================================
# T48: qc ↑in/↓out 取 transcript 累计，不碰原生「最近一次请求」字段
# ============================================================
new_box
cat >"$BOX/tr48.jsonl" <<'EOF2'
{"type":"assistant","message":{"usage":{"input_tokens":1000,"output_tokens":100,"cache_read_input_tokens":500}}}
{"type":"assistant","message":{"usage":{"input_tokens":2000,"output_tokens":300,"cache_read_input_tokens":1500}}}
EOF2
printf '{"cwd":"/tmp","model":{"display_name":"m"},"context_window":{"total_input_tokens":43138,"context_window_size":200000,"used_percentage":22},"transcript_path":"%s"}' "$BOX/tr48.jsonl" \
    | NO_COLOR=1 WREN_CACHE_DIR="$BOX/q48" python3 "$QC_PAYLOAD" >"$BOX/q48.txt" 2>&1
q48="$(tail -1 "$BOX/q48.txt")"
if printf '%s' "$q48" | grep -qF "↑3K ↓400" \
   && ! printf '%s' "$q48" | grep -qF "↑43K" \
   && ! printf '%s' "$q48" | grep -qF "↓0"; then
    pass T48 "qc ↑in/↓out from transcript sums, not native per-request field"
else
    fail T48 "l2=[$q48]"
fi

# ============================================================
# T49: qc ctx% 原生 used_percentage 优先；缺失时按 total_input_tokens 自算
# ============================================================
new_box
printf '{"cwd":"/tmp","model":{"display_name":"m"},"context_window":{"total_input_tokens":43138,"context_window_size":200000,"used_percentage":22}}' \
    | NO_COLOR=1 WREN_CACHE_DIR="$BOX/q49" python3 "$QC_PAYLOAD" 2>/dev/null | tail -1 >"$BOX/q49a.txt"
printf '{"cwd":"/tmp","model":{"display_name":"m"},"context_window":{"total_input_tokens":43138,"context_window_size":200000}}' \
    | NO_COLOR=1 WREN_CACHE_DIR="$BOX/q49" python3 "$QC_PAYLOAD" 2>/dev/null | tail -1 >"$BOX/q49b.txt"
q49a="$(<"$BOX/q49a.txt")"; q49b="$(<"$BOX/q49b.txt")"
if printf '%s' "$q49a" | grep -qF "22.00%/200K" \
   && printf '%s' "$q49b" | grep -qF "21.57%/200K"; then
    pass T49 "qc ctx%: native used_percentage first, self-computed fallback"
else
    fail T49 "a=[$q49a] b=[$q49b]"
fi

# ============================================================
# T50: qc CH 用 qoder 口径 cr/in（input 已含 cache，不得套 CC 公式）
# ============================================================
new_box
cat >"$BOX/tr50.jsonl" <<'EOF2'
{"type":"assistant","message":{"usage":{"input_tokens":26254,"output_tokens":203,"cache_read_input_tokens":24064}}}
EOF2
printf '{"cwd":"/tmp","model":{"display_name":"m"},"transcript_path":"%s"}' "$BOX/tr50.jsonl" \
    | NO_COLOR=1 WREN_CACHE_DIR="$BOX/q50" python3 "$QC_PAYLOAD" >"$BOX/q50.txt" 2>&1
q50="$(tail -1 "$BOX/q50.txt")"
if printf '%s' "$q50" | grep -qF "CH91.66%" \
   && printf '%s' "$q50" | grep -qF "R24K" \
   && ! printf '%s' "$q50" | grep -qF "CH47.82%"; then
    pass T50 "qc CH = cache_read/input_tokens (qoder input already includes cache)"
else
    fail T50 "l2=[$q50]"
fi

# ============================================================
# T51: qc 旧版口径自适应——input < cache_read 时回退 CC 公式
# ============================================================
new_box
cat >"$BOX/tr51.jsonl" <<'EOF2'
{"type":"assistant","message":{"usage":{"input_tokens":1000,"output_tokens":10,"cache_read_input_tokens":3000,"cache_creation_input_tokens":1000}}}
EOF2
printf '{"cwd":"/tmp","model":{"display_name":"m"},"transcript_path":"%s"}' "$BOX/tr51.jsonl" \
    | NO_COLOR=1 WREN_CACHE_DIR="$BOX/q51" python3 "$QC_PAYLOAD" >"$BOX/q51.txt" 2>&1
if grep -qF "CH60.00%" "$BOX/q51.txt"; then
    pass T51 "qc legacy fallback: CC formula when input < cache_read"
else
    fail T51 "l2=[$(tail -1 "$BOX/q51.txt")]"
fi

# ============================================================
# T52: qc cache_creation 为对象形态（ephemeral_5m/1h）且走回退公式
# ============================================================
new_box
cat >"$BOX/tr52.jsonl" <<'EOF2'
{"type":"assistant","message":{"usage":{"input_tokens":1000,"output_tokens":10,"cache_read_input_tokens":3000,"cache_creation":{"ephemeral_5m_input_tokens":1000,"ephemeral_1h_input_tokens":2000}}}}
EOF2
printf '{"cwd":"/tmp","model":{"display_name":"m"},"transcript_path":"%s"}' "$BOX/tr52.jsonl" \
    | NO_COLOR=1 WREN_CACHE_DIR="$BOX/q52" python3 "$QC_PAYLOAD" >"$BOX/q52.txt" 2>&1
if grep -qF "CH42.86%" "$BOX/q52.txt"; then
    pass T52 "qc cache_creation object form summed (5m+1h) in fallback"
else
    fail T52 "l2=[$(tail -1 "$BOX/q52.txt")]"
fi

# ============================================================
# T53: qc 时长 = transcript 推算的会话年龄（首条 ts → now），上移行1 尾与徽标合并；
#      cost.total_duration_ms 路径已删（宿主从不发送该字段，v6 起不读）
# ============================================================
new_box
TS53=$(python3 -c "import datetime;print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(minutes=9)).isoformat())")
printf '{"type":"assistant","timestamp":"%s","message":{"usage":{}}}\n' "$TS53" >"$BOX/tr53.jsonl"
printf '{"cwd":"/tmp","model":{"display_name":"m"},"transcript_path":"%s"}' "$BOX/tr53.jsonl" \
    | NO_COLOR=1 WREN_CACHE_DIR="$BOX/q53a" python3 "$QC_PAYLOAD" 2>/dev/null >"$BOX/q53a.txt"
printf '{"cwd":"/tmp","model":{"display_name":"m"},"cost":{"total_duration_ms":3900000}}' \
    | NO_COLOR=1 WREN_CACHE_DIR="$BOX/q53b" python3 "$QC_PAYLOAD" 2>/dev/null >"$BOX/q53b.txt"
q53a1="$(head -1 "$BOX/q53a.txt")"; q53a2="$(tail -1 "$BOX/q53a.txt")"; q53b1="$(head -1 "$BOX/q53b.txt")"
if printf '%s' "$q53a1" | grep -qF "qc · 9m" \
   && ! printf '%s' "$q53a2" | grep -qF "9m" \
   && printf '%s' "$q53b1" | grep -qF "| qc" && ! printf '%s' "$q53b1" | grep -qF "·"; then
    pass T53 "qc duration: session age from transcript on line1, cost field not read"
else
    fail T53 "a1=[$q53a1] a2=[$q53a2] b1=[$q53b1]"
fi

# ============================================================
# T54: qc 思考等级来自 transcript runtime-config；无记录时不渲染该段
# ============================================================
new_box
printf '{"type":"runtime-config","reasoningEffort":"high"}\n' >"$BOX/tr54.jsonl"
printf '{"cwd":"/tmp","model":{"display_name":"Test-Model"},"transcript_path":"%s"}' "$BOX/tr54.jsonl" \
    | NO_COLOR=1 WREN_CACHE_DIR="$BOX/q54" python3 "$QC_PAYLOAD" 2>/dev/null | tail -1 >"$BOX/q54a.txt"
printf '{"cwd":"/tmp","model":{"display_name":"Test-Model"}}' \
    | NO_COLOR=1 WREN_CACHE_DIR="$BOX/q54" python3 "$QC_PAYLOAD" 2>/dev/null | tail -1 >"$BOX/q54b.txt"
q54a="$(<"$BOX/q54a.txt")"; q54b="$(<"$BOX/q54b.txt")"
if printf '%s' "$q54a" | grep -qF "Test-Model · high" \
   && [[ "$q54b" == "↑0 ↓0 | R0 | Test-Model" ]]; then
    pass T54 "qc thinking from runtime-config record; absent -> segment hidden"
else
    fail T54 "a=[$q54a] b=[$q54b]"
fi

# ============================================================
# T55: qc Dracula 三色档（与 T39/T40 同一张表，带色断言精确到转义字节）
# ============================================================
new_box
R55="$BOX/r55"; mkdir -p "$R55"
(cd "$R55" && git -c init.defaultBranch=main init -q && git config user.email t@e.com && git config user.name t \
    && : >a.txt && git add -A && git commit -qm i) >/dev/null 2>&1
cat >"$BOX/tr55.jsonl" <<'EOF2'
{"type":"assistant","message":{"usage":{"input_tokens":26254,"output_tokens":203,"cache_read_input_tokens":24064}}}
{"type":"runtime-config","reasoningEffort":"high"}
EOF2
QC55=$(printf '{"cwd":"%s","model":{"display_name":"Test-Model"},"transcript_path":"%s"}' "$R55" "$BOX/tr55.jsonl")
qc55_tc=$(printf '%s' "$QC55" | COLORTERM=truecolor WREN_CACHE_DIR="$BOX/q55" python3 "$QC_PAYLOAD" 2>/dev/null)
qc55_256=$(printf '%s' "$QC55" | env -u COLORTERM WREN_CACHE_DIR="$BOX/q55" python3 "$QC_PAYLOAD" 2>/dev/null)
qc55_nc=$(printf '%s' "$QC55" | NO_COLOR=1 WREN_CACHE_DIR="$BOX/q55" python3 "$QC_PAYLOAD" 2>/dev/null)
t55_ok=1
# truecolor：粉模型 / 青思考 / 灰分隔 / 紫分支 四码必现；且不混入 256 码
for code in '38;2;255;121;198' '38;2;139;233;253' '38;2;98;114;164' '38;2;189;147;249'; do
    printf '%s' "$qc55_tc" | grep -qF "$code" || t55_ok=0
done
printf '%s' "$qc55_tc" | grep -qF '38;5;61' && t55_ok=0
# 256：粉 212 / 灰 61 / 青 117 / 紫 141
for code in '38;5;212' '38;5;61' '38;5;117' '38;5;141'; do
    printf '%s' "$qc55_256" | grep -qF "$code" || t55_ok=0
done
printf '%s' "$qc55_nc" | grep -q $'\x1b\[' && t55_ok=0
if [[ $t55_ok -eq 1 ]]; then
    pass T55 "qc Dracula: truecolor/256/NO_COLOR same table as cc/pi"
else
    fail T55 "tc_head=[$(printf '%s' "$qc55_tc" | head -c 100)]"
fi

# ============================================================
# T56: qc stdin 非法 JSON → 降级不炸（statusline 宁可退化也不能空/挂住）
# ============================================================
new_box
printf 'not json at all' \
    | NO_COLOR=1 WREN_CACHE_DIR="$BOX/q56" python3 "$QC_PAYLOAD" >"$BOX/q56.txt" 2>&1
q56_rc=$?
q56_lines=$(awk 'END{printf "%d", NR}' "$BOX/q56.txt")
q56_body="$(<"$BOX/q56.txt")"
if [[ $q56_rc -eq 0 && "$q56_lines" == "2" ]] \
   && printf '%s' "$q56_body" | grep -qF "no-model" \
   && printf '%s' "$q56_body" | grep -qF "| qc"; then
    pass T56 "qc invalid JSON -> degrade to 2 lines, exit 0"
else
    fail T56 "rc=$q56_rc lines=$q56_lines body=[$q56_body]"
fi

# ============================================================
# T57: qc WREN_DEBUG_DUMP 钩子落盘的即是 stdin 原始字节
# ============================================================
new_box
Q57IN='{"cwd":"/tmp","model":{"display_name":"m"}}'
printf '%s' "$Q57IN" \
    | NO_COLOR=1 WREN_CACHE_DIR="$BOX/q57" WREN_DEBUG_DUMP="$BOX/dump57.json" \
    python3 "$QC_PAYLOAD" >/dev/null 2>&1
if [[ -f "$BOX/dump57.json" ]] && printf '%s' "$Q57IN" | cmp -s - "$BOX/dump57.json"; then
    pass T57 "qc WREN_DEBUG_DUMP captures raw stdin bytes"
else
    fail T57 "dump=[$(cat "$BOX/dump57.json" 2>/dev/null)]"
fi

# ============================================================
# T58: qc ctx 回落链——原生缺失 → postTokens → 末次请求；CP 计数
# ============================================================
new_box
cat >"$BOX/tr58.jsonl" <<'EOF2'
{"type":"assistant","message":{"usage":{"input_tokens":1000,"output_tokens":100,"cache_read_input_tokens":3000,"cache_creation_input_tokens":1000}}}
{"type":"system","subtype":"compact_boundary","isSidechain":false,"compactMetadata":{"trigger":"manual","postTokens":50000}}
EOF2
printf '{"cwd":"/tmp","model":{"display_name":"m"},"context_window":{"context_window_size":200000},"transcript_path":"%s"}' "$BOX/tr58.jsonl" \
    | NO_COLOR=1 WREN_CACHE_DIR="$BOX/q58" python3 "$QC_PAYLOAD" >"$BOX/q58.txt" 2>&1
q58="$(tail -1 "$BOX/q58.txt")"
if printf '%s' "$q58" | grep -qF "CP1" \
   && printf '%s' "$q58" | grep -qF "25.00%/200K"; then
    pass T58 "qc ctx fallback chain: postTokens after compact_boundary; CP counted"
else
    fail T58 "l2=[$q58]"
fi

# ============================================================
# T59: qc 行1 与 wren-cc.py 跨实现同构（剥宿主徽标后逐字相同）
# ============================================================
new_box
R59="$BOX/r59"; mkdir -p "$R59"
(cd "$R59" && git -c init.defaultBranch=main init -q && git config user.email t@e.com && git config user.name t \
    && printf 'a\n' >a.txt && git add -A && git commit -qm i >/dev/null 2>&1 \
    && printf 'changed\n' >>a.txt && : >new.txt) >/dev/null 2>&1
cc59=$(printf '{"cwd":"%s","model":{"display_name":"m"}}' "$R59" \
    | NO_COLOR=1 WREN_CACHE_DIR="$BOX/c59" python3 "$CC_PAYLOAD" 2>/dev/null | head -1)
qc59=$(printf '{"cwd":"%s","model":{"display_name":"m"}}' "$R59" \
    | NO_COLOR=1 WREN_CACHE_DIR="$BOX/q59" python3 "$QC_PAYLOAD" 2>/dev/null | head -1)
cc59s="$(strip_tag "$cc59")"; qc59s="$(strip_tag "$qc59")"
if [[ -n "$cc59s" && "$cc59s" == "$qc59s" ]] && printf '%s' "$cc59s" | grep -qF "main"; then
    pass T59 "qc line1 identical to wren-cc.py after badge strip ($cc59s)"
else
    fail T59 "cc=[$cc59s] qc=[$qc59s]"
fi

# ============================================================
# T60: install qc → payload 副本（exec）+ statusLine 写绝对路径
# ============================================================
new_box
printf '{"model":"m"}\n' >"$QODER_SETTINGS"
run_wren install qc
q60="$QODER/wren-qc.py"
q60_cmd="$(json_field "$QODER_SETTINGS" 'd["statusLine"]["command"]')"
q60_type="$(json_field "$QODER_SETTINGS" 'd["statusLine"]["type"]')"
if [[ "$WREN_EXIT" == "0" && -f "$q60" && ! -L "$q60" ]] \
   && cmp -s "$q60" "$QC_PAYLOAD" && [[ -x "$q60" ]] \
   && [[ "$q60_cmd" == "$q60" && "$q60_type" == "command" ]]; then
    pass T60 "install qc copies payload + writes absolute statusLine"
else
    fail T60 "exit=$WREN_EXIT cmd=[$q60_cmd] type=[$q60_type]"
fi

# ============================================================
# T61: install qc 只动 qc 侧（cc/pi 目标与配置全不动）
# ============================================================
new_box
printf '{"model":"opus"}\n' >"$SETTINGS"
run_wren install qc
if [[ "$WREN_EXIT" == "0" && -f "$QODER/wren-qc.py" ]] \
   && [[ -z "$(ls -A "$BIN")" && -z "$(ls -A "$PIEXT")" ]] \
   && [[ "$(json_field "$SETTINGS" 'd.get("statusLine")')" == "None" ]] \
   && [[ ! -e "$SETTINGS.wren-bak" ]]; then
    pass T61 "install qc only touches qc side"
else
    fail T61 "exit=$WREN_EXIT bin=[$(ls -A "$BIN")] piext=[$(ls -A "$PIEXT")] sl=[$(json_field "$SETTINGS" 'd.get("statusLine")')]"
fi

# ============================================================
# T62: install qc → 键序保留 + 备份是安装前原始字节
# ============================================================
new_box
printf '{\n  "model": "m",\n  "statusLine": { "type": "command", "command": "old-thing", "padding": 0 },\n  "env": {"A": "1"}\n}\n' >"$QODER_SETTINGS"
run_wren install qc
q62_keys="$(json_field "$QODER_SETTINGS" '"|".join(d.keys())')"
q62_pad="$(json_field "$QODER_SETTINGS" 'd["statusLine"]["padding"]')"
q62_env="$(json_field "$QODER_SETTINGS" 'd["env"]["A"]')"
q62_bak="$QODER_SETTINGS.wren-bak"
if [[ "$q62_keys" == "model|statusLine|env" && "$q62_pad" == "0" && "$q62_env" == "1" ]] \
   && diff -q <(printf '{\n  "model": "m",\n  "statusLine": { "type": "command", "command": "old-thing", "padding": 0 },\n  "env": {"A": "1"}\n}\n') "$q62_bak" >/dev/null; then
    pass T62 "qc install preserves keys/order and backs up original bytes"
else
    fail T62 "keys=[$q62_keys] pad=[$q62_pad] env=[$q62_env] bak=[$(cat "$q62_bak" 2>/dev/null)]"
fi

# ============================================================
# T63: uninstall qc → 删 payload/statusLine/副产物，其他键保留
# ============================================================
new_box
printf '{"model":"m","env":{"A":"1"}}\n' >"$QODER_SETTINGS"
run_wren install qc
: >"$QODER_SETTINGS.wren-tmp"
run_wren uninstall qc
q63_keys="$(json_field "$QODER_SETTINGS" '"|".join(d.keys())')"
if [[ "$WREN_EXIT" == "0" ]] \
   && [[ ! -e "$QODER/wren-qc.py" && ! -L "$QODER/wren-qc.py" ]] \
   && [[ "$q63_keys" == "model|env" ]] \
   && [[ ! -e "$QODER_SETTINGS.wren-bak" && ! -e "$QODER_SETTINGS.wren-tmp" ]]; then
    pass T63 "uninstall qc removes payload/statusLine/sidecars, keeps rest"
else
    fail T63 "exit=$WREN_EXIT keys=[$q63_keys] qoder=[$(ls -A "$QODER")]"
fi

# ============================================================
# T64: uninstall qc 遇 foreign statusLine → 不动，明说
# ============================================================
new_box
run_wren install qc
python3 - "$QODER_SETTINGS" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["statusLine"]["command"] = "someone-else"
json.dump(d, open(p, "w"), indent=2)
PY
run_wren uninstall qc
q64_cmd="$(json_field "$QODER_SETTINGS" 'd["statusLine"]["command"]')"
if [[ "$WREN_EXIT" == "0" && "$q64_cmd" == "someone-else" ]] \
   && [[ ! -e "$QODER/wren-qc.py" ]] \
   && printf '%s' "$WREN_OUT" | grep -qi "left alone"; then
    pass T64 "qc uninstall leaves a foreign statusLine alone (payload still ours, removed)"
else
    fail T64 "exit=$WREN_EXIT cmd=[$q64_cmd] out=[$WREN_OUT]"
fi

# ============================================================
# T65: QODER_CONFIG_DIR 改道（不设 QODER_SETTINGS）→ 全部落新目录
# ============================================================
new_box
QCFG="$BOX/qcfg"; mkdir -p "$QCFG"
env NO_COLOR=1 PREFIX="$BIN" PI_EXT_DIR="$PIEXT" CLAUDE_SETTINGS="$SETTINGS" \
    QODER_CONFIG_DIR="$QCFG" "$WREN" install qc >"$BOX/out.txt" 2>&1
q65_rc=$?
if [[ $q65_rc -eq 0 && -f "$QCFG/wren-qc.py" ]] \
   && [[ "$(json_field "$QCFG/settings.json" 'd["statusLine"]["command"]')" == "$QCFG/wren-qc.py" ]] \
   && [[ -z "$(ls -A "$QODER")" ]]; then
    pass T65 "QODER_CONFIG_DIR honored; default dir untouched"
else
    fail T65 "rc=$q65_rc qcfg=[$(ls -A "$QCFG")] default=[$(ls -A "$QODER")]"
fi

# ============================================================
# T66: install qoder 别名 = qc
# ============================================================
new_box
run_wren install qoder
if [[ "$WREN_EXIT" == "0" && -f "$QODER/wren-qc.py" ]] \
   && [[ "$(json_field "$QODER_SETTINGS" 'd["statusLine"]["command"]')" == "$QODER/wren-qc.py" ]] \
   && [[ -z "$(ls -A "$BIN")" && -z "$(ls -A "$PIEXT")" ]]; then
    pass T66 "install qoder is an alias of qc"
else
    fail T66 "exit=$WREN_EXIT qoder=[$(ls -A "$QODER")]"
fi

# ============================================================
# T67: qoder settings 非法 + install（all）→ 预检挡住，零副作用
#（cc 配置合法、qc 非法：验证预检先行，不能装完 cc/pi 才发现 qc 写不进）
# ============================================================
new_box
printf '{ bad json\n' >"$QODER_SETTINGS"
printf '{"model":"opus"}\n' >"$SETTINGS"
cp "$SETTINGS" "$BOX/before67"
run_wren install
if [[ "$WREN_EXIT" == "1" ]] \
   && [[ -z "$(ls -A "$BIN")" && -z "$(ls -A "$PIEXT")" ]] \
   && [[ ! -e "$QODER/wren-qc.py" ]] \
   && diff -q "$BOX/before67" "$SETTINGS" >/dev/null \
   && [[ ! -e "$SETTINGS.wren-bak" && ! -e "$QODER_SETTINGS.wren-bak" ]]; then
    pass T67 "invalid qoder settings -> exit 1 before any install (pre-check gate)"
else
    fail T67 "exit=$WREN_EXIT bin=[$(ls -A "$BIN")] piext=[$(ls -A "$PIEXT")] qoder=[$(ls -A "$QODER")]"
fi

# ============================================================
# T68: 目标父目录不存在且不可创建（只读祖先）→ 预检挡住，零副作用
#（CR 轮 13 抓的缺口：check 只在 parent 已存在时探可写性，parent 缺失时放行，
#  payload 先装、makedirs 失败后才 exit 1，留下半装状态。root 下 chmod 555 无效会 SKIP）
# ============================================================
if [[ "$(id -u)" == "0" ]]; then
    skip T68 "running as root; read-only dir is not enforced"
else
    new_box
    RO="$BOX/readonly"; mkdir -p "$RO"; chmod 555 "$RO"
    printf '{"model":"opus"}\n' >"$SETTINGS"
    cp "$SETTINGS" "$BOX/before68"
    env NO_COLOR=1 PREFIX="$BIN" PI_EXT_DIR="$PIEXT" CLAUDE_SETTINGS="$SETTINGS" \
        QODER_CONFIG_DIR="$RO/qoder/nested" OPENCODE_CONFIG_DIR="$OC" OPENCODE_TUI_CONFIG="$OCCONF" \
        "$WREN" install >"$BOX/out68.txt" 2>"$BOX/err68.txt"
    E68=$?
    if [[ "$E68" == "1" ]] \
       && [[ -z "$(ls -A "$BIN")" && -z "$(ls -A "$PIEXT")" ]] \
       && [[ ! -e "$RO/qoder" ]] \
       && diff -q "$BOX/before68" "$SETTINGS" >/dev/null; then
        pass T68 "uncreatable qoder parent -> exit 1, zero side effects"
    else
        fail T68 "exit=$E68 bin=[$(ls -A "$BIN")] piext=[$(ls -A "$PIEXT")] ro=[$(ls -A "$RO" 2>/dev/null)]"
    fi
    chmod 755 "$RO"
fi

# ============================================================
# T69: pi 事件计时 TTFT（turn_start + 首个 message_update，内存态不入缓存）
# ============================================================
if [[ "$TS_OK" -ne 1 ]]; then
    skip T69 "node with .ts type-stripping not available"
else
    pi_ttft() {  # $1 = TTFT_MS（多轮用 , 分隔）, $2 = MSG_UPDATES（每轮用 | 分隔，空 = 该轮不发首片）
        env NO_COLOR=1 TTFT_MS="$1" MSG_UPDATES="$2" CTX_USAGE="$USAGE_OK" WREN_TS="$WREN_TS" \
            TUI_STUB="$PI_DIR/tui-stub.mjs" node --import "$PI_DIR/register.mjs" "$PI_DIR/harness.mjs" 2>/dev/null \
            | head -2 | tail -1
    }
    t69_a="$(pi_ttft 6600 0)"     # <10s：一位小数
    t69_b="$(pi_ttft 12000 0)"    # ≥10s：整数
    t69_c="$(pi_ttft 65000 0)"    # ≥60s：TTFT 1m05s
    t69_d="$(pi_ttft 6600 "0,300")"   # 第二个 message_update 不得改写首片时刻
    if printf '%s' "$t69_a" | grep -qF "TTFT 6.6s" \
       && printf '%s' "$t69_b" | grep -qF "TTFT 12s" \
       && printf '%s' "$t69_c" | grep -qF "TTFT 1m05s" \
       && printf '%s' "$t69_d" | grep -qF "TTFT 6.6s"; then
        pass T69 "pi TTFT from event stream (3 tiers + first-update-only)"
    else
        fail T69 "a=[$t69_a] b=[$t69_b] c=[$t69_c] d=[$t69_d]"
    fi
fi

# ============================================================
# T70: 时长归位——落在行1 徽标段，行2 不再出现（设计 §7）
# ============================================================
if [[ "$TS_OK" -ne 1 ]]; then
    skip T70 "node with .ts type-stripping not available"
else
    t70_out=$(env NO_COLOR=1 CTX_USAGE="$USAGE_OK" WREN_TS="$WREN_TS" TUI_STUB="$PI_DIR/tui-stub.mjs" \
        node --import "$PI_DIR/register.mjs" "$PI_DIR/harness.mjs" 2>/dev/null)
    t70_l1="$(printf '%s' "$t70_out" | head -1)"
    t70_l2="$(printf '%s' "$t70_out" | tail -1)"
    if printf '%s' "$t70_l1" | grep -qE '\| pi · ([0-9]+h[0-9]+m|[0-9]+h\+|[0-9]+m)$' \
       && ! printf '%s' "$t70_l2" | grep -qE '([0-9]+h[0-9]+m|[0-9]+h\+|[0-9]+m)$'; then
        pass T70 "duration in line1 badge slot, absent from line2"
    else
        fail T70 "l1=[$t70_l1] l2=[$t70_l2]"
    fi
fi

# ============================================================
# T71: 段缺失不留悬空分隔符（时长在、TTFT 缺）
# ============================================================
if [[ "$TS_OK" -ne 1 ]]; then
    skip T71 "node with .ts type-stripping not available"
else
    t71_l2=$(env NO_COLOR=1 CTX_USAGE="$USAGE_OK" WREN_TS="$WREN_TS" TUI_STUB="$PI_DIR/tui-stub.mjs" \
        node --import "$PI_DIR/register.mjs" "$PI_DIR/harness.mjs" 2>/dev/null | tail -1)
    t71_bad=0
    printf '%s' "$t71_l2" | grep -qE '  ' && t71_bad=1           # 双空格（段被剔除后未清干净）
    printf '%s' "$t71_l2" | grep -qE '(\||·) *$' && t71_bad=1   # 悬空分隔符
    printf '%s' "$t71_l2" | grep -qF '· |' && t71_bad=1
    printf '%s' "$t71_l2" | grep -qF '| |' && t71_bad=1
    if [[ $t71_bad -eq 0 ]] && printf '%s' "$t71_l2" | grep -qF "0.50%/200K | claude-opus-5"; then
        pass T71 "no dangling separator when TTFT absent"
    else
        fail T71 "l2=[$t71_l2] bad=$t71_bad"
    fi
fi

# ============================================================
# T72: 行1 梯子——预算不够先丢时长，徽标保住（设计 §4）
# ============================================================
if [[ "$TS_OK" -ne 1 ]]; then
    skip T72 "node with .ts type-stripping not available"
else
    T72_REPO="$BOX/r72"; mkdir -p "$T72_REPO"
    (cd "$T72_REPO" && git -c init.defaultBranch=main init -q && git config user.email t@e.com \
        && git config user.name t && : >f && git add -A && git commit -qm i >/dev/null 2>&1 \
        && git checkout -q -b feature/some-extremely-long-branch-name-for-testing-overflow && : >g) >/dev/null 2>&1
    t72_run() {  # $1 = WIDTH
        (cd "$T72_REPO" && env NO_COLOR=1 WIDTH="$1" BRANCHNAME="feature/some-extremely-long-branch-name-for-testing-overflow" \
            CTX_USAGE="$USAGE_OK" GIT_WAIT_MS=1500 WREN_TS="$WREN_TS" TUI_STUB="$PI_DIR/tui-stub.mjs" \
            node --import "$PI_DIR/register.mjs" "$PI_DIR/harness.mjs" 2>/dev/null | head -1)
    }
    t72_narrow="$(t72_run 55)"    # 预算会掉到 16 地板以下 → 先丢时长
    t72_wide="$(t72_run 120)"     # 宽终端：时长应在
    t72_w="$(cjk_strip "$t72_narrow")"; t72_w="${t72_w%%$'\n'*}"
    if printf '%s' "$t72_narrow" | grep -qF "| pi" \
       && ! printf '%s' "$t72_narrow" | grep -qF " · " \
       && [[ "$t72_w" -le 55 ]] \
       && printf '%s' "$t72_wide" | grep -qF " · "; then
        pass T72 "line1 ladder drops duration first (${t72_w} <= 55, badge kept)"
    else
        fail T72 "narrow(w=${t72_w})=[$t72_narrow] wide=[$t72_wide]"
    fi
fi

# ============================================================
# T73: 行2 梯子逐段剔——顺序 TTFT → CH → CP；永不剔 ↑in↓out / ctx% / 模型名（设计 §4）
# ============================================================
if [[ "$TS_OK" -ne 1 ]]; then
    skip T73 "node with .ts type-stripping not available"
else
    T73_BR='[{"type":"compaction"},{"type":"message","message":{"role":"assistant","usage":{"input":743000,"output":117000,"cacheRead":19560000,"cacheWrite":0}}}]'
    t73_run() {  # $1 = WIDTH
        env NO_COLOR=1 WIDTH="$1" BRANCH="$T73_BR" TTFT_MS=12400 MSG_UPDATES=0 THINKING=xhigh \
            CTX_USAGE='{"tokens":284200,"contextWindow":1000000,"percent":28.42}' \
            WREN_TS="$WREN_TS" TUI_STUB="$PI_DIR/tui-stub.mjs" \
            node --import "$PI_DIR/register.mjs" "$PI_DIR/harness.mjs" 2>/dev/null | tail -1
    }
    # 梯子阀值随 TTFT_BUDGET 变（现 11 格）：全在 ≥ 81 / 丢TTFT 69-80 / 丢CH 60-68 / 丢CP ≤ 59
    t73_w90="$(t73_run 90)"; t73_w75="$(t73_run 75)"
    t73_w65="$(t73_run 65)"; t73_w55="$(t73_run 55)"
    t73_ok=1
    # 90：三段全在
    printf '%s' "$t73_w90" | grep -qF "TTFT 12s" || t73_ok=0
    printf '%s' "$t73_w90" | grep -qF "CH96.34%" || t73_ok=0
    printf '%s' "$t73_w90" | grep -qF "CP1" || t73_ok=0
    # 75：先丢 TTFT
    printf '%s' "$t73_w75" | grep -qE 'TTFT [0-9]' && t73_ok=0
    printf '%s' "$t73_w75" | grep -qF "CH96.34%" || t73_ok=0
    # 65：再丢 CH
    printf '%s' "$t73_w65" | grep -qF "CH96.34%" && t73_ok=0
    printf '%s' "$t73_w65" | grep -qF "CP1" || t73_ok=0
    # 55：再丢 CP
    printf '%s' "$t73_w55" | grep -qF "CP1" && t73_ok=0
    # 四档都不剔：账本头、ctx%、模型名
    for l in "$t73_w90" "$t73_w75" "$t73_w65" "$t73_w55"; do
        printf '%s' "$l" | grep -qF "↑743K ↓117K" || t73_ok=0
        printf '%s' "$l" | grep -qF "28.42%/1M" || t73_ok=0
        printf '%s' "$l" | grep -qF "claude-opus-5" || t73_ok=0
    done
    if [[ $t73_ok -eq 1 ]]; then
        pass T73 "line2 ladder drop order TTFT -> CH -> CP; core segments never dropped"
    else
        fail T73 "w90=[$t73_w90] w75=[$t73_w75] w65=[$t73_w65] w55=[$t73_w55]"
    fi
fi

# ============================================================
# T74: v7 改名迁移——install pi 时旧目标名 wren.ts 被识别为 wren 系并删除
# ============================================================
new_box
cp "$PI_PAYLOAD" "$PIEXT/wren.ts"   # 模拟旧版部署（wren 系副本）
run_wren install pi
if [[ "$WREN_EXIT" == "0" && ! -e "$PIEXT/wren.ts" && -f "$PIEXT/wren-pi.ts" ]] \
   && cmp -s "$PIEXT/wren-pi.ts" "$PI_PAYLOAD" \
   && printf '%s' "$WREN_OUT" | grep -qF "migrated"; then
    pass T74 "install pi migrates legacy wren.ts -> wren-pi.ts"
else
    fail T74 "exit=$WREN_EXIT out=[$WREN_OUT] files=[$(ls -A "$PIEXT")]"
fi

# ============================================================
# T75: qc TTFT 等待期保持上一轮旧值（ttft_ms 存量，与 cc/pi 同语义）
# ============================================================
new_box
printf '{"type":"user","timestamp":"2026-09-28T10:00:00Z","message":{"content":"a"}}\n' >"$BOX/tr75.jsonl"
printf '{"type":"assistant","timestamp":"2026-09-28T10:00:07.400Z","message":{"usage":{"input_tokens":100,"output_tokens":10,"cache_read_input_tokens":80}}}\n' >>"$BOX/tr75.jsonl"
# 新轮开窗：只有 user、没有 assistant（生成等待期的 transcript 形态）
printf '{"type":"user","timestamp":"2026-09-28T10:05:00Z","message":{"content":"b"}}\n' >>"$BOX/tr75.jsonl"
printf '{"cwd":"/tmp","model":{"display_name":"m"},"transcript_path":"%s"}' "$BOX/tr75.jsonl" \
    | NO_COLOR=1 WREN_CACHE_DIR="$BOX/q75" python3 "$QC_PAYLOAD" 2>/dev/null | tail -1 >"$BOX/q75a.txt"
# 对照：完全无配对记录（首个新会话等待期）→ 段隐藏
printf '{"type":"user","timestamp":"2026-09-28T11:00:00Z","message":{"content":"c"}}\n' >"$BOX/tr75b.jsonl"
printf '{"cwd":"/tmp","model":{"display_name":"m"},"transcript_path":"%s"}' "$BOX/tr75b.jsonl" \
    | NO_COLOR=1 WREN_CACHE_DIR="$BOX/q75b" python3 "$QC_PAYLOAD" 2>/dev/null | tail -1 >"$BOX/q75b.txt"
q75a="$(<"$BOX/q75a.txt")"; q75b="$(<"$BOX/q75b.txt")"
if printf '%s' "$q75a" | grep -qF "TTFT 7.4s" \
   && ! printf '%s' "$q75b" | grep -qE 'TTFT [0-9]'; then
    pass T75 "qc TTFT keeps previous turn value during wait; hidden when never paired"
else
    fail T75 "a=[$q75a] b=[$q75b]"
fi

# ============================================================
# T76: qc TTFT 等待期后新配对仍成功（turn_first_ts 不清空、比较判开）
#      round1 配对 → round2 只有 user（等待期，缓存里留着旧 turn_first_ts）
#      → 追加 round2 两条 assistant → 增量续读后 T 应为 round2 首片值，
#      第二条 assistant 不得改写（首片定值），也不得停留在 round1 旧值
# ============================================================
new_box
: >"$BOX/tr76.jsonl"
printf '{"type":"user","timestamp":"2026-09-28T10:00:00Z","message":{"content":"a"}}\n' >"$BOX/tr76.jsonl"
printf '{"type":"assistant","timestamp":"2026-09-28T10:00:07.400Z","message":{"usage":{"input_tokens":100,"output_tokens":10,"cache_read_input_tokens":80}}}\n' >>"$BOX/tr76.jsonl"
printf '{"type":"user","timestamp":"2026-09-28T10:05:00Z","message":{"content":"b"}}\n' >>"$BOX/tr76.jsonl"
run_qc76() {
    printf '{"cwd":"/tmp","model":{"display_name":"m"},"transcript_path":"%s"}' "$BOX/tr76.jsonl" \
        | NO_COLOR=1 WREN_CACHE_DIR="$BOX/q76" python3 "$QC_PAYLOAD" 2>/dev/null | tail -1
}
t76_wait="$(run_qc76)"   # 等待期：显示 round1 旧值 TTFT 7.4s
printf '{"type":"assistant","timestamp":"2026-09-28T10:05:03.100Z","message":{"usage":{"input_tokens":120,"output_tokens":5,"cache_read_input_tokens":90}}}\n' >>"$BOX/tr76.jsonl"
printf '{"type":"assistant","timestamp":"2026-09-28T10:05:09Z","message":{"usage":{"input_tokens":130,"output_tokens":6,"cache_read_input_tokens":95}}}\n' >>"$BOX/tr76.jsonl"
t76_done="$(run_qc76)"   # 增量续读：配对 round2 首片，第二条不改写
if printf '%s' "$t76_wait" | grep -qF "TTFT 7.4s" \
   && printf '%s' "$t76_done" | grep -qF "TTFT 3.1s" \
   && ! printf '%s' "$t76_done" | grep -qF "TTFT 7.4s" \
   && ! printf '%s' "$t76_done" | grep -qF "TTFT 9.0s"; then
    pass T76 "qc TTFT re-pairs after wait via retained turn_first_ts; first piece wins"
else
    fail T76 "wait=[$t76_wait] done=[$t76_done]"
fi

# ============================================================
# T77: 方案 B —— 轮进行中保留上一轮的已完成值（不闪空白、也不提前显示新值）
# ============================================================
if [[ "$TS_OK" -ne 1 ]]; then
    skip T77 "node with .ts type-stripping not available"
else
    t77_inflight="$(pi_ttft '6600,12400' '0|')"   # 次轮 turn_start 已发、首片未到
    t77_first="$(pi_ttft 6600 '')"                # 首轮进行中：无已完成轮
    if printf '%s' "$t77_inflight" | grep -qF "TTFT 6.6s" \
       && ! printf '%s' "$t77_inflight" | grep -qF "TTFT 12s" \
       && ! printf '%s' "$t77_first" | grep -qE 'TTFT [0-9]'; then
        pass T77 "inflight turn keeps last completed TTFT (no flash / no early value)"
    else
        fail T77 "inflight=[$t77_inflight] first=[$t77_first]"
    fi
fi

# ============================================================
# T78: 首片落地时才原子覆盖为新一轮值
# ============================================================
if [[ "$TS_OK" -ne 1 ]]; then
    skip T78 "node with .ts type-stripping not available"
else
    t78="$(pi_ttft '6600,12400' '0|0')"
    if printf '%s' "$t78" | grep -qF "TTFT 12s" && ! printf '%s' "$t78" | grep -qF "TTFT 6.6s"; then
        pass T78 "first chunk atomically replaces TTFT (TTFT 12s, old value gone)"
    else
        fail T78 "l2=[$t78]"
    fi
fi

# ============================================================
# T79: qc 行2 梯子不受色档影响（预算串必须无色）
#      无色宽 61 ≤ 80 → 三档都应保留 TTFT；若预算串混入 ANSI，
#      truecolor 虚高 ~23 格误丢 TTFT（历史 bug：宿主 T 值「被吃」真凶）
# ============================================================
new_box
: >"$BOX/tr77.jsonl"
printf '{"type":"user","timestamp":"2026-09-28T10:00:00Z","message":{"content":"a"}}\n' >"$BOX/tr77.jsonl"
printf '{"type":"assistant","timestamp":"2026-09-28T10:00:07.400Z","message":{"usage":{"input_tokens":52100,"output_tokens":236,"cache_read_input_tokens":47000}}}\n' >>"$BOX/tr77.jsonl"
run_qc77() {
    printf '{"cwd":"/tmp","model":{"display_name":"GLM-4.7"},"transcript_path":"%s","context_window":{"total_input_tokens":30000,"context_window_size":1000000,"used_percentage":3}}' "$BOX/tr77.jsonl" \
        | env -u COLORTERM COLUMNS=80 WREN_CACHE_DIR="$BOX/q77" "$@" python3 "$QC_PAYLOAD" 2>/dev/null \
        | tail -1 | sed $'s/\x1b\\[[0-9;]*m//g'
}
t77_nc="$(NO_COLOR=1 run_qc77)"
t77_tc="$(COLORTERM=truecolor run_qc77)"
t77_256="$(run_qc77)"
if [ "$t77_nc" = "$t77_tc" ] && [ "$t77_nc" = "$t77_256" ] \
   && printf '%s' "$t77_nc" | grep -qF "TTFT 7.4s" \
   && printf '%s' "$t77_nc" | grep -qF "CH90.21%"; then
    pass T79 "qc line2 ladder color-agnostic; TTFT survives truecolor at width 80"
else
    fail T79 "nc=[$t77_nc] tc=[$t77_tc] 256=[$t77_256]"
fi

# ============================================================
# T80: 行2 梯子三宿主同构——同 COLUMNS 下三侧丢同一组段（设计 §7「梯子同构」）
# ============================================================
if [[ "$TS_OK" -ne 1 ]]; then
    skip T80 "node with .ts type-stripping not available"
else
    new_box
    # 匹配夹具：三侧同一组数字（input 743K / output 117K / R19.6M → CH96.34%；
    # postTokens 284200 → 28.42%/1M；CP1；user→assistant 12.4s → TTFT 12s）
    T80_TR="$BOX/tr80.jsonl"
    cat >"$T80_TR" <<'EOF2'
{"type":"user","timestamp":"2026-09-19T04:18:46.065Z","message":{"content":"hi"}}
{"type":"assistant","timestamp":"2026-09-19T04:18:58.465Z","message":{"usage":{"input_tokens":743000,"output_tokens":117000,"cache_read_input_tokens":19560000,"cache_creation_input_tokens":0}}}
{"type":"system","subtype":"compact_boundary","isSidechain":false,"compactMetadata":{"trigger":"manual","postTokens":284200}}
EOF2
    T80_BR='[{"type":"compaction"},{"type":"message","message":{"role":"assistant","usage":{"input":743000,"output":117000,"cacheRead":19560000,"cacheWrite":0}}}]'
    t80_sig() {  # 从行2 抽签名：T=TTFT / C=CH / P=CP
        local s=""
        printf '%s' "$1" | grep -qE 'TTFT [0-9]' && s="${s}T" || s="${s}-"
        printf '%s' "$1" | grep -qF "CH96.34%" && s="${s}C" || s="${s}-"
        printf '%s' "$1" | grep -qF "CP1" && s="${s}P" || s="${s}-"
        printf '%s' "$s"
    }
    t80_ok=1; t80_seen=""; t80_err=""
    for w in 90 81 80 70 65 55; do
        cc80=$(printf '{"cwd":"/tmp","model":{"display_name":"claude-opus-5"},"effort":{"level":"xhigh"},"context_window":{"context_window_size":1000000},"transcript_path":"%s"}' "$T80_TR" \
            | NO_COLOR=1 COLUMNS=$w WREN_CACHE_DIR="$BOX/c80-$w" python3 "$CC_PAYLOAD" 2>/dev/null | tail -1)
        qc80=$(printf '{"cwd":"/tmp","model":{"display_name":"claude-opus-5"},"effort":"xhigh","context_window":{"context_window_size":1000000},"transcript_path":"%s"}' "$T80_TR" \
            | NO_COLOR=1 COLUMNS=$w WREN_CACHE_DIR="$BOX/q80-$w" python3 "$QC_PAYLOAD" 2>/dev/null | tail -1)
        pi80=$(env NO_COLOR=1 WIDTH=$w BRANCH="$T80_BR" TTFT_MS=12400 MSG_UPDATES=0 THINKING=xhigh \
            CTX_USAGE='{"tokens":284200,"contextWindow":1000000,"percent":28.42}' \
            WREN_TS="$WREN_TS" TUI_STUB="$PI_DIR/tui-stub.mjs" \
            node --import "$PI_DIR/register.mjs" "$PI_DIR/harness.mjs" 2>/dev/null | tail -1)
        t80_a="$(t80_sig "$cc80")"; t80_b="$(t80_sig "$qc80")"; t80_c="$(t80_sig "$pi80")"
        [[ "$t80_a" == "$t80_b" && "$t80_b" == "$t80_c" ]] || { t80_ok=0; t80_err="$t80_err[W=$w cc=$t80_a qc=$t80_b pi=$t80_c]"; }
        t80_seen="$t80_seen $t80_a"
    done
    # 三侧同签名之外，再钉住丢序与阀值：90/81→TCP 80/70→-CP 65→--P 55→---
    # （81 是「全在」的临界点：预算常量差 1 格就会在这一档暴露）
    if [[ $t80_ok -eq 1 && "$t80_seen" == " TCP TCP -CP -CP --P ---" ]]; then
        pass T80 "3-host line2 ladder identical & ordered (w90/81/80/70/65/55:$t80_seen)"
    else
        fail T80 "seen:[$t80_seen] mismatch:$t80_err"
    fi
fi

# ============================================================
# T81: v8 迁移——install cc 时旧目标 $PREFIX/wren-cc 被识别为 wren 系并删除，
#      新目标落在 settings 同目录（绝对路径写进 statusLine）
# ============================================================
new_box
mkdir -p "$BIN"
cp "$CC_PAYLOAD" "$BIN/wren-cc"     # 模拟旧版部署（wren 系副本，旧落点）
run_wren install cc
if [[ "$WREN_EXIT" == "0" && ! -e "$BIN/wren-cc" && -f "$CLAUDE/wren-cc" ]] \
   && cmp -s "$CLAUDE/wren-cc" "$CC_PAYLOAD" \
   && [[ "$(json_field "$SETTINGS" 'd["statusLine"]["command"]')" == "$CLAUDE/wren-cc" ]] \
   && printf '%s' "$WREN_OUT" | grep -qF "migrated"; then
    pass T81 "install cc migrates legacy \$PREFIX/wren-cc, writes absolute command"
else
    fail T81 "exit=$WREN_EXIT out=[$WREN_OUT] bin=[$(ls -A "$BIN")]"
fi

# ============================================================
# T82: 对照——非 wren 系的同名文件不动（只告警）
# ============================================================
new_box
mkdir -p "$BIN"
printf '#!/bin/sh\necho foreign\n' >"$BIN/wren-cc"
run_wren install cc
if [[ "$WREN_EXIT" == "0" ]] && grep -qF "foreign" "$BIN/wren-cc" 2>/dev/null \
   && printf '%s' "$WREN_ERR" | grep -qi "not a wren payload"; then
    pass T82 "foreign \$PREFIX/wren-cc left alone"
else
    fail T82 "foreign file gone/changed: [$(cat "$BIN/wren-cc" 2>/dev/null)]"
fi

# ============================================================
# T83: TTFT 四档着色——三侧同值同色；探针含「原始 ms 档界」与「舍入后真档界」
# ============================================================
new_box
# 判据已改为显示值 ttft_secs（问题 3），所以真档界在舍入后：4950 / 20500 / 60500。
# 探针分两组：
#   a) 原始 ms 档界 5000/20000/60000 — 新语义下必须跟「显示同值」同档（问题 3 回归锚）
#   b) 真档界 ±10ms — 钉住阈值确实落在舍入点上。
#      （曾用 ±3ms，实测 harness 两个 Date.now() 间抖动 1~3ms，20497 会跳到 20500 而翻档；
#       ±10ms 下抖动不可达 20500，探针才是确定性的）
T83_PROBES="3000:green 4940:green 4960:fg 4999:fg 5000:fg 12000:fg 19999:fg 20000:fg \
20001:fg 20490:fg 20510:yellow 30000:yellow 59999:yellow 60000:yellow 60001:yellow \
60490:yellow 60510:red 90000:red"
t83_code() {
    case "$1" in
        green)  printf '38;2;80;250;123' ;;
        fg)     printf '38;2;248;248;242' ;;
        yellow) printf '38;2;241;250;140' ;;
        red)    printf '38;2;255;85;85' ;;
    esac
}
# 抽「TTFT 段自己的」文本与色码：取紧邻 "TTFT " 之前的那个转义码。
# 不能用整行 grep —— ctx% 可能同色（0.5% 也是绿），那样测不出「色配错段」。
t83_extract() {
    python3 -c "
import re, sys
m = re.search(r'\x1b\[([0-9;]+)m(TTFT [^\x1b]+)', sys.stdin.read())
print((m.group(2).strip() + '|' + m.group(1)) if m else '无|无')
"
}
t83_ok=1
t83_fixture() {  # $1 = ttft ms，$2 = 输出文件；用 python 生成合法 ISO 时间戳
    python3 - "$1" "$2" <<'PYEOF'
import json, sys
ms = int(sys.argv[1])
from datetime import datetime, timedelta, timezone
base = datetime(2026, 9, 28, 10, 0, 0, tzinfo=timezone.utc)
t0 = base.isoformat().replace("+00:00", "Z")
t1 = (base + timedelta(milliseconds=ms)).isoformat().replace("+00:00", "Z")
with open(sys.argv[2], "w") as fh:
    fh.write(json.dumps({"type": "user", "timestamp": t0, "message": {"content": "a"}}) + "\n")
    fh.write(json.dumps({"type": "assistant", "timestamp": t1,
                         "message": {"usage": {"input_tokens": 100, "output_tokens": 10,
                                               "cache_read_input_tokens": 80}}}) + "\n")
PYEOF
}
: >"$BOX/t83_table.txt"
for pair in $T83_PROBES; do
    ms="${pair%%:*}"; tier="${pair##*:}"; want="$(t83_code "$tier")"
    t83_fixture "$ms" "$BOX/t83_$ms.jsonl"
    cc_x="$(printf '{"cwd":"/tmp","model":{"display_name":"m"},"transcript_path":"%s"}' "$BOX/t83_$ms.jsonl" \
        | COLORTERM=truecolor WREN_CACHE_DIR="$BOX/c83_$ms" python3 "$CC_PAYLOAD" 2>/dev/null \
        | tail -1 | t83_extract)"
    qc_x="$(printf '{"cwd":"/tmp","model":{"display_name":"m"},"transcript_path":"%s"}' "$BOX/t83_$ms.jsonl" \
        | COLORTERM=truecolor WREN_CACHE_DIR="$BOX/q83_$ms" python3 "$QC_PAYLOAD" 2>/dev/null \
        | tail -1 | t83_extract)"
    [[ "${cc_x#*|}" == "$want" ]] || { t83_ok=0; echo "  cc ms=$ms 期望=${tier}(${want}) 实得=[$cc_x]" >&2; }
    [[ "$cc_x" == "$qc_x" ]] || { t83_ok=0; echo "  cc/qc 不同值同色 ms=$ms cc=[$cc_x] qc=[$qc_x]" >&2; }
    printf '%s %s\n' "$ms" "$cc_x" >>"$BOX/t83_table.txt"
done
if [[ $t83_ok -eq 1 ]]; then
    pass T83 "cc/qc TTFT 4-tier colour: 18 probes (raw-ms + rounded boundaries), text+code identical"
else
    fail T83 "tier colour mismatch (see stderr)"
fi

# ============================================================
# T84: pi 侧同表 + 与 cc 逐探针同值同色（读 T83 写下的表）
# ============================================================
if [[ "$TS_OK" -ne 1 ]]; then
    skip T84 "node with .ts type-stripping not available"
else
    t84_ok=1
    # 必须绕开 run_pi（它硬编 NO_COLOR=1，色码不会出现），直接调 harness；取行2
    t84_run() {
        env COLOR_MODE=truecolor BRANCH='[]' CTX_USAGE="$USAGE_OK" WREN_TS="$WREN_TS" \
            TUI_STUB="$PI_DIR/tui-stub.mjs" TTFT_MS="$1" MSG_UPDATES=0 \
            node --import "$PI_DIR/register.mjs" "$PI_DIR/harness.mjs" 2>/dev/null | tail -1
    }
    while read -r ms ccx; do
        want_text="${ccx%%|*}"; want_code="${ccx#*|}"
        pi_x="$(t84_run "$ms" | t83_extract)"
        pi_text="${pi_x%%|*}"; pi_code="${pi_x#*|}"
        [[ "$pi_code" == "$want_code" ]] || { t84_ok=0; echo "  pi ms=$ms 色码 期望=$want_code 实得=[$pi_x]" >&2; }
        [[ "$pi_text" == "$want_text" ]] || { t84_ok=0; echo "  pi ms=$ms 显示 期望=$want_text 实得=[$pi_text]" >&2; }
    done <"$BOX/t83_table.txt"
    if [[ $t84_ok -eq 1 ]]; then
        pass T84 "pi TTFT 4-tier colour + display identical to cc/qc, same probe table"
    else
        fail T84 "pi tier colour/text differs from cc/qc (see stderr)"
    fi
fi

# ============================================================
# T85: TTFT 边界探针（盲区守门：T83/T84 只测档中值，<= 改 < 注入 bug 仍绿）
#      判据 = ttft_secs（显示值）：
#        绿 <5.0s / 白 ≤20s / 黄 ≤60s / 红 >60s（.5s 处换档：20499 白、20500 黄）
#      共享值三侧同值同色；±1ms 边界串（4999/5000、19999/20000/20001、
#      59999/60000/60001）断言全部同档——防边界归属回退成原始 ms 判定。
#      pi 侧事件流有 ε（Date.now 粒度），只用 ε 单调安全（≥）的边：20500/60500。
# ============================================================
new_box
t85_extract() {  # 从渲染行2 抽 "code TTFT 文本"
    cat -v | LC_ALL=C grep -o '38;2;[0-9;]*mTTFT [^ ]*' | sed 's/\^\[\[0m$//' | tail -1
}
t85_qc() {  # $1 = ms → "code TTFT x"
    t83_fixture "$1" "$BOX/t85_$1.jsonl"
    printf '{"cwd":"/tmp","model":{"display_name":"m"},"transcript_path":"%s"}' "$BOX/t85_$1.jsonl" \
        | COLORTERM=truecolor WREN_CACHE_DIR="$BOX/c85_$1" python3 "$QC_PAYLOAD" 2>/dev/null | tail -1 | t85_extract
}
t85_cc() {
    t83_fixture "$1" "$BOX/t85c_$1.jsonl"
    printf '{"cwd":"/tmp","model":{"display_name":"m"},"transcript_path":"%s"}' "$BOX/t85c_$1.jsonl" \
        | COLORTERM=truecolor WREN_CACHE_DIR="$BOX/c85c_$1" python3 "$CC_PAYLOAD" 2>/dev/null | tail -1 | t85_extract
}
t85_pi() {
    env COLOR_MODE=truecolor BRANCH='[]' CTX_USAGE="$USAGE_OK" WREN_TS="$WREN_TS" \
        TUI_STUB="$PI_DIR/tui-stub.mjs" TTFT_MS="$1" MSG_UPDATES=0 \
        node --import "$PI_DIR/register.mjs" "$PI_DIR/harness.mjs" 2>/dev/null | tail -1 | t85_extract
}
t85_ok=1
t85_expect() {  # $1 = ms → 期望 "code TTFT 文本"
    case "$1" in
        4700)  echo "38;2;80;250;123mTTFT 4.7s" ;;
        4949)  echo "38;2;80;250;123mTTFT 4.9s" ;;
        4999)  echo "38;2;248;248;242mTTFT 5.0s" ;;
        5000)  echo "38;2;248;248;242mTTFT 5.0s" ;;
        19999) echo "38;2;248;248;242mTTFT 20s" ;;
        20000) echo "38;2;248;248;242mTTFT 20s" ;;
        20001) echo "38;2;248;248;242mTTFT 20s" ;;
        20499) echo "38;2;248;248;242mTTFT 20s" ;;
        20500) echo "38;2;241;250;140mTTFT 21s" ;;
        59999) echo "38;2;241;250;140mTTFT 1m00s" ;;
        60000) echo "38;2;241;250;140mTTFT 1m00s" ;;
        60001) echo "38;2;241;250;140mTTFT 1m00s" ;;
        60499) echo "38;2;241;250;140mTTFT 1m00s" ;;
        60500) echo "38;2;255;85;85mTTFT 1m01s" ;;
        61000) echo "38;2;255;85;85mTTFT 1m01s" ;;
    esac
}
# 共享值：三侧都要同值同色
for ms in 4999 5000 19999 20000 20001 20500 59999 60000 60001 60500; do
    want="$(t85_expect "$ms")"
    q="$(t85_qc "$ms")"; c="$(t85_cc "$ms")"; p="$(t85_pi "$ms")"
    if [[ "$q" != "$want" || "$c" != "$want" || "$p" != "$want" ]]; then
        t85_ok=0; echo "  ms=$ms want=[$want] qc=[$q] cc=[$c] pi=[$p]" >&2
    fi
done
# 精确边（±1ms / .5s 换档点）：qc/cc transcript 数学确定，可测 ε 敏感侧
for ms in 4949 20499 60499; do
    want="$(t85_expect "$ms")"
    q="$(t85_qc "$ms")"; c="$(t85_cc "$ms")"
    if [[ "$q" != "$want" || "$c" != "$want" ]]; then
        t85_ok=0; echo "  edge ms=$ms want=[$want] qc=[$q] cc=[$c]" >&2
    fi
done
# pi 补绿/红档 ε 安全见证
for ms in 4700 61000; do
    want="$(t85_expect "$ms")"
    p="$(t85_pi "$ms")"
    if [[ "$p" != "$want" ]]; then
        t85_ok=0; echo "  pi ms=$ms want=[$want] pi=[$p]" >&2
    fi
done
if [[ $t85_ok -eq 1 ]]; then
    pass T85 "TTFT boundary probes: display-synced tiers, +/-1ms bands same tier, 3-side identical"
else
    fail T85 "boundary mismatch (see stderr)"
fi

# ============================================================
# opencode（wren-oc.tsx + wren-oc.ts，TUI 插件）——
# 安装器部分在沙箱里真跑；渲染部分用 node 直接跑纯函数核心（无宿主依赖）
# ============================================================
OC_CORE_TS="$OC_CORE_PAYLOAD"
OCHARN="$TMPROOT/oc-harness.mjs"
cat >"$OCHARN" <<'EOF'
const { buildLines } = await import(process.env.OC_CORE)
const lines = buildLines(JSON.parse(process.env.OC_FIXTURE))
lines.forEach((segs, i) => {
  console.log(`L${i + 1}=${segs.map((s) => s.text).join("")}`)
  for (const s of segs) if (s.text.trim()) console.log(`T${i + 1}:${s.text}=${s.tone}`)
})
EOF
# oc_render <fixture-json> → 每个段一行：`L1=<明文>` / `T1:<段文本>=<色名>`
oc_render() {
    OC_CORE="$OC_CORE_TS" OC_FIXTURE="$1" node "$OCHARN" 2>/dev/null
}
# 最小 payload：无会话、无 git、无窗口
OC_MIN='{"width":120,"cwd":"/tmp","home":"/home/u","branch":null,"head":"","ab":"","added":0,"modified":0,"deleted":0,"herdr":"","durationMs":null,"inputTokens":0,"outputTokens":0,"cacheRead":0,"cacheWrite":0,"compactions":0,"ctxPercent":null,"ctxWindow":0,"model":"Test-Model","thinking":"","ttftMs":null}'
# 满配 payload：git 脏 + herdr + 时长 + token/缓存/压缩 + 窗口
OC_FULL='{"width":120,"cwd":"/home/u/Code/proj","home":"/home/u","branch":"main","head":"main","ab":" ↑1↓2","added":4,"modified":2,"deleted":1,"herdr":"w1:t2:p3","durationMs":3900000,"inputTokens":12000,"outputTokens":3000,"cacheRead":1200000,"cacheWrite":0,"compactions":2,"ctxPercent":8.4,"ctxWindow":200000,"model":"claude-opus-5","thinking":"high","ttftMs":6600}'

# ============================================================
# T86: install oc → 两个 payload 就位 + 新建 tui.json 并写入相对 spec
# ============================================================
new_box
run_wren install oc
if [[ "$WREN_EXIT" == "0" ]] \
   && cmp -s "$OC/plugins/wren-oc.tsx" "$OC_PAYLOAD" \
   && cmp -s "$OC/plugins/wren-oc.ts" "$OC_CORE_PAYLOAD" \
   && [[ "$(json_field "$OCCONF" "d['plugin']")" == "['./plugins/wren-oc.tsx']" ]]; then
    pass T86 "install oc: payloads copied + plugin spec written to tui.json"
else
    fail T86 "exit=$WREN_EXIT files=[$(ls -A "$OC" 2>/dev/null | tr '\n' ' ')] conf=[$(cat "$OCCONF" 2>/dev/null)]"
fi

# ============================================================
# T87: 幂等——重复 install oc 不重复追加 spec，payload 刷成最新副本
# ============================================================
new_box
run_wren install oc
printf '// 手改过的旧副本\n' >"$OC/plugins/wren-oc.tsx"
run_wren install oc
spec_n="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['plugin'].count('./plugins/wren-oc.tsx'))" "$OCCONF" 2>/dev/null)"
if [[ "$WREN_EXIT" == "0" && "$spec_n" == "1" ]] && cmp -s "$OC/plugins/wren-oc.tsx" "$OC_PAYLOAD"; then
    pass T87 "install oc idempotent: single spec entry, payload refreshed"
else
    fail T87 "exit=$WREN_EXIT spec_n=[$spec_n]"
fi

# ============================================================
# T88: JSONC 保真——注释/其他键/其他插件条目原样保留，卸载后逐字还原
# ============================================================
new_box
cat >"$OCCONF" <<'EOF2'
{
  // 我自己的注释，不能被吞
  "theme": "dracula",
  "plugin": [
    "./plugins/other.tsx", // 尾注也留着
    "./plugins/two.tsx"
  ],
  "keybinds": { "leader": "ctrl+x" } // 行尾注释
}
EOF2
cp "$OCCONF" "$BOX/before88"
run_wren install oc
inst_ok=1
printf '%s' "$(cat "$OCCONF")" | grep -qF "// 我自己的注释，不能被吞" || inst_ok=0
printf '%s' "$(cat "$OCCONF")" | grep -qF "// 尾注也留着" || inst_ok=0
printf '%s' "$(cat "$OCCONF")" | grep -qF '"./plugins/other.tsx"' || inst_ok=0
printf '%s' "$(cat "$OCCONF")" | grep -qF '"./plugins/two.tsx"' || inst_ok=0
printf '%s' "$(cat "$OCCONF")" | grep -qF '"./plugins/wren-oc.tsx"' || inst_ok=0
run_wren uninstall oc
diff -q "$BOX/before88" "$OCCONF" >/dev/null || inst_ok=0
if [[ $inst_ok -eq 1 ]]; then
    pass T88 "JSONC comments/keys/other plugins preserved; uninstall restores bytes"
else
    fail T88 "after install+uninstall: [$(cat "$OCCONF")]"
fi

# ============================================================
# T89: 只有 tui.jsonc（没有 tui.json）时接管 jsonc，不新建 tui.json
#      （不显式设 OPENCODE_TUI_CONFIG，走默认路径推导）
# ============================================================
new_box
rm -f "$OCCONF"
printf '{\n  "plugin": []\n}\n' >"$OC/tui.jsonc"
env NO_COLOR=1 PREFIX="$BIN" PI_EXT_DIR="$PIEXT" CLAUDE_CONFIG_DIR="$CLAUDE" CLAUDE_SETTINGS="$SETTINGS" \
    QODER_CONFIG_DIR="$QODER" QODER_SETTINGS="$QODER_SETTINGS" OPENCODE_CONFIG_DIR="$OC" \
    "$WREN" install oc >"$BOX/out89.txt" 2>"$BOX/err89.txt"
if [[ "$?" == "0" ]] \
   && grep -qF '"./plugins/wren-oc.tsx"' "$OC/tui.jsonc" \
   && [[ ! -e "$OC/tui.json" ]]; then
    pass T89 "tui.jsonc taken over when tui.json is absent (no new file)"
else
    fail T89 "jsonc=[$(cat "$OC/tui.jsonc" 2>/dev/null)] tui.json=[$(ls "$OC" | tr '\n' ' ')]"
fi

# ============================================================
# T90: uninstall oc——只摘自己的 spec + 删自己的 payload，其他插件不动；再执行幂等
# ============================================================
new_box
cat >"$OCCONF" <<'EOF2'
{
  "plugin": ["./plugins/other.tsx"]
}
EOF2
run_wren install oc
run_wren uninstall oc
first_out="$WREN_OUT"
if [[ "$WREN_EXIT" == "0" ]] \
   && [[ "$(json_field "$OCCONF" "d['plugin']")" == "['./plugins/other.tsx']" ]] \
   && [[ ! -e "$OC/plugins/wren-oc.tsx" && ! -e "$OC/plugins/wren-oc.ts" ]]; then
    run_wren uninstall oc
    if [[ "$WREN_EXIT" == "0" ]] && printf '%s' "$WREN_OUT" | grep -qF "left alone"; then
        pass T90 "uninstall oc removes only our spec/payloads; second run idempotent"
    else
        fail T90 "second run exit=$WREN_EXIT out=[$WREN_OUT]"
    fi
else
    fail T90 "first run exit=$WREN_EXIT conf=[$(cat "$OCCONF")] files=[$(ls -A "$OC/plugins" 2>/dev/null | tr '\n' ' ')] out=[$first_out]"
fi

# ============================================================
# T91: 被改过的 payload 不删（与 cc/pi 同口径），但 spec 仍摘掉
# ============================================================
new_box
run_wren install oc
printf '// 用户手改\n' >"$OC/plugins/wren-oc.tsx"
run_wren uninstall oc
if [[ "$WREN_EXIT" == "0" ]] \
   && [[ -f "$OC/plugins/wren-oc.tsx" ]] \
   && printf '%s' "$WREN_OUT" | grep -qF "left alone" \
   && ! grep -qF 'wren-oc.tsx' "$OCCONF"; then
    pass T91 "modified oc payload left alone; spec still removed from tui.json"
else
    fail T91 "exit=$WREN_EXIT files=[$(ls -A "$OC/plugins" | tr '\n' ' ')] conf=[$(cat "$OCCONF")]"
fi

# ============================================================
# T92: 配置目录不可写 → 预检挡住，零副作用（不装 payload、不建配置）
# ============================================================
if [[ "$(id -u)" == "0" ]]; then
    skip T92 "running as root; read-only dir is not enforced"
else
    new_box
    RO92="$BOX/ro92"; mkdir -p "$RO92"; chmod 555 "$RO92"
    env NO_COLOR=1 PREFIX="$BIN" PI_EXT_DIR="$PIEXT" CLAUDE_CONFIG_DIR="$CLAUDE" CLAUDE_SETTINGS="$SETTINGS" \
        QODER_CONFIG_DIR="$QODER" QODER_SETTINGS="$QODER_SETTINGS" \
        OPENCODE_CONFIG_DIR="$RO92" OPENCODE_TUI_CONFIG="$RO92/tui.json" \
        "$WREN" install oc >"$BOX/out92.txt" 2>"$BOX/err92.txt"
    E92=$?
    chmod 755 "$RO92"
    if [[ "$E92" == "1" ]] && [[ -z "$(ls -A "$RO92")" ]]; then
        pass T92 "unwritable opencode config dir -> exit 1, zero side effects"
    else
        fail T92 "exit=$E92 ro=[$(ls -A "$RO92" | tr '\n' ' ')] err=[$(cat "$BOX/err92.txt")]"
    fi
fi

# ============================================================
# T93: 读不懂的 tui.json（顶层数组 / 数组未闭合）→ exit 1，文件与 payload 都不碰
# ============================================================
new_box
printf '["./plugins/other.tsx"]\n' >"$OCCONF"
cp "$OCCONF" "$BOX/before93a"
run_wren install oc
e93a=$WREN_EXIT
printf '{ "plugin": [\n' >"$OCCONF"
cp "$OCCONF" "$BOX/before93b"
run_wren install oc
e93b=$WREN_EXIT
if [[ "$e93a" == "1" && "$e93b" == "1" ]] && [[ ! -e "$OC/plugins" ]] \
   && grep -qF '"./plugins/other.tsx"' "$BOX/before93a" && ! printf '%s' "$(cat "$BOX/before93b")" | grep -qF 'wren-oc'; then
    pass T93 "malformed tui.json -> exit 1, no payload installed, file untouched"
else
    fail T93 "a=$e93a b=$e93b plugins=[$(ls -A "$OC" 2>/dev/null | tr '\n' ' ')]"
fi

# ============================================================
# T94: target 别名与非法 target（别名只多不少：opencode == oc）
# ============================================================
new_box
run_wren install opencode
alias_ok=$WREN_EXIT
run_wren install oc9
bad_exit=$WREN_EXIT
if [[ "$alias_ok" == "0" ]] && grep -qF '"./plugins/wren-oc.tsx"' "$OCCONF" \
   && [[ "$bad_exit" == "2" ]] && grep -qF "unsupported target" "$BOX/err.txt"; then
    pass T94 "install opencode aliases oc; unknown target -> exit 2"
else
    fail T94 "alias=$alias_ok bad=$bad_exit err=[$(cat "$BOX/err.txt")]"
fi

# ============================================================
# T95: install all / uninstall all 把四个宿主都接上、都摘干净
# ============================================================
new_box
run_wren install all
inst_all=1
[[ -f "$CLAUDE/wren-cc" ]] || inst_all=0
[[ -f "$PIEXT/wren-pi.ts" ]] || inst_all=0
[[ -f "$QODER/wren-qc.py" ]] || inst_all=0
[[ -f "$OC/plugins/wren-oc.tsx" ]] || inst_all=0
[[ "$(json_field "$SETTINGS" "d['statusLine']['command']")" == "$CLAUDE/wren-cc" ]] || inst_all=0
[[ "$(json_field "$QODER_SETTINGS" "d['statusLine']['command']")" == "$QODER/wren-qc.py" ]] || inst_all=0
grep -qF '"./plugins/wren-oc.tsx"' "$OCCONF" || inst_all=0
run_wren uninstall all
un_all=1
[[ -e "$CLAUDE/wren-cc" || -e "$PIEXT/wren-pi.ts" || -e "$QODER/wren-qc.py" || -e "$OC/plugins/wren-oc.tsx" ]] && un_all=0
grep -qF 'wren-oc.tsx' "$OCCONF" && un_all=0
[[ "$(json_field "$SETTINGS" "d.get('statusLine')")" == "None" ]] || un_all=0
if [[ $inst_all -eq 1 && $un_all -eq 1 ]]; then
    pass T95 "install all wires 4 hosts; uninstall all unwires them"
else
    fail T95 "install_all=$inst_all uninstall_all=$un_all claude=[$(ls -A "$CLAUDE" | tr '\n' ' ')] oc=[$(ls -A "$OC" | tr '\n' ' ')] conf=[$(cat "$OCCONF" 2>/dev/null)]"
fi

# ============================================================
# T96: oc 最小 payload → 两行 + oc 徽标，不无中生有
# ============================================================
if [[ "$TS_OK" -ne 1 ]]; then
    skip T96 "node with .ts type-stripping not available"
else
    t96="$(oc_render "$OC_MIN")"
    if [[ "$(printf '%s' "$t96" | grep -c '^L')" == "2" ]] \
       && printf '%s' "$t96" | grep -qxF "L1=/tmp | oc" \
       && printf '%s' "$t96" | grep -qxF "L2=↑0 ↓0 | R0 | Test-Model"; then
        pass T96 "oc minimal payload: 2 lines, oc badge, no invented segments"
    else
        fail T96 "out=[$(printf '%s' "$t96" | tr '\n' '~')]"
    fi
fi

# ============================================================
# T97: oc 满配 payload → 行1 git/herdr/时长，行2 token/CH/CP/ctx/模型·思考
#      + 999_500 不得渲染成 1000K（与 cc/pi 同款守门）
# ============================================================
if [[ "$TS_OK" -ne 1 ]]; then
    skip T97 "node with .ts type-stripping not available"
else
    t97="$(oc_render "$OC_FULL")"
    t97m="$(oc_render '{"width":120,"cwd":"/tmp","home":"/tmp","branch":null,"head":"","ab":"","added":0,"modified":0,"deleted":0,"herdr":"","durationMs":null,"inputTokens":999500,"outputTokens":300,"cacheRead":0,"cacheWrite":0,"compactions":0,"ctxPercent":null,"ctxWindow":0,"model":"m","thinking":"","ttftMs":null}')"
    if printf '%s' "$t97" | grep -qxF "L1=~/Code/proj | main ↑1↓2 +4 ~1 ✱2 | w1:t2:p3 | oc · 1h5m" \
       && printf '%s' "$t97" | grep -qxF "L2=↑12K ↓3K | R1.2M CH99.01% CP2 | 8.40%/200K TTFT 6.6s | claude-opus-5 · high" \
       && printf '%s' "$t97m" | grep -qxF "L2=↑1.0M ↓300 | R0 | m" \
       && ! printf '%s' "$t97m" | grep -qF "1000K"; then
        pass T97 "oc full payload matches wren layout; 999_500 -> 1.0M"
    else
        fail T97 "full=[$(printf '%s' "$t97" | tr '\n' '~')] fmt=[$(printf '%s' "$t97m" | tr '\n' '~')]"
    fi
fi

# ============================================================
# T98: oc 行2 梯子丢弃顺序 TTFT → CH → CP；头/ctx%/模型名永不剔
# ============================================================
if [[ "$TS_OK" -ne 1 ]]; then
    skip T98 "node with .ts type-stripping not available"
else
    t98_ok=1
    drop_ttft=0 drop_ch=0 drop_cp=0
    for w in $(seq 120 -1 30); do
        body="${OC_FULL/\"width\":120/\"width\":$w}"
        out="$(oc_render "$body")"
        l2="$(printf '%s' "$out" | grep '^L2=')"
        printf '%s' "$l2" | grep -qF "TTFT" || { [[ $drop_ttft -eq 0 ]] && drop_ttft=$w; }
        printf '%s' "$l2" | grep -qF "CH" || { [[ $drop_ch -eq 0 ]] && drop_ch=$w; }
        printf '%s' "$l2" | grep -qF "CP" || { [[ $drop_cp -eq 0 ]] && drop_cp=$w; }
        # 核心段与模型名（粉）在梯子生效的宽度区间内不许消失（与 pi T73 同口径）
        case "$w" in 90|81|80|70|65|55)
            printf '%s' "$out" | grep -qF "↑12K ↓3K" || t98_ok=0
            printf '%s' "$out" | grep -qF "R1.2M" || t98_ok=0
            printf '%s' "$out" | grep -qF "8.40%/200K" || t98_ok=0
            printf '%s' "$out" | grep -qF "T2:claude-opus-5=pink" || t98_ok=0
            ;;
        esac
    done
    if [[ $t98_ok -eq 1 && $drop_ttft -gt 0 && $drop_ch -gt 0 && $drop_cp -gt 0 ]] \
       && [[ $drop_ttft -gt $drop_ch && $drop_ch -gt $drop_cp ]]; then
        pass T98 "oc line2 ladder: TTFT($drop_ttft) -> CH($drop_ch) -> CP($drop_cp); cores never dropped"
    else
        fail T98 "ok=$t98_ok drop_ttft=$drop_ttft drop_ch=$drop_ch drop_cp=$drop_cp"
    fi
fi

# ============================================================
# T99: oc 极端 CJK（长中文路径 + 长中文分支）两行都不超宽（按显示格计）
# ============================================================
if [[ "$TS_OK" -ne 1 ]]; then
    skip T99 "node with .ts type-stripping not available"
else
    CJK99='{"width":80,"cwd":"/home/u/中文项目目录名称很长的十六个汉字/另一个很长的中文目录名称十六个汉字/最后一级超长中文目录名称十六个字","home":"/home/u","branch":"二十四字符分支名称测试用abcdefghijklmnop","head":"main","ab":" ↑0↓0","added":0,"modified":0,"deleted":0,"herdr":"","durationMs":null,"inputTokens":1000,"outputTokens":100,"cacheRead":1000,"cacheWrite":0,"compactions":0,"ctxPercent":50,"ctxWindow":200000,"model":"m","thinking":"high","ttftMs":6600}'
    t99="$(oc_render "$CJK99")"
    t99_l1="$(printf '%s' "$t99" | grep '^L1=' | sed 's/^L1=//')"
    t99_l2="$(printf '%s' "$t99" | grep '^L2=' | sed 's/^L2=//')"
    w1="$(cjk_strip "$t99_l1")"; w1="${w1%%$'\n'*}"
    w2="$(cjk_strip "$t99_l2")"; w2="${w2%%$'\n'*}"
    if [[ -n "$t99_l1" && -n "$t99_l2" ]] && [[ "$w1" -le 80 && "$w2" -le 80 ]] && printf '%s' "$t99_l1" | grep -qF "| oc"; then
        pass T99 "oc CJK extreme: line1=${w1} line2=${w2} both <= 80"
    else
        fail T99 "l1=[$t99_l1]($w1) l2=[$t99_l2]($w2)"
    fi
fi

# ============================================================
# T100: oc TTFT 四档色 + 显示值同步（±1ms 带内同档、跨带换档）
# ============================================================
if [[ "$TS_OK" -ne 1 ]]; then
    skip T100 "node with .ts type-stripping not available"
else
    oc_ttft() {  # $1 = ms → "色名 显示值"
        local body line
        body='{"width":120,"cwd":"/tmp","home":"/tmp","branch":null,"head":"","ab":"","added":0,"modified":0,"deleted":0,"herdr":"","durationMs":null,"inputTokens":1000,"outputTokens":10,"cacheRead":0,"cacheWrite":0,"compactions":0,"ctxPercent":null,"ctxWindow":0,"model":"m","thinking":"","ttftMs":'"$1"'}'
        line="$(oc_render "$body" | grep '^T2:TTFT')"
        [[ -n "$line" ]] || return 0
        line="${line#T2:}"
        printf '%s %s' "${line##*=}" "${line%=*}"
    }
    t100_ok=1
    for probe in "4700:green TTFT 4.7s" "4949:green TTFT 4.9s" "4999:fg TTFT 5.0s" "5000:fg TTFT 5.0s" \
                 "19999:fg TTFT 20s" "20499:fg TTFT 20s" "20500:yellow TTFT 21s" \
                 "59999:yellow TTFT 1m00s" "60499:yellow TTFT 1m00s" "60500:red TTFT 1m01s" "3700000:red TTFT 1h01m"; do
        ms="${probe%%:*}"; want="${probe#*:}"
        got="$(oc_ttft "$ms")"
        [[ "$got" == "$want" ]] || { t100_ok=0; echo "  oc ms=$ms want=[$want] got=[$got]" >&2; }
    done
    if [[ $t100_ok -eq 1 ]]; then
        pass T100 "oc TTFT tiers: display-synced 4-tier colour, +/-1ms bands same tier"
    else
        fail T100 "tier mismatch (see stderr)"
    fi
fi

# ============================================================
# T101: 真机 e2e——装到沙箱配置后，opencode TUI 里真渲染出两行（无 opencode/tmux 则 SKIP）
#       这是唯一直接锁宿主 TUI 插件 API 的用例：slot 名/模块形态变了会在这里碎
# ============================================================
if ! command -v opencode >/dev/null 2>&1 || ! command -v tmux >/dev/null 2>&1; then
    skip T101 "opencode or tmux not available"
else
    new_box
    run_wren install oc
    mkdir -p "$BOX/proj"
    (cd "$BOX/proj" && git -c init.defaultBranch=main init -q >/dev/null 2>&1)
    SESS="wren_t101_$BOX_N"
    tmux kill-session -t "$SESS" 2>/dev/null || true
    tmux new-session -d -s "$SESS" -x 120 -y 40 \
        "cd '$BOX/proj' && OPENCODE_CONFIG_DIR='$OC' opencode 2>'$BOX/oc.log'" >/dev/null 2>&1
    sleep 25
    pane="$(tmux capture-pane -p -t "$SESS" 2>/dev/null)"
    tmux kill-session -t "$SESS" 2>/dev/null || true
    if printf '%s' "$pane" | grep -qF "| oc" \
       && printf '%s' "$pane" | grep -qF "↑0 ↓0 | R0" \
       && printf '%s' "$pane" | grep -qF "main"; then
        pass T101 "real opencode TUI renders wren two lines in app_bottom"
    else
        fail T101 "pane=[$(printf '%s' "$pane" | tail -4 | tr '\n' '~')] log=[$(tail -2 "$BOX/oc.log" 2>/dev/null | tr '\n' '~')]"
    fi
fi

# ============================================================
# T102: CRLF 配置需逐字节还原（读/写不能用 universal newline 转换）
#       Linux/mac 上的 text mode 会把 \r\n 读成 \n，install 一次就整文件改行尾
# ============================================================
new_box
printf '{\r\n  "theme": "dracula",\r\n  "plugin": [\r\n    "./plugins/other.tsx"\r\n  ]\r\n}\r\n' >"$OCCONF"
cp "$OCCONF" "$BOX/before102"
run_wren install oc
run_wren uninstall oc
t102_cr="$(python3 -c "import sys;print(open(sys.argv[1],'rb').read().count(b'\\r'))" "$OCCONF")"
if [[ "$t102_cr" == "6" ]] && diff -q "$BOX/before102" "$OCCONF" >/dev/null; then
    pass T102 "CRLF tui.json survives install+uninstall byte-for-byte (6 CR kept)"
else
    fail T102 "cr=$t102_cr diff=[$(diff "$BOX/before102" "$OCCONF" | head -3 | tr '\n' '~')]"
fi

# ============================================================
# T103: plugin 键值不是数组 → 预检就拒，exit 1 且零副作用
#     （否则会追出重复的 plugin 键，把用户原值遮蔽掉）
# ============================================================
new_box
printf '{\n  "plugin": "./plugins/other.tsx"\n}\n' >"$OCCONF"
cp "$OCCONF" "$BOX/before103"
run_wren install oc
if [[ "$WREN_EXIT" == "1" ]] && diff -q "$BOX/before103" "$OCCONF" >/dev/null \
   && [[ ! -e "$OC/plugins" ]] && printf '%s' "$WREN_ERR" | grep -qF "non-array"; then
    pass T103 "non-array plugin value -> exit 1 before payload install, file untouched"
else
    fail T103 "exit=$WREN_EXIT plugins=[$(ls -A "$OC" 2>/dev/null | tr '\n' ' ')] err=[$WREN_ERR]"
fi

# ============================================================
# T104: 核心文件改名迁移——早期落点 plugins/wren-oc-core.ts 被识别并删除
# ============================================================
new_box
mkdir -p "$OC/plugins"
printf '// wren 的 opencode 侧排版核心（旧名）\n' >"$OC/plugins/wren-oc-core.ts"
run_wren install oc
if [[ "$WREN_EXIT" == "0" ]] \
   && [[ ! -e "$OC/plugins/wren-oc-core.ts" ]] \
   && cmp -s "$OC/plugins/wren-oc.ts" "$OC_CORE_PAYLOAD" \
   && printf '%s' "$WREN_OUT" | grep -qF "migrated"; then
    pass T104 "install oc migrates legacy wren-oc-core.ts -> wren-oc.ts"
else
    fail T104 "exit=$WREN_EXIT files=[$(ls -A "$OC/plugins" 2>/dev/null | tr '\n' ' ')] out=[$WREN_OUT]"
fi

# ---------- 汇总 ----------
printf '\nTotal: %d  Pass: %d  Fail: %d  Skip: %d\n' "$TOTAL" "$PASS_N" "$FAIL_N" "$SKIP_N"

# ---------- 写结果文件 ----------
{
    printf '# wren 测试结果\n'
    printf '执行时间：%s\n\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf '| ID | 状态 | 备注 |\n'
    printf '|----|------|------|\n'
    for i in "${!RESULT_ID[@]}"; do
        note="${RESULT_NOTE[$i]//|/\\|}"
        printf '| %s | %s | %s |\n' "${RESULT_ID[$i]}" "${RESULT_STATUS[$i]}" "$note"
    done
    printf '\n汇总：Total %d / Pass %d / Fail %d / Skip %d\n' "$TOTAL" "$PASS_N" "$FAIL_N" "$SKIP_N"
} > "$RES_FILE"

if [[ $FAIL_N -gt 0 ]]; then
    exit 1
fi
exit 0
