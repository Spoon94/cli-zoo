#!/usr/bin/env bash
# wren-test.sh - 自动运行 wren 的 190 个用例（用例书见 .test_task/wren-test.md）。
#
# 用法: bash .test_scripts/wren-test.sh
# 写出: .test_res/wren-test-res.md（可用 WREN_TEST_RES_FILE 改道）
# 超时: WREN_TEST_CMD_TIMEOUT=30 单命令 / WREN_TEST_TOTAL_TIMEOUT=1200 整套（watchdog）
#
# 全程在 mktemp -d 里作业：PREFIX / PI_EXT_DIR / CLAUDE_SETTINGS / QODER_CONFIG_DIR /
# QODER_SETTINGS / AGY_CONFIG_DIR / AGY_SETTINGS / OPENCODE_CONFIG_DIR / OPENCODE_TUI_CONFIG
# 九个变量把安装目标全部改道，不会碰到真实的 /usr/local/bin、~/.pi、~/.claude、~/.qoder、
# ~/.gemini/antigravity-cli、~/.config/opencode。

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
AGY_PAYLOAD="$REPO_ROOT/zoo-scripts/wren/wren-agy.py"
OC_PAYLOAD="$REPO_ROOT/zoo-scripts/wren/wren-oc.tsx"
OC_CORE_PAYLOAD="$REPO_ROOT/zoo-scripts/wren/wren-oc.ts"
INSTALL_SH="$REPO_ROOT/cli-zoo-install.sh"
UNINSTALL_SH="$REPO_ROOT/cli-zoo-uninstall.sh"
RES_DIR="$REPO_ROOT/.test_res"
RES_FILE="${WREN_TEST_RES_FILE:-$RES_DIR/wren-test-res.md}"

mkdir -p "$RES_DIR"

# ---------- 结果收集 ----------
declare -a RESULT_ID RESULT_STATUS RESULT_NOTE
TOTAL=0
PASS_N=0
FAIL_N=0
SKIP_N=0

record() {
    local id="$1" status="$2" note="${3:-}"
    # 用例日志：watchdog 超时后靠它报出「卡在哪条用例之后」（2026-10-12 事故后加）
    printf '%s|%s|%s\n' "$status" "$id" "$note" >>"$CASE_LOG" 2>/dev/null || true
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
    AGY="$BOX/agy"
    AGY_SETTINGS="$AGY/settings.json"
    OC="$BOX/opencode"
    OCCONF="$OC/tui.json"
    mkdir -p "$BIN" "$PIEXT" "$CLAUDE" "$QODER" "$AGY" "$OC"
}
BOX_N=0
BOX="" BIN="" PIEXT="" CLAUDE="" SETTINGS="" QODER="" QODER_SETTINGS="" AGY="" AGY_SETTINGS="" OC="" OCCONF=""

# ---------- 超时保护（2026-10-12 事故）----------
# 背景：wren install oc 的 heredoc 曾在「多元素 plugin 数组」上进死循环，
# 测试跑挂死不报错——两个 python 进程 100% CPU 白烧 8 天，没人发现。
# 这里两层防护：
#   1) run_limited：每次外部命令调用都带墙钟上限，超时按 124 返回（GNU timeout 同约定）
#   2) watchdog：整体超时兜底，杀掉自己之前先把结果文件写完，绝不静默
# macOS 没有 timeout/gtimeout（BSD userland），所以自带实现。
CMD_TIMEOUT="${WREN_TEST_CMD_TIMEOUT:-30}"      # 单条外部命令上限（秒）
TOTAL_TIMEOUT="${WREN_TEST_TOTAL_TIMEOUT:-1200}"  # 整套上限（秒）
CASE_LOG="$TMPROOT/cases.log"
: >"$CASE_LOG"

# kill_tree <pid>：先杀子孙再杀自身（-9）。
# 只杀直接子进程是不够的：wren 在 `$(...)` 里 fork 子 shell 跑 heredoc，那个
# 子 shell 再拉 python——只杀 wren 主进程的话，子 shell 与 python 孙进程双双
# 变孤儿继续自旋（2026-10-12 实测：16 个孤儿烧掉 9.3 核 × 51 分钟）。
kill_tree() {
    local pid="$1" k
    for k in $(pgrep -P "$pid" 2>/dev/null); do kill_tree "$k"; done
    kill -9 "$pid" 2>/dev/null
}

# run_limited <秒> <命令...>：超时返回 124，其余透传命令退出码
run_limited() {
    local secs="$1"; shift
    "$@" & local _pid=$!
    local _ticks=0 _lim=$((secs * 20))
    while kill -0 "$_pid" 2>/dev/null; do
        if (( _ticks++ >= _lim )); then
            kill_tree "$_pid"
            sleep 0.2
            kill_tree "$_pid"   # 二遍：兜住遍历途中才 fork 出来的子进程
            wait "$_pid" 2>/dev/null
            return 124
        fi
        sleep 0.05
    done
    wait "$_pid"
}

# run_limited_in <秒> <目录> <命令...>：先 cd 再 exec，超时同样返回 124
run_limited_in() {
    local secs="$1" dir="$2"; shift 2
    ( cd "$dir" && exec "$@" ) & local _pid=$!
    local _ticks=0 _lim=$((secs * 20))
    while kill -0 "$_pid" 2>/dev/null; do
        if (( _ticks++ >= _lim )); then
            kill_tree "$_pid"
            sleep 0.2
            kill_tree "$_pid"
            wait "$_pid" 2>/dev/null
            return 124
        fi
        sleep 0.05
    done
    wait "$_pid"
}

# watchdog：整体超时就把已有结果落盘（含 watchdog FAIL 行）+ 杀掉主进程
# FIFO 唤醒：watchdog 用 read -t 等，主流程正常结束时写一个字节让它退出。
# 不用 `sleep` 子进程——杀子 shell 杀不到 sleep 孙进程，它会变成孤儿占住 stdout
# （管道下游 tail/tee 永不结束，2026-10-12 实测踩到）。
WD_FIFO="$TMPROOT/watchdog.fifo"
mkfifo "$WD_FIFO" 2>/dev/null || true
exec 3<>"$WD_FIFO"
watchdog_run() {
    if read -t "$TOTAL_TIMEOUT" -u 3 _ 2>/dev/null; then
        exit 0   # 主流程正常收工，静默退出
    fi
    local last
    last="$(tail -n 1 "$CASE_LOG" 2>/dev/null || echo "")"
    {
        printf '# wren 测试结果\n'
        printf '执行时间：%s\n\n' "$(date '+%Y-%m-%d %H:%M:%S')"
        printf '| ID | 状态 | 备注 |\n|----|------|------|\n'
        local line st id note
        while IFS='|' read -r st id note; do
            [ -n "${id:-}" ] && printf '| %s | %s | %s |\n' "$id" "$st" "${note//|/\\|}"
        done <"$CASE_LOG"
        printf '| watchdog | FAIL | 整体超时 %ss，最后完成的用例：%s |\n' "$TOTAL_TIMEOUT" "${last//|/ }"
        printf '\n汇总：整体超时（watchdog 介入，结果不完整）\n'
    } >"$RES_FILE" 2>/dev/null
    printf '\nFAIL watchdog 整体超时 %ss（最后完成的用例：%s）；已写 %s，强杀\n' \
        "$TOTAL_TIMEOUT" "$last" "$RES_FILE" >&2
    kill_tree "$MAIN_PID"
}
MAIN_PID=$$
watchdog_run &
WATCHDOG_PID=$!
trap 'printf x >&3 2>/dev/null; kill -9 "$WATCHDOG_PID" 2>/dev/null; rm -f "$WD_FIFO" 2>/dev/null; cleanup_all' EXIT

# 用沙箱环境调用 wren；输出落 OUT_FILE，退出码进 WREN_EXIT
run_wren() {
    # NO_COLOR=1：旧用例断言的是明文子串，色档统一关掉（带色断言在 T39+ 单独跑）
    run_limited "$CMD_TIMEOUT" env NO_COLOR=1 PREFIX="$BIN" PI_EXT_DIR="$PIEXT" \
        CLAUDE_CONFIG_DIR="$CLAUDE" CLAUDE_SETTINGS="$SETTINGS" \
        QODER_CONFIG_DIR="$QODER" QODER_SETTINGS="$QODER_SETTINGS" \
        AGY_CONFIG_DIR="$AGY" AGY_SETTINGS="$AGY_SETTINGS" \
        OPENCODE_CONFIG_DIR="$OC" OPENCODE_TUI_CONFIG="$OCCONF" \
        "$WREN" "$@" >"$BOX/out.txt" 2>"$BOX/err.txt"
    WREN_EXIT=$?
    if [[ "$WREN_EXIT" == "124" ]]; then
        printf 'wren: TIMEOUT after %ss (suspected infinite loop): %s\n' "$CMD_TIMEOUT" "$*" >>"$BOX/err.txt"
    fi
    WREN_OUT="$(<"$BOX/out.txt")"
    WREN_ERR="$(<"$BOX/err.txt")"
}
WREN_EXIT=0
WREN_OUT=""
WREN_ERR=""

