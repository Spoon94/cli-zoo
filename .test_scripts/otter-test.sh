#!/usr/bin/env bash
# otter-test.sh - 自动运行 .test_task/otter-test.md 中的 25 个用例。
#
# 用法: bash .test_scripts/otter-test.sh
# 写出: .test_res/otter-test-res.md

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OTTER="$REPO_ROOT/zoo-scripts/otter"
INSTALL_SH="$REPO_ROOT/cli-zoo-install.sh"
UNINSTALL_SH="$REPO_ROOT/cli-zoo-uninstall.sh"
RES_DIR="$REPO_ROOT/.test_res"
RES_FILE="$RES_DIR/otter-test-res.md"

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

assert_eq() {
    local id="$1" expected="$2" actual="$3" desc="${4:-}"
    if [[ "$expected" == "$actual" ]]; then
        pass "$id" "$desc"
    else
        fail "$id" "$desc | expected=[$expected] actual=[$actual]"
    fi
}

assert_contains() {
    local id="$1" needle="$2" haystack="$3" desc="${4:-}"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        pass "$id" "$desc"
    else
        fail "$id" "$desc | needle=[$needle] not found in: $haystack"
    fi
}

# ---------- session 清场 ----------
cleanup_sessions() {
    for s in "$@"; do
        tmux kill-session -t "=$s" 2>/dev/null || true
    done
}

cleanup_all() {
    cleanup_sessions otter_test_A otter_test_B otter_test_C otter_test_D otter_test_E otter_test_F otter_test_yazi otter_demo_dir
}

trap cleanup_all EXIT

# ---------- 前置依赖检查 ----------
if ! command -v tmux >/dev/null 2>&1; then
    echo "ERROR: tmux is required to run this test suite" >&2
    exit 2
fi

if [[ ! -x "$OTTER" ]]; then
    chmod +x "$OTTER"
fi

# 工具实际位置
REAL_TMUX="$(command -v tmux)"

HAS_NVIM=0
HAS_LAZYGIT=0
HAS_YAZI=0
HAS_CLAUDE=0
command -v nvim    >/dev/null 2>&1 && HAS_NVIM=1
command -v lazygit >/dev/null 2>&1 && HAS_LAZYGIT=1
command -v yazi    >/dev/null 2>&1 && HAS_YAZI=1
command -v claude  >/dev/null 2>&1 && HAS_CLAUDE=1

if [[ $HAS_CLAUDE -ne 1 ]]; then
    echo "ERROR: claude command not found in PATH; T06+ require it" >&2
    exit 2
fi

# 是否在 git 仓库
IN_GIT=0
git -C "$REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 && IN_GIT=1

cleanup_all

# ============================================================
# T01: otter 无参数 → exit 2 + usage
# ============================================================
out=$("$OTTER" 2>&1 >/dev/null; printf 'EXIT:%s' "$?")
exit_code="${out##*EXIT:}"
stderr_out="${out%EXIT:*}"
if [[ "$exit_code" == "2" ]] && printf '%s' "$stderr_out" | grep -qi "usage"; then
    pass T01 "no args -> exit 2 + usage"
else
    fail T01 "exit=$exit_code stderr=[$stderr_out]"
fi

# ============================================================
# T02: otter -h → exit 0 + 帮助
# ============================================================
out=$("$OTTER" -h 2>&1; printf 'EXIT:%s' "$?")
exit_code="${out##*EXIT:}"
body="${out%EXIT:*}"
if [[ "$exit_code" == "0" ]] && printf '%s' "$body" | grep -qi "usage"; then
    pass T02 "-h prints help"
else
    fail T02 "exit=$exit_code body=[$body]"
fi

# ============================================================
# T03: -c claude -ks foo → exit 2 + 互斥
# ============================================================
out=$("$OTTER" -c claude -ks foo 2>&1 >/dev/null; printf 'EXIT:%s' "$?")
exit_code="${out##*EXIT:}"
stderr_out="${out%EXIT:*}"
if [[ "$exit_code" == "2" ]] && printf '%s' "$stderr_out" | grep -qi "mutually exclusive"; then
    pass T03 "-c + -ks -> exit 2"
else
    fail T03 "exit=$exit_code stderr=[$stderr_out]"
fi