# 同 run_wren，但可前置任意 env 赋值（T181/T182 需要改 PATH / WREN_AGY_PYTHON）：
#   run_wrenx PATH=/x:$PATH WREN_AGY_PYTHON=off -- install agy
run_wrenx() {
    local extra=()
    while [[ $# -gt 0 && "$1" != "--" ]]; do extra+=("$1"); shift; done
    [[ "${1:-}" == "--" ]] && shift
    run_limited "$CMD_TIMEOUT" env NO_COLOR=1 PREFIX="$BIN" PI_EXT_DIR="$PIEXT" \
        CLAUDE_CONFIG_DIR="$CLAUDE" CLAUDE_SETTINGS="$SETTINGS" \
        QODER_CONFIG_DIR="$QODER" QODER_SETTINGS="$QODER_SETTINGS" \
        AGY_CONFIG_DIR="$AGY" AGY_SETTINGS="$AGY_SETTINGS" \
        OPENCODE_CONFIG_DIR="$OC" OPENCODE_TUI_CONFIG="$OCCONF" \
        ${extra[@]+"${extra[@]}"} "$WREN" "$@" >"$BOX/out.txt" 2>"$BOX/err.txt"
    WREN_EXIT=$?
    if [[ "$WREN_EXIT" == "124" ]]; then
        printf 'wren: TIMEOUT after %ss (suspected infinite loop): %s\n' "$CMD_TIMEOUT" "$*" >>"$BOX/err.txt"
    fi
    WREN_OUT="$(<"$BOX/out.txt")"
    WREN_ERR="$(<"$BOX/err.txt")"
}

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
    seg="${seg% | agy}"
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

for f in "$WREN" "$CC_PAYLOAD" "$PI_PAYLOAD" "$QC_PAYLOAD" "$AGY_PAYLOAD" "$OC_PAYLOAD" "$OC_CORE_PAYLOAD"; do
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
    QODER_CONFIG_DIR="$QODER" QODER_SETTINGS="$QODER_SETTINGS" \
    AGY_CONFIG_DIR="$AGY" AGY_SETTINGS="$AGY_SETTINGS" \
    OPENCODE_CONFIG_DIR="$OC" OPENCODE_TUI_CONFIG="$OCCONF" \
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
    QODER_CONFIG_DIR="$QODER" QODER_SETTINGS="$QODER_SETTINGS" \
    AGY_CONFIG_DIR="$AGY" AGY_SETTINGS="$AGY_SETTINGS" \
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
    QODER_CONFIG_DIR="$QODER" QODER_SETTINGS="$QODER_SETTINGS" \
    AGY_CONFIG_DIR="$AGY" AGY_SETTINGS="$AGY_SETTINGS" \
    OPENCODE_CONFIG_DIR="$OC" OPENCODE_TUI_CONFIG="$OCCONF" \
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
  model: { name: process.env.MODEL_NAME || "anthropic/claude-opus-5", contextWindow: Number(process.env.CTX_WINDOW || 200000) },
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
    run_limited_in "$CMD_TIMEOUT" "$where" env NO_COLOR=1 BRANCH="$branch" CTX_USAGE="$usage" \
        WREN_TS="$WREN_TS" TUI_STUB="$PI_DIR/tui-stub.mjs" ${extra:+$extra} \
        node --import "$PI_DIR/register.mjs" "$PI_DIR/harness.mjs" \
        >"$PI_OUT_FILE" 2>"$PI_DIR/err.txt"
    PI_EXIT=$?
    if [[ "$PI_EXIT" == "124" ]]; then
        printf 'pi harness: TIMEOUT after %ss (suspected hang)\n' "$CMD_TIMEOUT" >>"$PI_DIR/err.txt"
    fi
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
    # detached：分支名不显，dmg 照常（Bug 猎杀 #2 后两侧同构：seg=脏计数，无分支名）
    det_ok=0
    [[ "${got_det%%|*}" != *"main"* && "${got_det#*|}" != *"main"* \
       && "${got_det%%|*}" == "${got_det#*|}" && -n "${got_det%%|*}" ]] \
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
        fail T38 "det_ok=$det_ok ren_ok=$ren_ok conf_ok=$conf_ok conf_pre=$conf_pre pos=[$got_det_pos] det=[$got_det] ren=[$got_ren] conf=[$got_conf]"
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
# 长分支夹具（>24 格触发折叠）：cc 的 24 档必须与 qc 同构（head 8 / tail 15）。
# CR 三轮发现 d0dca44 曾把 cc 默认档改三七开致跨实现分叉——短分支夹具测不出。
(cd "$R59" && git checkout -q -b feat/very-long-branch-name-testing-cross-host-folding-parity) >/dev/null 2>&1
cc59l=$(printf '{"cwd":"%s","model":{"display_name":"m"}}' "$R59" \
    | NO_COLOR=1 WREN_CACHE_DIR="$BOX/c59l" python3 "$CC_PAYLOAD" 2>/dev/null | head -1)
qc59l=$(printf '{"cwd":"%s","model":{"display_name":"m"}}' "$R59" \
    | NO_COLOR=1 WREN_CACHE_DIR="$BOX/q59l" python3 "$QC_PAYLOAD" 2>/dev/null | head -1)
cc59ls="$(strip_tag "$cc59l")"; qc59ls="$(strip_tag "$qc59l")"
if [[ -n "$cc59s" && "$cc59s" == "$qc59s" ]] && printf '%s' "$cc59s" | grep -qF "main" \
   && [[ "$cc59ls" == "$qc59ls" ]] && printf '%s' "$cc59ls" | grep -qF "feat/ver"; then
    pass T59 "qc line1 identical to cc after badge strip, short+long branch ($cc59s / $cc59ls)"
else
    fail T59 "cc=[$cc59s] qc=[$qc59s] long: cc=[$cc59ls] qc=[$qc59ls]"
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
        QODER_CONFIG_DIR="$RO/qoder/nested" AGY_CONFIG_DIR="$AGY" AGY_SETTINGS="$AGY_SETTINGS" \
        OPENCODE_CONFIG_DIR="$OC" OPENCODE_TUI_CONFIG="$OCCONF" \
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
    # 55：窄档（≤55，与 cc T107 / qc T109 同契约）——短形 + 紧分隔；R/CP 本就
    # 不进段表；⏱ 升铁律（丢序 CP→CH），thinking 缩写 xh（十轮裁定后 45 ≤ 50 全在）
    printf '%s' "$t73_w55" | grep -qF "743K/117K|◈96.34%|▄28% ⏱12s|claude-opus-5 · xh" || t73_ok=0
    printf '%s' "$t73_w55" | grep -qF "CP1" && t73_ok=0
    # 宽档三档（90/75/65）都不剔：账本头、ctx%、模型名；55 窄档同段以短形在场
    for l in "$t73_w90" "$t73_w75" "$t73_w65"; do
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
    for w in 90 81 80 70 65 60; do
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
    # 三侧同签名之外，再钉住丢序与阀值：90/81→TCP 80/70→-CP 65/60→--P
    # （81 是「全在」的临界点：预算常量差 1 格就会在这一档暴露。
    #  ≤55 是 cc 独有的窄档短形层——CC 宿主实绘宽 ≈ COLUMNS−5 且输入框已带模型，
    #  同构断言只覆盖宽档，窄档由 T107 单钉）
    if [[ $t80_ok -eq 1 && "$t80_seen" == " TCP TCP -CP -CP --P --P" ]]; then
        pass T80 "3-host line2 ladder identical & ordered (w90/81/80/70/65/60:$t80_seen)"
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
# T95: install all / uninstall all 把五个宿主都接上、都摘干净
# ============================================================
new_box
WREN_AGY_PYTHON=off run_wren install all
inst_all=1
[[ -f "$CLAUDE/wren-cc" ]] || inst_all=0
[[ -f "$PIEXT/wren-pi.ts" ]] || inst_all=0
[[ -f "$QODER/wren-qc.py" ]] || inst_all=0
[[ -f "$AGY/wren-agy.py" ]] || inst_all=0
[[ -f "$OC/plugins/wren-oc.tsx" ]] || inst_all=0
[[ "$(json_field "$SETTINGS" "d['statusLine']['command']")" == "$CLAUDE/wren-cc" ]] || inst_all=0
[[ "$(json_field "$QODER_SETTINGS" "d['statusLine']['command']")" == "$QODER/wren-qc.py" ]] || inst_all=0
[[ "$(json_field "$AGY_SETTINGS" "d['statusLine']['command']")" == "$AGY/wren-agy.py" ]] || inst_all=0
grep -qF '"./plugins/wren-oc.tsx"' "$OCCONF" || inst_all=0
run_wren uninstall all
un_all=1
[[ -e "$CLAUDE/wren-cc" || -e "$PIEXT/wren-pi.ts" || -e "$QODER/wren-qc.py" || -e "$AGY/wren-agy.py" || -e "$OC/plugins/wren-oc.tsx" ]] && un_all=0
grep -qF 'wren-oc.tsx' "$OCCONF" && un_all=0
[[ "$(json_field "$SETTINGS" "d.get('statusLine')")" == "None" ]] || un_all=0
[[ "$(json_field "$AGY_SETTINGS" "d.get('statusLine')")" == "None" ]] || un_all=0
if [[ $inst_all -eq 1 && $un_all -eq 1 ]]; then
    pass T95 "install all wires 5 hosts; uninstall all unwires them"
else
    fail T95 "install_all=$inst_all uninstall_all=$un_all claude=[$(ls -A "$CLAUDE" | tr '\n' ' ')] agy=[$(ls -A "$AGY" | tr '\n' ' ')] oc=[$(ls -A "$OC" | tr '\n' ' ')] conf=[$(cat "$OCCONF" 2>/dev/null)]"
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
        # 核心段与模型名（粉）在梯子生效的宽度区间内不许消失（与 pi T73 同口径）。
        # ctx% 允许全形 `8.40%/200K` 或短形 `8%`（oc 侧窄预算先换短形保 CH/TTFT，见 T106）
        case "$w" in 90|81|80|70|65|55)
            printf '%s' "$out" | grep -qF "↑12K ↓3K" || t98_ok=0
            printf '%s' "$out" | grep -qF "R1.2M" || t98_ok=0
            printf '%s' "$out" | grep -qE "8\.40%/200K|[^0-9]8%" || t98_ok=0
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
#       唯一直接锁宿主 TUI 插件 API 的用例：slot 名/模块形态变了会在这里碎。
#       XDG_CONFIG_HOME 一并改道：opencode 会把默认全局配置目录".叠加"进来，
#       不改道的话用户真实装的同一个 payload 会让本用例恒真（测不到沙箱那份）
# ============================================================
if ! command -v opencode >/dev/null 2>&1 || ! command -v tmux >/dev/null 2>&1; then
    skip T101 "opencode or tmux not available"
else
    new_box
    run_wren install oc
    mkdir -p "$BOX/proj" "$BOX/xdg"
    (cd "$BOX/proj" && git -c init.defaultBranch=main init -q >/dev/null 2>&1)
    SESS="wren_t101_$BOX_N"
    tmux kill-session -t "$SESS" 2>/dev/null || true
    tmux new-session -d -s "$SESS" -x 120 -y 40 \
        "cd '$BOX/proj' && XDG_CONFIG_HOME='$BOX/xdg' OPENCODE_CONFIG_DIR='$OC' opencode 2>'$BOX/oc.log'" >/dev/null 2>&1
    # 高负载下首帧可能 >25s：轮询等断言内容出现，最多 75s
    pane=""
    for _ in $(seq 1 25); do
        sleep 3
        pane="$(tmux capture-pane -p -t "$SESS" 2>/dev/null)"
        if printf '%s' "$pane" | grep -qF "tab agents" && printf '%s' "$pane" | grep -qE "↑0 ↓0"; then
            break
        fi
    done
    tmux kill-session -t "$SESS" 2>/dev/null || true
    # 行1 与宿主的 `tab agents  ctrl+p commands` 同行（证明落在 prompt 框下方那一行、顶掉了 cwd）
    # 行2 只含 git 计数（无会话、无 provider 限额）
    if printf '%s' "$pane" | grep -F "tab agents" | grep -qF "| oc" \
       && printf '%s' "$pane" | grep -qE "^ *↑0 ↓0 \| R0[[:space:]]*$"; then
        pass T101 "real opencode TUI renders wren two lines below the prompt box"
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

# ============================================================
# T105: 空 cwd + 空身份组（oc 侧把 cwd 交给宿主行、模型交给宿主 prompt 行）
#       行1 首段就是 git 组、无悬空分隔符；行2 无尾部 " | "、无粉色模型段
# ============================================================
if [[ "$TS_OK" -ne 1 ]]; then
    skip T105 "node with .ts type-stripping not available"
else
    OC_NOID='{"width":120,"cwd":"","home":"/home/u","branch":"main","head":"main","ab":" ↑1↓2","added":4,"modified":2,"deleted":1,"herdr":"w1:t2:p3","durationMs":3900000,"inputTokens":12000,"outputTokens":3000,"cacheRead":1200000,"cacheWrite":0,"compactions":2,"ctxPercent":8.4,"ctxWindow":200000,"model":"","thinking":"","ttftMs":6600}'
    t105="$(oc_render "$OC_NOID")"
    if printf '%s' "$t105" | grep -qxF "L1=main ↑1↓2 +4 ~1 ✱2 | w1:t2:p3 | oc · 1h5m" \
       && printf '%s' "$t105" | grep -qxF "L2=↑12K ↓3K | R1.2M CH99.01% CP2 | 8.40%/200K TTFT 6.6s" \
       && ! printf '%s' "$t105" | grep -qE '^L[12]=.*\| $' \
       && ! printf '%s' "$t105" | grep -qE '^T[12]:.*=pink' \
       && ! printf '%s' "$t105" | grep -qE '^T2: · ='; then
        pass T105 "empty cwd + empty model: no leading/trailing separator, no identity group"
    else
        fail T105 "out=[$(printf '%s' "$t105" | tr '\n' '~')]"
    fi
fi

# ============================================================
# ============================================================
# T106: 行1/行2 双预算——行1 与宿主 usage/快捷键同行要收窄，行2 独占整行不收窄
#       （78 列窗格曾因共用行1 预算把 TTFT/ctx% 全挤掉）
# ============================================================
if [[ "$TS_OK" -ne 1 ]]; then
    skip T106 "node with .ts type-stripping not available"
else
    # 行2 在 49 格内：ctx% 先换短形 `16%`（保窗口位置：CH 之后、TTFT 之前），CH/TTFT 都保住
    OC_DUAL='{"width":49,"cwd":"/home/u/Code/proj","home":"/home/u","branch":"feat/wren_support_opencode","head":"feat/wren_support_opencode","ab":" ↑0↓0","added":0,"modified":11,"deleted":0,"herdr":"w1:t2:p3","durationMs":82900000,"inputTokens":898000,"outputTokens":14000,"cacheRead":7200000,"cacheWrite":0,"compactions":0,"ctxPercent":16.29,"ctxWindow":1000000,"model":"","thinking":"","ttftMs":3700}'
    t106="$(oc_render "$OC_DUAL")"
    # T133 后期望更新：folds 表补 4/0 档，级联按优先级（段 > 分支长度 > cwd）
    # 在 fold-4 处提前命中——cwd 存活（…/proj）、分支让位到 4 档（…ode），
    # 总宽 47 ≤ 49；旧行为是丢 cwd 保 16 档分支（旧表无 4/0 档可选）
    if printf '%s' "$t106" | grep -qF "L2=↑898K ↓14K | R7.2M CH88.91% | 16% TTFT 3.7s" \
       && printf '%s' "$t106" | grep -qxF "L1=…/proj | …ode ↑0↓0 ✱11 | w1:t2:p3 | oc · 23h1m"; then
        pass T106 "narrow budget swaps ctx% to short form before dropping CH/TTFT"
    else
        fail T106 "out=[$(printf '%s' "$t106" | tr '\n' '~')]"
    fi
fi

# ============================================================
# T107: cc 窄档（≤55 列，移动端 herdr 会把 pane PTY 拖成 51 列）——
#       预算按实绘宽 COLUMNS−5 收（宿主左缩进 2 + 尾部留白/省略号）；
#       用户裁定取舍：R/CP 窄档不进段表、CH 两位小数原样但前缀换 ◈、
#       ctx% 整数 + 四分位块高图标（▂<25 ▄<50 ▆<75 █≥75，与色档 70/90
#       正交：图标=体积，颜色=风险）、TTFT 换 ⏱ 前缀（计宽按 2 格防御
#       iOS 表情宽）、模型·思考保留、行1 时长不渲染、紧分隔 |。
#       兜底丢序（比 51 列更窄）：⏱ → ◈；↑in↓out 与 ◐ctx% 永不整段丢。
# ============================================================
new_box
T107_TR="$BOX/tr107.jsonl"
cat >"$T107_TR" <<'EOF2'
{"type":"user","timestamp":"2026-09-19T04:18:46.065Z","message":{"content":"hi"}}
{"type":"assistant","timestamp":"2026-09-19T04:18:58.465Z","message":{"usage":{"input_tokens":743000,"output_tokens":117000,"cache_read_input_tokens":19560000,"cache_creation_input_tokens":0}}}
{"type":"system","subtype":"compact_boundary","isSidechain":false,"compactMetadata":{"trigger":"manual","postTokens":284200}}
EOF2
t107_at() {
    printf '{"cwd":"/tmp","model":{"display_name":"m"},"effort":{"level":"xhigh"},"context_window":{"context_window_size":1000000},"transcript_path":"%s"}' "$T107_TR" \
        | NO_COLOR=1 COLUMNS=$1 WREN_CACHE_DIR="$BOX/c107-$1" python3 "$CC_PAYLOAD" 2>/dev/null | tail -1
}
# 四分位图标矩阵：同 fixture 换 ctx 值，钉 ▂▄▆█ 四档与色档正交（80%=█但黄）
t107_ctx() {
    printf '{"cwd":"/tmp","model":{"display_name":"m"},"context_window":{"context_window_size":1000000,"current_usage":{"input_tokens":%d,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}},"transcript_path":"%s"}' \
        "$((1000000 * $1 / 100))" "$T107_TR" \
        | NO_COLOR=1 COLUMNS=51 WREN_CACHE_DIR="$BOX/c107x-$1" python3 "$CC_PAYLOAD" 2>/dev/null | tail -1
}
t107_51="$(t107_at 51)"; t107_42="$(t107_at 42)"; t107_36="$(t107_at 36)"
t107_90="$(printf '{"cwd":"/tmp","model":{"display_name":"claude-opus-5"},"effort":{"level":"xhigh"},"context_window":{"context_window_size":1000000},"transcript_path":"%s"}' "$T107_TR" \
    | NO_COLOR=1 COLUMNS=90 WREN_CACHE_DIR="$BOX/c107-90" python3 "$CC_PAYLOAD" 2>/dev/null | tail -1)"
t107_l1="$(printf '{"cwd":"/tmp","model":{"display_name":"m"},"context_window":{"context_window_size":1000000},"transcript_path":"%s"}' "$T107_TR" \
    | NO_COLOR=1 COLUMNS=51 HERDR_WORKSPACE_ID=w9 HERDR_TAB_ID=w9:t1 HERDR_PANE_ID=w9:p1 WREN_CACHE_DIR="$BOX/c107-l1" python3 "$CC_PAYLOAD" 2>/dev/null | head -1)"
t107_q12="$(t107_ctx 12)"; t107_q37="$(t107_ctx 37)"; t107_q62="$(t107_ctx 62)"; t107_q80="$(t107_ctx 80)"; t107_q96="$(t107_ctx 96)"
# 51 满配 ◈96.34%+▄28%+⏱12s+身份组（m · xh 缩写）。⏱ 升铁律（用户裁定）：
# 42/36 丢 ◈ 保 ⏱；思考等级 xhigh→xh、模型去 [1m]（此 fixture 模型 m 无后缀）。
# 90 宽档原样（xhigh 不缩写）；行1 时长不在、herdr 坐标在
if printf '%s' "$t107_51" | grep -qF "◈96.34%" \
   && printf '%s' "$t107_51" | grep -qF "▄28%" \
   && printf '%s' "$t107_51" | grep -qF "⏱12s" \
   && printf '%s' "$t107_51" | grep -qF "|m · xh" \
   && ! printf '%s' "$t107_51" | grep -qF "R19.6M" \
   && ! printf '%s' "$t107_51" | grep -qF "CP1" \
   && ! printf '%s' "$t107_51" | grep -qF "28.42%" \
   && ! printf '%s' "$t107_42" | grep -qF "◈96.34%" \
   && printf '%s' "$t107_42" | grep -qF "⏱12s" \
   && ! printf '%s' "$t107_36" | grep -qF "◈" \
   && printf '%s' "$t107_36" | grep -qF "⏱12s" \
   && printf '%s' "$t107_36" | grep -qF "117K|▄28%" \
   && printf '%s' "$t107_90" | grep -qF "R19.6M CH96.34% CP1 | 28.42%/1M TTFT 12s | claude-opus-5" \
   && printf '%s' "$t107_l1" | grep -qF "w9:t1:p1" \
   && ! printf '%s' "$t107_l1" | grep -qE "· [0-9]+[hm]" \
   && printf '%s' "$t107_q12" | grep -qF "▂12%" \
   && printf '%s' "$t107_q37" | grep -qF "▄37%" \
   && printf '%s' "$t107_q62" | grep -qF "▆62%" \
   && printf '%s' "$t107_q80" | grep -qF "█80%" \
   && printf '%s' "$t107_q96" | grep -qF "█96%"; then
    pass T107 "cc narrow tier: ◈/▂▄▆█/⏱ icons, quartile×color orthogonal, TTFT->CH drop"
else
    fail T107 "51=[$t107_51] 42=[$t107_42] 36=[$t107_36] 90=[$t107_90] l1=[$t107_l1] q12=[$t107_q12] q37=[$t107_q37] q62=[$t107_q62] q80=[$t107_q80] q96=[$t107_q96]"
fi

# ============================================================
# T108: pi 窄档（≤55 列，与 cc T107 / qc T109 同一款）：预算 WIDTH−5 地板 4、
#       in/out 短形（去 ↑/↓ 与空格，/ 分向）、◈CH、▂▄▆█ ctx（整数 + 四分位
#       块高，与色档 70/90 正交）、⏱TTFT（预算 ⏱⏱99m59s 8 格防 iOS 表情宽）、
#       R/CP 不进段表、紧分隔 |、丢序 CP→TTFT→CH、行1 时长不渲染、徽标锁定。
#       宽档边界 56 仍走宽档形态（R/CH 原样），钉「≤55 才切窄」。
# ============================================================
if [[ "$TS_OK" -ne 1 ]]; then
    skip T108 "node with .ts type-stripping not available"
else
    T108_BR='[{"type":"compaction"},{"type":"message","message":{"role":"assistant","usage":{"input":743000,"output":117000,"cacheRead":19560000,"cacheWrite":0}}}]'
    t108_run() {  # $1=WIDTH $2=MODEL_NAME($3=percent)
        env NO_COLOR=1 WIDTH="$1" BRANCH="$T108_BR" TTFT_MS=12400 MSG_UPDATES=0 THINKING=xhigh \
            MODEL_NAME="${2:-m}" CTX_USAGE="{\"tokens\":284200,\"contextWindow\":1000000,\"percent\":${3:-28.42}}" \
            WREN_TS="$WREN_TS" TUI_STUB="$PI_DIR/tui-stub.mjs" \
            node --import "$PI_DIR/register.mjs" "$PI_DIR/harness.mjs" 2>/dev/null | tail -1
    }
    t108_51="$(t108_run 51)"; t108_44="$(t108_run 44)"; t108_42="$(t108_run 42)"; t108_36="$(t108_run 36)"
    t108_56="$(t108_run 56)"   # 宽档边界（MODEL=m 时 CH 仍在，与 55 窄档形态对照）
    t108_90="$(t108_run 90 claude-opus-5)"
    t108_q12="$(t108_run 51 m 12)"; t108_q37="$(t108_run 51 m 37)"
    t108_q62="$(t108_run 51 m 62)"; t108_q80="$(t108_run 51 m 80)"; t108_q96="$(t108_run 51 m 96)"
    t108_l1="$(env NO_COLOR=1 WIDTH=51 BRANCH="$T108_BR" TTFT_MS=12400 MSG_UPDATES=0 THINKING=xhigh \
        HERDR_WORKSPACE_ID=w9 HERDR_TAB_ID=w9:t1 HERDR_PANE_ID=w9:p1 \
        CTX_USAGE='{"tokens":284200,"contextWindow":1000000,"percent":28.42}' \
        WREN_TS="$WREN_TS" TUI_STUB="$PI_DIR/tui-stub.mjs" \
        node --import "$PI_DIR/register.mjs" "$PI_DIR/harness.mjs" 2>/dev/null | head -1)"
    t108_ok=1
    # 51 满配：短形 + ◈ + ▄ + ⏱ + 身份组（thinking 缩写 xh）；R/CP/小数 ctx/↑↓ 都不在
    printf '%s' "$t108_51" | grep -qF "◈96.34%" || t108_ok=0
    printf '%s' "$t108_51" | grep -qF "▄28%" || t108_ok=0
    printf '%s' "$t108_51" | grep -qF "⏱12s" || t108_ok=0
    printf '%s' "$t108_51" | grep -qF "|m · xh" || t108_ok=0
    printf '%s' "$t108_51" | grep -qF "743K/117K" || t108_ok=0
    printf '%s' "$t108_51" | grep -qF "R19.6M" && t108_ok=0
    printf '%s' "$t108_51" | grep -qF "CP1" && t108_ok=0
    printf '%s' "$t108_51" | grep -qF "28.42%" && t108_ok=0
    printf '%s' "$t108_51" | grep -qF "↑743K" && t108_ok=0
    # 丢序（新裁定）：⏱ 升铁律永不丢；44（预算 39）全在；42（37）丢 ◈ 保 ⏱；
    # 36（31）同 42 形（⏱ 在场、◈ 不在）
    printf '%s' "$t108_44" | grep -qF "◈96.34%" || t108_ok=0
    printf '%s' "$t108_44" | grep -qF "⏱12s" || t108_ok=0
    printf '%s' "$t108_42" | grep -qF "◈" && t108_ok=0
    printf '%s' "$t108_42" | grep -qF "117K|▄28% ⏱12s" || t108_ok=0
    printf '%s' "$t108_36" | grep -qF "◈" && t108_ok=0
    printf '%s' "$t108_36" | grep -qF "117K|▄28% ⏱12s" || t108_ok=0
    # 56 = 宽档边界：R/↑↓ 原样、无 ⏱/◈（与 55 窄档形态互斥；MODEL=m 时 56 实宽
    # 68→丢⏱ 57→丢◈ 48，R 在场即宽档形）
    printf '%s' "$t108_56" | grep -qF "R19.6M" || t108_ok=0
    printf '%s' "$t108_56" | grep -qF "↑743K ↓117K" || t108_ok=0
    printf '%s' "$t108_56" | grep -qF "⏱" && t108_ok=0
    printf '%s' "$t108_56" | grep -qF "◈" && t108_ok=0
    # 90 宽档全量（长模型名）
    printf '%s' "$t108_90" | grep -qF "R19.6M CH96.34% CP1 | 28.42%/1M TTFT 12s | claude-opus-5" || t108_ok=0
    # 身份组缩短：窄档去 '[1m]' 后缀 + thinking 缩写；宽档不缩（原样保留）
    t108_m1="$(t108_run 51 'forge[1m]')"
    t108_m2="$(t108_run 90 'forge[1m]')"
    printf '%s' "$t108_m1" | grep -qF "|forge · xh" || t108_ok=0
    printf '%s' "$t108_m1" | grep -qF "[1m]" && t108_ok=0
    printf '%s' "$t108_m2" | grep -qF "forge[1m] · xhigh" || t108_ok=0
    # 行1：herdr 坐标在、时长不在
    printf '%s' "$t108_l1" | grep -qF "w9:t1:p1" || t108_ok=0
    printf '%s' "$t108_l1" | grep -qF "| pi" || t108_ok=0
    printf '%s' "$t108_l1" | grep -qE "· [0-9]+[hm]" && t108_ok=0
    # 四分位矩阵：▂<25 ▄<50 ▆<75 █≥75（与色档 70/90 正交：80%=█但黄）
    printf '%s' "$t108_q12" | grep -qF "▂12%" || t108_ok=0
    printf '%s' "$t108_q37" | grep -qF "▄37%" || t108_ok=0
    printf '%s' "$t108_q62" | grep -qF "▆62%" || t108_ok=0
    printf '%s' "$t108_q80" | grep -qF "█80%" || t108_ok=0
    printf '%s' "$t108_q96" | grep -qF "█96%" || t108_ok=0
    if [[ $t108_ok -eq 1 ]]; then
        pass T108 "pi narrow tier: short-form/◈/▂▄▆█/⏱ iron law, CP→CH drop, identity shortened, quartile matrix"
    else
        fail T108 "51=[$t108_51] 44=[$t108_44] 42=[$t108_42] 36=[$t108_36] 56=[$t108_56] 90=[$t108_90] l1=[$t108_l1] q12=[$t108_q12] q37=[$t108_q37] q62=[$t108_q62] q80=[$t108_q80] q96=[$t108_q96]"
    fi
fi

# ============================================================
# T109: qc 窄档（≤55 列，与 cc T107 同一款）：预算 COLUMNS−5 地板 4、
#       in/out 短形 743K/117K、◈CH、四分位 ▂▄▆█ + 整数%、⏱ 前缀、
#       R/CP 不进段表、紧分隔 |、丢序 CP→TTFT→CH（⏱ 先于 ◈ 丢）、
#       行1 时长不渲染 + herdr/qc 徽标保留；宽档（90）零变化。
#       ctx 数据源走 qc 口径：原生 used_percentage（四分位矩阵）与
#       postTokens 回落（51 满配 ▄28%）两条都盖到；effort 走 runtime-config。
# ============================================================
new_box
T109_TR="$BOX/tr109.jsonl"
cat >"$T109_TR" <<'EOF2'
{"type":"user","timestamp":"2026-09-19T04:18:46.065Z","message":{"content":"hi"}}
{"type":"assistant","timestamp":"2026-09-19T04:18:58.465Z","message":{"usage":{"input_tokens":743000,"output_tokens":117000,"cache_read_input_tokens":19560000,"cache_creation_input_tokens":0}}}
{"type":"system","subtype":"compact_boundary","isSidechain":false,"compactMetadata":{"trigger":"manual","postTokens":284200}}
{"type":"runtime-config","reasoningEffort":"xhigh"}
EOF2
t109_at() {
    printf '{"cwd":"/tmp","model":{"display_name":"m"},"context_window":{"context_window_size":1000000},"transcript_path":"%s"}' "$T109_TR" \
        | NO_COLOR=1 WREN_QC_NARROW=1 COLUMNS=$1 WREN_CACHE_DIR="$BOX/c109-$1" python3 "$QC_PAYLOAD" 2>/dev/null | tail -1
}
# 四分位矩阵：原生 used_percentage（qc 的首选 ctx 源），钉 ▂▄▆█ 与色档正交
t109_ctx() {
    printf '{"cwd":"/tmp","model":{"display_name":"m"},"context_window":{"context_window_size":1000000,"used_percentage":%d},"transcript_path":"%s"}' \
        "$1" "$T109_TR" \
        | NO_COLOR=1 WREN_QC_NARROW=1 COLUMNS=51 WREN_CACHE_DIR="$BOX/c109x-$1" python3 "$QC_PAYLOAD" 2>/dev/null | tail -1
}
t109_55="$(t109_at 55)"; t109_51="$(t109_at 51)"; t109_42="$(t109_at 42)"; t109_36="$(t109_at 36)"
t109_90="$(printf '{"cwd":"/tmp","model":{"display_name":"claude-opus-5"},"context_window":{"context_window_size":1000000},"transcript_path":"%s"}' "$T109_TR" \
    | NO_COLOR=1 COLUMNS=90 WREN_CACHE_DIR="$BOX/c109-90" python3 "$QC_PAYLOAD" 2>/dev/null | tail -1)"
t109_l1="$(printf '{"cwd":"/tmp","model":{"display_name":"m"},"context_window":{"context_window_size":1000000},"transcript_path":"%s"}' "$T109_TR" \
    | NO_COLOR=1 WREN_QC_NARROW=1 COLUMNS=51 HERDR_WORKSPACE_ID=w9 HERDR_TAB_ID=w9:t1 HERDR_PANE_ID=w9:p1 WREN_CACHE_DIR="$BOX/c109-l1" python3 "$QC_PAYLOAD" 2>/dev/null | head -1)"
t109_q12="$(t109_ctx 12)"; t109_q37="$(t109_ctx 37)"; t109_q62="$(t109_ctx 62)"; t109_q80="$(t109_ctx 80)"; t109_q96="$(t109_ctx 96)"
if printf '%s' "$t109_55" | grep -qF "743K/117K|◈96.34%|▄28% ⏱12s|m · xh" \
   && printf '%s' "$t109_51" | grep -qF "743K/117K|◈96.34%|▄28% ⏱12s|m · xh" \
   && ! printf '%s' "$t109_51" | grep -qF "R19.6M" \
   && ! printf '%s' "$t109_51" | grep -qF "CP1" \
   && ! printf '%s' "$t109_51" | grep -qF "28.42%" \
   && printf '%s' "$t109_42" | grep -qF "743K/117K|▄28% ⏱12s|m · xh" \
   && ! printf '%s' "$t109_42" | grep -qF "◈" \
   && printf '%s' "$t109_36" | grep -qF "743K/117K|▄28% ⏱12s|m · xh" \
   && ! printf '%s' "$t109_36" | grep -qF "◈" \
   && printf '%s' "$t109_90" | grep -qF "R19.6M CH96.34% CP1 | 28.42%/1M TTFT 12s | claude-opus-5 · xhigh" \
   && printf '%s' "$t109_l1" | grep -qF "w9:t1:p1" \
   && printf '%s' "$t109_l1" | grep -qF "| qc" \
   && ! printf '%s' "$t109_l1" | grep -qF "· " \
   && printf '%s' "$t109_q12" | grep -qF "▂12%" \
   && printf '%s' "$t109_q37" | grep -qF "▄37%" \
   && printf '%s' "$t109_q62" | grep -qF "▆62%" \
   && printf '%s' "$t109_q80" | grep -qF "█80%" \
   && printf '%s' "$t109_q96" | grep -qF "█96%"; then
    pass T109 "qc narrow tier mirrors cc: short in/out, ◈/▂▄▆█/⏱, CP->TTFT->CH order, wide untouched"
else
    fail T109 "55=[$t109_55] 51=[$t109_51] 42=[$t109_42] 36=[$t109_36] 90=[$t109_90] l1=[$t109_l1] q12=[$t109_q12] q37=[$t109_q37] q62=[$t109_q62] q80=[$t109_q80] q96=[$t109_q96]"
fi

# ============================================================
# T116: pi herdr env 换行注入——herdrId 三段各自压平（与 cc one_line 同款）
#       后拼接；\n 类字符不得进渲染文本（2 行契约），压平后为空的段被
#       filter(Boolean) 拆掉（无 :: 残留）。CR 六轮补洞（cc 侧猎杀四轮 #4
#       的 pi 侧遗漏）；oc 侧同款见 T114（B-2）。
# ============================================================
if [[ "$TS_OK" -ne 1 ]]; then
    skip T116 "node with .ts type-stripping not available"
else
    t116_run() {  # $@ = 额外 env（HERDR_*）
        env -u HERDR_WORKSPACE_ID -u HERDR_TAB_ID -u HERDR_PANE_ID \
            NO_COLOR=1 WIDTH=80 TTFT_MS=12400 MSG_UPDATES=0 "$@" \
            WREN_TS="$WREN_TS" TUI_STUB="$PI_DIR/tui-stub.mjs" \
            node --import "$PI_DIR/register.mjs" "$PI_DIR/harness.mjs" 2>/dev/null
    }
    # A：TAB 含换行——压平进段，总行数仍 2，行1 无 EVIL 后续行残留
    t116_a="$(t116_run HERDR_WORKSPACE_ID=w9 HERDR_TAB_ID=$'t1\nEVIL' HERDR_PANE_ID=w9:p1)"
    # B：TAB 纯换行且无其它段——herdr 段整体消失
    t116_b="$(t116_run HERDR_TAB_ID=$'\n')"
    # C：TAB 纯换行但 WS/PANE 在——空段被拆，无 ::
    t116_c="$(t116_run HERDR_WORKSPACE_ID=w9 HERDR_TAB_ID=$'\n' HERDR_PANE_ID=w9:p1)"
    t116_a_l1="$(printf '%s' "$t116_a" | head -1)"
    t116_a_n="$(printf '%s\n' "$t116_a" | wc -l | tr -d ' ')"
    t116_b_l1="$(printf '%s' "$t116_b" | head -1)"
    t116_c_l1="$(printf '%s' "$t116_c" | head -1)"
    t116_ok=1
    # A：行1 压平为 w9:t1EVIL:p1；总行数 = 2（注入前 bug 会顶成 3）
    printf '%s' "$t116_a_l1" | grep -qF "w9:t1EVIL:p1" || t116_ok=0
    [[ $t116_a_n -eq 2 ]] || t116_ok=0
    # B：无 herdr 段（无 w9/:，只剩路径 + 徽标）
    printf '%s' "$t116_b_l1" | grep -qF "| pi" || t116_ok=0
    printf '%s' "$t116_b_l1" | grep -qE 'w9|:p' && t116_ok=0
    # C：空段被拆——w9:p1 紧凑拼接，无 :: 残留
    printf '%s' "$t116_c_l1" | grep -qF "w9:p1 | pi" || t116_ok=0
    printf '%s' "$t116_c_l1" | grep -qF "::" && t116_ok=0
    if [[ $t116_ok -eq 1 ]]; then
        pass T116 "pi herdr env flattened: newline-injection stays 2 lines, empty segment dropped"
    else
        fail T116 "A(n=$t116_a_n)=[$t116_a_l1] B=[$t116_b_l1] C=[$t116_c_l1]"
    fi
fi

# ============================================================
# T117: pi 窄档四分位边界 + 半偶舍入（交叉审 P3 变异补测）——
#       25/50/75 三边界没测过（矩阵只有 12/37/62/80/96）；半值 .5 处
#       Python :.0f（银行家）与 JS toFixed(0)/Math.round（半上）分叉，
#       pi 手写 roundHalfEven 对齐 cc/qc。附 cc 同值 74.5% 交叉验证。
# ============================================================
if [[ "$TS_OK" -ne 1 ]]; then
    skip T117 "node with .ts type-stripping not available"
else
    T117_BR='[{"type":"compaction"},{"type":"message","message":{"role":"assistant","usage":{"input":743000,"output":117000,"cacheRead":19560000,"cacheWrite":0}}}]'
    t117_ctx() {  # $1 = percent
        env -u HERDR_WORKSPACE_ID -u HERDR_TAB_ID -u HERDR_PANE_ID NO_COLOR=1 WIDTH=51 BRANCH="$T117_BR" TTFT_MS=12400 MSG_UPDATES=0 \
            MODEL_NAME=m CTX_USAGE="{\"tokens\":284200,\"contextWindow\":1000000,\"percent\":$1}" \
            WREN_TS="$WREN_TS" TUI_STUB="$PI_DIR/tui-stub.mjs" \
            node --import "$PI_DIR/register.mjs" "$PI_DIR/harness.mjs" 2>/dev/null | tail -1
    }
    t117_ok=1
    # 整数边界：▂<25 ▄<50 ▆<75 █≥75（边界值归上档）
    [[ "$(t117_ctx 25)"  == *"▄25%"*  ]] || t117_ok=0
    [[ "$(t117_ctx 50)"  == *"▆50%"*  ]] || t117_ok=0
    [[ "$(t117_ctx 75)"  == *"█75%"*  ]] || t117_ok=0
    # 半偶舍入：.5 归偶（toFixed(0)/Math.round 会给 25/51/75，全红）
    [[ "$(t117_ctx 24.5)" == *"▂24%"* ]] || t117_ok=0
    [[ "$(t117_ctx 25.5)" == *"▄26%"* ]] || t117_ok=0
    [[ "$(t117_ctx 49.5)" == *"▄50%"* ]] || t117_ok=0
    [[ "$(t117_ctx 50.5)" == *"▆50%"* ]] || t117_ok=0
    [[ "$(t117_ctx 74.5)" == *"▆74%"* ]] || t117_ok=0
    [[ "$(t117_ctx 75.5)" == *"█76%"* ]] || t117_ok=0
    # cc 交叉验证：tokens=149000/200000 → 74.5% 精确 → cc :.0f=74
    printf '{"cwd":"/tmp","model":{"display_name":"m"},"effort":{"level":"xhigh"},"context_window":{"current_usage":{"input_tokens":149000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"context_window_size":200000}}' \
        | NO_COLOR=1 COLUMNS=51 python3 "$CC_PAYLOAD" 2>/dev/null | tail -1 | grep -qF "▆74%" || t117_ok=0
    if [[ $t117_ok -eq 1 ]]; then
        pass T117 "pi narrow quartile boundaries 25/50/75 + banker's rounding (.5->even), cc parity at 74.5%"
    else
        fail T117 "25=[$(t117_ctx 25)] 50=[$(t117_ctx 50)] 75=[$(t117_ctx 75)] 24.5=[$(t117_ctx 24.5)] 50.5=[$(t117_ctx 50.5)] 74.5=[$(t117_ctx 74.5)] 75.5=[$(t117_ctx 75.5)]"
    fi
fi

# ============================================================
# T118: pi 预算地板（变异补测）——max(4, width-5) 变异成 max(24,·)
#       时现有用例全绿；钉 COLUMNS 20/10/6 三档：有内容、逐格不超宽。
# ============================================================
if [[ "$TS_OK" -ne 1 ]]; then
    skip T118 "node with .ts type-stripping not available"
else
    T118_BR='[{"type":"compaction"},{"type":"message","message":{"role":"assistant","usage":{"input":743000,"output":117000,"cacheRead":19560000,"cacheWrite":0}}}]'
    t118_run() {  # $1 = WIDTH
        env -u HERDR_WORKSPACE_ID -u HERDR_TAB_ID -u HERDR_PANE_ID NO_COLOR=1 WIDTH="$1" BRANCH="$T118_BR" TTFT_MS=12400 MSG_UPDATES=0 \
            MODEL_NAME=m CTX_USAGE='{"tokens":284200,"contextWindow":1000000,"percent":28.42}' \
            WREN_TS="$WREN_TS" TUI_STUB="$PI_DIR/tui-stub.mjs" \
            node --import "$PI_DIR/register.mjs" "$PI_DIR/harness.mjs" 2>/dev/null | tail -1
    }
    t118_20="$(t118_run 20)"; t118_10="$(t118_run 10)"; t118_6="$(t118_run 6)"
    t118_ok=1
    # 逐格钉形：预算 15/5/4（梯子丢空后硬截到预算宽）
    [[ "$t118_20" == "743K/117K|▄28% " ]] || t118_ok=0
    [[ "$t118_10" == "743K/" ]] || t118_ok=0
    [[ "$t118_6" == "743K" ]] || t118_ok=0
    if [[ $t118_ok -eq 1 ]]; then
        pass T118 "pi narrow budget floor max(4,W-5): W=20/10/6 -> exact truncated forms"
    else
        fail T118 "20=[$t118_20] 10=[$t118_10] 6=[$t118_6]"
    fi
fi

# ============================================================
# T119: pi 徽标两遍锁定（变异补测）——整删两遍重拼后现有用例全绿；
#       39 格长 herdr 标签 + 51 列把徽标挤出自然序，第二遍（徽标优先）
#       必须保住前缀位，herdr 让位。
# ============================================================
if [[ "$TS_OK" -ne 1 ]]; then
    skip T119 "node with .ts type-stripping not available"
else
    T119_X="$(printf 'x%.0s' {1..33})"
    T119_OUT="$(env -u HERDR_WORKSPACE_ID -u HERDR_TAB_ID -u HERDR_PANE_ID NO_COLOR=1 WIDTH=51 TTFT_MS=12400 MSG_UPDATES=0 \
        HERDR_WORKSPACE_ID=w9 HERDR_TAB_ID="w9:$T119_X" HERDR_PANE_ID=w9:p1 \
        WREN_TS="$WREN_TS" TUI_STUB="$PI_DIR/tui-stub.mjs" \
        node --import "$PI_DIR/register.mjs" "$PI_DIR/harness.mjs" 2>/dev/null)"
    T119_L1="$(printf '%s' "$T119_OUT" | head -1)"
    T119_N="$(printf '%s\n' "$T119_OUT" | wc -l | tr -d ' ')"
    t119_ok=1
    # 物理极限区：徽标铁律保住（前缀位），长 herdr 让位，2 行契约不破。
    # 断言 cwd 无关（任意 checkout 下尾缀 | pi 成立），长标签逐字不在场
    [[ "$T119_L1" == *" | pi" ]] || t119_ok=0
    printf '%s' "$T119_L1" | grep -qF "w9:$T119_X" && t119_ok=0
    [[ $T119_N -eq 2 ]] || t119_ok=0
    if [[ $t119_ok -eq 1 ]]; then
        pass T119 "pi badge two-pass lock: long herdr yields, badge keeps prefix slot at floor width"
    else
        fail T119 "l1=[$T119_L1] n=$T119_N"
    fi
fi

# ============================================================
# T120: pi 模型名/思考等级压平 + 尾斜杠空段回落（交叉审 P1/P2）——
#       与 cc one_line(raw).split("/")[-1] or "?" 同口径；注入 \n
#       不得顶飞 2 行契约，"prefix/" 不得留悬空 "| ·" 尾。
# ============================================================
if [[ "$TS_OK" -ne 1 ]]; then
    skip T120 "node with .ts type-stripping not available"
else
    T120_BR='[{"type":"compaction"},{"type":"message","message":{"role":"assistant","usage":{"input":743000,"output":117000,"cacheRead":19560000,"cacheWrite":0}}}]'
    t120_run() {  # $@ = 额外 env；W=90 宽档（身份组形态与窄档共用解析）
        env -u HERDR_WORKSPACE_ID -u HERDR_TAB_ID -u HERDR_PANE_ID NO_COLOR=1 WIDTH=90 BRANCH="$T120_BR" TTFT_MS=12400 MSG_UPDATES=0 "$@" \
            WREN_TS="$WREN_TS" TUI_STUB="$PI_DIR/tui-stub.mjs" \
            node --import "$PI_DIR/register.mjs" "$PI_DIR/harness.mjs" 2>/dev/null
    }
    t120_a="$(t120_run MODEL_NAME=$'evil\nmodel' THINKING=$'high\nx')"
    t120_b="$(t120_run MODEL_NAME='anthropic/' | tail -1)"
    t120_c="$(t120_run MODEL_NAME=$'\n' | tail -1)"
    t120_d="$(t120_run THINKING=$'\n' | tail -1)"
    t120_a_n="$(printf '%s\n' "$t120_a" | wc -l | tr -d ' ')"
    t120_ok=1
    # P1：换行压平进段，2 行契约不破
    printf '%s' "$t120_a" | grep -qF "evilmodel · highx" || t120_ok=0
    [[ $t120_a_n -eq 2 ]] || t120_ok=0
    # P2：尾斜杠空段回落 "?"，无悬空 "| ·"
    printf '%s' "$t120_b" | grep -qF "| ? · high" || t120_ok=0
    printf '%s' "$t120_b" | grep -qF "| ·" && t120_ok=0
    # 纯换行模型名压平后为空 → 同样回落 "?"
    printf '%s' "$t120_c" | grep -qF "| ? · high" || t120_ok=0
    # 思考等级压平后为空 → 不进段表（无尾随 " · "）
    printf '%s' "$t120_d" | grep -qE '\| claude-opus-5$' || t120_ok=0
    printf '%s' "$t120_d" | grep -qF " · $" && t120_ok=0
    if [[ $t120_ok -eq 1 ]]; then
        pass T120 "pi model/thinking flattened; trailing-slash and empty-after-flatten fall back to '?'"
    else
        fail T120 "a(n=$t120_a_n)=[$(printf '%s' "$t120_a" | tr '\n' '~')] b=[$t120_b] c=[$t120_c] d=[$t120_d]"
    fi
fi

# ============================================================
#       CLAUDE_SETTINGS/OPENCODE_TUI_CONFIG 给裸文件名（无斜杠）时配置落 CWD，
#       payload 旧版落 $CLAUDE_CONFIG_DIR / ${OPENCODE_CONFIG_DIR}（分裂）；
#       QODER_SETTINGS 覆盖到别处时 qc payload 旧版仍钉死 ${QODER_CONFIG_DIR}。
#       修法：payload 落点跟随配置文件所在目录（cc/qc 绝对化，host 要绝对 command）。
# ============================================================
new_box
(cd "$BOX" && env NO_COLOR=1 PREFIX="$BIN" CLAUDE_CONFIG_DIR="$CLAUDE" CLAUDE_SETTINGS="settings.json" \
    "$WREN" install cc) >"$BOX/o110a.txt" 2>&1; t110a=$?
(cd "$BOX" && env NO_COLOR=1 PREFIX="$BIN" OPENCODE_CONFIG_DIR="$OC" OPENCODE_TUI_CONFIG="tui.json" \
    "$WREN" install oc) >"$BOX/o110b.txt" 2>&1; t110b=$?
(cd "$BOX" && env NO_COLOR=1 PREFIX="$BIN" QODER_CONFIG_DIR="$QODER" QODER_SETTINGS="$BOX/alt/q.json" \
    "$WREN" install qc) >"$BOX/o110c.txt" 2>&1; t110c=$?
if [[ $t110a -eq 0 && -f "$BOX/settings.json" && -f "$BOX/wren-cc" && ! -e "$CLAUDE/wren-cc" ]] \
   && [[ "$(json_field "$BOX/settings.json" 'd.get("statusLine",{}).get("command")')" == "$BOX/wren-cc" ]] \
   && [[ $t110b -eq 0 && -f "$BOX/tui.json" && -f "$BOX/plugins/wren-oc.tsx" && ! -e "$OC/plugins/wren-oc.tsx" ]] \
   && [[ "$(json_field "$BOX/tui.json" "d['plugin']")" == "['./plugins/wren-oc.tsx']" ]] \
   && [[ $t110c -eq 0 && -f "$BOX/alt/wren-qc.py" && ! -e "$QODER/wren-qc.py" ]] \
   && [[ "$(json_field "$BOX/alt/q.json" 'd.get("statusLine",{}).get("command")')" == "$BOX/alt/wren-qc.py" ]]; then
    pass T110 "bare-relative config env keeps payload next to config (cc/oc/qc)"
else
    fail T110 "a=$t110a[$(ls "$BOX" | tr '\n' ' ')] b=$t110b[$(ls "$BOX/plugins" 2>/dev/null | tr '\n' ' ')] c=$t110c[$(ls "$BOX/alt" 2>/dev/null | tr '\n' ' ')]"
fi

# ============================================================
# T111: B-4 plugin 数组嵌套对象误命中——find 只认数组顶层的字符串元素。
#       旧版 install 判「已存在」静默 no-op；uninstall 删嵌套 token 产出非法 JSON。
# ============================================================
new_box
printf '{\n  "plugin": [\n    { "src": "./plugins/wren-oc.tsx", "on": "session_start" }\n  ]\n}\n' >"$OCCONF"
run_wren install oc
t111_after="$(json_field "$OCCONF" "[repr(x) for x in d['plugin']]")"
run_wren uninstall oc
t111_valid="$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(repr(d['plugin']))" "$OCCONF" 2>&1)"
if [[ "$t111_after" == "[\"'./plugins/wren-oc.tsx'\", \"{'src': './plugins/wren-oc.tsx', 'on': 'session_start'}\"]" ]] \
   && [[ "$t111_valid" == "[{'src': './plugins/wren-oc.tsx', 'on': 'session_start'}]" ]] \
   && grep -qF '"src": "./plugins/wren-oc.tsx"' "$OCCONF"; then
    pass T111 "plugin-array scan matches top-level strings only; uninstall leaves object intact"
else
    fail T111 "after=[$t111_after] uninstalled=[$t111_valid] raw=[$(cat "$OCCONF" | tr '\n' '~')]"
fi

# ============================================================
# T112: B-5 配置是符号链接时不顶掉链接（chezmoi/stow 常态）——解引用写真实目标。
#       覆盖有效链接（cc settings + oc tui.json）与悬空链接（qc settings）。
# ============================================================
new_box
mkdir -p "$BOX/real"
printf '{"model":"m"}\n' >"$BOX/real/cc.json"
printf '{\n  "plugin": []\n}\n' >"$BOX/real/tui.json"
ln -s "$BOX/real/cc.json" "$SETTINGS"
ln -s "$BOX/real/tui.json" "$OCCONF"
ln -s "$BOX/nope/qc.json" "$QODER_SETTINGS"
t112_cc="$CLAUDE/wren-cc"; t112_qc="$QODER/wren-qc.py"
run_wren install all
if [[ "$WREN_EXIT" == "0" && -L "$SETTINGS" && -L "$OCCONF" && -L "$QODER_SETTINGS" ]] \
   && [[ "$(json_field "$SETTINGS" 'd.get("statusLine",{}).get("command")')" == "$t112_cc" ]] \
   && [[ "$(json_field "$OCCONF" "d['plugin']")" == "['./plugins/wren-oc.tsx']" ]] \
   && [[ -f "$BOX/nope/qc.json" ]] \
   && [[ "$(json_field "$BOX/nope/qc.json" 'd.get("statusLine",{}).get("command")')" == "$t112_qc" ]]; then
    pass T112 "symlinked configs resolved, links preserved (incl. dangling)"
else
    fail T112 "exit=$WREN_EXIT links=[$(ls -l "$SETTINGS" "$OCCONF" "$QODER_SETTINGS" 2>&1 | tr '\n' ' ')] cc=[$(cat "$SETTINGS" 2>/dev/null | tr '\n' '~')] qc=[$(cat "$BOX/nope/qc.json" 2>/dev/null | tr '\n' '~')]"
fi

# ============================================================
# T113: B-6 卸载不连用户子键一起删——只摘 wren 写入的 type/command，
#       装前用户原生 statusLine.padding 存活；空壳才整键删。
# ============================================================
new_box
printf '{"model":"m","statusLine":{"type":"command","command":"old-thing","padding":5}}\n' >"$SETTINGS"
run_wren install cc
run_wren uninstall cc
if [[ "$WREN_EXIT" == "0" && ! -e "$CLAUDE/wren-cc" ]] \
   && [[ "$(json_field "$SETTINGS" "repr(d.get('statusLine'))")" == "{'padding': 5}" ]] \
   && [[ "$(json_field "$SETTINGS" '"|".join(d.keys())')" == "model|statusLine" ]]; then
    pass T113 "uninstall strips only wren-written keys; user subkeys survive"
else
    fail T113 "sl=[$(json_field "$SETTINGS" 'repr(d.get("statusLine"))')] keys=[$(json_field "$SETTINGS" '"|".join(d.keys())')]"
fi

# ============================================================
# T114: B-2 herdr env 压平——oneLine（cc one_line 同字符集：
#       \n \r \v \f \x1c \x1d \x1e \x85 \u2028 \u2029），wren-oc.ts 导出、
#       wren-oc.tsx herdr 三段各自压平再 filter。含与 cc 侧逐字符集交叉验证。
# ============================================================
if [[ "$TS_OK" -ne 1 ]]; then
    skip T114 "node with .ts type-stripping not available"
else
    t114_out="$(OC_CORE="$OC_CORE_TS" node -e '
import(process.env.OC_CORE).then((m) => {
  const cases = ["a\nb", "x\u2028y", "w9\n:t1", "p\u00856", "q\u2029r\vs", "plain"];
  console.log(cases.map((s) => m.oneLine(s)).join("\n"));
});
' 2>&1)"
    t114_py="$(python3 -c '
cases = ["a\nb", "x\u2028y", "w9\n:t1", "p\u00856", "q\u2029r\vs", "plain"]
def one_line(s):
    return "".join(ch for ch in s if ch not in "\n\r\v\f\x1c\x1d\x1e\x85\u2028\u2029")
print("\n".join(one_line(s) for s in cases))')"
    if [[ "$t114_out" == "$t114_py" && "$t114_out" == $'ab\nxy\nw9:t1\np6\nqrs\nplain' ]] \
       && grep -qF "oneLine(process.env.HERDR_WORKSPACE_ID)" "$OC_PAYLOAD" \
       && grep -qF "oneLine(process.env.HERDR_TAB_ID" "$OC_PAYLOAD" \
       && grep -qF "oneLine(process.env.HERDR_PANE_ID" "$OC_PAYLOAD"; then
        pass T114 "oc oneLine flattens herdr envs; charset matches cc one_line"
    else
        fail T114 "ts=[$(printf '%s' "$t114_out" | tr '\n' '~')] py=[$(printf '%s' "$t114_py" | tr '\n' '~')]"
    fi
fi

# ============================================================
# T115: B-3 session_prompt 兜底不丢 props——契约意外变化（session_id 缺失）时
#       退回的裸 Prompt 必须透传白名单 + ref（结构钉：tsx 是 JSX，harness 无法
#       执行，行为面由 T101 真机 e2e 兜）。
# ============================================================
if grep -qF '<api.ui.Prompt sessionID={props?.session_id} visible={props?.visible} disabled={props?.disabled} onSubmit={props?.on_submit} ref={props?.ref} />' "$OC_PAYLOAD"; then
    pass T115 "session_prompt fallback passes through props (whitelist + ref)"
else
    fail T115 "tsx=[$(grep -n 'session_prompt' "$OC_PAYLOAD" | tr '\n' ' ')]"
fi

# ============================================================
# T121: 交叉审 Q1/Q2 —— 原生 stdin 字段净化（对齐 cc _nt 纪律）：
#       used_percentage NaN / total_input_tokens '500'（字符串）/ current_usage
#       Infinity / 负 used_percentage。非法一律当缺失走回落链，不出 nan/inf/负 %。
# ============================================================
new_box
t121_tr="$BOX/t121.jsonl"
printf '{"type":"user","timestamp":"2026-09-28T10:00:00Z","message":{"content":"a"}}\n{"type":"assistant","timestamp":"2026-09-28T10:00:07.4Z","message":{"usage":{"input_tokens":26254,"output_tokens":10,"cache_read_input_tokens":24064}}}\n' >"$t121_tr"
t121_run() {  # $1 = context_window JSON 片段，$2 = 缓存键
    printf '{"cwd":"/tmp","model":{"display_name":"m"},"context_window":%s,"transcript_path":"%s"}' "$1" "$t121_tr" \
        | NO_COLOR=1 COLUMNS=90 WREN_CACHE_DIR="$BOX/c116-$2" python3 "$QC_PAYLOAD" 2>/dev/null
}
t121a="$(t121_run '{"context_window_size":1000000,"used_percentage":NaN,"total_input_tokens":30000}' a)"
t121b="$(t121_run '{"context_window_size":1000000,"used_percentage":-5}' b)"
t121c="$(t121_run '{"context_window_size":1000000,"current_usage":{"input_tokens":Infinity,"cache_read_input_tokens":100}}' c)"
t121d="$(t121_run '{"context_window_size":1000000,"total_input_tokens":"500"}' d)"
t121_lines_a=$(printf '%s\n' "$t121a" | wc -l | tr -d ' ')
t121_lines_d=$(printf '%s\n' "$t121d" | wc -l | tr -d ' ')
if [[ "$t121_lines_a" == "2" && "$t121_lines_d" == "2" ]] \
   && printf '%s' "$t121a" | tail -1 | grep -qF "3.00%/1M" \
   && ! printf '%s' "$t121a" | grep -qi "nan" \
   && ! printf '%s' "$t121b" | grep -qF -- "-5" \
   && ! printf '%s' "$t121c" | grep -qi "inf" \
   && printf '%s' "$t121c" | tail -1 | grep -qF "CH100.00%"; then
    pass T121 "native stdin fields sanitized: NaN/str/Infinity fall back, negative pct not rendered"
else
    fail T121 "a=[$(printf '%s' "$t121a" | tr '\n' '~')] b=[$(printf '%s' "$t121b" | tr '\n' '~')] c=[$(printf '%s' "$t121c" | tr '\n' '~')] d=[$(printf '%s' "$t121d" | tr '\n' '~')]"
fi

# ============================================================
# T122: 变异存活（one_line 整删）—— display_name / runtime-config effort 带 \n
#       注入，输出必须恰好 2 行（行界顶破契约的复现面）。
# ============================================================
new_box
t122_tr="$BOX/t122.jsonl"
printf '{"type":"user","timestamp":"2026-09-28T10:00:00Z","message":{"content":"a"}}\n{"type":"assistant","timestamp":"2026-09-28T10:00:07.4Z","message":{"usage":{"input_tokens":100,"output_tokens":10,"cache_read_input_tokens":80}}}\n{"type":"runtime-config","reasoningEffort":"max\\nhigh"}\n' >"$t122_tr"
t122_out="$(printf '{"cwd":"/tmp","model":{"display_name":"Evil\\nModel"},"context_window":{"context_window_size":1000000},"transcript_path":"%s"}' "$t122_tr" \
    | NO_COLOR=1 COLUMNS=90 WREN_CACHE_DIR="$BOX/c117" python3 "$QC_PAYLOAD" 2>/dev/null)"
t122_n="$(printf '%s\n' "$t122_out" | wc -l | tr -d ' ')"
if [[ "$t122_n" == "2" ]] \
   && printf '%s' "$t122_out" | grep -qF "EvilModel" \
   && printf '%s' "$t122_out" | tail -1 | grep -qF "maxhigh"; then
    pass T122 "newline injection in display_name/effort flattened; exactly 2 lines"
else
    fail T122 "n=$t122_n out=[$(printf '%s' "$t122_out" | tr '\n' '~')]"
fi

# ============================================================
# T123: 变异存活（split("\\n") 回退 splitlines()）—— transcript 记录的 JSON
#       字符串字段含 U+2028：splitlines 会把该行拦腰斩断、记录丢失少记 token。
# ============================================================
new_box
python3 - "$BOX/t123.jsonl" <<'T123PY'
import json, sys
recs = [
    {"type": "user", "timestamp": "2026-09-28T10:00:00Z", "message": {"content": "a"}},
    {"type": "assistant", "timestamp": "2026-09-28T10:00:07.4Z",
     "message": {"usage": {"input_tokens": 52100, "output_tokens": 236, "cache_read_input_tokens": 47000},
                 "content": "paste\u2028with-line-separator"}},
]
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    for r in recs:
        fh.write(json.dumps(r, ensure_ascii=False) + "\n")
T123PY
t123_out="$(printf '{"cwd":"/tmp","model":{"display_name":"m"},"context_window":{"context_window_size":1000000,"total_input_tokens":30000},"transcript_path":"%s"}' "$BOX/t123.jsonl" \
    | NO_COLOR=1 COLUMNS=90 WREN_CACHE_DIR="$BOX/c118" python3 "$QC_PAYLOAD" 2>/dev/null | tail -1)"
if printf '%s' "$t123_out" | grep -qF "↑52K" && printf '%s' "$t123_out" | grep -qF "R47K"; then
    pass T123 "U+2028 inside record string does not lose the record (split by \\n only)"
else
    fail T123 "l2=[$t123_out]"
fi

# ============================================================
# T124: 变异存活（预算地板 max(4)→max(24)）—— COLUMNS ∈ {20,10,6}：
#       窄档有内容（徽标在场）且两行显示宽都 ≤ COLUMNS。
# ============================================================
new_box
t124_tr="$BOX/t124.jsonl"
printf '{"type":"user","timestamp":"2026-09-28T10:00:00Z","message":{"content":"a"}}\n{"type":"assistant","timestamp":"2026-09-28T10:00:07.4Z","message":{"usage":{"input_tokens":52100,"output_tokens":236,"cache_read_input_tokens":47000}}}\n' >"$t124_tr"
t124_ok=1
for w in 20 10 6; do
    printf '{"cwd":"/very/long/path/for/narrow/tier","model":{"display_name":"m"},"context_window":{"context_window_size":1000000,"used_percentage":3},"transcript_path":"%s"}' "$t124_tr" \
        | NO_COLOR=1 COLUMNS=$w WREN_CACHE_DIR="$BOX/c119-$w" python3 "$QC_PAYLOAD" >"$BOX/o119-$w.txt" 2>/dev/null
    n=$(grep -c '' "$BOX/o119-$w.txt")  # 文件无尾换行（两行契约即如此），grep -c '' 按"有内容的行"计
    maxw=$(python3 - "$BOX/o119-$w.txt" "$w" <<'T124PY'
import sys, unicodedata
w = 0
for ln in open(sys.argv[1], encoding="utf-8"):
    lw = sum(2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1 for ch in ln.rstrip("\n"))
    w = max(w, lw)
print("OVER" if w > int(sys.argv[2]) else "ok")
T124PY
)
    # 徽标两遍锁定在物理可容区（" | qc" = 5 格）才断言：COLUMNS=6 → 实绘 4 格，
    # 连徽标带分隔都放不下（物理极限区，与 cc 同边界），只钉「2 行 + 不超宽」
    if [[ "$w" -ge 20 ]]; then   # 徽标需 cwd 地板 4 + " | qc" 5 = 9 格实绘；20 列（实绘 15）才物理可容
        grep -q "qc" "$BOX/o119-$w.txt" || t124_ok=0
    fi
    [[ "$n" == "2" && "$maxw" == "ok" ]] || { t124_ok=0; echo "  w=$w n=$n width=$maxw" >&2; }
done
if [[ $t124_ok -eq 1 ]]; then
    pass T124 "extreme narrow (20/10/6 cols): 2 lines, qc badge, width within COLUMNS"
else
    fail T124 "see stderr"
fi

# ============================================================
# T125: 变异存活（四分位边界 off-by-one）—— 25/50/75 三个换档值，
#       双源（原生 used_percentage + postTokens 回落）都盖。
# ============================================================
new_box
t125_tr="$BOX/t125.jsonl"
printf '{"type":"user","timestamp":"2026-09-28T10:00:00Z","message":{"content":"a"}}\n{"type":"assistant","timestamp":"2026-09-28T10:00:07.4Z","message":{"usage":{"input_tokens":100,"output_tokens":10,"cache_read_input_tokens":80}}}\n{"type":"system","subtype":"compact_boundary","isSidechain":false,"compactMetadata":{"trigger":"manual","postTokens":250000}}\n' >"$t125_tr"
t125_ok=1
for pct in 25 50 75; do
    case $pct in 25) icon="▄" ;; 50) icon="▆" ;; 75) icon="█" ;; esac
    a="$(printf '{"cwd":"/tmp","model":{"display_name":"m"},"context_window":{"context_window_size":1000000,"used_percentage":%d},"transcript_path":"%s"}' "$pct" "$t125_tr" \
        | NO_COLOR=1 WREN_QC_NARROW=1 COLUMNS=51 WREN_CACHE_DIR="$BOX/c120n-$pct" python3 "$QC_PAYLOAD" 2>/dev/null | tail -1)"
    printf '%s' "$a" | grep -qF "${icon}${pct}%" || { t125_ok=0; echo "  native $pct=[$a]" >&2; }
done
for pct in 25 50 75; do
    case $pct in 25) icon="▄"; post=250000 ;; 50) icon="▆"; post=500000 ;; 75) icon="█"; post=750000 ;; esac
    tr2="$BOX/t125_$post.jsonl"
    printf '{"type":"user","timestamp":"2026-09-28T10:00:00Z","message":{"content":"a"}}\n{"type":"assistant","timestamp":"2026-09-28T10:00:07.4Z","message":{"usage":{"input_tokens":100,"output_tokens":10,"cache_read_input_tokens":80}}}\n{"type":"system","subtype":"compact_boundary","isSidechain":false,"compactMetadata":{"trigger":"manual","postTokens":%d}}\n' "$post" >"$tr2"
    b="$(printf '{"cwd":"/tmp","model":{"display_name":"m"},"context_window":{"context_window_size":1000000},"transcript_path":"%s"}' "$tr2" \
        | NO_COLOR=1 WREN_QC_NARROW=1 COLUMNS=51 WREN_CACHE_DIR="$BOX/c120f-$post" python3 "$QC_PAYLOAD" 2>/dev/null | tail -1)"
    printf '%s' "$b" | grep -qF "${icon}${pct}%" || { t125_ok=0; echo "  fallback $pct=[$b]" >&2; }
done
if [[ $t125_ok -eq 1 ]]; then
    pass T125 "quartile boundaries 25/50/75 pinned on both native and postTokens sources"
else
    fail T125 "see stderr"
fi

# ============================================================
# T126: cc 徽标两遍锁定——自然序放不下徽标时 rescue 重拼（变异 M7b 守门：
#   交叉审 18 变异 8 存活之一；cwd 含 "cc" 子串同时钉 T2 的入选索引判定）
# ============================================================
new_box
mkdir -p "$BOX/acc"
t126=$(printf '{"cwd":"%s","model":{"display_name":"m"}}' "$BOX/acc" \
    | NO_COLOR=1 COLUMNS=24 HERDR_WORKSPACE_ID=wW HERDR_TAB_ID=wW:t12 HERDR_PANE_ID=wW:p34 \
      python3 "$CC_PAYLOAD" 2>/dev/null | head -1)
# 24 列：herdr(13) 吃掉自然序尾部 → rescue 必须保 " | cc" 在行内
if printf '%s' "$t126" | grep -qF "| cc"; then
    pass T126 "cc badge two-pass lock: rescue keeps badge at 24 cols (cwd has cc substring)"
else
    fail T126 "24col=[$t126]"
fi

# ============================================================
# T127: BUG1 徽标保住判定不能拿子串猜——cwd 折叠后含 "qc"（/tmp/xqc）时
#       'qc' not in line1 误判已保住、跳过 rescue。判定必须用入选索引
#       （对齐 cc 7ee3794 的 assemble_l1_report 模式）。
#       24 列：natural 序 herdr 在/徽标出 → rescue 后徽标必须在场；
#       51 列 + 38 格 herdr 同款（cwd+herdr 放得下、+徽标放不下）。
# ============================================================
new_box
t127_env() {  # $1 = COLUMNS, $2 = herdr 三段
    printf '{"cwd":"/tmp/xqc","model":{"display_name":"m"},"context_window":{"context_window_size":1000000,"used_percentage":3}}' \
        | NO_COLOR=1 COLUMNS=$1 HERDR_WORKSPACE_ID=$2 HERDR_TAB_ID=$3 HERDR_PANE_ID=$4 \
            WREN_CACHE_DIR="$BOX/c127-$1" python3 "$QC_PAYLOAD" 2>/dev/null | head -1
}
t127_a="$(t127_env 24 wW t12 p34)"
t127_b="$(t127_env 51 wW t1234567890123456789012345678901 p34)"
if printf '%s' "$t127_a" | grep -qF " | qc" \
   && printf '%s' "$t127_b" | grep -qF " | qc"; then
    pass T127 "badge rescue decided by taken-index, not substring (cwd containing qc)"
else
    fail T127 "24=[$t127_a] 51=[$t127_b]"
fi

# ============================================================
# T128: BUG5 跨宿主缓存键碰撞——cc 与 qc 共用 ~/.cache/wren 且键同为
#       sha1(path)[:16].json。同一 transcript 两宿主先后读，后读方继承
#       先写方 last_prompt_tokens 语义（两宿主 CH 口径不同）。
#       fixture：input=10000, cache_read=8000 →
#       cc 口径 CH = 8000/(10000+8000) = 44.44%；qc 口径 CH = 8000/10000 = 80.00%。
#       断言：cc 先跑、qc 后跑（同缓存目录）→ qc 仍显 80.00%（键已掺宿主标识）。
# ============================================================
new_box
t128_tr="$BOX/t128.jsonl"
printf '{"type":"user","timestamp":"2026-09-28T10:00:00Z","message":{"content":"a"}}\n{"type":"assistant","timestamp":"2026-09-28T10:00:05Z","message":{"usage":{"input_tokens":10000,"output_tokens":10,"cache_read_input_tokens":8000,"cache_creation_input_tokens":0}}}\n' >"$t128_tr"
printf '{"cwd":"/tmp","model":{"display_name":"m"},"transcript_path":"%s"}' "$t128_tr" \
    | NO_COLOR=1 COLUMNS=90 WREN_CACHE_DIR="$BOX/shared" python3 "$CC_PAYLOAD" >/dev/null 2>&1
t128_qc="$(printf '{"cwd":"/tmp","model":{"display_name":"m"},"transcript_path":"%s"}' "$t128_tr" \
    | NO_COLOR=1 COLUMNS=90 WREN_CACHE_DIR="$BOX/shared" python3 "$QC_PAYLOAD" 2>/dev/null | tail -1)"
if printf '%s' "$t128_qc" | grep -qF "CH80.00%" && ! printf '%s' "$t128_qc" | grep -qF "CH44.44%"; then
    pass T128 "cross-host cache keys do not collide (qc after cc keeps qc CH semantics)"
else
    fail T128 "qc=[$t128_qc]"
fi

# ============================================================
# T129: BUG6 空串 user content 不开 TTFT 窗——message.content='' 的记录
#       不是轮首（对齐 cc F2 语义：bool(content)）。5s 后 assistant 落盘
#       不得显示 TTFT；对照：content='a' 的同形 transcript 显示 TTFT 5.0s。
# ============================================================
new_box
printf '{"type":"user","timestamp":"2026-09-28T10:00:00Z","message":{"content":""}}\n{"type":"assistant","timestamp":"2026-09-28T10:00:05Z","message":{"usage":{"input_tokens":100,"output_tokens":10,"cache_read_input_tokens":80}}}\n' >"$BOX/t129a.jsonl"
printf '{"type":"user","timestamp":"2026-09-28T10:00:00Z","message":{"content":"a"}}\n{"type":"assistant","timestamp":"2026-09-28T10:00:05Z","message":{"usage":{"input_tokens":100,"output_tokens":10,"cache_read_input_tokens":80}}}\n' >"$BOX/t129b.jsonl"
t129a="$(printf '{"cwd":"/tmp","model":{"display_name":"m"},"transcript_path":"%s"}' "$BOX/t129a.jsonl" \
    | NO_COLOR=1 COLUMNS=90 WREN_CACHE_DIR="$BOX/c129a" python3 "$QC_PAYLOAD" 2>/dev/null | tail -1)"
t129b="$(printf '{"cwd":"/tmp","model":{"display_name":"m"},"transcript_path":"%s"}' "$BOX/t129b.jsonl" \
    | NO_COLOR=1 COLUMNS=90 WREN_CACHE_DIR="$BOX/c129b" python3 "$QC_PAYLOAD" 2>/dev/null | tail -1)"
if ! printf '%s' "$t129a" | grep -qE "TTFT" \
   && printf '%s' "$t129b" | grep -qF "TTFT 5.0s"; then
    pass T129 "empty-string user content does not open the TTFT window"
else
    fail T129 "empty=[$t129a] control=[$t129b]"
fi

# ============================================================
# T130: pi transcript usage 净化（第七轮 BUG4）——猎杀四轮 tok() 只盖了
#       cc/qc，pi 裸 += 会被负值/字符串/NaN 污染：负值带负号进渲染、字符串
#       += 串接（"0500"）、负 cacheWrite 缩 CH 分母虚高到 100%。三注入形态
#       全钳 0（typeof number + isFinite + >0）。
# ============================================================
if [[ "$TS_OK" -ne 1 ]]; then
    skip T130 "node with .ts type-stripping not available"
else
    t130_run() {  # $1 = BRANCH json
        env -u HERDR_WORKSPACE_ID -u HERDR_TAB_ID -u HERDR_PANE_ID NO_COLOR=1 WIDTH=90 BRANCH="$1" TTFT_MS=12400 MSG_UPDATES=0 MODEL_NAME=m \
            WREN_TS="$WREN_TS" TUI_STUB="$PI_DIR/tui-stub.mjs" \
            node --import "$PI_DIR/register.mjs" "$PI_DIR/harness.mjs" 2>/dev/null | tail -1
    }
    t130_a="$(t130_run '[{"type":"message","message":{"role":"assistant","usage":{"input":-50,"output":-7,"cacheRead":-100,"cacheWrite":-100}}}]')"
    t130_b="$(t130_run '[{"type":"message","message":{"role":"assistant","usage":{"input":"500","cacheRead":"300","output":"7"}}}]')"
    t130_c="$(t130_run '[{"type":"message","message":{"role":"assistant","usage":{"input":100,"cacheRead":50,"cacheWrite":-100}}}]')"
    t130_ok=1
    # a/b：负值与字符串全钳 0（无负号、无串接数字、无 NaN）
    [[ "$t130_a" == "↑0 ↓0 | R0 | ?/200K TTFT 12s | m · high" ]] || t130_ok=0
    [[ "$t130_b" == "↑0 ↓0 | R0 | ?/200K TTFT 12s | m · high" ]] || t130_ok=0
    for l in "$t130_a" "$t130_b"; do
        printf '%s' "$l" | grep -qE '\-|NaN' && t130_ok=0
    done
    # c：负 cacheWrite 不再缩 CH 分母（150 分母 → 33.33%，非 100%）
    printf '%s' "$t130_c" | grep -qF "CH33.33%" || t130_ok=0
    printf '%s' "$t130_c" | grep -qF "CH100.00%" && t130_ok=0
    if [[ $t130_ok -eq 1 ]]; then
        pass T130 "pi usage sanitized: negative/string -> 0, negative cacheWrite no longer inflates CH"
    else
        fail T130 "a=[$t130_a] b=[$t130_b] c=[$t130_c]"
    fi
fi

# ============================================================
# T131: 宽档 .2f 半值三侧同偶（第七轮 BUG2）——pi/oc 的 toFixed(2) 是半上，
#       cc 的 Python :.2f 是半偶。0.125%（250/200000，二进制精确）与
#       CH 12.125%（485/4000）两个精确半值：三侧统一半偶（pi/oc 改，
#       cc/qc 现状即半偶不动）。
# ============================================================
if [[ "$TS_OK" -ne 1 ]]; then
    skip T131 "node with .ts type-stripping not available"
else
    # pi：ctx percent=0.125 + CH 485/4000
    t131_pi="$(env -u HERDR_WORKSPACE_ID -u HERDR_TAB_ID -u HERDR_PANE_ID NO_COLOR=1 WIDTH=90 \
        BRANCH='[{"type":"message","message":{"role":"assistant","usage":{"input":3515,"output":0,"cacheRead":485,"cacheWrite":0}}}]' \
        TTFT_MS=12400 MSG_UPDATES=0 MODEL_NAME=m CTX_USAGE='{"tokens":250,"contextWindow":200000,"percent":0.125}' \
        WREN_TS="$WREN_TS" TUI_STUB="$PI_DIR/tui-stub.mjs" \
        node --import "$PI_DIR/register.mjs" "$PI_DIR/harness.mjs" 2>/dev/null | tail -1)"
    # cc 同值对照（ctx 与 CH 共用一条 native 记录，拆两跑）：
    #   cc-ctx：input=250 → 250/200000 = 0.125% → 0.12%（CH 无 cache 不显示）
    #   cc-ch：input=3515 + cache_read=485 → 485/4000 = 12.125% → CH12.12%
    t131_ccctx="$(printf '{"cwd":"/tmp","model":{"display_name":"m"},"effort":{"level":"xhigh"},"context_window":{"current_usage":{"input_tokens":250,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"context_window_size":200000}}' \
        | NO_COLOR=1 COLUMNS=90 python3 "$CC_PAYLOAD" 2>/dev/null | tail -1)"
    t131_ccch="$(printf '{"cwd":"/tmp","model":{"display_name":"m"},"effort":{"level":"xhigh"},"context_window":{"current_usage":{"input_tokens":3515,"cache_read_input_tokens":485,"cache_creation_input_tokens":0},"context_window_size":200000}}' \
        | NO_COLOR=1 COLUMNS=90 python3 "$CC_PAYLOAD" 2>/dev/null | tail -1)"
    # oc：同值 buildLines（纯函数直调）
    t131_oc="$(OC_CORE="$OC_CORE_TS" node -e '
import(process.env.OC_CORE).then((m) => {
  const lines = m.buildLines({width:90, cwd:"/tmp", home:"/h", branch:null, head:"", ab:"",
    added:0, modified:0, deleted:0, herdr:"", durationMs:60000,
    inputTokens:3515, outputTokens:0, cacheRead:485, cacheWrite:0, compactions:0,
    ctxPercent:0.125, ctxWindow:200000, model:"m", thinking:"high", ttftMs:null});
  const texts = lines.flat().map((s) => s.text).join("|");
  const ch = /CH[0-9.]+%/.exec(texts);
  const ctx = /[0-9.]+%\/[^ |]*/.exec(texts);
  console.log((ch ? ch[0] : "NO-CH") + " " + (ctx ? ctx[0] : "NO-CTX"));
});' 2>&1)"
    t131_ok=1
    printf '%s' "$t131_pi" | grep -qF "CH12.12%" || t131_ok=0
    printf '%s' "$t131_pi" | grep -qF "0.12%/200K" || t131_ok=0
    printf '%s' "$t131_ccch" | grep -qF "CH12.12%" || t131_ok=0
    printf '%s' "$t131_ccctx" | grep -qF "0.12%/200K" || t131_ok=0
    printf '%s' "$t131_oc" | grep -qF "CH12.12% 0.12%/200K" || t131_ok=0
    # 半上变体必须不在场（toFixed(2) 会给 12.13/0.13）
    for l in "$t131_pi" "$t131_ccch" "$t131_ccctx" "$t131_oc"; do
        printf '%s' "$l" | grep -qE '12\.13|0\.13' && t131_ok=0
    done
    if [[ $t131_ok -eq 1 ]]; then
        pass T131 "wide .2f half-even parity across pi/oc/cc: 0.125% -> 0.12, CH 12.125% -> 12.12"
    else
        fail T131 "pi=[$t131_pi] ccctx=[$t131_ccctx] ccch=[$t131_ccch] oc=[$t131_oc]"
    fi
fi

# ============================================================
# T132: pi 窄档量化链（第七轮 BUG3）——cc 先 :.2f 量化再 :.0f；pi 拿原始
#       double 会差一档（25.499999 → 25 vs cc 26）。裁定：窄档链 = 量化(2位
#       半偶) → 四分位/整数，色档阈值同读量化值（cc pct_val 同源）。
# ============================================================
if [[ "$TS_OK" -ne 1 ]]; then
    skip T132 "node with .ts type-stripping not available"
else
    t132_run() {  # $1 = percent
        env -u HERDR_WORKSPACE_ID -u HERDR_TAB_ID -u HERDR_PANE_ID NO_COLOR=1 WIDTH=51 \
            BRANCH='[{"type":"message","message":{"role":"assistant","usage":{"input":743000,"output":117000,"cacheRead":19560000,"cacheWrite":0}}}]' \
            TTFT_MS=12400 MSG_UPDATES=0 MODEL_NAME=m CTX_USAGE="{\"tokens\":1,\"contextWindow\":1000000,\"percent\":$1}" \
            WREN_TS="$WREN_TS" TUI_STUB="$PI_DIR/tui-stub.mjs" \
            node --import "$PI_DIR/register.mjs" "$PI_DIR/harness.mjs" 2>/dev/null | tail -1
    }
    t132_cc="$(printf '{"cwd":"/tmp","model":{"display_name":"m"},"effort":{"level":"xhigh"},"context_window":{"current_usage":{"input_tokens":254960,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"context_window_size":1000000}}' \
        | NO_COLOR=1 COLUMNS=51 python3 "$CC_PAYLOAD" 2>/dev/null | tail -1)"
    t132_ok=1
    # 25.499999 / 25.496：量化到 25.50 → 半偶取整 26（旧行为 25，差一档）
    printf '%s' "$(t132_run 25.499999)" | grep -qF "▄26%" || t132_ok=0
    printf '%s' "$(t132_run 25.496)" | grep -qF "▄26%" || t132_ok=0
    # cc 同带（254960/1M = 25.496% → 量化 25.50 → ▄26%）交叉验证
    printf '%s' "$t132_cc" | grep -qF "▄26%" || t132_ok=0
    # 色档同读量化值：70.001 → 量化 70.00 → 三档色 green（旧行为 raw>70 → yellow）
    t132_col="$(env -u HERDR_WORKSPACE_ID -u HERDR_TAB_ID -u HERDR_PANE_ID NO_COLOR= COLOR_MODE=truecolor WIDTH=90 \
        BRANCH='[{"type":"message","message":{"role":"assistant","usage":{"input":743000,"output":117000,"cacheRead":19560000,"cacheWrite":0}}}]' \
        TTFT_MS=12400 MSG_UPDATES=0 MODEL_NAME=m CTX_USAGE='{"tokens":140002,"contextWindow":200000,"percent":70.001}' \
        WREN_TS="$WREN_TS" TUI_STUB="$PI_DIR/tui-stub.mjs" \
        node --import "$PI_DIR/register.mjs" "$PI_DIR/harness.mjs" 2>/dev/null | tail -1)"
    printf '%s' "$t132_col" | grep -qF '38;2;80;250;123' || t132_ok=0
    printf '%s' "$t132_col" | grep -qF '38;2;241;250;140' && t132_ok=0
    if [[ $t132_ok -eq 1 ]]; then
        pass T132 "pi narrow quantize chain: 2dp half-even then int; color reads quantized (cc parity)"
    else
        fail T132 "p1=[$(t132_run 25.499999)] p2=[$(t132_run 25.496)] cc=[$t132_cc] col=[$(printf '%s' "$t132_col" | LC_ALL=C sed 's/\x1b/ESC/g')]"
    fi
fi

# ============================================================
# T133: oc foldBranch 档位契约对齐（深度审核·决策落地）——旧单公式
#       head8+…+tail(maxLen−9) 在 <24 档违反预算（12 档折出 14 格、8 档丢
#       …），靠行1 出口硬截遮住。移植 cc/qc/pi 的六级+特例：24 档 8/15 同构、
#       <24 三七开、≤4 …+尾段、0 空串；folds 表补 4/0 档。
# ============================================================
if [[ "$TS_OK" -ne 1 ]]; then
    skip T133 "node with .ts type-stripping not available"
else
    t133_out="$(OC_CORE="$OC_CORE_TS" node -e '
import(process.env.OC_CORE).then((m) => {
  const b = "verylongbranchname-x";
  const rows = [];
  for (const n of [24, 12, 8, 4, 0]) {
    const r = m.foldBranch(b, n);
    rows.push(`${n}|${r}|${m.visibleWidth(r)}`);
  }
  const cjk = "一二三四五六七八九十百千万亿甲乙丙".slice(0, 13);
  const c = m.foldBranch(cjk, 12);
  rows.push(`cjk|${c}|${m.visibleWidth(c)}`);
  rows.push(`short|${m.foldBranch("feat/x", 12)}`);
  const l1 = (w) => {
    const lines = m.buildLines({width:w, cwd:"/tmp", home:"/h", branch:b, head:b,
      ab:" ↑1↓2", added:3, modified:1, deleted:2, herdr:"w9:t1:p1", durationMs:3600000,
      inputTokens:100, outputTokens:50, cacheRead:200, cacheWrite:0, compactions:0,
      ctxPercent:12.5, ctxWindow:200000, model:"m", thinking:"high", ttftMs:null});
    const seg = lines[0];
    const wsum = seg.reduce((a, s) => a + m.visibleWidth(s.text), 0);
    const br = seg.find((s) => s.tone === "purple");
    return `L1:${w}:${wsum}:${br ? br.text : "-"}`;
  };
  for (const w of [30, 26, 22]) rows.push(l1(w));
  console.log(rows.join("\n"));
});' 2>&1)"
    t133_ok=1
    # 24 档：20 ≤ 24 整名直过
    printf '%s' "$t133_out" | grep -qF '24|verylongbranchname-x|20' || t133_ok=0
    # 12 档：ver…chname-x 恰 12 格（旧公式给 verylong…e-x 14 格）
    printf '%s' "$t133_out" | grep -qF '12|ver…chname-x|12' || t133_ok=0
    # 8 档：ver…me-x 恰 8 格带 …（旧公式 verylong 无 …）
    printf '%s' "$t133_out" | grep -qF '8|ver…me-x|8' || t133_ok=0
    # 4 档：…+尾3 恰 4 格（三侧公式 max(2, maxLen−1)；≤3 档才 …+尾2）
    printf '%s' "$t133_out" | grep -qF '4|…e-x|4' || t133_ok=0
    # 0 档：空串（git 段让位）
    printf '%s' "$t133_out" | grep -qF '0||0' || t133_ok=0
    # CJK 13 码点 26 格：按格折（12 档内、非原串）
    printf '%s' "$t133_out" | grep -E '^cjk\|' | grep -qF '一二三四五六七八九十百千万亿甲' && t133_ok=0
    printf '%s' "$t133_out" | awk -F'|' '$1=="cjk" && $3+0>12 {exit 1}' || t133_ok=0
    # 短名不折
    printf '%s' "$t133_out" | grep -qF 'short|feat/x' || t133_ok=0
    # 行1 级联：三档宽度都在预算内；26 列命中新 4 档（…e-x 在场证明 folds 表补档生效）
    printf '%s' "$t133_out" | grep -qF 'L1:30:30:' || t133_ok=0
    printf '%s' "$t133_out" | grep -qF 'L1:26:25:…e-x' || t133_ok=0
    printf '%s' "$t133_out" | grep -qF 'L1:22:21:' || t133_ok=0
    if [[ $t133_ok -eq 1 ]]; then
        pass T133 "oc foldBranch tiers match cc/qc/pi: 8/15 at 24, 30/70 below, …+tail at 4, empty at 0; folds table has 4/0"
    else
        fail T133 "out=[$(printf '%s' "$t133_out" | tr '\n' '~')]"
    fi