# ============================================================
# T04: -c notexist → exit 2 + 不在白名单
# ============================================================
out=$("$OTTER" -c notexist 2>&1 >/dev/null; printf 'EXIT:%s' "$?")
exit_code="${out##*EXIT:}"
stderr_out="${out%EXIT:*}"
if [[ "$exit_code" == "2" ]] && printf '%s' "$stderr_out" | grep -qi "ALLOWED_TOOLS"; then
    pass T04 "non-whitelist -> exit 2"
else
    fail T04 "exit=$exit_code stderr=[$stderr_out]"
fi

# ============================================================
# T05: source 后 sanitize_session
# ============================================================
out=$(bash -c "source \"$OTTER\"; sanitize_session 'a.b c:d[x]'")
expected="a_b_c_d_x_"
assert_eq T05 "$expected" "$out" "sanitize"

# ============================================================
# T06: 启动 session A，window claude 含 3 pane
# ============================================================
SESSION_A="otter_test_A"
cleanup_sessions "$SESSION_A"
OTTER_NO_ATTACH=1 "$OTTER" -c claude -s "$SESSION_A" >/dev/null 2>&1
rc=$?
if [[ $rc -ne 0 ]]; then
    fail T06 "otter exit=$rc"
elif ! tmux has-session -t "=$SESSION_A" 2>/dev/null; then
    fail T06 "session $SESSION_A not created"