fi

# ============================================================
# T134: 决策 2 —— ab 优先于 cwd 地板：行1 让位穷举把 with_ab 提到 floor 外层。
#       46-52 列四档 ab（↑1↓0）恒在，cwd 提前折短代替闪灭 ab。
#       fixture：带上游 ahead=1 的干净 repo + 12 格 herdr（48-52 为旧序红带：
#       旧序 floor 外层会在 [43,47] 实绘带选「floor16+丢 ab」而非「floor8+保 ab」）。
# ============================================================
new_box
T134_REPO="$BOX/r134"
T134_REMOTE="$BOX/r134_remote"
mkdir -p "$T134_REPO"
(
    cd "$T134_REPO" || exit 1
    git -c init.defaultBranch=main init -q
    git config user.email t@example.com
    git config user.name t
    printf 'a\n' >a.txt
    git add -A >/dev/null 2>&1
    git commit -q -m init >/dev/null 2>&1
    git init -q --bare "$T134_REMOTE"
    git remote add origin "$T134_REMOTE"
    git push -q -u origin main >/dev/null 2>&1
    printf 'b\n' >>a.txt
    git add -A >/dev/null 2>&1
    git commit -q -m second >/dev/null 2>&1
) >/dev/null 2>&1
t134_ok=1
for w in 46 48 50 52; do
    out="$(printf '{"cwd":"%s","model":{"display_name":"m"},"context_window":{"context_window_size":1000000,"used_percentage":3}}' "$T134_REPO" \
        | NO_COLOR=1 COLUMNS=$w HERDR_WORKSPACE_ID=wW HERDR_TAB_ID=wW:t1234 HERDR_PANE_ID=wW:p5678 \
            WREN_CACHE_DIR="$BOX/c134-$w" python3 "$QC_PAYLOAD" 2>/dev/null | head -1)"
    printf '%s' "$out" | grep -qF "↑1↓0" || { t134_ok=0; echo "  w=$w l1=[$out]" >&2; }
    printf '%s' "$out" | grep -qF "| qc" || { t134_ok=0; echo "  w=$w badge-missing l1=[$out]" >&2; }
done
if [[ $t134_ok -eq 1 ]]; then
    pass T134 "ab survives cwd-floor sacrifice at 46-52 cols (with_ab hoisted above floor)"
else
    fail T134 "see stderr"
fi

# ============================================================
# T135: 决策 3 —— 缓存清扫：CACHE_DIR 里 .json 超过 200 个时按 mtime 删最旧
#       （cc-*/qc-*/无前缀三种都盖，模式就是 *.json）。渲染一次后 ≤200、
#       最旧的没了、本次会话的 qc-<sha1> 键与较新文件存活。
# ============================================================
new_box
t135_tr="$BOX/t135.jsonl"
printf '{"type":"user","timestamp":"2026-09-28T10:00:00Z","message":{"content":"a"}}\n{"type":"assistant","timestamp":"2026-09-28T10:00:07.4Z","message":{"usage":{"input_tokens":100,"output_tokens":10,"cache_read_input_tokens":80}}}\n' >"$t135_tr"
mkdir -p "$BOX/cache"
i=0
while [[ $i -lt 205 ]]; do
    printf '{}' >"$BOX/cache/fake$i.json"
    # mtime 逐个递增（2025-01-01 00:mm:ss）：格式串只能有一个转换符——
    # 写成 'YYYYMMDDhh%02d' 再传两个参数时，bash printf 会重复整个格式串，
    # 拼出 24 字符 → BSD touch 全数拒收、mtime 钉死形同虚设（2026-10-12 实测）
    touch -t "20250101$(printf '%02d' $((i / 60)))$(printf '%02d' $((i % 60)))" "$BOX/cache/fake$i.json"
    i=$((i + 1))
done
printf '{"cwd":"/tmp","model":{"display_name":"m"},"transcript_path":"%s"}' "$t135_tr" \
    | NO_COLOR=1 COLUMNS=90 WREN_CACHE_DIR="$BOX/cache" python3 "$QC_PAYLOAD" >/dev/null 2>&1
t135_n=$(ls "$BOX/cache" | grep -c '\.json$')
if [[ "$t135_n" -le 200 && "$t135_n" -ge 199 ]] \
   && [[ ! -e "$BOX/cache/fake0.json" ]] \
   && ls "$BOX/cache" | grep -q "^qc-" \
   && [[ -e "$BOX/cache/fake204.json" ]]; then
    pass T135 "cache swept to <=200 by mtime; oldest gone, session key + newest survive"
else
    fail T135 "n=$t135_n fake0=$([[ -e $BOX/cache/fake0.json ]] && echo y || echo n) qckey=$(ls "$BOX/cache" | grep -c '^qc-')"
fi

# ============================================================
# T136: cc 物理极限区色档幻影分隔符——清空 git 段后 colored_git 是纯 ANSI
#   包裹空串，.strip() 剥不掉转义（终审 3.1；NO_COLOR 用例全绿因无色档下
#   c() 原样返回空串恰好掩盖）。truecolor 26/30 列断言无 ' | ' 空槽/尾悬空。
# ============================================================
new_box
mkdir -p "$BOX/pk"
(cd "$BOX/pk" && git init -q -b main && git config user.email t@e.com && git config user.name t \
    && : >f && git add -A && git commit -qm i && printf 'x\n' >>f) >/dev/null 2>&1
t136() {
    printf '{"cwd":"%s","model":{"display_name":"m"}}' "$BOX/pk" \
        | COLORTERM=truecolor COLUMNS=$1 HERDR_WORKSPACE_ID=wW HERDR_TAB_ID=wW:t12 HERDR_PANE_ID=wW:p34 \
          WREN_CACHE_DIR="$BOX/t136-$1" python3 "$CC_PAYLOAD" 2>/dev/null | head -1 \
        | python3 -c "import sys,re; print(re.sub(r'\x1b\\[[0-9;]*m','',sys.stdin.read().rstrip()))"
}
t136_26="$(t136 26)"; t136_30="$(t136 30)"
# 无空槽（' |  | '）无尾悬空（以 ' | ' 或 '|' 结尾）
t136_ok=1
printf '%s' "$t136_26" | grep -qF '|  |' && t136_ok=0
printf '%s' "$t136_26" | grep -qE '( \| |\|)$' && t136_ok=0
printf '%s' "$t136_30" | grep -qF '|  |' && t136_ok=0
printf '%s' "$t136_30" | grep -qE '( \| |\|)$' && t136_ok=0
if [[ $t136_ok -eq 1 ]]; then
    pass T136 "cc physical-limit colored phantom separator absent (26/30 cols truecolor)"
else
    fail T136 "26=[$t136_26] 30=[$t136_30]"
fi

# ============================================================
# T137: pi 物理极限区色档幻影分隔符（终审九轮 #1）——分支折到 0 档后
#       coloredGit 是纯 ANSI 包裹（cAt 包空串），truthy 判剥不掉 → 幻影
#       ' | ' 空槽 + 3 格幻影宽偷 cwd。彩色档下剥色后无 '|  |' 双竖、行1
#       以徽标收尾；且首帧 none/上色两帧渲染一致（跨帧不闪）。
# ============================================================
if [[ "$TS_OK" -ne 1 ]]; then
    skip T137 "node with .ts type-stripping not available"
else
    new_box
    # 长尾名仓库目录：W=37 探针靠「路径能展开几格」区分 gitW 幻影
    # （maxPath 7 vs 10 → …trepo vs …hostrepo）
    T137_REPO="$BOX/r137_ghostrepo"
    mkdir -p "$T137_REPO"
    (cd "$T137_REPO" && git -c init.defaultBranch=main init -q && git config user.email t@e.com         && git config user.name t && git checkout -q -b some-extremely-long-branch-name-for-ghost 2>/dev/null         && : >f && git add -A && git commit -qm i) >/dev/null 2>&1
    t137_run() {  # $1 = COLOR_MODE 值（"truecolor" 或 "none"） $2 = WIDTH
        # BRANCHNAME 喂 harness 的 getGitBranch()，与 porcelain 真 head 一起
        # 使 hasBranch 为真：40 格分支在预算下折到 0 档（空串）触发幻影
        (cd "$T137_REPO" && env NO_COLOR= COLOR_MODE="$1" WIDTH="${2:-30}" \
            BRANCHNAME=some-extremely-long-branch-name-for-ghost \
            HERDR_WORKSPACE_ID=wW HERDR_TAB_ID=wW:t1234 HERDR_PANE_ID=wW:p5678 GIT_WAIT_MS=1200 \
            WREN_TS="$WREN_TS" TUI_STUB="$PI_DIR/tui-stub.mjs" \
            node --import "$PI_DIR/register.mjs" "$PI_DIR/harness.mjs" 2>/dev/null | head -1)
    }
    t137_c="$(t137_run truecolor)"
    t137_n="$(t137_run none)"
    # W=37：maxPath 10（gitW 幻影修前只有 7）——路径能展开到 …hostrepo 即
    # 证 ' | ' 前缀没偷预算；修前会缩成 …trepo
    t137_37="$(t137_run none 37)"
    t137_strip() { printf '%s' "$1" | LC_ALL=C sed 's/\x1b\[[0-9;]*m//g'; }
    t137_ok=1
    # 剥色后：无幻影空槽（连续分隔）、无尾悬空 '| '；herdr 与徽标都在
    t137_cs="$(t137_strip "$t137_c")"
    printf '%s' "$t137_cs" | grep -qF '|  |' && t137_ok=0
    printf '%s' "$t137_cs" | grep -qE '\| *$' && t137_ok=0
    printf '%s' "$t137_cs" | grep -qF 'wW:t1234:p5678' || t137_ok=0
    printf '%s' "$t137_cs" | grep -qF '| pi' || t137_ok=0
    # 剥色宽 ≤ termW（W=30 → 25 格）
    t137_w="$(printf '%s' "$t137_cs" | python3 -c 'import sys; s=sys.stdin.read().rstrip("\n"); print(sum(2 if ord(ch)>0x2E80 else 1 for ch in s))' 2>/dev/null)"
    [[ ${t137_w:-99} -le 25 ]] || t137_ok=0
    # 跨帧一致：none 帧与彩色帧剥色后逐字相同（幻影修前：none 帧无幻影、彩色帧有）
    t137_ns="$(t137_strip "$t137_n")"
    [[ "$t137_cs" == "$t137_ns" ]] || t137_ok=0
    # gitW 核空判：W=37 路径可展开到 …hostrepo（修前 3 格幻影宽偷预算 → …trepo）
    printf '%s' "$t137_37" | grep -qF '…hostrepo' || t137_ok=0
    printf '%s' "$t137_37" | grep -qF '…trepo' && t137_ok=0
    if [[ $t137_ok -eq 1 ]]; then
        pass T137 "pi physical-limit colored phantom separator absent; none/color frames identical"
    else
        fail T137 "color=[$t137_cs] none=[$t137_ns] w=$t137_w"
    fi
fi

# ============================================================
# T138: pi 决策 2 —— ab 优先于 cwd 地板（终审九轮 #2）：穷举序翻转
#       （wdur → wab → blen → floor），46-52 列带 ab（↑1↓0）时 ab 恒在、
#       徽标恒在。旧序 floor 最外/wab 最内 = ab 最先丢，46-50 列红带
#       （cc T134 同型）。
# ============================================================
if [[ "$TS_OK" -ne 1 ]]; then
    skip T138 "node with .ts type-stripping not available"
else
    new_box
    T138_REPO="$BOX/r138"
    T138_REMOTE="$BOX/r138_remote"
    mkdir -p "$T138_REPO"
    (cd "$T138_REPO" && git -c init.defaultBranch=main init -q && git config user.email t@e.com         && git config user.name t && printf 'a\n' >a.txt && git add -A && git commit -qm init         && git init -q --bare "$T138_REMOTE" && git remote add origin "$T138_REMOTE"         && git push -q -u origin main && printf 'b\n' >>a.txt && git add -A && git commit -qm second) >/dev/null 2>&1
    t138_ok=1
    for w in 46 48 50 52; do
        out="$(cd "$T138_REPO" && env NO_COLOR=1 WIDTH=$w             HERDR_WORKSPACE_ID=wW HERDR_TAB_ID=wW:t1234 HERDR_PANE_ID=wW:p5678 GIT_WAIT_MS=1200             WREN_TS="$WREN_TS" TUI_STUB="$PI_DIR/tui-stub.mjs"             node --import "$PI_DIR/register.mjs" "$PI_DIR/harness.mjs" 2>/dev/null | head -1)"
        printf '%s' "$out" | grep -qF '↑1↓0' || { t138_ok=0; echo "  w=$w ab-missing l1=[$out]" >&2; }
        printf '%s' "$out" | grep -qF '| pi' || { t138_ok=0; echo "  w=$w badge-missing l1=[$out]" >&2; }
    done
    if [[ $t138_ok -eq 1 ]]; then
        pass T138 "pi ab survives cwd-floor sacrifice at 46-52 cols (decision-2 loop order)"
    else
        fail T138 "see stderr"
    fi
fi

# ============================================================
# T139: 终审 9-1 幻影分隔符（物理极限区 + truecolor）——git 段被清空后
#       colored_git 是纯 ANSI 包裹空串，.strip() 剥不掉 → 行1 幻影 " | "
#       空槽/尾悬空（现有用例全 NO_COLOR，无色档恰好掩盖）。26/30 列两档：
#       断言剥色后无 ' | ' 空槽（连续分隔）、无尾悬空 '| '，qc 徽标在场。
# ============================================================
new_box
t139_env() {  # $1 = COLUMNS
    printf '{"cwd":"/tmp","model":{"display_name":"m"},"context_window":{"context_window_size":1000000,"used_percentage":3}}' \
        | COLORTERM=truecolor COLUMNS=$1 HERDR_WORKSPACE_ID=wW HERDR_TAB_ID=wW:t1234567890123456 HERDR_PANE_ID=wW:p78 \
            WREN_CACHE_DIR="$BOX/c139-$1" python3 "$QC_PAYLOAD" 2>/dev/null | head -1
}
t139_ok=1
for w in 26 30; do
    out="$(t139_env "$w")"
    plain="$(printf '%s' "$out" | sed $'s/\x1b\\[[0-9;]*m//g')"
    printf '%s' "$plain" | grep -qF "| qc" || { t139_ok=0; echo "  w=$w badge-missing l1=[$plain]" >&2; }
    printf '%s' "$plain" | grep -qE '\| *\|' && { t139_ok=0; echo "  w=$w phantom-slot l1=[$plain]" >&2; }
    printf '%s' "$plain" | grep -qE '\| *$' && { t139_ok=0; echo "  w=$w trailing-sep l1=[$plain]" >&2; }
done
if [[ $t139_ok -eq 1 ]]; then
    pass T139 "physical-limit truecolor: no phantom separator slot after git segment cleared"
else
    fail T139 "see stderr"
fi

# ============================================================
# T140: 宽度探测链（终审十轮·任务 3）——qoder 宿主不给 COLUMNS（payload 无
#       宽度字段、spawn env 原样继承），stdout 又是管道。链：COLUMNS env →
#       控制终端（ctermid）→ 兜底 80。窄档默认关（WREN_QC_NARROW 开关，真身
#       进程探测不可达——探针实锤 /dev/tty ENXIO），本用例显式开 + pty 造
#       51 列控制终端、剥 COLUMNS：探测链应命中窄档（短形 + xh 缩写）。
# ============================================================
new_box
t140_tr="$BOX/t140.jsonl"
printf '{"type":"user","timestamp":"2026-09-19T04:18:46.065Z","message":{"content":"hi"}}\n{"type":"assistant","timestamp":"2026-09-19T04:18:58.465Z","message":{"usage":{"input_tokens":743000,"output_tokens":117000,"cache_read_input_tokens":19560000,"cache_creation_input_tokens":0}}}\n{"type":"system","subtype":"compact_boundary","isSidechain":false,"compactMetadata":{"trigger":"manual","postTokens":284200}}\n{"type":"runtime-config","reasoningEffort":"xhigh"}\n' >"$t140_tr"
t140_out="$(python3 - "$QC_PAYLOAD" "$t140_tr" "$BOX/c140" <<'T140PY'
import fcntl, os, pty, select, struct, subprocess, sys, termios

payload = '{"cwd":"/tmp","model":{"display_name":"m"},"context_window":{"context_window_size":1000000},"transcript_path":"%s"}' % sys.argv[2]
m, s = pty.openpty()
fcntl.ioctl(s, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 51, 0, 0))
env = {k: v for k, v in os.environ.items() if k != "COLUMNS"}
env.update({"NO_COLOR": "1", "WREN_QC_NARROW": "1", "WREN_CACHE_DIR": sys.argv[3]})

def preexec():
    os.setsid()
    fcntl.ioctl(s, termios.TIOCSCTTY, 0)

p = subprocess.Popen([sys.executable, sys.argv[1]], stdin=subprocess.PIPE, stdout=s, stderr=s,
                     env=env, preexec_fn=preexec)
os.close(s)  # 父进程关掉 slave，子进程退出后 master 才有 EOF
p.stdin.write(payload.encode())
p.stdin.close()
out = b""
while True:
    r, _, _ = select.select([m], [], [], 5)
    if not r:
        break
    try:
        chunk = os.read(m, 4096)
    except OSError:
        break
    if not chunk:
        break
    out += chunk
os.close(m)
p.wait(timeout=10)
sys.stdout.write(out.decode("utf-8", "ignore"))
T140PY
)"
t140_l2="$(printf '%s' "$t140_out" | tail -1)"
if printf '%s' "$t140_l2" | grep -qF "743K/117K|◈96.34%|▄28% ⏱12s|m · xh"; then
    pass T140 "width probe chain: no COLUMNS + 51-col controlling tty triggers narrow tier"
else
    fail T140 "l2=[$t140_l2] out=[$(printf '%s' "$t140_out" | tr '\n' '~')]"
fi

# ============================================================
# T141: oc 编辑不死循环——2026-10-12 事故回归
#   事故：find_string 的「其它字面量」分支停在逗号上不前进，外层 while 原地
#   空转；多元素 plugin 数组（{"plugin": ["x","x",...]}）触发 install oc 卡死，
#   python 100% CPU 空烧 8 天（父进程 bash wren install oc）。
#   本用例把当时点名的形态全固化：任一形态再原地打转，run_limited 会在
#   CMD_TIMEOUT 秒后返回 124 → 断言立刻 FAIL（而不是把整套测试挂死）。
# ============================================================
new_box
t141_ok=1; t141_note=""
t141_big="$(python3 -c "import json; print(json.dumps({'plugin': ['x'] * 207}))")"
t141_case() {  # t141_case <名字> <fixture 正文> <期望: exit 码或 any>
    local name="$1" body="$2" want="$3"
    printf '%s\n' "$body" >"$OCCONF"
    local before; before="$(<"$OCCONF")"
    run_wren install oc
    if [[ "$WREN_EXIT" == "124" ]]; then t141_ok=0; t141_note="$t141_note [$name:install 超时]"; return; fi
    if [[ "$want" != "any" && "$WREN_EXIT" != "$want" ]]; then
        t141_ok=0; t141_note="$t141_note [$name:rc=${WREN_EXIT}≠$want]"; return
    fi
    if [[ "$want" == "1" ]]; then  # 拒收路径：文件必须原样
        [[ "$(<"$OCCONF")" == "$before" ]] || { t141_ok=0; t141_note="$t141_note [$name:被改动]"; }
        return
    fi
    run_wren install oc   # 幂等：第二次不得再加一条
    if [[ "$WREN_EXIT" == "124" ]]; then t141_ok=0; t141_note="$t141_note [$name:二次 install 超时]"; return; fi
    run_wren uninstall oc  # 卸载：同样不得原地打转
    if [[ "$WREN_EXIT" == "124" ]]; then t141_ok=0; t141_note="$t141_note [$name:uninstall 超时]"; fi
}
t141_case "多元素数组207" "$t141_big" any
t141_case "两元素(目标在第二位)" '{"plugin": ["./plugins/other.tsx", "./plugins/wren-oc.tsx"]}' any
t141_case "尾逗号+连续逗号+首逗号" '{"plugin": [ , "./plugins/other.tsx",, ]}' any
t141_case "纯空白+逗号段" '{"plugin": [  ,  ,  ]}' any
t141_case "嵌套数组" '{"plugin": [["a"], "b"]}' any
t141_case "未闭合块注释" '{"plugin": ["./plugins/other.tsx" /* oops ]}' 1
t141_case "未闭合字符串" '{"plugin": ["./plugins/other.tsx, "y"]}' 1
# 幂等与内容完整性：207 元素数组装完必须只多一条 spec，且原有元素不丢
printf '%s\n' "$t141_big" >"$OCCONF"
run_wren install oc
t141_after="$(<"$OCCONF")"
if [[ "$(printf '%s' "$t141_after" | grep -o '"x"' | wc -l | tr -d ' ')" != "207" ]] \
   || [[ "$(printf '%s' "$t141_after" | grep -o -F './plugins/wren-oc.tsx' | wc -l | tr -d ' ')" != "1" ]]; then
    t141_ok=0; t141_note="$t141_note [207 元素/幂等计数不符]"
fi
# 嵌套对象里的同值字符串不算「已存在」（B-4）：应另加一条顶层项
printf '%s\n' '{"plugin": [{"src": "./plugins/wren-oc.tsx"}], "theme": "dark"}' >"$OCCONF"
run_wren install oc
if [[ "$WREN_EXIT" == "124" ]] || [[ "$(grep -o -F './plugins/wren-oc.tsx' "$OCCONF" | wc -l | tr -d ' ')" != "2" ]]; then
    t141_ok=0; t141_note="$t141_note [嵌套对象 B-4 语义不符]"
fi
if [[ $t141_ok -eq 1 ]]; then
    pass T141 "oc edit terminates on all shapes (multi-element / stray commas / unclosed comment+string / nesting)"
else
    fail T141 "$t141_note"
fi

# ============================================================
# T142: 超时护栏自证——run_limited 必须真能掐断死循环
#   护栏自己坏掉的话，T141 会退化成「挂死」而不是「FAIL」——
#   2026-10-12 事故正是这么发生的（测试卡住没人发现）。
# ============================================================
t142_t0="$(date +%s)"
run_limited 2 bash -c 'while :; do :; done'
t142_rc=$?
t142_dt=$(( $(date +%s) - t142_t0 ))
if [[ "$t142_rc" == "124" && "$t142_dt" -lt 8 ]]; then
    pass T142 "timeout guard kills spinning child (rc=124 in ${t142_dt}s)"
else
    fail T142 "rc=$t142_rc elapsed=${t142_dt}s (guard ineffective)"
fi

# ============================================================
# T143: watchdog 自证——整体超时必须落盘 + 强杀，绝不静默
#   嵌套跑一次本套件（总超时压到 15s，正常要 ~100s）：
#   期望 watchdog 介入、结果文件写出 FAIL 行、退出码非 0。
# ============================================================
t143_res="$TMPROOT/t143-res.md"
t143_t0="$(date +%s)"
( WREN_TEST_TOTAL_TIMEOUT=15 WREN_TEST_RES_FILE="$t143_res" \
    bash "$SCRIPT_DIR/wren-test.sh" >"$TMPROOT/t143.out" 2>&1 ) 2>/dev/null
t143_rc=$?
t143_dt=$(( $(date +%s) - t143_t0 ))
if [[ $t143_rc -ne 0 ]] && [[ -f "$t143_res" ]] && grep -q "watchdog | FAIL" "$t143_res" \
   && [[ "$t143_dt" -lt 90 ]]; then
    pass T143 "watchdog trips on total timeout: writes FAIL row + nonzero exit in ${t143_dt}s"
else
    fail T143 "rc=$t143_rc elapsed=${t143_dt}s res=[$(head -c 200 "$t143_res" 2>/dev/null)]"
fi

# ============================================================
# T144: 护栏必须杀「整棵进程树」，不是只杀直接子进程
#   2026-10-12 实测漏洞：run_limited 只 kill 直接子进程，而 wren 在 $(...) 里
#   fork 子 shell 跑 heredoc、子 shell 再拉 python——只杀 wren 主进程，子 shell
#   与 python 孙进程双双变孤儿继续自旋（16 个孤儿烧掉 9.3 核 × 51 分钟）。
#   本用例起一个「bash → python 自旋」的两层结构，超时后必须一个都不剩。
# ============================================================
t144_marker="wren-test-treekill-$$"
run_limited 2 bash -c "python3 -c 'import time
while True: time.sleep(0.01)' \"$t144_marker\"" >/dev/null 2>&1
t144_rc=$?
sleep 0.5
t144_left="$(pgrep -fl "$t144_marker" 2>/dev/null | tr '\n' ' ')"
if [[ "$t144_rc" == "124" && -z "$t144_left" ]]; then
    pass T144 "timeout guard kills the whole tree (no orphan grandchildren)"
else
    fail T144 "rc=$t144_rc leftover=[$t144_left]"
fi

# ============================================================
# agy（wren-agy.py）—— 从 T145 起。夹具全部手工脱敏构造（结构同真实
# transcript：USER_INPUT / PLANNER_RESPONSE / GENERIC…，content 用占位
# 文本），不拷贝任何真实会话数据。
# ============================================================

# agy_ts <秒偏移>：UTC 秒级时间戳（agy transcript 的 created_at 精度）
agy_ts() {
    python3 -c "import datetime,sys;print((datetime.datetime.now(datetime.timezone.utc)+datetime.timedelta(seconds=int(sys.argv[1]))).strftime('%Y-%m-%dT%H:%M:%SZ'))" "$1"
}

# agy_out <cache_dir> <columns> <none|truecolor> <payload> → 两行 stdout
agy_out() {
    local cache="$1" cols="$2" mode="$3" payload="$4"
    if [[ "$mode" == "truecolor" ]]; then
        printf '%s' "$payload" | env -u NO_COLOR COLORTERM=truecolor COLUMNS="$cols" \
            WREN_CACHE_DIR="$cache" python3 "$AGY_PAYLOAD" 2>/dev/null
    else
        printf '%s' "$payload" | env NO_COLOR=1 COLUMNS="$cols" \
            WREN_CACHE_DIR="$cache" python3 "$AGY_PAYLOAD" 2>/dev/null
    fi
}

# agy_lines <text>：行数（命令替换已剥尾换行，两行输出 → 2）
agy_lines() { printf '%s' "$1" | awk 'END{printf "%d", NR}'; }

# agy_w <text>：单行显示宽（剥 ANSI、CJK 计 2）
agy_w() {
    python3 -c '
import sys, re, unicodedata
s = re.sub(r"\x1b\[[0-9;]*m", "", sys.stdin.read())
print(sum(2 if unicodedata.east_asian_width(c) in ("W", "F") else 1 for c in s))
'
}

# agy_plain：剥 ANSI
agy_plain() {
    python3 -c '
import sys, re
sys.stdout.write(re.sub(r"\x1b\[[0-9;]*m", "", sys.stdin.read()))
'
}

# agy_strip_cost：去掉行尾 cost 段（宽档 " | ~$x" / 窄档 "|~$x"，含 sub:）
agy_strip_cost() {
    sed -E 's/ ?\| ?~?(\$[0-9]+\.[0-9]+|<\$0\.01)( ?\| ?sub:(\$[0-9]+\.[0-9]+|<\$0\.01))?$//'
}

# agy_cache_file <cache_dir> <transcript>：agy 缓存键（与实现同式）
agy_cache_file() {
    python3 -c 'import hashlib,sys;print(sys.argv[1]+"/agy-"+hashlib.sha1(sys.argv[2].encode()).hexdigest()[:16]+".json")' "$1" "$2"
}

# agy_base_fixture <out>：标准脱敏 transcript。固定旧时间戳 → 时长恒 99h+
# （不随测试时钟抖动）；TTFT 1.0s；三条 PLANNER_RESPONSE 同轮多步，
# token 累计 4000/400/4000，末次 prompt 3000（CH 66.67%，ctx 1.50%/200K）。
agy_base_fixture() {
    cat >"$1" <<'EOF2'
{"step_index":1,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-01-01T00:00:00Z","content":"hello"}
{"step_index":2,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-01-01T00:00:01Z","model":"m","input_tokens":1000,"output_tokens":100,"cache_read_tokens":500,"content":"a"}
{"step_index":3,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-01-01T00:00:02Z","model":"m","input_tokens":2000,"output_tokens":200,"cache_read_tokens":1500,"content":"b"}
{"step_index":4,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-01-01T00:00:03Z","model":"m","input_tokens":1000,"output_tokens":100,"cache_read_tokens":2000,"content":"c"}
EOF2
}

# agy_fault_check <name> <out> <err> <rc> [want-substr...]
# 契约断言：rc=0、stderr 空、恰好 2 行、两行宽 ≤ COLUMNS=80。
agy_fault_check() {
    local name="$1" out="$2" err="$3" rc="$4"; shift 4
    local n w1 w2 want
    n="$(agy_lines "$out")"
    w1="$(printf '%s' "${out%%$'\n'*}" | agy_w)"
    w2="$(printf '%s' "${out##*$'\n'}" | agy_w)"
    if [[ "$rc" != "0" || -n "$err" || "$n" != "2" || "$w1" -gt 80 || "$w2" -gt 80 ]]; then
        printf 'agy fault[%s]: rc=%s err=[%s] lines=%s w=%s/%s\n' "$name" "$rc" "$err" "$n" "$w1" "$w2" >&2
        return 1
    fi
    for want in "$@"; do
        if ! printf '%s' "$out" | grep -qF -- "$want"; then
            printf 'agy fault[%s]: missing [%s] in [%s]\n' "$name" "$want" "$out" >&2
            return 1
        fi
    done
    return 0
}

# ============================================================
# T145: agy 宽档两行精确断言——transcript 累计 ↑in/↓out/R、CH、ctx、effort、
#       cost（~ 前缀 + sub）、TTFT（秒级、只配首条）、时长段。
# ============================================================
new_box
t145_tr="$BOX/t145.jsonl"
python3 - "$t145_tr" <<'T145PY'
import datetime, json, sys
base = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=90)
def ts(off):
    return (base + datetime.timedelta(seconds=off)).strftime("%Y-%m-%dT%H:%M:%SZ")
recs = [
    {"step_index": 1, "source": "USER_EXPLICIT", "type": "USER_INPUT", "status": "DONE", "created_at": ts(0), "content": "hello"},
    {"step_index": 2, "source": "MODEL", "type": "PLANNER_RESPONSE", "status": "DONE", "created_at": ts(1), "model": "m", "input_tokens": 1000, "output_tokens": 100, "cache_read_tokens": 500, "content": "a"},
    {"step_index": 3, "source": "MODEL", "type": "PLANNER_RESPONSE", "status": "DONE", "created_at": ts(2), "model": "m", "input_tokens": 2000, "output_tokens": 200, "cache_read_tokens": 1500, "content": "b"},
    {"step_index": 4, "source": "MODEL", "type": "PLANNER_RESPONSE", "status": "DONE", "created_at": ts(3), "model": "m", "input_tokens": 1000, "output_tokens": 100, "cache_read_tokens": 2000, "content": "c"},
]
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    for r in recs:
        fh.write(json.dumps(r) + "\n")
T145PY
t145_p="$(printf '{"cwd":"/tmp","model":{"id":"m","display_name":"m","effort":"high"},"context_window":{"context_window_size":200000},"transcript_path":"%s","cost":{"total_usd":0.03,"subagent_usd":0.01,"estimated":true}}' "$t145_tr")"
t145_out="$(agy_out "$BOX/c145" 120 none "$t145_p")"
t145_l1="${t145_out%%$'\n'*}"; t145_l2="${t145_out##*$'\n'}"
if [[ "$(agy_lines "$t145_out")" == "2" \
   && "$t145_l1" == "/tmp | agy · 1m" \
   && "$t145_l2" == "↑4K ↓400 | R4K CH66.67% | 1.50%/200K TTFT 1.0s | m · high | ~\$0.03 | sub:\$0.01" ]]; then
    pass T145 "agy wide: exact 2 lines (totals/CH/ctx/TTFT/effort/cost/duration)"
else
    fail T145 "l1=[$t145_l1] l2=[$t145_l2]"
fi

# ============================================================
# T146: agy 窄档（COLUMNS=51）——紧凑形、R 不进段表、cost 先让位、行宽 ≤ 46
# ============================================================
new_box
agy_base_fixture "$BOX/t146.jsonl"
t146_p="$(printf '{"cwd":"/tmp","model":{"id":"m","display_name":"m","effort":"high"},"context_window":{"context_window_size":200000},"transcript_path":"%s"}' "$BOX/t146.jsonl")"
t146_out="$(agy_out "$BOX/c146" 51 none "$t146_p")"
t146_l1="${t146_out%%$'\n'*}"; t146_l2="${t146_out##*$'\n'}"
t146_w1="$(printf '%s' "$t146_l1" | agy_w)"; t146_w2="$(printf '%s' "$t146_l2" | agy_w)"
if [[ "$t146_l1" == "/tmp | agy" \
   && "$t146_l2" == "4K/400|◈66.67%|▂2% ⏱1.0s|m · hi" \
   && "$t146_w1" -le 46 && "$t146_w2" -le 46 ]]; then
    pass T146 "agy narrow: compact form, width $t146_w1/$t146_w2 <= 46"
else
    fail T146 "l1=[$t146_l1] l2=[$t146_l2] w=$t146_w1/$t146_w2"
fi

# ============================================================
# T147: agy NO_COLOR=1 纯文本；且等于「带色输出剥 ANSI」（色档不改变内容）
# ============================================================
new_box
agy_base_fixture "$BOX/t147.jsonl"
t147_p="$(printf '{"cwd":"/tmp","model":{"display_name":"m","effort":"low"},"context_window":{"context_window_size":200000},"transcript_path":"%s"}' "$BOX/t147.jsonl")"
t147_tc="$(agy_out "$BOX/c147" 120 truecolor "$t147_p")"
t147_nc="$(agy_out "$BOX/c147" 120 none "$t147_p")"
t147_ok=1
printf '%s' "$t147_nc" | grep -q $'\x1b\[' && t147_ok=0
printf '%s' "$t147_tc" | grep -qF '38;2;' || t147_ok=0
[[ "$(printf '%s' "$t147_tc" | agy_plain)" == "$t147_nc" ]] || t147_ok=0
if [[ $t147_ok -eq 1 ]]; then
    pass T147 "agy NO_COLOR: plain output equals ANSI-stripped colour output"
else
    fail T147 "nc=[$(printf '%s' "$t147_nc" | head -c 120)] tc=[$(printf '%s' "$t147_tc" | head -c 120)]"
fi

# ============================================================
# T148: agy TTFT 语义——同轮多步只配首条；新 USER_INPUT 后保留旧值直到
#       首条响应；非 USER_EXPLICIT 的 USER_INPUT 不开窗（不重配）。
# ============================================================
new_box
t148_tr="$BOX/t148.jsonl"
cat >"$t148_tr" <<'EOF2'
{"source":"USER_EXPLICIT","type":"USER_INPUT","created_at":"2026-01-01T00:00:00Z","content":"q1"}
{"source":"MODEL","type":"PLANNER_RESPONSE","created_at":"2026-01-01T00:00:01Z","input_tokens":100,"output_tokens":10,"cache_read_tokens":0}
{"source":"MODEL","type":"PLANNER_RESPONSE","created_at":"2026-01-01T00:00:02Z","input_tokens":100,"output_tokens":10,"cache_read_tokens":0}
EOF2
t148_p="$(printf '{"cwd":"/tmp","model":{"display_name":"m"},"transcript_path":"%s"}' "$t148_tr")"
t148_a="$(agy_out "$BOX/c148" 120 none "$t148_p" | tail -1)"
printf '{"source":"USER_EXPLICIT","type":"USER_INPUT","created_at":"2026-01-01T00:00:10Z","content":"q2"}\n' >>"$t148_tr"
t148_b="$(agy_out "$BOX/c148" 120 none "$t148_p" | tail -1)"
printf '{"source":"MODEL","type":"PLANNER_RESPONSE","created_at":"2026-01-01T00:00:13Z","input_tokens":100,"output_tokens":10,"cache_read_tokens":0}\n' >>"$t148_tr"
t148_c="$(agy_out "$BOX/c148" 120 none "$t148_p" | tail -1)"
printf '{"source":"SYSTEM","type":"USER_INPUT","created_at":"2026-01-01T00:00:20Z","content":"injected"}\n{"source":"MODEL","type":"PLANNER_RESPONSE","created_at":"2026-01-01T00:00:23Z","input_tokens":100,"output_tokens":10,"cache_read_tokens":0}\n' >>"$t148_tr"
t148_d="$(agy_out "$BOX/c148" 120 none "$t148_p" | tail -1)"
if printf '%s' "$t148_a" | grep -qF "TTFT 1.0s" \
   && printf '%s' "$t148_b" | grep -qF "TTFT 1.0s" \
   && printf '%s' "$t148_c" | grep -qF "TTFT 3.0s" \
   && printf '%s' "$t148_d" | grep -qF "TTFT 3.0s"; then
    pass T148 "agy TTFT: first response only, stock value while waiting, SYSTEM input ignored"
else
    fail T148 "a=[$t148_a] b=[$t148_b] c=[$t148_c] d=[$t148_d]"
fi

# ============================================================
# T149: agy 时长——行1 出现 ` · <时长>`；created_at 在未来（时钟异常）
#       不显示负值
# ============================================================
new_box
printf '{"source":"MODEL","type":"GENERIC","created_at":"%s","content":"x"}\n' "$(agy_ts -3600)" >"$BOX/t149.jsonl"
t149_p="$(printf '{"cwd":"/tmp","model":{"display_name":"m"},"transcript_path":"%s"}' "$BOX/t149.jsonl")"
t149_l1="$(agy_out "$BOX/c149" 120 none "$t149_p" | head -1)"
printf '{"source":"MODEL","type":"GENERIC","created_at":"%s","content":"x"}\n' "$(agy_ts 3600)" >"$BOX/t149f.jsonl"
t149_pf="$(printf '{"cwd":"/tmp","model":{"display_name":"m"},"transcript_path":"%s"}' "$BOX/t149f.jsonl")"
t149_l1f="$(agy_out "$BOX/c149f" 120 none "$t149_pf" | head -1)"
if [[ "$t149_l1" == "/tmp | agy · 1h0m" && "$t149_l1f" == "/tmp | agy" ]]; then
    pass T149 "agy duration on line1; future clock anomaly shows no negative duration"
else
    fail T149 "l1=[$t149_l1] future=[$t149_l1f]"
fi

# ============================================================
# T150: agy 无 transcript → payload totals / current_usage 回退；
#       win 未知时 ctx 只显示 xx.xx%（不带 /win，不猜 200K）
# ============================================================
new_box
t150_p1='{"cwd":"/tmp","model":{"display_name":"m"},"context_window":{"context_window_size":200000,"total_input_tokens":43138,"total_output_tokens":5200,"current_usage":{"input_tokens":1000,"cache_read_input_tokens":3000,"cache_creation_input_tokens":0}}}'
t150_l2a="$(agy_out "$BOX/c150" 120 none "$t150_p1" | tail -1)"
t150_p2='{"cwd":"/tmp","model":{"display_name":"m"},"context_window":{"used_percentage":22}}'
t150_l2b="$(agy_out "$BOX/c150" 120 none "$t150_p2" | tail -1)"
if [[ "$t150_l2a" == "↑43K ↓5K | R3K CH75.00% | 2.00%/200K | m" \
   && "$t150_l2b" == "↑0 ↓0 | R0 | 22.00% | m" ]]; then
    pass T150 "agy payload fallback: totals/current_usage; unknown win renders pct only"
else
    fail T150 "a=[$t150_l2a] b=[$t150_l2b]"
fi

# ============================================================
# T151: agy 增量缓存——追加行后二次渲染 == 对完整文件冷扫；offset 前进
# ============================================================
new_box
t151_tr="$BOX/t151.jsonl"
cat >"$t151_tr" <<'EOF2'
{"source":"USER_EXPLICIT","type":"USER_INPUT","created_at":"2026-01-01T00:00:00Z","content":"q"}
{"source":"MODEL","type":"PLANNER_RESPONSE","created_at":"2026-01-01T00:00:01Z","input_tokens":1000,"output_tokens":100,"cache_read_tokens":500}
EOF2
t151_p="$(printf '{"cwd":"/tmp","model":{"display_name":"m"},"context_window":{"context_window_size":200000},"transcript_path":"%s"}' "$t151_tr")"
t151_a="$(agy_out "$BOX/c151" 120 none "$t151_p")"
t151_cf="$(agy_cache_file "$BOX/c151" "$t151_tr")"
t151_ok=1; t151_note=""
[[ "$(json_field "$t151_cf" 'd["offset"]')" == "$(wc -c <"$t151_tr" | tr -d ' ')" ]] \
    || { t151_ok=0; t151_note="$t151_note [offset-after-first]"; }
printf '%s' "$t151_a" | grep -qF "↑1K ↓100" || { t151_ok=0; t151_note="$t151_note [first-totals]"; }
printf '%s' "$t151_a" | grep -qF "CH33.33%" || { t151_ok=0; t151_note="$t151_note [first-ch]"; }
printf '{"source":"MODEL","type":"PLANNER_RESPONSE","created_at":"2026-01-01T00:00:02Z","input_tokens":2000,"output_tokens":200,"cache_read_tokens":1500}\n' >>"$t151_tr"
t151_b="$(agy_out "$BOX/c151" 120 none "$t151_p")"
cp "$t151_tr" "$BOX/t151-full.jsonl"
t151_pcold="$(printf '{"cwd":"/tmp","model":{"display_name":"m"},"context_window":{"context_window_size":200000},"transcript_path":"%s"}' "$BOX/t151-full.jsonl")"
t151_c="$(agy_out "$BOX/c151cold" 120 none "$t151_pcold")"
[[ "$t151_b" == "$t151_c" ]] || { t151_ok=0; t151_note="$t151_note [warm!=cold]"; }
[[ "$(json_field "$t151_cf" 'd["offset"]')" == "$(wc -c <"$t151_tr" | tr -d ' ')" ]] \
    || { t151_ok=0; t151_note="$t151_note [offset-after-append]"; }
printf '%s' "$t151_b" | grep -qF "↑3K ↓300" || { t151_ok=0; t151_note="$t151_note [appended-totals]"; }
printf '%s' "$t151_b" | grep -qF "CH42.86%" || { t151_ok=0; t151_note="$t151_note [appended-ch]"; }
if [[ $t151_ok -eq 1 ]]; then
    pass T151 "agy incremental cache: warm append == cold full scan, offset advances"
else
    fail T151 "$t151_note"
fi

# ============================================================
# T152: agy transcript 故障矩阵——缺失/空/二进制垃圾/非法 JSON 行/末尾半行/
#       文件被截断（offset>size 重扫）/毒缓存（offset 毒型/非 dict/JSON 损坏/
#       状态字段毒型）→ 输出正确且缓存自愈。
# ============================================================
new_box
t152_ok=1; t152_note=""
t152_chk() {  # <name> <out> [want...]
    local name="$1" out="$2"; shift 2
    local want n
    n="$(agy_lines "$out")"
    if [[ "$n" != "2" ]]; then t152_ok=0; t152_note="$t152_note [$name:lines=$n]"; return; fi
    for want in "$@"; do
        printf '%s' "$out" | grep -qF -- "$want" || { t152_ok=0; t152_note="$t152_note [$name:missing $want]"; }
    done
}
t152_p() { printf '{"cwd":"/tmp","model":{"display_name":"m"},"context_window":{"context_window_size":200000},"transcript_path":"%s"}' "$1"; }
t152_chk missing "$(agy_out "$BOX/c152-miss" 120 none "$(t152_p "$BOX/nope.jsonl")")" "↑0 ↓0"
: >"$BOX/t152-empty.jsonl"
t152_chk empty "$(agy_out "$BOX/c152-empty" 120 none "$(t152_p "$BOX/t152-empty.jsonl")")" "↑0 ↓0"
printf '\x00\xff\xfe\x1b\x02garbage\n' >"$BOX/t152-bin.jsonl"
t152_chk binary "$(agy_out "$BOX/c152-bin" 120 none "$(t152_p "$BOX/t152-bin.jsonl")")" "↑0 ↓0"
printf 'not json at all\n{"source":"MODEL","type":"PLANNER_RESPONSE","created_at":"2026-01-01T00:00:01Z","input_tokens":1000,"output_tokens":100,"cache_read_tokens":500}\n' >"$BOX/t152-mixed.jsonl"
t152_chk mixed "$(agy_out "$BOX/c152-mixed" 120 none "$(t152_p "$BOX/t152-mixed.jsonl")")" "↑1K ↓100" "R500"
# 末尾半行：只喂完整行，offset 停在半行起点；补齐 + \n 后计入
printf '{"source":"MODEL","type":"PLANNER_RESPONSE","created_at":"2026-01-01T00:00:01Z","input_tokens":1000,"output_tokens":100,"cache_read_tokens":500}\n{"source":"MODEL","type":"PLANNER_RESPONSE"' >"$BOX/t152-half.jsonl"
t152_chk half "$(agy_out "$BOX/c152-half" 120 none "$(t152_p "$BOX/t152-half.jsonl")")" "↑1K"
t152_line1_len="$(python3 -c 'import sys;d=open(sys.argv[1],"rb").read();print(d.index(b"\n")+1)' "$BOX/t152-half.jsonl")"
[[ "$(json_field "$(agy_cache_file "$BOX/c152-half" "$BOX/t152-half.jsonl")" 'd["offset"]')" == "$t152_line1_len" ]] \
    || { t152_ok=0; t152_note="$t152_note [half:offset]"; }
printf ',"input_tokens":2000,"output_tokens":200,"cache_read_tokens":1500}\n' >>"$BOX/t152-half.jsonl"
t152_chk half2 "$(agy_out "$BOX/c152-half" 120 none "$(t152_p "$BOX/t152-half.jsonl")")" "↑3K"
# 文件被截断到 cached offset 以下 → 全量重扫
printf '{"source":"MODEL","type":"PLANNER_RESPONSE","created_at":"2026-01-01T00:00:01Z","input_tokens":1000,"output_tokens":100,"cache_read_tokens":500}\n{"source":"MODEL","type":"PLANNER_RESPONSE","created_at":"2026-01-01T00:00:02Z","input_tokens":2000,"output_tokens":200,"cache_read_tokens":1500}\n' >"$BOX/t152-trunc.jsonl"
t152_chk trunc-a "$(agy_out "$BOX/c152-trunc" 120 none "$(t152_p "$BOX/t152-trunc.jsonl")")" "↑3K"
printf '{"source":"MODEL","type":"PLANNER_RESPONSE","created_at":"2026-01-01T00:00:01Z","input_tokens":1000,"output_tokens":100,"cache_read_tokens":500}\n' >"$BOX/t152-trunc.jsonl"
t152_chk trunc-b "$(agy_out "$BOX/c152-trunc" 120 none "$(t152_p "$BOX/t152-trunc.jsonl")")" "↑1K"
# 毒缓存：每种形态渲染正确 + 缓存被覆写成健康状态（offset = 文件大小）
printf '{"source":"MODEL","type":"PLANNER_RESPONSE","created_at":"2026-01-01T00:00:01Z","input_tokens":1000,"output_tokens":100,"cache_read_tokens":500}\n' >"$BOX/t152-poison.jsonl"
t152_pp="$(t152_p "$BOX/t152-poison.jsonl")"
t152_cf="$(agy_cache_file "$BOX/c152-poison" "$BOX/t152-poison.jsonl")"
t152_sz="$(wc -c <"$BOX/t152-poison.jsonl" | tr -d ' ')"
mkdir -p "$BOX/c152-poison"
t152_poisons=(
    '{"path":"%s","offset":"50"}'
    '{"path":"%s","offset":6.5}'
    '{"path":"%s","offset":true}'
    '{"path":"%s","offset":-1}'
    '{"path":"%s","offset":999999}'
    '[]'
    '{oops'
    '{"path":"%s","offset":0,"input_t":-5,"first_ts":"x","ttft_ms":"y"}'
    '{"path":"wrong","offset":1}'
)
for t152_tmpl in "${t152_poisons[@]}"; do
    if [[ "$t152_tmpl" == *"%s"* ]]; then
        # shellcheck disable=SC2059
        printf "$t152_tmpl" "$BOX/t152-poison.jsonl" >"$t152_cf"
    else
        printf '%s' "$t152_tmpl" >"$t152_cf"
    fi
    t152_out="$(agy_out "$BOX/c152-poison" 120 none "$t152_pp")"
    t152_chk "poison:$t152_tmpl" "$t152_out" "↑1K ↓100" "R500"
    if [[ "$(json_field "$t152_cf" "type(d.get('offset')).__name__ == 'int' and d.get('offset') == $t152_sz")" != "True" ]]; then
        t152_ok=0; t152_note="$t152_note [poison:$t152_tmpl:not-healed]"
    fi
done
# 状态字段毒型：first_ts/ttft_ms 非数值、input_t 负数。文件本身没有 created_at
# → 合法结果不得出现时长；line2 必须与健康状态逐字一致。
printf '{"source":"MODEL","type":"PLANNER_RESPONSE","input_tokens":1000,"output_tokens":100,"cache_read_tokens":500}\n' >"$BOX/t152-nosan.jsonl"
t152_nsan_p="$(t152_p "$BOX/t152-nosan.jsonl")"
t152_nsan_cf="$(agy_cache_file "$BOX/c152-nosan" "$BOX/t152-nosan.jsonl")"
mkdir -p "$BOX/c152-nosan"
printf '{"path":"%s","offset":0,"input_t":-5,"first_ts":"x","ttft_ms":"y","turn_user_ts":"z"}' \
    "$BOX/t152-nosan.jsonl" >"$t152_nsan_cf"
t152_nsan_out="$(agy_out "$BOX/c152-nosan" 120 none "$t152_nsan_p")"
t152_chk sanitize "$t152_nsan_out" "↑1K ↓100 | R500 CH33.33% | 0.75%/200K | m"
[[ "${t152_nsan_out%%$'\n'*}" == "/tmp | agy" ]] \
    || { t152_ok=0; t152_note="$t152_note [sanitize:duration]"; }
if [[ $t152_ok -eq 1 ]]; then
    pass T152 "agy transcript faults: missing/empty/garbage/bad-line/half-line/truncation/poison cache all safe"
else
    fail T152 "$t152_note"
fi

# ============================================================
# T153: agy stdin 容灾——EOF→idle 两行；管道保持打开 3s→≤1.2s 返回；
#       非法 UTF-8 / 截断 JSON / 顶层数组 / 超 8MiB 均不崩。
# ============================================================
new_box
t153_eof="$(env NO_COLOR=1 COLUMNS=120 WREN_CACHE_DIR="$BOX/c153" python3 "$AGY_PAYLOAD" </dev/null 2>"$BOX/e153a")"
t153_eof_rc=$?
t153_eof_err="$(<"$BOX/e153a")"
t153_open="$(python3 - "$AGY_PAYLOAD" "$BOX/c153-open" <<'T153PY'
import os, subprocess, sys, threading, time
env = {k: v for k, v in os.environ.items() if k != "NO_COLOR"}
env.update({"NO_COLOR": "1", "COLUMNS": "120", "WREN_CACHE_DIR": sys.argv[2]})
p = subprocess.Popen([sys.executable, sys.argv[1]], stdin=subprocess.PIPE,
                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
t0 = time.monotonic()
buf = {}
def _read():
    buf["out"] = p.stdout.read()
th = threading.Thread(target=_read)
th.start()
th.join(timeout=5)          # 读取线程兜底：真挂死时杀进程并按 99s 报 FAIL，不拖住整套
if th.is_alive():
    p.kill()
    sys.stdout.write("99.00 1 0 0")
    raise SystemExit(0)
dt = time.monotonic() - t0
rc = p.wait()
err = p.stderr.read()
# 宿主迟迟不关 stdin 的姿态：写端保持打开满 3s 再关（子进程早已返回）
remain = 3.0 - (time.monotonic() - t0)
if remain > 0:
    time.sleep(remain)
p.stdin.close()
lines = buf["out"].decode("utf-8", "replace").rstrip("\n").count("\n") + 1 if buf["out"].strip() else 0
sys.stdout.write("%.2f %d %d %d" % (dt, rc, lines, len(err)))
T153PY
)"
read -r t153_dt t153_rc t153_lines t153_errlen <<<"$t153_open"
t153_ok=1; t153_note=""
[[ "$t153_eof_rc" == "0" && -z "$t153_eof_err" && "$(agy_lines "$t153_eof")" == "2" ]] \
    || { t153_ok=0; t153_note="$t153_note [eof]"; }
[[ "$t153_rc" == "0" && "$t153_lines" == "2" && "$t153_errlen" == "0" ]] \
    || { t153_ok=0; t153_note="$t153_note [open:rc=$t153_rc lines=$t153_lines err=$t153_errlen]"; }
awk "BEGIN{exit !($t153_dt <= 1.2)}" || { t153_ok=0; t153_note="$t153_note [open:dt=$t153_dt]"; }
t153_bad="$(printf '\xff\xfe{"cwd":"/tmp"}\n' | env NO_COLOR=1 COLUMNS=120 WREN_CACHE_DIR="$BOX/c153b" python3 "$AGY_PAYLOAD" 2>/dev/null)"
[[ "$(agy_lines "$t153_bad")" == "2" ]] || { t153_ok=0; t153_note="$t153_note [bad-utf8]"; }
t153_trunc="$(printf '{"cwd":"/tmp"' | env NO_COLOR=1 COLUMNS=120 WREN_CACHE_DIR="$BOX/c153t" python3 "$AGY_PAYLOAD" 2>/dev/null)"
[[ "$(agy_lines "$t153_trunc")" == "2" ]] || { t153_ok=0; t153_note="$t153_note [truncated-json]"; }
t153_arr="$(printf '[]' | env NO_COLOR=1 COLUMNS=120 WREN_CACHE_DIR="$BOX/c153a" python3 "$AGY_PAYLOAD" 2>/dev/null)"
[[ "$(agy_lines "$t153_arr")" == "2" ]] || { t153_ok=0; t153_note="$t153_note [array]"; }
t153_t0="$(date +%s)"
t153_big="$( (python3 -c 'import sys; sys.stdout.write("{\"cwd\":\"/tmp\",\"model\":{\"display_name\":\"m\"}}" + " " * 9000000)' 2>/dev/null) \
    | env NO_COLOR=1 COLUMNS=120 WREN_CACHE_DIR="$BOX/c153big" python3 "$AGY_PAYLOAD" 2>/dev/null )"
t153_big_rc=$?
t153_big_dt=$(( $(date +%s) - t153_t0 ))
[[ "$t153_big_rc" == "0" && "$(agy_lines "$t153_big")" == "2" && "$t153_big_dt" -lt 5 ]] \
    || { t153_ok=0; t153_note="$t153_note [8MiB:rc=$t153_big_rc dt=$t153_big_dt]"; }
if [[ $t153_ok -eq 1 ]]; then
    pass T153 "agy stdin: EOF idle, open pipe returns in ${t153_dt}s, bad bytes/JSON/array/8MiB safe"
else
    fail T153 "$t153_note"
fi

# ============================================================
# T154: agy 故障矩阵——字段类型/NaN/Infinity/负数注入；每个用例契约：
#       rc=0、stderr 空、恰好 2 行、行宽 ≤ 有效宽度（COLUMNS=80）
# ============================================================
new_box
t154_cases=(
    '{"cwd":"/tmp","model":null}'
    '{"cwd":"/tmp","model":"x"}'
    '{"cwd":"/tmp","context_window":null,"transcript_path":null}'
    '{"cwd":"/tmp","context_window":[]}'
    '{"cwd":"/tmp","context_window":{"current_usage":null}}'
    '{"cwd":"/tmp","context_window":{"current_usage":[1,2]}}'
    '{"cwd":"/tmp","context_window":{"context_window_size":200000,"used_percentage":NaN}}'
    '{"cwd":"/tmp","context_window":{"context_window_size":200000,"used_percentage":Infinity}}'
    '{"cwd":"/tmp","context_window":{"context_window_size":200000,"used_percentage":"500"}}'
    '{"cwd":"/tmp","context_window":{"context_window_size":200000,"used_percentage":-5}}'
    '{"cwd":"/tmp","context_window":{"context_window_size":200000,"current_usage":{"input_tokens":NaN,"cache_read_input_tokens":Infinity,"cache_creation_input_tokens":-3}}}'
    '{"cwd":"/tmp","cost":"abc"}'
    '{"cwd":"/tmp","cost":{"total_usd":NaN}}'
    '{"cwd":"/tmp","cost":{"total_usd":0.5,"estimated":"true"}}'
    '{"cwd":"/tmp","cost":{"total_usd":-1}}'
    '{"cwd":"/tmp","terminal_width":0}'
    '{"cwd":"/tmp","terminal_width":"80"}'
    '{"cwd":"/tmp","terminal_width":true}'
    '{"cwd":"/tmp","terminal_width":-1}'
    '{"cwd":123}'
    '{"cwd":""}'
    '{"cwd":"/tmp/evil\nname"}'
    '{"cwd":"/tmp","transcript_path":5}'
    '{"workspace":true,"cwd":"/tmp","model":{"display_name":"m"}}'
    '{"workspace":{"current_dir":7},"cwd":"/tmp"}'
    '{"cwd":"/tmp","model":{"display_name":"Gem\u001b[31mevil\u001b[0m"}}'
    '{"cwd":"/tmp/a\u202eb","model":{"display_name":"ab\u202ecdef","effort":"hi\u2066"}}'
    '{"cwd":"/tmp","model":{"display_name":"ab\u001b]0;title\u0007cdef","effort":"me\u001b[2Jdium"}}'
    '{"cwd":"/tmp","context_window":{"context_window_size":200000,"used_percentage":-Infinity}}'
    '{"cwd":"/tmp","context_window":{"context_window_size":200000,"used_percentage":1e999}}'
    '{"cwd":"/tmp","context_window":{"context_window_size":200000,"current_usage":{"input_tokens":-Infinity,"cache_read_input_tokens":NaN,"cache_creation_input_tokens":1e999}}}'
    '{"cwd":"/tmp","cost":{"total_cost_usd":1.5}}'
    '{"cwd":"/tmp","cost":{"total_usd":1e-9}}'
    '{"cwd":"/tmp","cost":{"total_usd":null}}'
    '{"cwd":"/tmp","cost":{"total_usd":0.5,"estimated":1}}'
    '{"cwd":"/tmp","terminal_width":1000000000}'
    '{"cwd":"/tmp","terminal_width":51.5}'
)
t154_ok=1; t154_i=0
for t154_case in "${t154_cases[@]}"; do
    t154_i=$((t154_i + 1))
    t154_out="$(printf '%s' "$t154_case" | env NO_COLOR=1 COLUMNS=80 WREN_CACHE_DIR="$BOX/c154" \
        python3 "$AGY_PAYLOAD" 2>"$BOX/e154")"
    t154_rc=$?
    t154_err="$(<"$BOX/e154")"
    agy_fault_check "case$t154_i" "$t154_out" "$t154_err" "$t154_rc" || t154_ok=0
    printf '%s' "$t154_out" | grep -q $'\x1b\[' && { t154_ok=0; printf 'case%s: ANSI under NO_COLOR\n' "$t154_i" >&2; }
    printf '%s' "$t154_out" | python3 -c 'import sys
d = sys.stdin.read()
sys.exit(0 if not any((ord(c) < 32 and c != "\n") or ord(c) == 127 for c in d) else 1)' \
        || { t154_ok=0; printf 'case%s: control chars\n' "$t154_i" >&2; }
done
# BOM JSON（UTF-8 BOM 开头）：解析失败按空 payload 降级，契约不变
t154_bom_out="$(printf '\xef\xbb\xbf{"cwd":"/tmp","model":{"display_name":"m"}}' \
    | env NO_COLOR=1 COLUMNS=80 WREN_CACHE_DIR="$BOX/c154b" python3 "$AGY_PAYLOAD" 2>"$BOX/e154b")"
t154_bom_rc=$?
agy_fault_check BOM "$t154_bom_out" "$(<"$BOX/e154b")" "$t154_bom_rc" || t154_ok=0
if [[ $t154_ok -eq 1 ]]; then
    pass T154 "agy fault matrix: 39 malformed payloads (incl. BOM/NaN/bidi/ANSI/OSC/cost) -> rc0, stderr empty, 2 lines, width<=80"
else
    fail T154 "one or more fault cases violated the contract (see stderr)"
fi

# ============================================================
# T155: agy 宽度链——COLUMNS 优先；无 COLUMNS + 控制终端 51 列（payload
#       terminal_width=80 陈旧值）→ 用 51；无 tty → terminal_width；都没有 → 80
# ============================================================
new_box
t155_ab="$(python3 - "$AGY_PAYLOAD" "$BOX/c155ab" <<'T155ABPY'
import fcntl, os, pty, select, struct, subprocess, sys, termios

def run_pty(cols, extra, payload):
    m, s = pty.openpty()
    fcntl.ioctl(s, termios.TIOCSWINSZ, struct.pack("HHHH", 24, cols, 0, 0))
    env = {k: v for k, v in os.environ.items() if k != "COLUMNS"}
    env.update({"NO_COLOR": "1", "WREN_CACHE_DIR": sys.argv[2] + str(cols)})
    env.update(extra)
    def preexec():
        os.setsid()
        fcntl.ioctl(s, termios.TIOCSCTTY, 0)
    p = subprocess.Popen([sys.executable, sys.argv[1]], stdin=subprocess.PIPE, stdout=s, stderr=s,
                         env=env, preexec_fn=preexec)
    os.close(s)
    p.stdin.write(payload.encode())
    p.stdin.close()
    out = b""
    while True:
        r, _, _ = select.select([m], [], [], 5)
        if not r:
            break
        try:
            chunk = os.read(m, 4096)
        except OSError:
            break
        if not chunk:
            break
        out += chunk
    os.close(m)
    p.wait(timeout=10)
    return out.decode("utf-8", "ignore")

# A：COLUMNS=51 压过 120 列控制终端 → 窄档
a = run_pty(120, {"COLUMNS": "51"}, '{"cwd":"/tmp","model":{"display_name":"m"}}')
# B：无 COLUMNS，控制终端 51 列 + 陈旧 terminal_width=80 → 用 tty 的 51（关键验收）
b = run_pty(51, {}, '{"cwd":"/tmp","model":{"display_name":"m"},"terminal_width":80}')
sys.stdout.write(a.rstrip("\n") + "@@" + b.rstrip("\n"))
T155ABPY
)"
t155_a="${t155_ab%%@@*}"; t155_b="${t155_ab##*@@}"
t155_cd="$(python3 - "$AGY_PAYLOAD" "$BOX/c155cd" <<'T155CDPY'
import os, subprocess, sys

def run(payload, cache):
    env = {k: v for k, v in os.environ.items() if k != "COLUMNS"}
    env.update({"NO_COLOR": "1", "WREN_CACHE_DIR": cache})
    p = subprocess.run([sys.executable, sys.argv[1]], input=payload.encode(), capture_output=True,
                       env=env, preexec_fn=os.setsid)   # setsid：无控制终端
    return p.returncode, p.stdout.decode("utf-8", "replace"), p.stderr.decode("utf-8", "replace")

rc, c, err = run('{"cwd":"/tmp","model":{"display_name":"m"},"terminal_width":51}', sys.argv[2] + "c")
assert rc == 0 and not err, (rc, err)
rc2, d, err2 = run('{"cwd":"/tmp/%s","model":{"display_name":"m"}}' % ("x" * 200), sys.argv[2] + "d")
assert rc2 == 0 and not err2, (rc2, err2)
sys.stdout.write(c.rstrip("\n") + "@@" + d.rstrip("\n"))
T155CDPY
)"
t155_c="${t155_cd%%@@*}"; t155_d="${t155_cd##*@@}"
t155_ok=1
[[ "${t155_a##*$'\n'}" == "0/0|m" ]] || t155_ok=0      # COLUMNS 优先（tty=120 也不影响）
[[ "${t155_b##*$'\n'}" == "0/0|m" ]] || t155_ok=0      # tty=51 压过 terminal_width=80
[[ "${t155_c##*$'\n'}" == "0/0|m" ]] || t155_ok=0      # 无 tty → terminal_width=51
[[ "${t155_d##*$'\n'}" == "↑0 ↓0 | R0 | m" ]] || t155_ok=0   # 都没有 → 默认 80（宽档）
t155_dw="$(printf '%s' "${t155_d%%$'\n'*}" | agy_w)"
# 默认 80：200 字符 cwd 被折到 74 格预算（"…"+72 格），加 " | agy" 共 79。
# 若默认值不是 80（例如 100/120），这行会是 99/119——区间断言足够钉住。
[[ "$t155_dw" -ge 78 && "$t155_dw" -le 80 ]] || t155_ok=0
if [[ $t155_ok -eq 1 ]]; then
    pass T155 "agy width chain: COLUMNS > ctty (51 beats stale terminal_width=80) > payload > 80"
else
    fail T155 "a=[${t155_a##*$'\n'}] b=[${t155_b##*$'\n'}] c=[${t155_c##*$'\n'}] d=[${t155_d##*$'\n'}] dw=$t155_dw"
fi

# ============================================================
# T156: agy 编码——LC_ALL=C LANG=C PYTHONCOERCECLOCALE=0 下仍输出合法
#       UTF-8 两行（含 ↑），不因 locale 抛 UnicodeEncodeError
# ============================================================
new_box
t156_p='{"cwd":"/tmp","model":{"display_name":"m"},"context_window":{"context_window_size":200000,"total_input_tokens":43138,"total_output_tokens":5200}}'
t156_out="$(printf '%s' "$t156_p" | env LC_ALL=C LANG=C PYTHONCOERCECLOCALE=0 NO_COLOR=1 COLUMNS=120 \
    WREN_CACHE_DIR="$BOX/c156" python3 "$AGY_PAYLOAD" 2>"$BOX/e156")"
t156_rc=$?
t156_err="$(<"$BOX/e156")"
printf '%s' "$t156_out" | python3 -c 'import sys; sys.stdin.buffer.read().decode("utf-8")' 2>/dev/null
t156_utf8=$?
if [[ "$t156_rc" == "0" && -z "$t156_err" && "$t156_utf8" == "0" \
   && "$(agy_lines "$t156_out")" == "2" ]] && printf '%s' "$t156_out" | grep -qF "↑43K"; then
    pass T156 "agy LC_ALL=C: valid UTF-8 two lines with ↑ (stdout reconfigured)"
else
    fail T156 "rc=$t156_rc utf8=$t156_utf8 err=[$t156_err] out=[$t156_out]"
fi

# ============================================================
# T157: agy 长分支 + 长 CJK 路径在 80/60/40/30 列不溢出；徽标尽量保住
# ============================================================
new_box
T157DIR="$BOX/中文项目目录名称很长的十六个汉字/另一个很长的中文目录名称十六个汉字/最后一级超长中文目录名称十六个字"
mkdir -p "$T157DIR"
(cd "$T157DIR" && git -c init.defaultBranch=main init -q && git config user.email t@e.com && git config user.name t \
    && : >f && git add -A && git commit -qm i >/dev/null 2>&1 \
    && git checkout -q -b feat/very-long-branch-name-for-wren-agy-width-test \
    && printf 'x\n' >>f) >/dev/null 2>&1
t157_p="$(printf '{"cwd":"%s","model":{"display_name":"m"},"context_window":{"context_window_size":200000}}' "$T157DIR")"
t157_ok=1; t157_note=""
for t157_cols in 80 60 40 30; do
    t157_out="$(agy_out "$BOX/c157-$t157_cols" "$t157_cols" none "$t157_p")"
    t157_l1="${t157_out%%$'\n'*}"; t157_l2="${t157_out##*$'\n'}"
    t157_budget="$t157_cols"
    [[ "$t157_cols" -le 55 ]] && t157_budget=$((t157_cols - 5))
    t157_w1="$(printf '%s' "$t157_l1" | agy_w)"; t157_w2="$(printf '%s' "$t157_l2" | agy_w)"
    [[ "$t157_w1" -le "$t157_budget" && "$t157_w2" -le "$t157_budget" ]] \
        || { t157_ok=0; t157_note="$t157_note [$t157_cols:w=$t157_w1/$t157_w2>budget$t157_budget]"; }
    printf '%s' "$t157_l1" | grep -qF "agy" || { t157_ok=0; t157_note="$t157_note [$t157_cols:badge]"; }
done
if [[ $t157_ok -eq 1 ]]; then
    pass T157 "agy long branch + CJK path fits 80/60/40/30, badge kept"
else
    fail T157 "$t157_note"
fi

# ============================================================
# T158: agy 非 git cwd——无分支段、不报错
# ============================================================
new_box
mkdir -p "$BOX/plain"
t158_p="$(printf '{"cwd":"%s","model":{"display_name":"m"}}' "$BOX/plain")"
t158_out="$(agy_out "$BOX/c158" 120 none "$t158_p")"
t158_l1="${t158_out%%$'\n'*}"; t158_l2="${t158_out##*$'\n'}"
if [[ "$t158_l1" == "$BOX/plain | agy" && "$t158_l2" == "↑0 ↓0 | R0 | m" ]]; then
    pass T158 "agy non-git cwd: no branch segment, no error"
else
    fail T158 "l1=[$t158_l1] l2=[$t158_l2]"
fi

# ============================================================
# T159: agy ↔ cc 一致性——同一逻辑状态分别喂两个 payload（各自格式的
#       transcript），宽档/窄档/NO_COLOR 下除宿主徽标与 cost 段外逐字相同
# ============================================================
new_box
R159="$BOX/r159"; mkdir -p "$R159"
(cd "$R159" && git -c init.defaultBranch=main init -q && git config user.email t@e.com && git config user.name t \
    && printf 'a\n' >a.txt && git add -A && git commit -qm i >/dev/null 2>&1 && printf 'b\n' >>a.txt) >/dev/null 2>&1
cat >"$BOX/cc159.jsonl" <<'EOF2'
{"type":"user","timestamp":"2026-01-01T00:00:00Z","message":{"content":"hi"}}
{"type":"assistant","timestamp":"2026-01-01T00:00:01Z","message":{"usage":{"input_tokens":1000,"output_tokens":100,"cache_read_input_tokens":500}}}
{"type":"assistant","timestamp":"2026-01-01T00:00:02Z","message":{"usage":{"input_tokens":2000,"output_tokens":200,"cache_read_input_tokens":1500}}}
EOF2
cat >"$BOX/agy159.jsonl" <<'EOF2'
{"source":"USER_EXPLICIT","type":"USER_INPUT","created_at":"2026-01-01T00:00:00Z","content":"hi"}
{"source":"MODEL","type":"PLANNER_RESPONSE","created_at":"2026-01-01T00:00:01Z","input_tokens":1000,"output_tokens":100,"cache_read_tokens":500}
{"source":"MODEL","type":"PLANNER_RESPONSE","created_at":"2026-01-01T00:00:02Z","input_tokens":2000,"output_tokens":200,"cache_read_tokens":1500}
EOF2
t159_cc_p="$(printf '{"cwd":"%s","model":{"display_name":"m"},"effort":{"level":"high"},"context_window":{"context_window_size":200000,"current_usage":{"input_tokens":1000,"cache_read_input_tokens":3000,"cache_creation_input_tokens":0}},"transcript_path":"%s"}' "$R159" "$BOX/cc159.jsonl")"
t159_agy_p="$(printf '{"cwd":"%s","model":{"id":"m","display_name":"m","effort":"high"},"context_window":{"context_window_size":200000,"current_usage":{"input_tokens":1000,"cache_read_input_tokens":3000,"cache_creation_input_tokens":0}},"transcript_path":"%s","cost":{"total_usd":0.03,"subagent_usd":0.01,"estimated":true}}' "$R159" "$BOX/agy159.jsonl")"
t159_ok=1; t159_note=""
for t159_mode in wide narrow; do
    if [[ "$t159_mode" == "wide" ]]; then t159_cols=120; else t159_cols=51; fi
    t159_cc="$(printf '%s' "$t159_cc_p" | env NO_COLOR=1 COLUMNS="$t159_cols" WREN_CACHE_DIR="$BOX/c159cc$t159_cols" python3 "$CC_PAYLOAD" 2>/dev/null)"
    t159_agy="$(agy_out "$BOX/c159agy$t159_cols" "$t159_cols" none "$t159_agy_p")"
    t159_cc_l1="${t159_cc%%$'\n'*}"; t159_cc_l2="${t159_cc##*$'\n'}"
    t159_agy_l1="${t159_agy%%$'\n'*}"; t159_agy_l2="${t159_agy##*$'\n'}"
    t159_cc_l1s="$(strip_tag "$t159_cc_l1")"; t159_agy_l1s="$(strip_tag "$t159_agy_l1")"
    t159_agy_l2s="$(printf '%s' "$t159_agy_l2" | agy_strip_cost)"
    [[ "$t159_cc_l1s" == "$t159_agy_l1s" ]] \
        || { t159_ok=0; t159_note="$t159_note [$t159_mode:l1 cc=[$t159_cc_l1s] agy=[$t159_agy_l1s]]"; }
    [[ "$t159_cc_l2" == "$t159_agy_l2s" ]] \
        || { t159_ok=0; t159_note="$t159_note [$t159_mode:l2 cc=[$t159_cc_l2] agy=[$t159_agy_l2s]]"; }
done
t159_agy_tc="$(agy_out "$BOX/c159tc" 120 truecolor "$t159_agy_p")"
t159_agy_nc="$(agy_out "$BOX/c159nc" 120 none "$t159_agy_p")"
[[ "$(printf '%s' "$t159_agy_tc" | agy_plain)" == "$t159_agy_nc" ]] \
    || { t159_ok=0; t159_note="$t159_note [NO_COLOR!=stripped]"; }
# 行2 溢出丢序：超长模型名压到两档宽度——agy 的 cost 必须先让位，其余段
# （TTFT→CH→身份组）与 cc 同序；丢错序会在这里分叉。
t159_long="$(python3 -c 'print("Model-" + "M" * 90)')"
t159_cc_p2="$(printf '{"cwd":"%s","model":{"display_name":"%s"},"effort":{"level":"high"},"context_window":{"context_window_size":200000,"current_usage":{"input_tokens":1000,"cache_read_input_tokens":3000,"cache_creation_input_tokens":0}},"transcript_path":"%s"}' "$R159" "$t159_long" "$BOX/cc159.jsonl")"
t159_agy_p2="$(printf '{"cwd":"%s","model":{"id":"%s","display_name":"%s","effort":"high"},"context_window":{"context_window_size":200000,"current_usage":{"input_tokens":1000,"cache_read_input_tokens":3000,"cache_creation_input_tokens":0}},"transcript_path":"%s","cost":{"total_usd":0.03,"subagent_usd":0.01,"estimated":true}}' "$R159" "$t159_long" "$t159_long" "$BOX/agy159.jsonl")"
for t159_cols in 120 51; do
    t159_cc2="$(printf '%s' "$t159_cc_p2" | env NO_COLOR=1 COLUMNS="$t159_cols" WREN_CACHE_DIR="$BOX/c159cc$t159_cols" python3 "$CC_PAYLOAD" 2>/dev/null)"
    t159_agy2="$(agy_out "$BOX/c159agy$t159_cols" "$t159_cols" none "$t159_agy_p2")"
    t159_cc2_l2="${t159_cc2##*$'\n'}"
    t159_agy2_l2="$(printf '%s' "${t159_agy2##*$'\n'}" | agy_strip_cost)"
    [[ "$t159_cc2_l2" == "$t159_agy2_l2" ]] \
        || { t159_ok=0; t159_note="$t159_note [overflow@$t159_cols:cc=[$t159_cc2_l2] agy=[$t159_agy2_l2]]"; }
done
if [[ $t159_ok -eq 1 ]]; then
    pass T159 "agy line1/line2 identical to cc after badge+cost strip (wide/narrow/NO_COLOR)"
else
    fail T159 "$t159_note"
fi

# ============================================================
# T160: install agy——enabled:true + 其他键（padding/stack_with_default）保留 +
#       幂等 + 备份是最原始字节 + payload 是 exec 副本
# ============================================================
new_box
printf '{\n  "model": "m",\n  "statusLine": { "type": "command", "command": "old-thing", "padding": 0, "stack_with_default": true, "enabled": false },\n  "env": {"A": "1"}\n}\n' >"$AGY_SETTINGS"
cp "$AGY_SETTINGS" "$BOX/before160"
WREN_AGY_PYTHON=off run_wren install agy
t160_rc1="$WREN_EXIT"
t160_cmd="$(json_field "$AGY_SETTINGS" 'd["statusLine"]["command"]')"
t160_type="$(json_field "$AGY_SETTINGS" 'd["statusLine"]["type"]')"
t160_en="$(json_field "$AGY_SETTINGS" 'd["statusLine"]["enabled"]')"
t160_pad="$(json_field "$AGY_SETTINGS" 'd["statusLine"]["padding"]')"
t160_stack="$(json_field "$AGY_SETTINGS" 'd["statusLine"]["stack_with_default"]')"
t160_env="$(json_field "$AGY_SETTINGS" 'd["env"]["A"]')"
cp "$AGY_SETTINGS" "$BOX/after160a"
WREN_AGY_PYTHON=off run_wren install agy
t160_rc2="$WREN_EXIT"
t160_ok=1
[[ "$t160_rc1" == "0" && "$t160_rc2" == "0" ]] || t160_ok=0
[[ "$t160_cmd" == "$AGY/wren-agy.py" && "$t160_type" == "command" && "$t160_en" == "True" ]] || t160_ok=0
[[ "$t160_pad" == "0" && "$t160_stack" == "True" && "$t160_env" == "1" ]] || t160_ok=0
[[ -f "$AGY/wren-agy.py" && -x "$AGY/wren-agy.py" ]] && cmp -s "$AGY/wren-agy.py" "$AGY_PAYLOAD" || t160_ok=0
diff -q "$BOX/before160" "$AGY_SETTINGS.wren-bak" >/dev/null || t160_ok=0
diff -q "$BOX/after160a" "$AGY_SETTINGS" >/dev/null || { t160_ok=0; t160_note="not idempotent"; }
if [[ $t160_ok -eq 1 ]]; then
    pass T160 "install agy: enabled true, other keys kept, idempotent, payload copy + original backup"
else
    fail T160 "cmd=[$t160_cmd] type=[$t160_type] en=[$t160_en] pad=[$t160_pad] stack=[$t160_stack] note=${t160_note:-}"
fi

# ============================================================
# T161: uninstall agy——对称；enabled:true 一并摘；enabled:false 保留；
#       padding 等用户子键保留；command 被用户改过 → left alone
# ============================================================
new_box
printf '{\n  "statusLine": { "type": "command", "command": "old", "padding": 2, "stack_with_default": false }\n}\n' >"$AGY_SETTINGS"
run_wren install agy
# 用户主动关掉
python3 - "$AGY_SETTINGS" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["statusLine"]["enabled"] = False
with open(p, "w", encoding="utf-8") as fh:
    json.dump(d, fh, indent=2)
    fh.write("\n")
PY
run_wren uninstall agy
t161_ok=1
[[ "$(json_field "$AGY_SETTINGS" 'd["statusLine"].get("type")')" == "None" ]] || t161_ok=0
[[ "$(json_field "$AGY_SETTINGS" 'd["statusLine"].get("command")')" == "None" ]] || t161_ok=0
[[ "$(json_field "$AGY_SETTINGS" 'd["statusLine"].get("enabled")')" == "False" ]] || t161_ok=0
[[ "$(json_field "$AGY_SETTINGS" 'd["statusLine"]["padding"]')" == "2" ]] || t161_ok=0
[[ "$(json_field "$AGY_SETTINGS" 'd["statusLine"]["stack_with_default"]')" == "False" ]] || t161_ok=0
[[ ! -e "$AGY/wren-agy.py" ]] || t161_ok=0
# 干净安装 → 卸载后 statusLine 整键消失
new_box
run_wren install agy
run_wren uninstall agy
[[ "$(json_field "$AGY_SETTINGS" '("statusLine" in d)')" == "False" ]] || t161_ok=0
[[ ! -e "$AGY/wren-agy.py" ]] || t161_ok=0
# 用户改过 command → 不碰用户配置
run_wren install agy
python3 - "$AGY_SETTINGS" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["statusLine"]["command"] = "/usr/local/bin/user-statusline"
with open(p, "w", encoding="utf-8") as fh:
    json.dump(d, fh, indent=2)
    fh.write("\n")
PY
run_wren uninstall agy
[[ "$(json_field "$AGY_SETTINGS" 'd["statusLine"]["command"]')" == "/usr/local/bin/user-statusline" ]] || t161_ok=0
if [[ $t161_ok -eq 1 ]]; then
    pass T161 "uninstall agy: symmetric; enabled:true dropped, enabled:false/padding kept, foreign command left alone"
else
    fail T161 "sl=[$(cat "$AGY_SETTINGS")] payload=$([[ -e $AGY/wren-agy.py ]] && echo y || echo n)"
fi

# ============================================================
# T162: install agy 遇非法 settings JSON → exit 1 且零副作用
# ============================================================
new_box
printf '{ this is not json\n' >"$AGY_SETTINGS"
cp "$AGY_SETTINGS" "$BOX/before162"
run_wren install agy
if [[ "$WREN_EXIT" == "1" ]] \
   && diff -q "$BOX/before162" "$AGY_SETTINGS" >/dev/null \
   && [[ "$(ls -A "$AGY")" == "settings.json" ]] \
   && [[ ! -e "$AGY_SETTINGS.wren-bak" && ! -e "$AGY_SETTINGS.wren-tmp" ]]; then
    pass T162 "install agy invalid JSON -> exit 1, zero side effects"
else
    fail T162 "exit=$WREN_EXIT files=[$(ls -A "$AGY" | tr '\n' ' ')]"
fi

# ============================================================
# T163: statusLine 非对象（true）→ 归一化成对象；agy/antigravity 别名互通
# ============================================================
new_box
printf '{"statusLine": true, "model": "m"}\n' >"$AGY_SETTINGS"
WREN_AGY_PYTHON=off run_wren install antigravity
t163_ok=1
[[ "$WREN_EXIT" == "0" ]] || t163_ok=0
[[ "$(json_field "$AGY_SETTINGS" 'type(d["statusLine"]).__name__')" == "dict" ]] || t163_ok=0
[[ "$(json_field "$AGY_SETTINGS" 'd["statusLine"].get("type")')" == "command" ]] || t163_ok=0
[[ "$(json_field "$AGY_SETTINGS" 'd["statusLine"].get("command")')" == "$AGY/wren-agy.py" ]] || t163_ok=0
[[ "$(json_field "$AGY_SETTINGS" 'd["statusLine"].get("enabled")')" == "True" ]] || t163_ok=0
run_wren uninstall agy
[[ "$(json_field "$AGY_SETTINGS" '("statusLine" in d)')" == "False" ]] || t163_ok=0
if [[ $t163_ok -eq 1 ]]; then
    pass T163 "install antigravity normalizes non-object statusLine; agy/antigravity aliases"
else
    fail T163 "settings=[$(cat "$AGY_SETTINGS")] exit=$WREN_EXIT"
fi

# ============================================================
# T164: 性能护栏——标准夹具下单次热运行 < 1.5s（防灾难性回归，阈值放宽）
# ============================================================
new_box
agy_base_fixture "$BOX/t164.jsonl"
t164_p="$(printf '{"cwd":"/tmp","model":{"display_name":"m","effort":"high"},"context_window":{"context_window_size":200000},"transcript_path":"%s","cost":{"total_usd":0.03}}' "$BOX/t164.jsonl")"
t164_s="$(python3 - "$AGY_PAYLOAD" "$BOX/c164" "$t164_p" <<'T164PY'
import os, subprocess, sys, time
env = dict(os.environ, NO_COLOR="1", COLUMNS="120", WREN_CACHE_DIR=sys.argv[2])
env.pop("HERDR_WORKSPACE_ID", None)
times = []
for _ in range(3):
    t0 = time.monotonic()
    r = subprocess.run([sys.executable, sys.argv[1]], input=sys.argv[3].encode(), capture_output=True, env=env)
    times.append(time.monotonic() - t0)
    assert r.returncode == 0 and not r.stderr, (r.returncode, r.stderr)
print("%.3f" % max(times))
T164PY
)"
if awk "BEGIN{exit !($t164_s < 1.5)}"; then
    pass T164 "agy warm run ${t164_s}s < 1.5s (3-run max)"
else
    fail T164 "warm run ${t164_s}s >= 1.5s"
fi

# ============================================================
# T165: 缓存键隔离——agy 用 agy- 前缀；同 transcript 被 cc/qc 扫过后
#       agy 输出不变（不串味）
# ============================================================
new_box
agy_base_fixture "$BOX/t165.jsonl"
t165_p="$(printf '{"cwd":"/tmp","model":{"display_name":"m"},"context_window":{"context_window_size":200000},"transcript_path":"%s"}' "$BOX/t165.jsonl")"
t165_a="$(agy_out "$BOX/c165" 120 none "$t165_p")"
t165_cf="$(agy_cache_file "$BOX/c165" "$BOX/t165.jsonl")"
printf '{"cwd":"/tmp","model":{"display_name":"m"},"transcript_path":"%s"}' "$BOX/t165.jsonl" \
    | NO_COLOR=1 WREN_CACHE_DIR="$BOX/c165" python3 "$CC_PAYLOAD" >/dev/null 2>&1
printf '{"cwd":"/tmp","model":{"display_name":"m"},"transcript_path":"%s"}' "$BOX/t165.jsonl" \
    | NO_COLOR=1 WREN_CACHE_DIR="$BOX/c165" python3 "$QC_PAYLOAD" >/dev/null 2>&1
t165_b="$(agy_out "$BOX/c165" 120 none "$t165_p")"
t165_nagy="$(ls "$BOX/c165" | grep -c '^agy-')"
t165_ncc="$(ls "$BOX/c165" | grep -c '^cc-')"
t165_nqc="$(ls "$BOX/c165" | grep -c '^qc-')"
if [[ -f "$t165_cf" && "$t165_a" == "$t165_b" && "$t165_nagy" == "1" \
   && "$t165_ncc" == "1" && "$t165_nqc" == "1" ]]; then
    pass T165 "agy cache key isolated: agy- prefix, no cross-host contamination"
else
    fail T165 "agy-files=$t165_nagy cc=$t165_ncc qc=$t165_nqc same=$([[ "$t165_a" == "$t165_b" ]] && echo y || echo n)"
fi

# ============================================================
# T166: 文本净化（R2-1/R3-3）——ANSI/OSC/CSI/bidi/零宽空格注入不得进入 stdout；
#       ZWNJ 保留；正常文本逐字不变；注入 ESC 不得干掉本进程着色（R3-3 移除
#       fail-safe 后：彩色模式仍有 38;2; 码，且不含注入的裸 SGR）。
# ============================================================
new_box
t166_ok=1; t166_note=""
# A) ANSI in model.display_name（NO_COLOR 被摘掉、COLORTERM 开启）
t166_ap='{"cwd":"/tmp","model":{"display_name":"Gem\u001b[31mevil\u001b[0m","effort":"medium"},"context_window":{}}'
t166_a="$(printf '%s' "$t166_ap" \
    | env -u NO_COLOR COLORTERM=truecolor COLUMNS=120 WREN_CACHE_DIR="$BOX/c166a" python3 "$AGY_PAYLOAD" 2>"$BOX/e166a")"
t166_arc=$?
t166_an="$(printf '%s' "$t166_ap" \
    | env NO_COLOR=1 COLUMNS=120 WREN_CACHE_DIR="$BOX/c166an" python3 "$AGY_PAYLOAD" 2>/dev/null)"
[[ "$t166_arc" == "0" && -z "$(cat "$BOX/e166a")" ]] || { t166_ok=0; t166_note="$t166_note [ansi:rc/err]"; }
printf '%s' "$t166_a" | grep -qF "38;2;" || { t166_ok=0; t166_note="$t166_note [ansi:truecolor]"; }
printf '%s' "$t166_a" | grep -qF $'\x1b[31m' && { t166_ok=0; t166_note="$t166_note [ansi:bare-sgr]"; }
[[ "$(printf '%s' "$t166_a" | agy_plain)" == "$t166_an" ]] || { t166_ok=0; t166_note="$t166_note [ansi:text]"; }
printf '%s' "$t166_a" | grep -qF "Gemevil" || { t166_ok=0; t166_note="$t166_note [ansi:name]"; }
# B) bidi（RLO/LRI）注入 model / effort / cwd
# 注：以下 ZWNJ / RLO / LRI 断言用八进制字节转义（$'\342\200\214' 等），
# 不用反斜杠-u 四 hex 转义：bash 3.2 在整段脚本的上下文里不解释后者（T189 第 2 条规则守门）。
t166_b="$(printf '%s' '{"cwd":"/tmp/a\u202eb","workspace":{"current_dir":"/tmp/a\u202eb"},"model":{"display_name":"ab\u202ecdef","effort":"hi\u2066"},"context_window":{}}' \
    | env NO_COLOR=1 COLUMNS=120 WREN_CACHE_DIR="$BOX/c166b" python3 "$AGY_PAYLOAD" 2>/dev/null)"
printf '%s' "$t166_b" | grep -q $'\342\200\256' && { t166_ok=0; t166_note="$t166_note [bidi:202E]"; }
printf '%s' "$t166_b" | grep -q $'\342\201\246' && { t166_ok=0; t166_note="$t166_note [bidi:2066]"; }
printf '%s' "$t166_b" | grep -qF "abcdef · hi" || { t166_ok=0; t166_note="$t166_note [bidi:text]"; }
[[ "${t166_b%%$'\n'*}" == "/tmp/ab | agy" ]] || { t166_ok=0; t166_note="$t166_note [bidi:cwd]"; }
# C) OSC（BEL 结尾）/ CSI（ED）注入
t166_c="$(printf '%s' '{"cwd":"/tmp","model":{"display_name":"ab\u001b]0;title\u0007cdef","effort":"me\u001b[2Jdium"},"context_window":{}}' \
    | env NO_COLOR=1 COLUMNS=120 WREN_CACHE_DIR="$BOX/c166c" python3 "$AGY_PAYLOAD" 2>/dev/null)"
printf '%s' "$t166_c" | grep -q $'\x1b' && { t166_ok=0; t166_note="$t166_note [osc:ESC]"; }
printf '%s' "$t166_c" | grep -qF ";title" && { t166_ok=0; t166_note="$t166_note [osc:title]"; }
printf '%s' "$t166_c" | grep -qF "[2J" && { t166_ok=0; t166_note="$t166_note [csi:2J]"; }
printf '%s' "$t166_c" | grep -qF "abcdef · medium" || { t166_ok=0; t166_note="$t166_note [osc:text]"; }
# D) ZWNJ 保留（波斯文模型名）
t166_d="$(printf '%s' '{"cwd":"/tmp","model":{"display_name":"ف\u200cب"},"context_window":{}}' \
    | env NO_COLOR=1 COLUMNS=120 WREN_CACHE_DIR="$BOX/c166d" python3 "$AGY_PAYLOAD" 2>/dev/null)"
printf '%s' "$t166_d" | grep -q $'\342\200\214' || { t166_ok=0; t166_note="$t166_note [zwnj]"; }
# E) 正常文本（空格/括号/连字符/CJK）逐字不变
t166_e="$(printf '%s' '{"cwd":"/tmp","model":{"display_name":"Gemini 4 Neon (Medium) — 测试 ×2"},"context_window":{}}' \
    | env NO_COLOR=1 COLUMNS=120 WREN_CACHE_DIR="$BOX/c166e" python3 "$AGY_PAYLOAD" 2>/dev/null)"
printf '%s' "$t166_e" | grep -qF "Gemini 4 Neon (Medium) — 测试 ×2" || { t166_ok=0; t166_note="$t166_note [normal]"; }
# F) herdr env 注入（ESC + bidi）：着色不受影响，注入的裸 SGR 被剥掉
t166_f="$(printf '%s' '{"cwd":"/tmp","model":{"display_name":"m"},"context_window":{}}' \
    | env -u NO_COLOR COLORTERM=truecolor COLUMNS=120 WREN_CACHE_DIR="$BOX/c166f" \
        HERDR_WORKSPACE_ID=$'w\x1b[31m1' HERDR_TAB_ID=$'t\342\200\2562' HERDR_PANE_ID='p3' \
        python3 "$AGY_PAYLOAD" 2>/dev/null)"
printf '%s' "$t166_f" | grep -qF "38;2;" || { t166_ok=0; t166_note="$t166_note [herdr:truecolor]"; }
printf '%s' "$t166_f" | grep -qF $'\x1b[31m' && { t166_ok=0; t166_note="$t166_note [herdr:bare-sgr]"; }
printf '%s' "$t166_f" | grep -qF "w1:t2:p3" || { t166_ok=0; t166_note="$t166_note [herdr:text]"; }
if [[ $t166_ok -eq 1 ]]; then
    pass T166 "agy text sanitize: ANSI/OSC/CSI/bidi stripped, colour kept, ZWNJ kept, plain text unchanged"
else
    fail T166 "$t166_note"
fi

# ============================================================
# T167: token 取整（R2-2）——transcript 与 payload 回退的 token 计数统一 int
#       （999.9→999、2.0→2、3.9→3）；旧缓存里的 float 状态同样截断。
# ============================================================
new_box
cat >"$BOX/t167.jsonl" <<'EOF2'
{"source":"MODEL","type":"PLANNER_RESPONSE","created_at":"2026-01-01T00:00:01Z","input_tokens":999.9,"output_tokens":2.0,"cache_read_tokens":3.9}
EOF2
t167_p="$(printf '{"cwd":"/tmp","model":{"display_name":"m"},"context_window":{"context_window_size":200000},"transcript_path":"%s"}' "$BOX/t167.jsonl")"
t167_a="$(agy_out "$BOX/c167" 120 none "$t167_p" | tail -1)"
t167_p2='{"cwd":"/tmp","model":{"display_name":"m"},"context_window":{"context_window_size":200000,"total_input_tokens":999.9,"total_output_tokens":2.0,"current_usage":{"input_tokens":100.9,"cache_read_input_tokens":3.9,"cache_creation_input_tokens":0.9}}}'
t167_b="$(agy_out "$BOX/c167b" 120 none "$t167_p2" | tail -1)"
# 旧缓存 float 状态：空 transcript + 全 float 状态 → int 后渲染
: >"$BOX/t167-empty.jsonl"
t167_cf="$(agy_cache_file "$BOX/c167c" "$BOX/t167-empty.jsonl")"
mkdir -p "$BOX/c167c"
printf '{"path":"%s","offset":0,"input_t":5.9,"output_t":1.2,"cache_r":3.7,"last_prompt_tokens":7.9,"last_cache_r":2.2}' \
    "$BOX/t167-empty.jsonl" >"$t167_cf"
t167_c="$(agy_out "$BOX/c167c" 120 none "$(printf '{"cwd":"/tmp","model":{"display_name":"m"},"context_window":{"context_window_size":200000},"transcript_path":"%s"}' "$BOX/t167-empty.jsonl")" | tail -1)"
t167_ok=1
[[ "$t167_a" == "↑999 ↓2 | R3 CH0.30% | 0.50%/200K | m" ]] || { t167_ok=0; t167_note="a=[$t167_a]"; }
[[ "$t167_b" == "↑999 ↓2 | R3 CH3.69% | 0.05%/200K | m" ]] || { t167_ok=0; t167_note="$t167_note b=[$t167_b]"; }
[[ "$t167_c" == "↑5 ↓1 | R3 CH28.57% | 0.00%/200K | m" ]] || { t167_ok=0; t167_note="$t167_note c=[$t167_c]"; }
if [[ $t167_ok -eq 1 ]]; then
    pass T167 "agy token ints: transcript/payload fallback/cached floats truncate (2.0 -> 2)"
else
    fail T167 "$t167_note"
fi

# ============================================================
# T168: git 运行时预算（R2-3）——PATH 里放 sleep 10 的假 git，总时长 < 2.2s
# ============================================================
new_box
mkdir -p "$BOX/slowbin"
printf '#!/bin/sh\nsleep 10\n' >"$BOX/slowbin/git"
chmod +x "$BOX/slowbin/git"
t168="$(python3 - "$AGY_PAYLOAD" "$BOX/slowbin" "$BOX/c168" <<'T168PY'
import json, os, subprocess, sys, time
env = dict(os.environ, NO_COLOR="1", COLUMNS="120", WREN_CACHE_DIR=sys.argv[3],
           PATH=sys.argv[2] + ":" + os.environ["PATH"])
payload = json.dumps({"cwd": "/tmp", "model": {"display_name": "m"}}).encode()
t0 = time.monotonic()
r = subprocess.run([sys.executable, sys.argv[1]], input=payload, capture_output=True, env=env)
print("%.2f %d %d %d" % (time.monotonic() - t0, r.returncode,
                         len(r.stdout.rstrip(b"\n").split(b"\n")), len(r.stderr)))
T168PY
)"
read -r t168_dt t168_rc t168_lines t168_errlen <<<"$t168"
if [[ "$t168_rc" == "0" && "$t168_lines" == "2" && "$t168_errlen" == "0" ]] \
   && awk "BEGIN{exit !($t168_dt < 2.2)}"; then
    pass T168 "agy git budget: hanging git returns in ${t168_dt}s < 2.2s (GIT_TIMEOUT_S=1.5)"
else
    fail T168 "dt=$t168_dt rc=$t168_rc lines=$t168_lines err=$t168_errlen"
fi

# ============================================================
# T169: 最坏路径（R2-3）——stdin 保持打开 + 慢 git 同时发生，总时长 < 3.8s
#       （stdin 1.0s + git 1.5s + 启动，期望 ~2.6s）
# ============================================================
new_box
mkdir -p "$BOX/slowbin"
printf '#!/bin/sh\nsleep 10\n' >"$BOX/slowbin/git"
chmod +x "$BOX/slowbin/git"
t169="$(python3 - "$AGY_PAYLOAD" "$BOX/slowbin" "$BOX/c169" <<'T169PY'
import os, subprocess, sys, time
env = dict(os.environ, NO_COLOR="1", COLUMNS="120", WREN_CACHE_DIR=sys.argv[3],
           PATH=sys.argv[2] + ":" + os.environ["PATH"])
p = subprocess.Popen([sys.executable, sys.argv[1]], stdin=subprocess.PIPE,
                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
t0 = time.monotonic()
out = p.stdout.read()      # 父进程始终不写、不关 stdin（模拟宿主不关管道）
dt = time.monotonic() - t0
rc = p.wait()
err = p.stderr.read()
p.stdin.close()
print("%.2f %d %d %d" % (dt, rc, len(out.rstrip(b"\n").split(b"\n")), len(err)))
T169PY
)"
read -r t169_dt t169_rc t169_lines t169_errlen <<<"$t169"
if [[ "$t169_rc" == "0" && "$t169_lines" == "2" && "$t169_errlen" == "0" ]] \
   && awk "BEGIN{exit !($t169_dt < 3.8)}"; then
    pass T169 "agy worst case: stdin open + hanging git returns in ${t169_dt}s < 3.8s"
else
    fail T169 "dt=$t169_dt rc=$t169_rc lines=$t169_lines err=$t169_errlen"
fi

# ============================================================
# T170: 扫描时间盒（R2-3）——大 transcript + WREN_AGY_SCAN_BUDGET=0.02：
#       首次 < 1.5s 且 0<offset<size；反复运行 offset 收敛到 size，最终输出
#       与默认预算冷扫一致；非法预算回落 1.0 不崩。
# ============================================================
new_box
t170_tr="$BOX/t170.jsonl"
python3 - "$t170_tr" <<'T170PY'
import json, sys
line = {"source": "MODEL", "type": "PLANNER_RESPONSE", "created_at": "2026-01-01T00:00:01Z",
        "input_tokens": 100, "output_tokens": 10, "cache_read_tokens": 50, "content": "x" * 400}
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    for _ in range(10000):
        fh.write(json.dumps(line) + "\n")
T170PY
t170_p="$(printf '{"cwd":"/tmp","model":{"display_name":"m"},"context_window":{"context_window_size":200000},"transcript_path":"%s"}' "$t170_tr")"
t170="$(python3 - "$AGY_PAYLOAD" "$BOX/c170" "$t170_p" "$t170_tr" <<'T170PY'
import glob, json, os, subprocess, sys, time
script, cache, payload, tr = sys.argv[1], sys.argv[2], sys.argv[3].encode(), sys.argv[4]
env = dict(os.environ, NO_COLOR="1", COLUMNS="120", WREN_CACHE_DIR=cache,
           WREN_AGY_SCAN_BUDGET="0.02")
def run(e=None):
    r = subprocess.run([sys.executable, script], input=payload, capture_output=True, env=e or env)
    assert r.returncode == 0 and not r.stderr, (r.returncode, r.stderr)
    return r.stdout.decode("utf-8", "replace")
def off():
    cf = glob.glob(os.path.join(cache, "agy-*.json"))[0]
    return json.load(open(cf)).get("offset")
size = os.path.getsize(tr)
t0 = time.monotonic(); run(); dt = time.monotonic() - t0
o_first = off()
runs = 0
while o_first is not None and o_first < size and runs < 120:
    run(); o_first = off(); runs += 1
full = run({**env, "WREN_AGY_SCAN_BUDGET": ""})          # 空 → 默认 1.0
cold_dir = cache + "-cold"
cold = run({**env, "WREN_CACHE_DIR": cold_dir, "WREN_AGY_SCAN_BUDGET": ""})
bad = run({**env, "WREN_CACHE_DIR": cache + "-bad", "WREN_AGY_SCAN_BUDGET": "abc"})
print("%.2f %d %d %d %d %d" % (dt, o_first, size, runs,
      int("↑1M ↓100K" in full and full == cold), int("↑1M" in bad)))
T170PY
)"
read -r t170_dt t170_off t170_size t170_runs t170_full t170_bad <<<"$t170"
if awk "BEGIN{exit !($t170_dt < 1.5)}" \
   && [[ "$t170_off" == "$t170_size" && "$t170_runs" -ge 1 \
      && "$t170_full" == "1" && "$t170_bad" == "1" ]]; then
    pass T170 "agy scan timebox: first ${t170_dt}s, converged in ${t170_runs} resumes == full scan; bogus budget falls back"