else
    pane_count=$(tmux list-panes -t "=$SESSION_A:claude" 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$pane_count" == "3" ]]; then
        pass T06 "session+window with 3 panes"
    else
        fail T06 "pane_count=$pane_count (expected 3)"
    fi
fi

# ============================================================
# T07: 等 0.5s 后左 pane 当前命令含 claude
# ============================================================
if tmux has-session -t "=$SESSION_A" 2>/dev/null; then
    sleep 0.8
    first_cmd=$(tmux list-panes -t "=$SESSION_A:claude" -F '#{pane_index} #{pane_current_command}' 2>/dev/null | sort -n | head -1 | awk '{print $2}')
    # node/claude 启动后 pane_current_command 可能是 node、claude、bash(等待) 等
    if printf '%s' "$first_cmd" | grep -qiE 'claude|node'; then
        pass T07 "left pane runs claude/node ($first_cmd)"
    else
        # 视为软失败：claude 实际可能立即 exit / fork 子进程；保守处理
        fail T07 "left pane current_command=[$first_cmd]"
    fi
else
    fail T07 "session $SESSION_A missing"
fi

# ============================================================
# T08: nvim window 存在（条件）
# ============================================================
if [[ $HAS_NVIM -ne 1 ]]; then
    skip T08 "nvim not installed"
elif ! tmux has-session -t "=$SESSION_A" 2>/dev/null; then
    fail T08 "session $SESSION_A missing"
else
    if tmux list-windows -t "=$SESSION_A" -F '#{window_name}' 2>/dev/null | grep -qx "nvim"; then
        pass T08 "nvim window present"
    else
        fail T08 "nvim window missing"
    fi
fi

# ============================================================
# T09: lazygit window 存在（条件: lazygit + git repo）
# ============================================================
if [[ $HAS_LAZYGIT -ne 1 ]]; then
    skip T09 "lazygit not installed"
elif [[ $IN_GIT -ne 1 ]]; then
    skip T09 "not in a git repo"
elif ! tmux has-session -t "=$SESSION_A" 2>/dev/null; then
    fail T09 "session $SESSION_A missing"
else
    if tmux list-windows -t "=$SESSION_A" -F '#{window_name}' 2>/dev/null | grep -qx "lazygit"; then
        pass T09 "lazygit window present"
    else
        fail T09 "lazygit window missing"
    fi
fi

# ============================================================
# T10: 在临时非 git 目录下运行，无 lazygit window
# ============================================================
TMP_NONGIT="$(mktemp -d 2>/dev/null || mktemp -d -t otter)"
SESSION_B="otter_test_B"
cleanup_sessions "$SESSION_B"
(
    cd "$TMP_NONGIT" || exit 1
    OTTER_NO_ATTACH=1 "$OTTER" -c claude -s "$SESSION_B" >/dev/null 2>&1
)
rc=$?
if [[ $rc -ne 0 ]] || ! tmux has-session -t "=$SESSION_B" 2>/dev/null; then
    fail T10 "session not created (rc=$rc)"
else
    if tmux list-windows -t "=$SESSION_B" -F '#{window_name}' 2>/dev/null | grep -qx "lazygit"; then
        fail T10 "lazygit window unexpectedly present"
    else
        pass T10 "no lazygit window in non-git dir"
    fi
fi
cleanup_sessions "$SESSION_B"
rm -rf "$TMP_NONGIT"

# ============================================================
# T11: 复用同名 session+window，window 数不变
# ============================================================
if ! tmux has-session -t "=$SESSION_A" 2>/dev/null; then
    fail T11 "T06 session missing"
else
    before=$(tmux list-windows -t "=$SESSION_A" 2>/dev/null | wc -l | tr -d ' ')
    OTTER_NO_ATTACH=1 "$OTTER" -c claude -s "$SESSION_A" >/dev/null 2>&1
    after=$(tmux list-windows -t "=$SESSION_A" 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$before" == "$after" ]]; then
        pass T11 "window count stable ($before)"
    else
        fail T11 "window count before=$before after=$after"
    fi
fi

# ============================================================
# T12: 删除 claude window 后再次 otter，重建 3-pane claude window
# ============================================================
if ! tmux has-session -t "=$SESSION_A" 2>/dev/null; then
    fail T12 "T06 session missing"
else
    tmux kill-window -t "=$SESSION_A:claude" 2>/dev/null || true
    OTTER_NO_ATTACH=1 "$OTTER" -c claude -s "$SESSION_A" >/dev/null 2>&1
    if tmux list-windows -t "=$SESSION_A" -F '#{window_name}' 2>/dev/null | grep -qx "claude"; then
        pane_count=$(tmux list-panes -t "=$SESSION_A:claude" 2>/dev/null | wc -l | tr -d ' ')
        if [[ "$pane_count" == "3" ]]; then
            pass T12 "claude window rebuilt with 3 panes"
        else
            fail T12 "rebuilt window has $pane_count panes (expected 3)"
        fi
    else
        fail T12 "claude window not rebuilt"
    fi
fi

# ============================================================
# T13: -ks 删除存在的 session，exit 0
# ============================================================
if ! tmux has-session -t "=$SESSION_A" 2>/dev/null; then
    # 重建以保证测试可执行
    OTTER_NO_ATTACH=1 "$OTTER" -c claude -s "$SESSION_A" >/dev/null 2>&1
fi
"$OTTER" -ks "$SESSION_A" >/dev/null 2>&1
rc=$?
if [[ $rc -eq 0 ]] && ! tmux has-session -t "=$SESSION_A" 2>/dev/null; then
    pass T13 "session killed, exit 0"
else
    fail T13 "exit=$rc still_exists=$(tmux has-session -t "=$SESSION_A" 2>/dev/null && echo yes || echo no)"
fi

# ============================================================
# T14: -ks 不存在的 session → exit 0 + stderr not found
# ============================================================
out=$("$OTTER" -ks otter_test_notexist 2>&1 >/dev/null; printf 'EXIT:%s' "$?")
exit_code="${out##*EXIT:}"
stderr_out="${out%EXIT:*}"
if [[ "$exit_code" == "0" ]] && printf '%s' "$stderr_out" | grep -qi "not found"; then
    pass T14 "ks nonexistent -> exit 0 + not found"
else
    fail T14 "exit=$exit_code stderr=[$stderr_out]"
fi

# ============================================================
# T15: PREFIX install
# ============================================================
INSTALL_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t otterp)"
if [[ ! -w "$INSTALL_DIR" ]]; then
    skip T15 "tmpdir not writable"
    skip T16 "tmpdir not writable"
    skip T17 "tmpdir not writable"
    skip T18 "tmpdir not writable"
else
    PREFIX="$INSTALL_DIR" "$INSTALL_SH" otter >/dev/null 2>&1
    rc=$?
    target="$INSTALL_DIR/otter"
    if [[ $rc -eq 0 && -L "$target" ]]; then
        link_dest="$(readlink "$target")"
        if [[ "$link_dest" == "$OTTER" ]]; then
            pass T15 "install symlink ok"
        else
            fail T15 "link dest=[$link_dest] expected=[$OTTER]"
        fi
    else
        fail T15 "install rc=$rc target_exists=$([[ -e $target ]] && echo yes || echo no)"
    fi

    # T16: 再次安装 → 替换
    PREFIX="$INSTALL_DIR" "$INSTALL_SH" otter >/dev/null 2>&1
    rc=$?
    if [[ $rc -eq 0 && -L "$target" && "$(readlink "$target")" == "$OTTER" ]]; then
        pass T16 "reinstall replaces link"
    else
        fail T16 "reinstall rc=$rc"
    fi

    # T17: uninstall
    PREFIX="$INSTALL_DIR" "$UNINSTALL_SH" otter >/dev/null 2>&1
    rc=$?
    if [[ $rc -eq 0 && ! -e "$target" && ! -L "$target" ]]; then
        pass T17 "uninstall removes link"
    else
        fail T17 "uninstall rc=$rc still_exists=$([[ -e $target || -L $target ]] && echo yes || echo no)"
    fi

    # T18: 再次卸载
    PREFIX="$INSTALL_DIR" "$UNINSTALL_SH" otter >/dev/null 2>&1
    rc=$?
    if [[ $rc -eq 0 ]]; then
        pass T18 "uninstall idempotent"
    else
        fail T18 "uninstall rc=$rc"
    fi
    rm -rf "$INSTALL_DIR"
fi

# ============================================================
# T19: claude 缺失 → exit 3
# ============================================================
# tmux 和 claude 都在 /usr/local/bin，所以仅把 tmux 软链到新目录，从而模拟 claude 缺失
T19_BIN="$(mktemp -d 2>/dev/null || mktemp -d -t otterT19)"
ln -s "$REAL_TMUX" "$T19_BIN/tmux"
SESSION_C="otter_test_C"
cleanup_sessions "$SESSION_C"
out=$(PATH="$T19_BIN:/bin:/usr/bin" OTTER_NO_ATTACH=1 "$OTTER" -c claude -s "$SESSION_C" 2>&1 >/dev/null; printf 'EXIT:%s' "$?")
exit_code="${out##*EXIT:}"
stderr_out="${out%EXIT:*}"
if [[ "$exit_code" == "3" ]] && printf '%s' "$stderr_out" | grep -qi "claude" && printf '%s' "$stderr_out" | grep -qi "not installed"; then
    pass T19 "missing claude -> exit 3"
else
    fail T19 "exit=$exit_code stderr=[$stderr_out]"
fi
cleanup_sessions "$SESSION_C"
rm -rf "$T19_BIN"

# ============================================================
# T20: source 后 PATH 为空时 require_cmd tmux → exit 3
# ============================================================
out=$(bash -c "source \"$OTTER\"; PATH=/empty_path_$$ require_cmd tmux" 2>&1; printf 'EXIT:%s' "$?")
exit_code="${out##*EXIT:}"
body="${out%EXIT:*}"
if [[ "$exit_code" == "3" ]] && printf '%s' "$body" | grep -qi "tmux"; then
    pass T20 "missing tmux -> exit 3"
else
    fail T20 "exit=$exit_code body=[$body]"
fi

# ============================================================
# T21: yazi 缺失，3 pane 仍创建，右上 pane 是 shell
# ============================================================
SESSION_YAZI="otter_test_yazi"
cleanup_sessions "$SESSION_YAZI"
# 准备一个不含 yazi 的 PATH：单独创建目录，软链 tmux/claude（但不软链 yazi）
T21_BIN="$(mktemp -d 2>/dev/null || mktemp -d -t otterT21)"
ln -s "$REAL_TMUX" "$T21_BIN/tmux"
ln -s "$(command -v claude)" "$T21_BIN/claude"
PATH="$T21_BIN:/bin:/usr/bin" OTTER_NO_ATTACH=1 "$OTTER" -c claude -s "$SESSION_YAZI" >/dev/null 2>&1
rc=$?
if [[ $rc -ne 0 ]] || ! tmux has-session -t "=$SESSION_YAZI" 2>/dev/null; then
    fail T21 "session not created (rc=$rc)"
else
    pane_count=$(tmux list-panes -t "=$SESSION_YAZI:claude" 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$pane_count" != "3" ]]; then
        fail T21 "pane_count=$pane_count (expected 3)"
    else
        # 右上 pane 是 index 1（split-window -h 后是 .1）
        sleep 0.5
        right_top_cmd=$(tmux list-panes -t "=$SESSION_YAZI:claude" -F '#{pane_index} #{pane_current_command}' 2>/dev/null | awk '$1=="1"{print $2}')
        if [[ -n "$right_top_cmd" ]] && ! printf '%s' "$right_top_cmd" | grep -qi "yazi"; then
            pass T21 "right-top pane runs shell ($right_top_cmd), not yazi"
        else
            fail T21 "right-top current_command=[$right_top_cmd]"
        fi
    fi
fi
cleanup_sessions "$SESSION_YAZI"
rm -rf "$T21_BIN"

# ============================================================
# T22: 不带 -s，session 名 = basename($PWD) 经 sanitize
# ============================================================
DEMO_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t otter)/otter_demo_dir"
mkdir -p "$DEMO_DIR"
SESSION_DEMO="otter_demo_dir"
cleanup_sessions "$SESSION_DEMO"
(
    cd "$DEMO_DIR" || exit 1
    OTTER_NO_ATTACH=1 "$OTTER" -c claude >/dev/null 2>&1
)
rc=$?
if [[ $rc -eq 0 ]] && tmux has-session -t "=$SESSION_DEMO" 2>/dev/null; then
    pass T22 "default session name = basename(PWD)"
else
    fail T22 "rc=$rc has_session=$(tmux has-session -t "=$SESSION_DEMO" 2>/dev/null && echo yes || echo no)"
fi
cleanup_sessions "$SESSION_DEMO"
rm -rf "$(dirname "$DEMO_DIR")"

# ============================================================
# T23: -ks 不带值 → exit 2 + usage
# ============================================================
out=$("$OTTER" -ks 2>&1 >/dev/null; printf 'EXIT:%s' "$?")
exit_code="${out##*EXIT:}"
stderr_out="${out%EXIT:*}"
if [[ "$exit_code" == "2" ]] && printf '%s' "$stderr_out" | grep -qi "usage"; then
    pass T23 "-ks no value -> exit 2"
else
    fail T23 "exit=$exit_code stderr=[$stderr_out]"
fi

# ============================================================
# T24: -s foo 无 -c → exit 2 + usage
# ============================================================
out=$("$OTTER" -s foo 2>&1 >/dev/null; printf 'EXIT:%s' "$?")
exit_code="${out##*EXIT:}"
stderr_out="${out%EXIT:*}"
if [[ "$exit_code" == "2" ]] && printf '%s' "$stderr_out" | grep -qi "usage"; then
    pass T24 "-s without -c -> exit 2"
else
    fail T24 "exit=$exit_code stderr=[$stderr_out]"
fi

# ============================================================
# T25: -s foo -ks bar → exit 2 + usage
# ============================================================
out=$("$OTTER" -s foo -ks bar 2>&1 >/dev/null; printf 'EXIT:%s' "$?")
exit_code="${out##*EXIT:}"
stderr_out="${out%EXIT:*}"
if [[ "$exit_code" == "2" ]] && printf '%s' "$stderr_out" | grep -qi "usage"; then
    pass T25 "-s + -ks -> exit 2"
else
    fail T25 "exit=$exit_code stderr=[$stderr_out]"
fi

# ---------- 清理与汇总 ----------
cleanup_all

printf '\nTotal: %d  Pass: %d  Fail: %d  Skip: %d\n' "$TOTAL" "$PASS_N" "$FAIL_N" "$SKIP_N"

# ---------- 写结果文件 ----------
{
    printf '# otter 测试结果\n'
    printf '执行时间：%s\n\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf '| ID | 状态 | 备注 |\n'
    printf '|----|------|------|\n'
    for i in "${!RESULT_ID[@]}"; do
        # 转义管道符避免破坏表格
        note="${RESULT_NOTE[$i]//|/\\|}"
        printf '| %s | %s | %s |\n' "${RESULT_ID[$i]}" "${RESULT_STATUS[$i]}" "$note"
    done
    printf '\n汇总：Total %d / Pass %d / Fail %d / Skip %d\n' "$TOTAL" "$PASS_N" "$FAIL_N" "$SKIP_N"
} > "$RES_FILE"

if [[ $FAIL_N -gt 0 ]]; then
    exit 1
fi
exit 0