else
    fail T170 "dt=$t170_dt off=$t170_off/$t170_size runs=$t170_runs full=$t170_full bad=$t170_bad"
fi

# ============================================================
# T171: transcript 非普通文件（R3-1）——/dev/zero、FIFO、目录都不能打开/阻塞；
#       快速返回两行，token 回退 payload totals。
# ============================================================
new_box
mkdir -p "$BOX/t171dir"
mkfifo "$BOX/t171.fifo" 2>/dev/null || true
t171_p() { printf '{"cwd":"/tmp","model":{"display_name":"m"},"context_window":{"total_input_tokens":88244,"total_output_tokens":61074,"current_usage":{"cache_read_input_tokens":20857}},"transcript_path":"%s"}' "$1"; }
t171_ok=1; t171_note=""
for t171_spec in "zero:/dev/zero" "fifo:$BOX/t171.fifo" "dir:$BOX/t171dir"; do
    t171_name="${t171_spec%%:*}"; t171_path="${t171_spec#*:}"
    t171_meta="$(python3 - "$AGY_PAYLOAD" "$t171_path" "$BOX/c171-$t171_name" "$(t171_p "$t171_path")" "$BOX/o171-$t171_name" <<'T171PY'
import os, subprocess, sys, time
script, path, cache, payload, outpath = sys.argv[1:6]
env = dict(os.environ, NO_COLOR="1", COLUMNS="120", WREN_CACHE_DIR=cache)
t0 = time.monotonic()
r = subprocess.run([sys.executable, script], input=payload.encode(), capture_output=True, env=env, timeout=8)
open(outpath, "wb").write(r.stdout)
print("%.2f %d %d %d" % (time.monotonic() - t0, r.returncode,
                         len(r.stdout.rstrip(b"\n").split(b"\n")), len(r.stderr)))
T171PY
)"
    read -r t171_dt t171_rc t171_lines t171_errlen <<<"$t171_meta"
    t171_out="$(<"$BOX/o171-$t171_name")"
    [[ "$t171_rc" == "0" && "$t171_lines" == "2" && "$t171_errlen" == "0" ]] \
        || { t171_ok=0; t171_note="$t171_note [$t171_name:rc=$t171_rc lines=$t171_lines err=$t171_errlen]"; }
    awk "BEGIN{exit !($t171_dt < 2.0)}" || { t171_ok=0; t171_note="$t171_note [$t171_name:dt=$t171_dt]"; }
    printf '%s' "$t171_out" | grep -qF "↑88K ↓61K | R21K" \
        || { t171_ok=0; t171_note="$t171_note [$t171_name:fallback]"; }
done
if [[ $t171_ok -eq 1 ]]; then
    pass T171 "agy non-regular transcript: /dev/zero, FIFO, dir -> fast two-line payload fallback"
else
    fail T171 "$t171_note"
fi

# ============================================================
# T172: 超长单行（>8MiB）（R3-1）——整行跳过、后续行照常聚合、offset==size；
#       输出等于「只有后续正常行」的文件冷扫。
# ============================================================
new_box
python3 - "$BOX/t172.jsonl" "$BOX/t172-ref.jsonl" <<'T172PY'
import json, sys
tail = {"source": "MODEL", "type": "PLANNER_RESPONSE", "created_at": "2026-01-01T00:00:05Z",
        "input_tokens": 7, "output_tokens": 2, "cache_read_tokens": 3}
big = dict(tail)
big.update({"input_tokens": 5, "output_tokens": 1, "cache_read_tokens": 2,
            "content": "x" * (9 * 1024 * 1024)})
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    fh.write(json.dumps(big) + "\n")
    fh.write(json.dumps(tail) + "\n")
with open(sys.argv[2], "w", encoding="utf-8") as fh:
    fh.write(json.dumps(tail) + "\n")
T172PY
t172_p="$(printf '{"cwd":"/tmp","model":{"display_name":"m"},"context_window":{"context_window_size":200000},"transcript_path":"%s"}' "$BOX/t172.jsonl")"
t172_pr="$(printf '{"cwd":"/tmp","model":{"display_name":"m"},"context_window":{"context_window_size":200000},"transcript_path":"%s"}' "$BOX/t172-ref.jsonl")"
t172_a="$(agy_out "$BOX/c172" 120 none "$t172_p")"
t172_b="$(agy_out "$BOX/c172r" 120 none "$t172_pr")"
t172_cf="$(agy_cache_file "$BOX/c172" "$BOX/t172.jsonl")"
t172_off="$(json_field "$t172_cf" 'd.get("offset")')"
t172_size="$(wc -c <"$BOX/t172.jsonl" | tr -d ' ')"
if [[ "$t172_a" == "$t172_b" && "$t172_off" == "$t172_size" ]] \
   && printf '%s' "$t172_a" | grep -qF "↑7 ↓2 | R3"; then
    pass T172 "agy overlong line skipped: later line aggregated, offset==size, output == reference"
else
    fail T172 "off=$t172_off size=$t172_size l2=[${t172_a##*$'\n'}] ref=[${t172_b##*$'\n'}]"
fi

# ============================================================
# T173: 分支名净化（R3-2）——git 分支名里的 RLO 不得原样进入状态栏
# ============================================================
new_box
R173="$BOX/r173"; mkdir -p "$R173"
(cd "$R173" && git -c init.defaultBranch=main init -q && git config user.email t@e.com && git config user.name t \
    && : >f && git add -A && git commit -qm i >/dev/null 2>&1 \
    && git checkout -q -b $'feature‮evil') >/dev/null 2>&1
t173_p="$(printf '{"cwd":"%s","model":{"display_name":"m"}}' "$R173")"
t173_out="$(agy_out "$BOX/c173" 120 none "$t173_p")"
t173_l1="${t173_out%%$'\n'*}"
t173_ok=1; t173_note=""
printf '%s' "$t173_l1" | grep -q $'‮' && { t173_ok=0; t173_note="$t173_note [RLO kept]"; }
printf '%s' "$t173_l1" | grep -qF "featureevil" || { t173_ok=0; t173_note="$t173_note [text]"; }
printf '%s' "$t173_l1" | grep -qF "| agy" || { t173_ok=0; t173_note="$t173_note [badge]"; }
if [[ $t173_ok -eq 1 ]]; then
    pass T173 "agy branch sanitize: RLO stripped from git branch name (featureevil), badge kept"
else
    fail T173 "$t173_note l1=[$t173_l1]"
fi

# ============================================================
# T174: 彩色注入不改着色（R3-3）——移除 fail-safe 后，模型名注入 ESC 仍保留
#       本进程 truecolor 码，且不含注入的裸 SGR；剥色后与 NO_COLOR 逐字相同。
# ============================================================
new_box
t174_p='{"cwd":"/tmp","model":{"display_name":"Gem\u001b[31mevil\u001b[0m","effort":"medium"},"context_window":{}}'
t174_c="$(printf '%s' "$t174_p" | env -u NO_COLOR COLORTERM=truecolor COLUMNS=120 WREN_CACHE_DIR="$BOX/c174c" python3 "$AGY_PAYLOAD" 2>/dev/null)"
t174_n="$(printf '%s' "$t174_p" | env NO_COLOR=1 COLUMNS=120 WREN_CACHE_DIR="$BOX/c174n" python3 "$AGY_PAYLOAD" 2>/dev/null)"
t174_ok=1; t174_note=""
printf '%s' "$t174_c" | grep -qF "38;2;" || { t174_ok=0; t174_note="$t174_note [truecolor]"; }
printf '%s' "$t174_c" | grep -qF $'\x1b[31m' && { t174_ok=0; t174_note="$t174_note [bare-sgr]"; }
[[ "$(printf '%s' "$t174_c" | agy_plain)" == "$t174_n" ]] || { t174_ok=0; t174_note="$t174_note [text]"; }
printf '%s' "$t174_c" | grep -qF "Gemevil" || { t174_ok=0; t174_note="$t174_note [name]"; }
if [[ $t174_ok -eq 1 ]]; then
    pass T174 "agy colour injection: truecolor kept, injected SGR stripped, text == NO_COLOR"
else
    fail T174 "$t174_note"
fi

# ============================================================
# T175: git 超时杀整棵树（R8）——假 git fork 出带标记的孙进程；超时后
#       脚本 rc0/两行/<2.4s，且 1s 内无任何带标记的进程存活。
#       标记必须在真实 argv 里（写成 shell 注释会被剥掉，ps/pgrep 看不到）。
# ============================================================
new_box
t175_tag="wrent175-$$"
t175_bin="$BOX/fakegit-$t175_tag"
mkdir -p "$t175_bin" "$BOX/c175"
cat >"$t175_bin/git" <<EOF2
#!/bin/sh
python3 -c "import time; time.sleep(120)  # $t175_tag"
EOF2
chmod +x "$t175_bin/git"
t175_meta="$(python3 - "$AGY_PAYLOAD" "$t175_bin" "$BOX/c175" <<'T175PY'
import json, os, subprocess, sys, time
script, bin_dir, cache = sys.argv[1], sys.argv[2], sys.argv[3]
env = {k: v for k, v in os.environ.items() if k not in ("COLUMNS", "NO_COLOR")}
env.update({"PATH": bin_dir + ":" + env["PATH"], "NO_COLOR": "1",
            "COLUMNS": "120", "WREN_CACHE_DIR": cache})
t0 = time.monotonic()
r = subprocess.run([sys.executable, script],
                   input=json.dumps({"cwd": "/tmp", "model": {"display_name": "m"}}).encode(),
                   capture_output=True, env=env, timeout=20)
print("%.2f %d %d %d" % (time.monotonic() - t0, r.returncode,
                         r.stdout.rstrip(b"\n").count(b"\n") + 1, len(r.stderr)))
T175PY
)"
read -r t175_dt t175_rc t175_lines t175_errlen <<<"$t175_meta"
t175_left=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
    t175_left="$(pgrep -f "$t175_tag" 2>/dev/null | tr '\n' ' ')"
    [[ -z "$t175_left" ]] && break
    sleep 0.1
done
pkill -9 -f "$t175_tag" 2>/dev/null || true
if [[ "$t175_rc" == "0" && "$t175_lines" == "2" && "$t175_errlen" == "0" && -z "$t175_left" ]] \
   && awk "BEGIN{exit !($t175_dt < 2.4)}"; then
    pass T175 "agy git timeout kills whole tree: ${t175_dt}s, rc0, 2 lines, no survivors"
else
    fail T175 "dt=$t175_dt rc=$t175_rc lines=$t175_lines err=$t175_errlen left=[$t175_left]"
fi

# ============================================================
# T176: 信号打断杀整棵树（R8）——SIGTERM/SIGHUP/SIGINT 各一次：发信号前
#       先确认假 git 进程树活着（否则用例无效），发信号后断言 rc0、stderr 空、
#       恰好两行、无存活进程；结束统一 pkill 清场，不给整套测试留孤儿。
# ============================================================
new_box
t176_tag="wrent176-$$"
t176_bin="$BOX/fakegit-$t176_tag"
mkdir -p "$t176_bin" "$BOX/c176"
cat >"$t176_bin/git" <<EOF2
#!/bin/sh
python3 -c "import time; time.sleep(120)  # $t176_tag"
EOF2
chmod +x "$t176_bin/git"
t176_out="$(T176_SCRIPT="$AGY_PAYLOAD" T176_BIN="$t176_bin" T176_TAG="$t176_tag" T176_CACHE="$BOX/c176" python3 - <<'T176PY'
import json, os, signal, subprocess, sys, time
script = os.environ["T176_SCRIPT"]
bin_dir = os.environ["T176_BIN"]
tag = os.environ["T176_TAG"]
cache = os.environ["T176_CACHE"]
env = {k: v for k, v in os.environ.items() if k not in ("COLUMNS", "NO_COLOR")}
env.update({"PATH": bin_dir + ":" + env["PATH"], "NO_COLOR": "1",
            "COLUMNS": "120", "WREN_CACHE_DIR": cache})
pay = json.dumps({"cwd": "/tmp", "model": {"display_name": "m"}}).encode()

def survivors():
    out = subprocess.run(["ps", "-axo", "pid=,command="], capture_output=True, text=True).stdout
    return [l.strip() for l in out.splitlines() if tag in l]

def sweep():
    subprocess.run(["pkill", "-9", "-f", tag], capture_output=True)
    time.sleep(0.2)

for name in ("SIGTERM", "SIGHUP", "SIGINT"):
    sig = getattr(signal, name)
    p = subprocess.Popen([sys.executable, script], stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                         env=env, start_new_session=True)
    p.stdin.write(pay)
    p.stdin.close()
    # 等到 git 包装脚本与孙进程都出现再发信号（高负载下固定 0.7s 可能不够；
    # 发信号前进程树必须活着，否则用例无效）
    deadline = time.time() + 2.5
    alive = []
    while time.time() < deadline:
        alive = survivors()
        if len(alive) >= 2:
            break
        time.sleep(0.05)
    p.send_signal(sig)
    try:
        out, err = p.communicate(timeout=6)
    except subprocess.TimeoutExpired:
        p.kill()
        out, err = p.communicate()
    time.sleep(0.5)
    left = survivors()
    print("%s %d %d %d %d %d" % (name, len(alive), p.returncode,
                                 out.rstrip(b"\n").count(b"\n") + 1, len(err), len(left)))
    for l in left:
        print("  leaked:", l[:140])
    sweep()
sweep()
T176PY
)"
t176_ok=1; t176_note=""
t176_rows="$(printf '%s\n' "$t176_out" | grep -E '^(SIGTERM|SIGHUP|SIGINT) ')"
while read -r t176_name t176_alive t176_rc t176_lines t176_errlen t176_left; do
    [[ -z "$t176_name" ]] && continue
    if [[ "$t176_alive" -lt 2 || "$t176_rc" != "0" || "$t176_lines" != "2" \
       || "$t176_errlen" != "0" || "$t176_left" != "0" ]]; then
        t176_ok=0
        t176_note="$t176_note [$t176_name alive=$t176_alive rc=$t176_rc lines=$t176_lines err=$t176_errlen left=$t176_left]"
    fi
done <<<"$t176_rows"
t176_seen="$(printf '%s\n' "$t176_rows" | grep -cE '^(SIGTERM|SIGHUP|SIGINT) ')"
pkill -9 -f "$t176_tag" 2>/dev/null || true
if [[ $t176_ok -eq 1 && "$t176_seen" == "3" ]]; then
    pass T176 "agy signals kill whole tree: SIGTERM/SIGHUP/SIGINT -> rc0, 2 lines, no survivors"
else
    fail T176 "seen=$t176_seen$t176_note out=[$(printf '%s' "$t176_out" | tr '\n' '~')]"
fi

# ============================================================
# T177 (R9): 慢启动计入预算——包装脚本先睡 2.6s 再 exec（进程创建时刻早于
# Python 启动），stdin 保持不关、假 git 挂住：从包装启动算 < 4.0s 结束，
# rc0、恰好两行、stderr 空、无孤儿；agy-slow.log 记录 startup >= 2.5。
# （修复前：预算从 main() 起算 + stdin 1.0 + git 1.5+ → 超 5s 被宿主 SIGKILL，零输出。）
# ============================================================
new_box
t177_tag="wrent177-$$"
t177_bin="$BOX/fakegit-$t177_tag"
mkdir -p "$t177_bin" "$BOX/c177"
cat >"$t177_bin/git" <<EOF2
#!/bin/sh
python3 -c "import time; time.sleep(120)  # $t177_tag"
EOF2
chmod +x "$t177_bin/git"
t177_meta="$(T177_SCRIPT="$AGY_PAYLOAD" T177_BIN="$t177_bin" T177_TAG="$t177_tag" T177_CACHE="$BOX/c177" python3 - <<'T177PY'
import json, os, signal, subprocess, sys, threading, time
script, bindir, tag, cache = (os.environ[k] for k in
                              ("T177_SCRIPT", "T177_BIN", "T177_TAG", "T177_CACHE"))
env = dict(os.environ, PATH=bindir + ":" + os.environ["PATH"], NO_COLOR="1",
           COLUMNS="120", WREN_CACHE_DIR=cache)
env.pop("WREN_AGY_HARD_LIMIT", None)
p = subprocess.Popen(["/bin/sh", "-c", "sleep 2.6; exec %s %s" % (sys.executable, script)],
                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                     env=env, start_new_session=True)
t0 = time.monotonic()
host_killed = [False]
def host_kill():
    time.sleep(5.0)          # 模拟宿主：5.0s 从进程创建起算的 SIGKILL
    if p.poll() is None:
        host_killed[0] = True
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except Exception:
            pass
threading.Thread(target=host_kill, daemon=True).start()
out = p.stdout.read()        # stdin 始终不写、不关
err = p.stderr.read()
rc = p.wait()
dt = time.monotonic() - t0
p.stdin.close()
left = []
for _ in range(10):
    left = [l for l in subprocess.run(["ps", "-axo", "pid=,command="], capture_output=True,
                                      text=True).stdout.splitlines() if tag in l]
    if not left:
        break
    time.sleep(0.1)
subprocess.run(["pkill", "-9", "-f", tag], capture_output=True)
startup = -1.0
try:
    rows = [json.loads(x) for x in open(os.path.join(cache, "agy-slow.log")).read().splitlines() if x.strip()]
    startup = max([r.get("startup", -1.0) for r in rows] + [-1.0])
except Exception:
    pass
lines = out.rstrip(b"\n").count(b"\n") + 1 if out else 0
print("%.2f %d %d %d %d %d %.3f" % (dt, rc, lines, len(err), int(host_killed[0]), len(left), startup))
T177PY
)"
read -r t177_dt t177_rc t177_lines t177_errlen t177_hostkill t177_left t177_startup <<<"$t177_meta"
if [[ "$t177_rc" == "0" && "$t177_lines" == "2" && "$t177_errlen" == "0" \
   && "$t177_hostkill" == "0" && "$t177_left" == "0" ]] \
   && awk "BEGIN{exit !($t177_dt < 4.0)}" \
   && awk "BEGIN{exit !($t177_startup >= 2.5)}"; then
    pass T177 "agy slow start counted: ${t177_dt}s from spawn (<4.0), rc0, 2 lines, slow log startup=${t177_startup}s"
else
    fail T177 "dt=$t177_dt rc=$t177_rc lines=$t177_lines err=$t177_errlen hostkill=$t177_hostkill left=$t177_left startup=$t177_startup"
fi

# ============================================================
# T178 (R9/R10c): 看门狗——WREN_AGY_HARD_LIMIT=0.6 + 假 git 挂住（带标记孙进程）：
# ≤1.3s 退出、rc0、恰好两行、无孤儿；agy-slow.log 的 reason=watchdog、phase=git，
# 且 git 阶段耗时已结算（0.3 <= git <= 0.6，抓「看门狗中途触发时 _T 恒为 0」）。
# ============================================================
new_box
t178_tag="wrent178-$$"
t178_bin="$BOX/fakegit-$t178_tag"
mkdir -p "$t178_bin" "$BOX/c178"
cat >"$t178_bin/git" <<EOF2
#!/bin/sh
python3 -c "import time; time.sleep(120)  # $t178_tag"
EOF2
chmod +x "$t178_bin/git"
t178_meta="$(T178_SCRIPT="$AGY_PAYLOAD" T178_BIN="$t178_bin" T178_TAG="$t178_tag" T178_CACHE="$BOX/c178" python3 - <<'T178PY'
import json, os, subprocess, sys, time
script, bindir, tag, cache = (os.environ[k] for k in
                              ("T178_SCRIPT", "T178_BIN", "T178_TAG", "T178_CACHE"))
env = dict(os.environ, PATH=bindir + ":" + os.environ["PATH"], NO_COLOR="1",
           COLUMNS="120", WREN_CACHE_DIR=cache, WREN_AGY_HARD_LIMIT="0.6")
payload = json.dumps({"cwd": "/tmp", "model": {"display_name": "m"}}).encode()
t0 = time.monotonic()
r = subprocess.run([sys.executable, script], input=payload, capture_output=True,
                   env=env, start_new_session=True, timeout=20)
dt = time.monotonic() - t0
left = []
for _ in range(10):
    left = [l for l in subprocess.run(["ps", "-axo", "pid=,command="], capture_output=True,
                                      text=True).stdout.splitlines() if tag in l]
    if not left:
        break
    time.sleep(0.1)
subprocess.run(["pkill", "-9", "-f", tag], capture_output=True)
reason = phase = ""
git_t = -1.0
try:
    rows = [json.loads(x) for x in open(os.path.join(cache, "agy-slow.log")).read().splitlines() if x.strip()]
    for row in reversed(rows):
        if row.get("reason") == "watchdog":
            reason, phase = row.get("reason"), row.get("phase")
            git_t = float(row.get("git", -1.0))
            break
    if not reason and rows:
        reason, phase = rows[-1].get("reason", ""), rows[-1].get("phase", "")
        git_t = float(rows[-1].get("git", -1.0))
except Exception:
    pass
print("%.2f %d %d %d %d %s %s %.3f" % (dt, r.returncode, r.stdout.count(b"\n") + 1, len(r.stderr),
                                        len(left), reason, phase, git_t))
T178PY
)"
read -r t178_dt t178_rc t178_lines t178_errlen t178_left t178_reason t178_phase t178_git <<<"$t178_meta"
if [[ "$t178_rc" == "0" && "$t178_lines" == "2" && "$t178_errlen" == "0" && "$t178_left" == "0" \
   && "$t178_reason" == "watchdog" && "$t178_phase" == "git" ]] \
   && awk "BEGIN{exit !($t178_dt <= 1.3)}" \
   && awk "BEGIN{exit !($t178_git >= 0.3 && $t178_git <= 0.6)}"; then
    pass T178 "agy watchdog: ${t178_dt}s (hard limit 0.6), rc0, 2 lines, reason=watchdog phase=git git=${t178_git}s, no leak"
else
    fail T178 "dt=$t178_dt rc=$t178_rc lines=$t178_lines err=$t178_errlen left=$t178_left reason=$t178_reason phase=$t178_phase git=$t178_git"
fi

# ============================================================
# T179 (R9): 进程创建时刻读得准——sleep 1.2 再 exec → 日志 startup >= 1.2；
# 直接运行时 startup < 0.5；_linux_start_ticks 两段样例（comm 含空格/括号）。
# ============================================================
new_box
t179_a="$(T179_SCRIPT="$AGY_PAYLOAD" T179_CACHE="$BOX/c179" python3 - <<'T179PY'
import json, os, subprocess, sys
script, cache = os.environ["T179_SCRIPT"], os.environ["T179_CACHE"]
env = dict(os.environ, NO_COLOR="1", COLUMNS="120", WREN_CACHE_DIR=cache)
env.pop("WREN_AGY_HARD_LIMIT", None)
r = subprocess.run(["/bin/sh", "-c", "sleep 1.2; exec %s %s" % (sys.executable, script)],
                   input=b'{"cwd":"/tmp"}', capture_output=True, env=env, timeout=20, cwd="/tmp")
startup = -1.0
try:
    rows = [json.loads(x) for x in open(os.path.join(cache, "agy-slow.log")).read().splitlines() if x.strip()]
    startup = max([x.get("startup", -1.0) for x in rows] + [-1.0])
except Exception:
    pass
print("%d %.3f" % (r.returncode, startup))
T179PY
)"
read -r t179_arc t179_astartup <<<"$t179_a"
t179_b="$(python3 - "$AGY_PAYLOAD" <<'T179PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("wren_agy_mod", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
def sample(comm, ticks):
    mid = " ".join(str(i) for i in range(3, 22))   # 字段 3..21，共 19 个
    return ("1234 (%s) %s %d 0" % (comm, mid, ticks)).encode()
print("%.3f %s %s" % (m._STARTUP_S,
                      m._linux_start_ticks(sample("python3", 987654)),
                      m._linux_start_ticks(sample("my (weird) prog", 424242))))
T179PY
)"
read -r t179_bstartup t179_a_ticks t179_b_ticks <<<"$t179_b"
if [[ "$t179_arc" == "0" && "$t179_a_ticks" == "987654" && "$t179_b_ticks" == "424242" ]] \
   && awk "BEGIN{exit !($t179_astartup >= 1.2)}" \
   && awk "BEGIN{exit !($t179_bstartup < 0.5)}"; then
    pass T179 "agy proc-start read: delayed startup=${t179_astartup}s (>=1.2), direct startup=${t179_bstartup}s (<0.5), stat field 22 parsed"
else
    fail T179 "arc=$t179_arc astartup=$t179_astartup bstartup=$t179_bstartup ticks=$t179_a_ticks/$t179_b_ticks"
fi

# ============================================================
# T180 (R9): 信号重入——假 git 挂住时连发 3 次 SIGHUP（间隔 10ms）：
# rc0、恰好两行、stderr 空、无孤儿（第一次处理即屏蔽后续信号）。
# ============================================================
new_box
t180_tag="wrent180-$$"
t180_bin="$BOX/fakegit-$t180_tag"
mkdir -p "$t180_bin" "$BOX/c180"
cat >"$t180_bin/git" <<EOF2
#!/bin/sh
python3 -c "import time; time.sleep(120)  # $t180_tag"
EOF2
chmod +x "$t180_bin/git"
t180_meta="$(T180_SCRIPT="$AGY_PAYLOAD" T180_BIN="$t180_bin" T180_TAG="$t180_tag" T180_CACHE="$BOX/c180" python3 - <<'T180PY'
import json, os, signal, subprocess, sys, time
script, bindir, tag, cache = (os.environ[k] for k in
                              ("T180_SCRIPT", "T180_BIN", "T180_TAG", "T180_CACHE"))
env = dict(os.environ, PATH=bindir + ":" + os.environ["PATH"], NO_COLOR="1",
           COLUMNS="120", WREN_CACHE_DIR=cache)
env.pop("WREN_AGY_HARD_LIMIT", None)
def survivors():
    return [l for l in subprocess.run(["ps", "-axo", "pid=,command="], capture_output=True,
                                      text=True).stdout.splitlines() if tag in l]
p = subprocess.Popen([sys.executable, script], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     stderr=subprocess.PIPE, env=env, start_new_session=True)
p.stdin.write(json.dumps({"cwd": "/tmp", "model": {"display_name": "m"}}).encode())
p.stdin.close()
deadline = time.time() + 2.5
alive = []
while time.time() < deadline:
    alive = survivors()
    if len(alive) >= 2:
        break
    time.sleep(0.05)
for _ in range(3):
    try:
        p.send_signal(signal.SIGHUP)
    except Exception:
        pass
    time.sleep(0.01)
try:
    out, err = p.communicate(timeout=6)
except subprocess.TimeoutExpired:
    p.kill()
    out, err = p.communicate()
left = []
for _ in range(10):
    left = survivors()
    if not left:
        break
    time.sleep(0.1)
subprocess.run(["pkill", "-9", "-f", tag], capture_output=True)
print("%d %d %d %d %d" % (len(alive), p.returncode, out.count(b"\n") + 1, len(err), len(left)))
T180PY
)"
read -r t180_alive t180_rc t180_lines t180_errlen t180_left <<<"$t180_meta"
if [[ "$t180_alive" -ge 2 && "$t180_rc" == "0" && "$t180_lines" == "2" \
   && "$t180_errlen" == "0" && "$t180_left" == "0" ]]; then
    pass T180 "agy repeated SIGHUP x3: rc0, exactly 2 lines, no survivors (reentry blocked)"
else
    fail T180 "alive=$t180_alive rc=$t180_rc lines=$t180_lines err=$t180_errlen left=$t180_left"
fi

# ============================================================
# T181 (R9): 安装器绕开 python3 shim——沙箱 PATH=[假 shim, 好 python3 目录, 原 PATH]。
# 假 shim 留标记；好目录 python3 是指向真解释器的软链。install agy 后 command
# 是片段且指向好目录解释器；sh -c 跑通出两行且 shim 标记不存在；uninstall 摘干净。
# ============================================================
new_box
t181_shim="$BOX/pyshim"
t181_good="$BOX/pygood"
mkdir -p "$t181_shim" "$t181_good"
t181_real="$(python3 -c 'import sys; print(sys.executable)')"
printf '#!/bin/sh\ntouch "%s"\nexec "%s" "$@"\n' "$BOX/shim-used" "$t181_real" >"$t181_shim/python3"
chmod +x "$t181_shim/python3"
ln -s "$t181_real" "$t181_good/python3"
rm -f "$BOX/shim-used"
run_wrenx PATH="$t181_shim:$t181_good:$PATH" -- install agy
t181_rc1="$WREN_EXIT"
t181_cmd="$(json_field "$AGY_SETTINGS" 'd["statusLine"]["command"]')"
rm -f "$BOX/shim-used"
t181_out="$(printf '%s' '{"cwd":"/tmp","model":{"display_name":"m"}}' \
    | env NO_COLOR=1 COLUMNS=120 PATH="$t181_shim:$t181_good:$PATH" WREN_CACHE_DIR="$BOX/c181" \
        sh -c "$t181_cmd" 2>"$BOX/e181")"
t181_rc2=$?
t181_lines="$(agy_lines "$t181_out")"
t181_shim_used=0
[[ -e "$BOX/shim-used" ]] && t181_shim_used=1   # 卸载的 heredoc 会再走 shim，先取证
run_wrenx PATH="$t181_shim:$t181_good:$PATH" -- uninstall agy
t181_rc3="$WREN_EXIT"
t181_ok=1
[[ "$t181_rc1" == "0" && "$t181_rc2" == "0" && "$t181_rc3" == "0" ]] || t181_ok=0
[[ -n "$t181_cmd" && "$t181_cmd" != "$AGY/wren-agy.py" ]] || t181_ok=0
[[ "$t181_cmd" == *"$t181_good/python3"* ]] || t181_ok=0
[[ "$t181_lines" == "2" && ! -s "$BOX/e181" ]] || t181_ok=0
[[ "$t181_shim_used" == "0" ]] || t181_ok=0
[[ "$(json_field "$AGY_SETTINGS" '("statusLine" in d)')" == "False" && ! -e "$AGY/wren-agy.py" ]] || t181_ok=0
if [[ $t181_ok -eq 1 ]]; then
    pass T181 "install agy bypasses python3 shim: fragment -> $t181_good/python3, shim never entered, 2 lines"
else
    fail T181 "rc=$t181_rc1/$t181_rc2/$t181_rc3 cmd=[$t181_cmd] lines=$t181_lines err=[$(cat "$BOX/e181" 2>/dev/null)] shim=$t181_shim_used sl=[$(json_field "$AGY_SETTINGS" 'd.get("statusLine")')]"
fi

# ============================================================
# T182 (R9): 开关与回落——off → 裸路径；不存在的路径 → 警告 + 回落且 exit 0；
# PATH 首位的 shim 之外没有可用候选 → 裸路径 + 提示；旧式裸路径接线能被卸载。
# （「没有可用候选」用 PYTHONHOME 指向不存在目录构造：候选健全性检查必失败，
#   假 shim 自己 unset PYTHONHOME 后 exec 真解释器，安装器本体照常工作。）
# ============================================================
new_box
t182_ok=1; t182_note=""
run_wrenx WREN_AGY_PYTHON=off -- install agy
t182_cmd="$(json_field "$AGY_SETTINGS" 'd["statusLine"]["command"]')"
[[ "$WREN_EXIT" == "0" && "$t182_cmd" == "$AGY/wren-agy.py" ]] || { t182_ok=0; t182_note="$t182_note [off]"; }
run_wrenx WREN_AGY_PYTHON="$BOX/nope/python3" -- install agy
t182_cmd="$(json_field "$AGY_SETTINGS" 'd["statusLine"]["command"]')"
[[ "$WREN_EXIT" == "0" ]] || { t182_ok=0; t182_note="$t182_note [bad:rc=$WREN_EXIT]"; }
printf '%s' "$WREN_ERR" | grep -qF "WREN_AGY_PYTHON" || { t182_ok=0; t182_note="$t182_note [bad:warn]"; }
[[ "$t182_cmd" == "$AGY/wren-agy.py" || "$t182_cmd" == *"python"* ]] || { t182_ok=0; t182_note="$t182_note [bad:cmd=$t182_cmd]"; }
t182_shim="$BOX/pyshim2"
mkdir -p "$t182_shim"
printf '#!/bin/sh\nunset PYTHONHOME\nexec "%s" "$@"\n' "$(python3 -c 'import sys; print(sys.executable)')" >"$t182_shim/python3"
chmod +x "$t182_shim/python3"
run_wrenx PATH="$t182_shim:$PATH" PYTHONHOME=/nonexistent -- install agy
t182_cmd="$(json_field "$AGY_SETTINGS" 'd["statusLine"]["command"]')"
[[ "$WREN_EXIT" == "0" && "$t182_cmd" == "$AGY/wren-agy.py" ]] || { t182_ok=0; t182_note="$t182_note [nocand:rc=$WREN_EXIT cmd=$t182_cmd]"; }
printf '%s' "$WREN_ERR" | grep -qF "绕开" || { t182_ok=0; t182_note="$t182_note [nocand:hint]"; }
# 旧式裸路径接线（payload 已装、command 为裸路径）也能被卸载摘掉
new_box
mkdir -p "$AGY"
cp "$AGY_PAYLOAD" "$AGY/wren-agy.py"
chmod +x "$AGY/wren-agy.py"
printf '{"model":"m","statusLine":{"type":"command","command":"%s/wren-agy.py","enabled":true}}\n' "$AGY" >"$AGY_SETTINGS"
run_wren uninstall agy
[[ "$WREN_EXIT" == "0" ]] || { t182_ok=0; t182_note="$t182_note [old:rc=$WREN_EXIT]"; }
[[ "$(json_field "$AGY_SETTINGS" '("statusLine" in d)')" == "False" && ! -e "$AGY/wren-agy.py" ]] \
    || { t182_ok=0; t182_note="$t182_note [old:sl]"; }
if [[ $t182_ok -eq 1 ]]; then
    pass T182 "agy interpreter switch: off->bare, bad path warns+falls back (exit 0), no candidate->bare+hint, old wiring uninstalls"
else
    fail T182 "$t182_note"
fi

# ============================================================
# T183 (R9): Python 3.9 兼容——/usr/bin/python3（<3.10 时）编译并跑一次最小
# payload；否则 SKIP。compile() 不落 __pycache__，不污染仓库。
# ============================================================
new_box
if [[ -x /usr/bin/python3 ]] && /usr/bin/python3 -c 'import sys; sys.exit(0 if sys.version_info < (3, 10) else 1)' 2>/dev/null; then
    if /usr/bin/python3 -c 'import sys; compile(open(sys.argv[1], encoding="utf-8").read(), sys.argv[1], "exec")' "$AGY_PAYLOAD" \
       && printf '%s' '{"cwd":"/tmp","model":{"display_name":"m"}}' \
          | env NO_COLOR=1 COLUMNS=120 WREN_CACHE_DIR="$BOX/c183" /usr/bin/python3 "$AGY_PAYLOAD" >"$BOX/o183" 2>"$BOX/e183" \
       && [[ "$(agy_lines "$(<"$BOX/o183")")" == "2" && ! -s "$BOX/e183" ]]; then
        pass T183 "python $(/usr/bin/python3 -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])') compiles and renders 2 lines"
    else
        fail T183 "py39 compile/run failed err=[$(cat "$BOX/e183" 2>/dev/null)]"
    fi
else
    skip T183 "no /usr/bin/python3 older than 3.10"
fi

# ============================================================
# T184 (R10): 升级路径——R8 用户的裸路径接线 + 旧 payload + 用户子键，
# 升级安装后应换成片段并保留一切用户数据；卸载对称。
# ============================================================
new_box
t184_shim="$BOX/pyshim"
t184_good="$BOX/pygood"
mkdir -p "$t184_shim" "$t184_good"
t184_real="$(python3 -c 'import sys; print(sys.executable)')"
printf '#!/bin/sh\ntouch "%s"\nexec "%s" "$@"\n' "$BOX/shim-used" "$t184_real" >"$t184_shim/python3"
chmod +x "$t184_shim/python3"
ln -s "$t184_real" "$t184_good/python3"
# R8 现场：旧 payload（与仓库不同）+ 裸路径 command + 用户子键
printf '#!/bin/sh\nexit 0\n' >"$AGY/wren-agy.py"
chmod +x "$AGY/wren-agy.py"
printf '{\n  "model": "m",\n  "statusLine": { "type": "command", "command": "%s/wren-agy.py", "padding": 2, "stack_with_default": true, "enabled": true }\n}\n' "$AGY" >"$AGY_SETTINGS"
cp "$AGY_SETTINGS" "$BOX/before184"
run_wrenx PATH="$t184_shim:$t184_good:$PATH" -- install agy
t184_rc1="$WREN_EXIT"
t184_cmd="$(json_field "$AGY_SETTINGS" 'd["statusLine"]["command"]')"
t184_payload_ok=0
cmp -s "$AGY/wren-agy.py" "$AGY_PAYLOAD" && t184_payload_ok=1
t184_bak_ok=0
[[ -e "$AGY_SETTINGS.wren-bak" ]] && diff -q "$BOX/before184" "$AGY_SETTINGS.wren-bak" >/dev/null && t184_bak_ok=1
t184_pad="$(json_field "$AGY_SETTINGS" 'd["statusLine"].get("padding")')"
t184_stack="$(json_field "$AGY_SETTINGS" 'd["statusLine"].get("stack_with_default")')"
t184_en="$(json_field "$AGY_SETTINGS" 'd["statusLine"].get("enabled")')"
t184_type="$(json_field "$AGY_SETTINGS" 'd["statusLine"].get("type")')"
rm -f "$BOX/shim-used"
t184_out="$(printf '%s' '{"cwd":"/tmp","model":{"display_name":"m"}}' \
    | env NO_COLOR=1 COLUMNS=120 PATH="$t184_shim:$t184_good:$PATH" WREN_CACHE_DIR="$BOX/c184" \
        sh -c "$t184_cmd" 2>"$BOX/e184")"
t184_rc2=$?
t184_shim_used=0
[[ -e "$BOX/shim-used" ]] && t184_shim_used=1
t184_lines="$(agy_lines "$t184_out")"
t184_errlen=0
[[ -s "$BOX/e184" ]] && t184_errlen=1
run_wrenx -- uninstall agy
t184_rc3="$WREN_EXIT"
t184_ok=1
[[ "$t184_rc1" == "0" && "$t184_rc2" == "0" && "$t184_rc3" == "0" ]] || t184_ok=0
[[ -n "$t184_cmd" && "$t184_cmd" != "$AGY/wren-agy.py" && "$t184_cmd" == *"$t184_good/python3"* ]] || t184_ok=0
[[ "$t184_pad" == "2" && "$t184_stack" == "True" && "$t184_en" == "True" && "$t184_type" == "command" ]] || t184_ok=0
[[ "$t184_payload_ok" == "1" && "$t184_bak_ok" == "1" ]] || t184_ok=0
[[ "$t184_lines" == "2" && "$t184_errlen" == "0" && "$t184_shim_used" == "0" ]] || t184_ok=0
[[ "$(json_field "$AGY_SETTINGS" 'd["statusLine"].get("padding")')" == "2" \
   && "$(json_field "$AGY_SETTINGS" 'd["statusLine"].get("stack_with_default")')" == "True" \
   && "$(json_field "$AGY_SETTINGS" 'd["statusLine"].get("enabled")')" == "None" \
   && "$(json_field "$AGY_SETTINGS" 'd["statusLine"].get("type")')" == "None" \
   && "$(json_field "$AGY_SETTINGS" 'd["statusLine"].get("command")')" == "None" ]] || t184_ok=0
[[ ! -e "$AGY/wren-agy.py" && ! -e "$AGY_SETTINGS.wren-bak" ]] || t184_ok=0
if [[ $t184_ok -eq 1 ]]; then
    pass T184 "R8->R9 upgrade: fragment installed, user keys kept, backup == pre-state, old payload replaced, uninstall symmetric"
else
    fail T184 "rc=$t184_rc1/$t184_rc2/$t184_rc3 cmd=[$t184_cmd] lines=$(agy_lines "$t184_out") err=[$(cat "$BOX/e184" 2>/dev/null)] shim=$t184_shim_used payload=$t184_payload_ok bak=$t184_bak_ok sl=[$(json_field "$AGY_SETTINGS" 'd.get("statusLine")')] payload_exists=$([[ -e $AGY/wren-agy.py ]] && echo y || echo n) bak_exists=$([[ -e $AGY_SETTINGS.wren-bak ]] && echo y || echo n)"
fi

# ============================================================
# T185 (R10): 慢日志不得拖住退出——把 agy-slow.log 做成 FIFO（写入点确定阻塞）：
# (a) 看门狗路径（0.6s + 假 git 挂住）≤1.6s；(b) 正常收尾（sleep 1.6 后 exec，
# 真 git 在 /tmp 立刻返回）≤2.6s。两条都 rc0、恰好两行、stderr 空、无孤儿。
# 每条路径自带超时击杀（修复前的版本会卡在 FIFO 上）。
# ============================================================
new_box
t185_tag="wrent185-$$"
t185_bin="$BOX/fakegit-$t185_tag"
mkdir -p "$t185_bin" "$BOX/c185w" "$BOX/c185n"
cat >"$t185_bin/git" <<EOF2
#!/bin/sh
python3 -c "import time; time.sleep(120)  # $t185_tag"
EOF2
chmod +x "$t185_bin/git"
mkfifo "$BOX/c185w/agy-slow.log"
mkfifo "$BOX/c185n/agy-slow.log"
t185_probe() {  # <cache> <watchdog|normal> → "dt rc lines errlen killed survivors"
    T185_SCRIPT="$AGY_PAYLOAD" T185_CACHE="$1" T185_KIND="$2" T185_TAG="$t185_tag" T185_BIN="$t185_bin" \
    python3 - <<'T185PY'
import fcntl, json, os, signal, subprocess, sys, time
script, cache, kind, tag, bindir = (os.environ[k] for k in
                                   ("T185_SCRIPT", "T185_CACHE", "T185_KIND", "T185_TAG", "T185_BIN"))
env = dict(os.environ, NO_COLOR="1", COLUMNS="120", WREN_CACHE_DIR=cache)
env.pop("WREN_AGY_HARD_LIMIT", None)
if kind == "watchdog":
    env["PATH"] = bindir + ":" + os.environ["PATH"]
    env["WREN_AGY_HARD_LIMIT"] = "0.6"
    argv, limit = [sys.executable, script], 3.0
else:
    argv, limit = ["/bin/sh", "-c", "sleep 1.6; exec %s %s" % (sys.executable, script)], 4.0
p = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                     env=env, start_new_session=True)
t0 = time.monotonic()
out = b""
killed = False
try:
    p.stdin.write(json.dumps({"cwd": "/tmp", "model": {"display_name": "m"}}).encode())
    p.stdin.flush()
    p.stdin.close()
    fd = p.stdout.fileno()
    fl = fcntl.fcntl(fd, fcntl.F_GETFL)
    fcntl.fcntl(fd, fcntl.F_SETFL, fl | os.O_NONBLOCK)
    while time.monotonic() - t0 < limit:
        try:
            chunk = p.stdout.read()
            if chunk:
                out += chunk
        except BlockingIOError:
            pass
        if p.poll() is not None:
            break
        time.sleep(0.02)
    if p.poll() is None:
        killed = True
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except OSError:
            pass
    p.wait()
    try:
        tail = p.stdout.read()
        if tail:
            out += tail
    except Exception:
        pass
    err = p.stderr.read()
finally:
    for fh in (p.stdin, p.stdout, p.stderr):
        try:
            fh.close()
        except Exception:
            pass
dt = time.monotonic() - t0
lines = out.rstrip(b"\n").count(b"\n") + 1 if out else 0
after = []
for _ in range(10):
    after = [l for l in subprocess.run(["ps", "-axo", "pid=,command="], capture_output=True,
                                       text=True).stdout.splitlines() if tag in l]
    if not after:
        break
    time.sleep(0.1)
subprocess.run(["pkill", "-9", "-f", tag], capture_output=True)
print("%.2f %d %d %d %d %d" % (dt, p.returncode, lines, len(err), int(killed), len(after)))
T185PY
}
read -r t185_wdt t185_wrc t185_wlines t185_werr t185_wkill t185_wleft <<<"$(t185_probe "$BOX/c185w" watchdog)"
read -r t185_ndt t185_nrc t185_nlines t185_nerr t185_nkill t185_nleft <<<"$(t185_probe "$BOX/c185n" normal)"
if [[ "$t185_wrc" == "0" && "$t185_wlines" == "2" && "$t185_werr" == "0" \
   && "$t185_wkill" == "0" && "$t185_wleft" == "0" \
   && "$t185_nrc" == "0" && "$t185_nlines" == "2" && "$t185_nerr" == "0" \
   && "$t185_nkill" == "0" && "$t185_nleft" == "0" ]] \
   && awk "BEGIN{exit !($t185_wdt <= 1.6)}" \
   && awk "BEGIN{exit !($t185_ndt <= 2.6)}"; then
    pass T185 "slow log never blocks exit: FIFO watchdog ${t185_wdt}s, normal ${t185_ndt}s; rc0/2 lines/no leak"
else
    fail T185 "watchdog dt=$t185_wdt rc=$t185_wrc lines=$t185_wlines err=$t185_werr kill=$t185_wkill left=$t185_wleft | normal dt=$t185_ndt rc=$t185_nrc lines=$t185_nlines err=$t185_nerr kill=$t185_nkill left=$t185_nleft"
fi

# ============================================================
# T186 (R10): 慢日志原子 + 轮转——种子 40 行 → 一个慢帧后恰好 40 行、逐行合法、
# 首行 n==1、末行 reason=watchdog；再并发 8 个慢帧：仍逐行合法、≤40 行、
# 目录无 agy-slow.log.*.tmp 残留。
# ============================================================
new_box
t186_tag="wrent186-$$"
t186_bin="$BOX/fakegit-$t186_tag"
t186_cache="$BOX/c186"
mkdir -p "$t186_bin" "$t186_cache"
cat >"$t186_bin/git" <<EOF2
#!/bin/sh
python3 -c "import time; time.sleep(120)  # $t186_tag"
EOF2
chmod +x "$t186_bin/git"
python3 - "$t186_cache/agy-slow.log" <<'T186SEED'
import json, sys
with open(sys.argv[1], "w") as fh:
    for i in range(40):
        fh.write(json.dumps({"reason": "seed", "n": i}) + "\n")
T186SEED
t186_out="$(T186_SCRIPT="$AGY_PAYLOAD" T186_CACHE="$t186_cache" T186_BIN="$t186_bin" T186_TAG="$t186_tag" python3 - <<'T186PY'
import json, os, subprocess, sys, time
script, cache, bindir, tag = (os.environ[k] for k in
                              ("T186_SCRIPT", "T186_CACHE", "T186_BIN", "T186_TAG"))
env = dict(os.environ, PATH=bindir + ":" + os.environ["PATH"], NO_COLOR="1",
           COLUMNS="120", WREN_CACHE_DIR=cache, WREN_AGY_HARD_LIMIT="0.6")
payload = json.dumps({"cwd": "/tmp", "model": {"display_name": "m"}}).encode()
log = os.path.join(cache, "agy-slow.log")
r = subprocess.run([sys.executable, script], input=payload, capture_output=True,
                   env=env, start_new_session=True, timeout=10)
ok1 = r.returncode == 0 and r.stdout.count(b"\n") == 1 and not r.stderr
rows = []
try:
    rows = [json.loads(x) for x in open(log).read().splitlines() if x.strip()]
except Exception:
    pass
ok2 = (len(rows) == 40 and rows and rows[0].get("n") == 1
       and rows[-1].get("reason") == "watchdog")
procs = []
for _ in range(8):
    procs.append(subprocess.Popen([sys.executable, script], stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env,
                                  start_new_session=True))
for p in procs:
    p.stdin.write(payload)
    p.stdin.close()
rcs = []
for p in procs:
    try:
        out, err = p.communicate(timeout=10)
    except subprocess.TimeoutExpired:
        p.kill()
        out, err = p.communicate()
    rcs.append((p.returncode, out.count(b"\n") + 1 if out else 0, len(err)))
conc_ok = len(rcs) == 8 and all(rc == 0 and n == 2 and e == 0 for rc, n, e in rcs)
raw = [x for x in open(log).read().splitlines() if x.strip()]
valid = True
for x in raw:
    try:
        json.loads(x)
    except Exception:
        valid = False
tmp = [f for f in os.listdir(cache) if f.startswith("agy-slow.log.") and f.endswith(".tmp")]
print("%d %d %d %d %d %d %d" % (int(ok1), int(ok2), len(rows), len(raw), int(valid), len(tmp), int(conc_ok)))
print("concurrent:", rcs)
subprocess.run(["pkill", "-9", "-f", tag], capture_output=True)
T186PY
)"
t186_first="$(printf '%s\n' "$t186_out" | head -1)"
t186_conc="$(printf '%s\n' "$t186_out" | tail -1)"
read -r t186_ok1 t186_ok2 t186_rows t186_raw t186_valid t186_tmp t186_concok <<<"$t186_first"
if [[ "$t186_ok1" == "1" && "$t186_ok2" == "1" && "$t186_rows" == "40" \
   && "$t186_raw" -ge 1 && "$t186_raw" -le 40 && "$t186_valid" == "1" && "$t186_tmp" == "0" \
   && "$t186_concok" == "1" ]]; then
    pass T186 "slow log atomic+rotate: seed40 -> 40 lines (n=1..39+watchdog), 8 concurrent rc0/2 lines, valid JSON, no tmp"
else
    fail T186 "ok1=$t186_ok1 ok2=$t186_ok2 rows=$t186_rows raw=$t186_raw valid=$t186_valid tmp=$t186_tmp conc=$t186_concok $t186_conc"
fi

# ============================================================
# T187 (R10): 进程年龄合理性——_sane_since 表驱动：0.0/0.05/3.5/59.9 原样；
# 60.1/-0.1/7200/nan/inf/None → None；STARTUP_MAX_S == 60.0。
# ============================================================
new_box
if python3 - "$AGY_PAYLOAD" <<'T187PY'
import importlib.util, math, sys
spec = importlib.util.spec_from_file_location("wren_agy_mod", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
assert m.STARTUP_MAX_S == 60.0, m.STARTUP_MAX_S
for v in (0.0, 0.05, 3.5, 59.9):
    assert m._sane_since(v) == v, (v, m._sane_since(v))
for v in (60.1, -0.1, 7200, float("nan"), float("inf"), None):
    assert m._sane_since(v) is None, (v, m._sane_since(v))
T187PY
then
    pass T187 "process age sanity: 0..59.9 kept, 60.1/-0.1/7200/nan/inf/None -> None"
else
    fail T187 "sane_since table mismatch"
fi

# ============================================================
# T188 (R11): git 子进程自带到期时间——宿主只 SIGKILL wren 本体、不杀进程组时，
# 正在跑的单进程假 git 必须在 ≤3.5s 内自己消失（alarm 跨 exec 保留）；
# 后半：慢但成功的 git（sleep 0.3 后输出分支名，余量 1.2s）不被兜底 alarm 误杀。
# ============================================================
new_box
t188_tag="wrent188-$$"
t188_bin="$BOX/fakegit-$t188_tag"
t188_slow="$BOX/fakegit-slow-$t188_tag"
mkdir -p "$t188_bin" "$t188_slow" "$BOX/notgit" "$BOX/c188a" "$BOX/c188b"
printf '#!/usr/bin/env python3\nwhile True:\n    pass\n' >"$t188_bin/git"
chmod +x "$t188_bin/git"
printf '#!/bin/sh\nsleep 0.3\necho "# branch.head main"\n' >"$t188_slow/git"
chmod +x "$t188_slow/git"
t188_out="$(T188_SCRIPT="$AGY_PAYLOAD" T188_BIN="$t188_bin" T188_SLOW="$t188_slow" T188_TAG="$t188_tag" \
    T188_CWD="$BOX/notgit" T188_CACHE_A="$BOX/c188a" T188_CACHE_B="$BOX/c188b" python3 - <<'T188PY'
import json, os, signal, subprocess, sys, time
script, bindir, slowdir, tag, cwd, cache_a, cache_b = (os.environ[k] for k in
    ("T188_SCRIPT", "T188_BIN", "T188_SLOW", "T188_TAG", "T188_CWD", "T188_CACHE_A", "T188_CACHE_B"))
base_env = dict(os.environ, NO_COLOR="1", COLUMNS="120")
base_env.pop("WREN_AGY_HARD_LIMIT", None)
payload = json.dumps({"cwd": cwd, "model": {"display_name": "m"}}).encode()

def git_pids():
    out = subprocess.run(["ps", "-axww", "-o", "pid=,command="], capture_output=True, text=True).stdout
    return [int(l.split(None, 1)[0]) for l in out.splitlines() if tag in l and "/git " in l and "ps -axww" not in l]

# 前半：SIGKILL wren 本体后，挂住的单进程假 git 自己到点消失
env = dict(base_env, PATH=bindir + ":" + os.environ["PATH"], WREN_CACHE_DIR=cache_a)
p = subprocess.Popen([sys.executable, script], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     stderr=subprocess.PIPE, env=env, start_new_session=True)
p.stdin.write(payload)
p.stdin.flush()
p.stdin.close()
deadline = time.time() + 4.0
while time.time() < deadline and not git_pids() and p.poll() is None:
    time.sleep(0.02)
time.sleep(0.15)
before = git_pids()
os.kill(p.pid, signal.SIGKILL)          # 宿主顶替：只杀 wren 本体，不杀进程组
p.wait()
t0 = time.time()
gone = None
while time.time() - t0 < 4.0:           # 测试只观察，不替它收尾
    if not git_pids():
        gone = time.time() - t0
        break
    time.sleep(0.05)
left = git_pids()
for pid in left:
    try:
        os.kill(pid, signal.SIGKILL)
    except OSError:
        pass
for fh in (p.stdin, p.stdout, p.stderr):
    try:
        fh.close()
    except Exception:
        pass

# 后半：慢但成功的 git（0.3s < 2s alarm）不被误杀
env_b = dict(base_env, PATH=slowdir + ":" + os.environ["PATH"], WREN_CACHE_DIR=cache_b)
t0 = time.time()
rb = subprocess.run([sys.executable, script], input=payload, capture_output=True,
                    env=env_b, start_new_session=True, timeout=10)
dtb = time.time() - t0
l2 = rb.stdout.decode("utf-8", "replace").rstrip("\n").split("\n")
l1 = l2[0] if l2 else ""
print("A %d %s %d" % (len(before), ("%.2f" % gone) if gone is not None else "none", len(left)))
print("B %.2f %d %d %d %d" % (dtb, rb.returncode, len(l2), int("main" in l1), len(rb.stderr)))
subprocess.run(["pkill", "-9", "-f", tag], capture_output=True)
T188PY
)"
t188_a="$(printf '%s\n' "$t188_out" | head -1)"
t188_b="$(printf '%s\n' "$t188_out" | tail -1)"
read -r _ t188_before t188_gone t188_left <<<"$t188_a"
read -r _ t188_bdt t188_brc t188_blines t188_bmain t188_berr <<<"$t188_b"
pkill -9 -f "$t188_tag" 2>/dev/null || true
if [[ "$t188_before" -ge 1 && "$t188_gone" != "none" && "$t188_left" == "0" ]] \
   && awk "BEGIN{exit !($t188_gone > 0 && $t188_gone <= 3.5)}" \
   && [[ "$t188_brc" == "0" && "$t188_blines" == "2" && "$t188_bmain" == "1" && "$t188_berr" == "0" ]] \
   && awk "BEGIN{exit !($t188_bdt < 2.5)}"; then
    pass T188 "git self-expires: orphan gone in ${t188_gone}s after wren SIGKILL, no leak; slow 0.3s git still renders main in ${t188_bdt}s"
else
    fail T188 "A: before=$t188_before gone=$t188_gone left=$t188_left | B: dt=$t188_bdt rc=$t188_brc lines=$t188_blines main=$t188_bmain err=$t188_berr"
fi

# ============================================================
# T189 (R12/R12b): 静态守卫——shebang 含 sh 的脚本里两条规则：
# 1) `$变量名` 后面不得紧跟非 ASCII 字节（bash 3.2 在 UTF-8 locale 下会把后续
#    字节并进变量名，set -u 下直接中止）；
# 2) `$'…'` 里不得出现反斜杠-u 四 hex 转义（bash 3.2 在整段脚本的上下文里不解释）。
# 不依赖 git ls-files（无 .git 的副本也能跑），排除 .git 目录。
# ============================================================
new_box
t189_out="$(python3 - "$REPO_ROOT" <<'T189PY'
import os, re, sys
root = sys.argv[1]
pat1 = re.compile(rb'\$[A-Za-z_][A-Za-z0-9_]*[\x80-\xff]')
pat2 = re.compile(rb"\$'[^']*\\u[0-9a-fA-F]{4}")
hits = []
for dirpath, dirnames, filenames in os.walk(root):
    dirnames[:] = [d for d in dirnames if d != ".git"]
    for fn in filenames:
        p = os.path.join(dirpath, fn)
        try:
            with open(p, "rb") as fh:
                data = fh.read()
        except OSError:
            continue
        first = data.split(b"\n", 1)[0]
        if not first.startswith(b"#!") or b"sh" not in first:
            continue
        for i, line in enumerate(data.splitlines(), 1):
            for rule, pat in (("1:var+nonascii", pat1), ("2:unicode-escape", pat2)):
                for m in pat.finditer(line):
                    snippet = line[max(0, m.start() - 24):m.end() + 8].decode("utf-8", "replace")
                    hits.append("%s:%d [%s]: %s" % (os.path.relpath(p, root), i, rule, snippet))
print(len(hits))
for h in hits[:20]:
    print(h)
T189PY
)"
t189_n="$(printf '%s\n' "$t189_out" | head -1)"
t189_list="$(printf '%s\n' "$t189_out" | tail -n +2)"
if [[ "$t189_n" == "0" ]]; then
    pass T189 "bash 3.2 static guard: no var+nonascii, no unicode-escape inside dollar-quotes in sh scripts"
else
    fail T189 "$t189_n hit(s): $(printf '%s' "$t189_list" | tr '\n' '~')"
fi

# ============================================================
# T190 (R12): 用系统 /bin/bash（macOS 3.2）实跑 `install agy`，UTF-8 locale +
# PATH 首位是留标记的假 shim：rc0，提示必须完整（不被变量名吞并截断），
# statusLine.command 是片段。bash 5.x 上同样应通过。
# ============================================================
new_box
if [[ -x /bin/bash ]]; then
    t190_shim="$BOX/pyshim"
    t190_good="$BOX/pygood"
    mkdir -p "$t190_shim" "$t190_good"
    t190_real="$(python3 -c 'import sys; print(sys.executable)')"
    printf '#!/bin/sh\nexec "%s" "$@"\n' "$t190_real" >"$t190_shim/python3"
    chmod +x "$t190_shim/python3"
    ln -s "$t190_real" "$t190_good/python3"
    run_limited "$CMD_TIMEOUT" env NO_COLOR=1 LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 \
        PREFIX="$BIN" PI_EXT_DIR="$PIEXT" \
        CLAUDE_CONFIG_DIR="$CLAUDE" CLAUDE_SETTINGS="$SETTINGS" \
        QODER_CONFIG_DIR="$QODER" QODER_SETTINGS="$QODER_SETTINGS" \
        AGY_CONFIG_DIR="$AGY" AGY_SETTINGS="$AGY_SETTINGS" \
        OPENCODE_CONFIG_DIR="$OC" OPENCODE_TUI_CONFIG="$OCCONF" \
        PATH="$t190_shim:$t190_good:$PATH" \
        /bin/bash "$WREN" install agy >"$BOX/out190.txt" 2>"$BOX/err190.txt"
    t190_rc=$?
    t190_out="$(<"$BOX/out190.txt")"
    t190_err="$(<"$BOX/err190.txt")"
    t190_cmd="$(json_field "$AGY_SETTINGS" 'd["statusLine"]["command"]')"
    t190_want="python3 是 shim（$t190_shim/python3）；状态栏改用 $t190_good/python3"
    t190_ok=1
    [[ "$t190_rc" == "0" ]] || t190_ok=0
    printf '%s' "$t190_out" | grep -qF "$t190_want" || t190_ok=0
    [[ -n "$t190_cmd" && "$t190_cmd" == *"$t190_good/python3"* ]] || t190_ok=0
    if [[ $t190_ok -eq 1 ]]; then
        pass T190 "/bin/bash ($(/bin/bash -c 'echo $BASH_VERSION' 2>/dev/null)) + UTF-8: full shim notice, fragment written"
    else
        fail T190 "rc=$t190_rc err=[$t190_err] out=[$t190_out] cmd=[$t190_cmd]"
    fi
else
    skip T190 "/bin/bash not executable"
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
