#!/usr/bin/env python3
# wren for agy（Antigravity CLI）（两行版，与 wren-cc.py / wren-qc.py 同构）
# 布局:
#   行1: ~/cwd | branch ↑a↓b +增 ~删 ✱改 | ws:tab:pane | agy · 时长
#   行2: ↑in ↓out | R cacheR CH% | ctx%/win TTFT | 模型名 · 思考等级 | cost
#
# 数据来源（agy statusline payload + Gemini 格式 transcript）：
#   - stdin:      agy 的 statusline runner 可能不关 stdin → 1s 超时读取；空/超时回退 {}（idle）
#   - cwd:        workspace.current_dir 优先，回退 cwd，最后 os.getcwd()
#   - ↑in/↓out:   transcript 累计（input_tokens 不含 cache，与 CC 同口径）；无 transcript 回退
#                 payload context_window.total_input_tokens / total_output_tokens
#   - R:          transcript 累计 cache_read_tokens；回退 current_usage.cache_read_input_tokens
#   - ctx%:       context_window.used_percentage 原生优先 → current_usage(in+cr+cw) → transcript 末次请求
#   - CH:         current_usage 的 cache_read / (input + read + write) → transcript 末次
#   - TTFT:       最近一次 USER_INPUT → 其后首条 PLANNER_RESPONSE；created_at 是秒级精度，
#                 故 TTFT 量化到 1s（格式沿用 fmt_ttft）
#   - 时长:       transcript 首条 created_at → now（宿主 payload 没有时长字段）
#   - 压缩:       agy transcript 没有压缩标记 → compactions 恒 0，CPn 不显示
#   - 思考等级:   model.effort（agy 原生字段）；缺失则不显示
#   - cost:       cost.total_usd → total_cost_usd 回退；estimated → ~ 前缀；
#                 subagent_usd>0 → "| sub:$x"
#   - 宽度:       COLUMNS → 控制终端（ctermid，任何异常即跳过）→ payload.terminal_width → 80
#   - 宿主徽标:   agy
# 色板/降级与 cc/qc 一致：NO_COLOR → 裸文本；COLORTERM∈{truecolor,24bit} → truecolor；否则 256。
# 假定深色终端底色（Dracula 为暗底设计）。
# 文本净化（R2-1/R3-2）：model.display_name/id、effort、cwd、herdr env、git 分支名
# 统一走 _clean_text——剥 ESC/OSC/CSI 整段、Cc、bidi 控制符、U+200B（保留 ZWNJ/ZWJ），
# 压平行界；不可信 ESC 不会进入 stdout。
# transcript 容灾（R3-1）：只读普通文件（设备/FIFO 直接跳过）；单行 >8MiB 整行跳过。
# token 取整（R2-2）：transcript 与 payload 回退的 token 计数统一 int（2.0 → 2）。
# 运行时预算（R2-3）：总 3.5s / git 1.5s / transcript 扫描 1.0s——agy 的 runner
# 约 4.7s SIGKILL 并计一次失败，连续 30 次失败自动禁用状态栏。
# 容灾铁律：任何情况下 rc=0、stderr 为空、输出恰好两行——agy 连续失败会自动禁用
# 自定义状态栏（"Statusline disabled after %d consecutive failures."）。
import json
import math
import os
import re
import signal
import subprocess
import sys
import time
import unicodedata
from pathlib import Path

# ---- 运行时预算（R2-3）----
# agy 的 statusline runner 约 4.7s 后 SIGKILL 脚本并计一次失败
# （statusline_runner.go:259，failure N/30），连续 30 次失败自动禁用状态栏；
# 失败后立即重跑、无退避。所以总预算必须压在这条硬线之下，且 git 超时比
# cc/qc 的 3s 短（宿主 4.7s 硬杀 + 失败计数）。
TOTAL_BUDGET_S = 3.5
GIT_TIMEOUT_S = 1.5
SCAN_BUDGET_S = 1.0


def _scan_budget_s():
    """扫描预算：默认 SCAN_BUDGET_S；WREN_AGY_SCAN_BUDGET（秒）覆盖并钳在
    [0.01, 5.0]；非法/非有限值回落默认（测试专用，正常用户不设）。"""
    raw = os.environ.get("WREN_AGY_SCAN_BUDGET")
    if not raw:
        return SCAN_BUDGET_S
    try:
        v = float(raw)
    except (TypeError, ValueError):
        return SCAN_BUDGET_S
    if not math.isfinite(v):
        return SCAN_BUDGET_S
    return min(5.0, max(0.01, v))


def _default_cache_dir():
    """模块级 Path.home() 守卫（R2-4）：HOME 缺失且 pwd 查不到时不能 import 崩。"""
    try:
        home = Path.home()
    except Exception:
        home = Path(os.environ.get("HOME") or "/tmp")
    return Path(os.getenv("WREN_CACHE_DIR") or (home / ".cache" / "wren"))


CACHE_DIR = _default_cache_dir()

# 文本净化（R2-1）：输入字段里的终端控制序列整段剥掉，禁止注入 ESC。
# CSI（\x1b[ … final）、OSC（\x1b] … BEL|ST）、其它两字符 ESC 序列。
_ESC_RE = re.compile(
    r"\x1b\[[0-?]*[ -/]*[@-~]"              # CSI
    r"|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)"   # OSC
    r"|\x1b[@-Z\\-_]"                       # 其它 ESC 序列（两字符）
)
# bidi 控制符 U+202A–202E / U+2066–2069 + 零宽空格 U+200B；
# ZWNJ/ZWJ（U+200C/200D）保留——复杂文字模型名/路径要用。
_BIDI_RE = re.compile(r"[\u202a-\u202e\u2066-\u2069\u200b]")

def _clean_text(v):
    """统一字段净化：非 str → ""；剥 ESC/OSC/CSI 整段；去 Cc、bidi 控制符、
    U+200B；压平 Unicode 行界（U+0085/U+2028/U+2029）；strip()。
    ZWNJ/ZWJ 保留。所有进入 stdout 的文本字段都走这里（含 git 分支名）。"""
    if not isinstance(v, str) or not v:
        return ""
    s = _ESC_RE.sub("", v)
    s = _BIDI_RE.sub("", s)
    s = "".join(ch for ch in s
                if unicodedata.category(ch) != "Cc" and ch not in "\u2028\u2029")
    return s.strip()

# ---- Dracula 色板（官方），两档预计算：truecolor 与 256 近似（同 pi 宿主 rgbTo256 算法） ----
_DRACULA = {
    # name:       (truecolor "38;2;R;G;B",        256 "38;5;N")
    "fg":      ("38;2;248;248;242", "38;5;231"),   # #f8f8f2 前景白
    "comment": ("38;2;98;114;164",  "38;5;61"),    # #6272a4 注释灰（弱化信息：cwd/herdr/CP）
    "purple":  ("38;2;189;147;249", "38;5;141"),   # #bd93f9 分支名
    "green":   ("38;2;80;250;123",  "38;5;84"),    # #50fa7b +增 / ctx% 正常
    "red":     ("38;2;255;85;85",   "38;5;203"),   # #ff5555 ~删 / ctx% 危险
    "yellow":  ("38;2;241;250;140", "38;5;228"),   # #f1fa8c ✱改 / ctx% 偏高
    "pink":    ("38;2;255;121;198", "38;5;212"),   # #ff79c6 模型名
    "cyan":    ("38;2;139;233;253", "38;5;117"),   # #8be9fd CH / 思考等级
}


def _color_mode():
    """NO_COLOR → 无色；COLORTERM 报 truecolor/24bit → truecolor；否则 256。
    statusline 的 stdout 接宿主本体不是 tty，isatty() 恒 false，不能用来判。"""
    if os.environ.get("NO_COLOR"):
        return "none"
    ct = os.environ.get("COLORTERM", "")
    return "truecolor" if ct in ("truecolor", "24bit") else "256"


_C = _color_mode()

# 窄档身份组缩写（用户裁定：⏱ 升铁律后，模型名去 [1m] 后缀、思考等级缩写腾格子）
_THINK_SHORT = {"xhigh": "xh", "high": "hi", "medium": "med", "low": "low", "max": "max"}


def c(name, text):
    """按当前色档给 text 上色；无色档原样返回。"""
    if _C == "none":
        return text
    return f"\033[{_DRACULA[name][0 if _C == 'truecolor' else 1]}m{text}\033[0m"


ZERO_STATE = {
    "input_t": 0, "output_t": 0, "cache_r": 0,
    "last_prompt_tokens": 0, "last_cache_r": 0,
    "first_ts": None,
    # TTFT：ttft_ms 是配对成功时落下的存量（等待期/新轮显示上一轮旧值，
    # 与 cc/pi/qc 同语义）；turn_user_ts 只作配对，不参与渲染
    "ttft_ms": None, "turn_user_ts": None,
}


_GIT = None


def _kill_git():
    """杀掉 git 整棵进程树。git 以新会话启动（start_new_session），进程组组长
    就是它本身，killpg 连包装脚本 fork 的子孙一起清——只杀直接子进程会漏孤儿
    （对齐 2026-10-12 测试护栏事故的教训）。"""
    p = _GIT
    if p is None or p.poll() is not None:
        return
    try:
        os.killpg(p.pid, signal.SIGKILL)
    except Exception:
        try:
            p.kill()
        except Exception:
            pass
    try:
        p.communicate(timeout=1)
    except Exception:
        pass


def sh(args, timeout=3):
    """单次外部命令（git）。Popen + 独立会话：超时/异常先杀整棵树再返回 ""。
    正常路径返回值语义不变（stdout.strip()）。"""
    global _GIT
    p = None
    try:
        kwargs = {"start_new_session": True} if hasattr(os, "killpg") else {}
        p = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             text=True, **kwargs)
        _GIT = p
        out, _ = p.communicate(timeout=timeout)
        return out.strip()
    except subprocess.TimeoutExpired:
        _kill_git()
        return ""
    except Exception:
        _kill_git()
        return ""
    finally:
        _GIT = None


def _on_signal(signum, frame):
    """被宿主打断（重载/关闭状态栏、退出、Ctrl-C）：清掉 git 进程树，输出兜底
    两行，rc=0——既不漏进程，也不以信号死亡（agy 不把它记成一次失败）。"""
    _kill_git()
    emit_fallback()
    os._exit(0)


def fmt(n):
    if n < 1000:
        return str(n)
    if n < 1_000_000:
        k = round(n / 1000)
        if k >= 1000:  # 999_500..999_999 四舍五入会变成 1000K，改显示 1.0M
            return f"{n / 1_000_000:.1f}M"
        return f"{k}K"
    m = n / 1_000_000
    return f"{m:.0f}M" if m == int(m) else f"{m:.1f}M"


def fmt_duration(ms):
    s = ms // 1000
    h = s // 3600
    if h >= 100:  # 99h59m 之后钳制，行1 预算的 9 格上界常量才成立
        return "99h+"
    return f"{h}h{(s % 3600)//60}m" if h > 0 else f"{s//60}m"


def fmt_ttft(ms):
    """首片延迟分档（三侧同式，与 pi 的 fmtTtft 逐档对齐）：<10s 一位小数；
    ≥10s 整数；≥60s m+s；≥1h h+m。统一带 `TTFT ` 前缀。
    上界 11 格（TTFT 99m59s）；>99h 钳到 `TTFT 99h+`（9 格）。
    取整口径与 pi 一致：先四舍五入到整秒再判档（`(ms+500)//1000` 等价于 JS
    Math.round 且不碰浮点）——用原始 ms 判 60s 界会与 pi 差一档。
    <10s 档沿用 `:.1f`（与 JS toFixed 同口径；仅 ms%1000==250 这类二进制精确
    半值差 0.1s，属已知残留）。"""
    if ms < 10_000:
        return f"TTFT {ms / 1000:.1f}s"
    total = (ms + 500) // 1000
    if total < 60:
        return f"TTFT {total}s"
    if total < 3600:
        return f"TTFT {total // 60}m{total % 60:02d}s"
    h = total // 3600
    if h > 99:
        return "TTFT 99h+"
    return f"TTFT {h}h{(total % 3600) // 60:02d}m"


def ttft_secs(ms):
    """TTFT 显示值（秒）：<10s 保留一位小数（与 :.1f 同口径），≥10s 四舍五入到整秒。
    色档判定用它而非原始 ms —— 否则「TTFT 20s」在 19.6s~20.4s 之间会白黄跳。"""
    if ms is None:
        return None
    if ms < 10_000:
        return round(ms / 1000, 1)
    return (ms + 500) // 1000


def ttft_color(ms):
    """TTFT 四档着色（与 ctx% 同为突变式，不做渐变）：绿 <5s、白 5-20s、黄 20-60s、
    红 >60s。判据取 ttft_secs(ms)（显示器渲染值），保证同屏同值同色。"""
    v = ttft_secs(ms)
    if v is None:
        return "fg"
    if v < 5:
        return "green"
    if v <= 20:
        return "fg"
    if v <= 60:
        return "yellow"
    return "red"


def _epoch(ts):
    if not ts:
        return None
    from datetime import datetime
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
    except Exception:
        return None


def _clean_path(v):
    """cwd 字段净化：复用 _clean_text（非 str/空 → ""；剥 ESC、控制字符、
    bidi、零宽空格，压平行界后 strip）。"""
    return _clean_text(v)


def dwidth(s):
    """显示宽度：CJK 全角字符占 2 格（与 pi 侧 visibleWidth 口径一致）。
    只用于折叠预算的计算，不影响输出内容。"""
    w = 0
    for ch in s:
        w += 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1
    return w


def slice_cells(s, maxw, from_end=False):
    """按显示宽取头/尾片段，结果不超过 maxw 格。"""
    seq = reversed(s) if from_end else s
    out, w = [], 0
    for ch in seq:
        cw = 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1
        if w + cw > maxw:
            break
        out.append(ch)
        w += cw
    return "".join(reversed(out)) if from_end else "".join(out)


_ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")


def strip_ansi(s):
    """剥 ANSI 转义（量宽用）：dwidth 按 char 记宽，带色串虚高。"""
    return _ANSI_RE.sub("", s)


def truncate_display(s, maxw):
    """按显示宽度硬截断整行，ANSI 转义原样保留、宽度记 0。
    地位与 pi 侧的 truncateToWidth 相同：折叠公式算偏了也不会溢出。"""
    out, w, i, n, saw = [], 0, 0, len(s), False
    while i < n and w < maxw:
        if s[i] == "\033":
            m = _ANSI_RE.match(s, i)
            if m:
                out.append(m.group())
                saw = True
                i = m.end()
                continue
        ch = s[i]
        cw = 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1
        if w + cw > maxw:
            break
        out.append(ch)
        w += cw
        i += 1
    if saw and i < n:
        out.append("\033[0m")
    return "".join(out)


def fold_path(p, budget):
    """路径折叠：给定预算逐级降级（头2+尾2 → 头1+尾2 → 尾2 → 尾1），末级对尾段字符截断。"""
    if dwidth(p) <= budget:
        return p
    segs = p.split("/")
    cands = [
        "/".join(segs[:2]) + "/…/" + "/".join(segs[-2:]),
        segs[0] + "/…/" + "/".join(segs[-2:]),
        "…/" + "/".join(segs[-2:]),
        "…/" + segs[-1],
    ]
    for cand in cands:
        if dwidth(cand) <= budget:
            return cand
    last = "…/" + segs[-1]
    if dwidth(last) <= budget:
        return last
    keep = budget - 2  # "…" + 至少 1 格
    if keep < 1:
        return slice_cells(p, max(0, budget))
    return "…" + slice_cells(segs[-1], keep, from_end=True)


def fold_branch(b, max_len=24):
    """分支折叠：max_len 驱动（行1 梯子逐级传 24→20→16→12→8→4）。
    24 档与 cc/pi/oc 三侧同构（head 8 / tail 15，尾重头轻）；
    <24 档是窄档私有档位，头尾三七开（head≈30%、尾吃剩余）。
    触发条件与切片都按显示格（与 cc CR 轮 11 同口径）。"""
    if dwidth(b) <= max_len:
        return b
    if max_len >= 24:  # 宽档默认档：三侧同构 8/15
        return slice_cells(b, 8) + "…" + slice_cells(b, 15, from_end=True)
    if max_len <= 0:  # 0 档 = git 段整体让位（物理极限区最后一级）
        return ""
    if max_len <= 4:  # 极窄档：只剩 "…" + 尾 2
        return "…" + slice_cells(b, max(2, max_len - 1), from_end=True)
    head = max(3, max_len * 3 // 10 - 1)          # …，头 30%
    tail = max(4, max_len - head - 1)             # 尾吃剩余，兜住最后一级 8 格
    if head + 1 + tail > max_len:                 # 兜底互踩时尾让位（小档防溢出）
        tail = max(2, max_len - head - 1)
    return slice_cells(b, head) + "…" + slice_cells(b, tail, from_end=True)


def tok(v):
    """token 字段净化（与 qc 的 tok 同纪律 + R2-2 取整）：仅接受有限、非负的
    int/float（排除 bool），其余当 0；float 截断为 int（output_tokens: 2.0 → 2），
    避免 `↓2.0` 这类渲染。json.loads 接受非标 NaN/Infinity，直接累加会让
    fmt 的 round() 抛 ValueError/OverflowError 走裸 cwd。"""
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        return 0
    if isinstance(v, float) and not math.isfinite(v):
        return 0
    return int(v) if v > 0 else 0


def accumulate(st, d):
    """把一条 agy transcript 记录并入聚合状态。

    记录只有 5 种（USER_INPUT / PLANNER_RESPONSE / GENERIC / SYSTEM_MESSAGE /
    ERROR_MESSAGE）。聚合口径（实证见 README、spec §1.3）：
      - input_tokens 不含 cache（与 Claude 同口径）→ CH 分母 = input+read；
      - ↑in/↓out/R 取全量累计（与 cc/qc 同口径），payload totals 只作回退；
      - TTFT 配对：最近一次真 USER_INPUT → 其后首条 PLANNER_RESPONSE，
        同轮后续 step 不覆盖；配对成功后关窗，等待期渲染读 ttft_ms 存量；
      - 没有压缩标记 → compactions 恒 0；
      - first_ts 取所有记录 created_at 的最小值（时长 = now − first_ts）。
    """
    if not isinstance(d, dict):
        return
    t = d.get("created_at")
    ts = _epoch(t) if isinstance(t, str) else None
    if ts is not None and (st["first_ts"] is None or ts < st["first_ts"]):
        st["first_ts"] = ts
    typ = d.get("type")
    if typ == "USER_INPUT":
        src = d.get("source")
        if (not isinstance(src, str)) or src == "USER_EXPLICIT":   # 真用户才开轮窗口
            if ts is not None:
                st["turn_user_ts"] = ts
    elif typ == "PLANNER_RESPONSE":
        i = tok(d.get("input_tokens"))
        o = tok(d.get("output_tokens"))
        cr = tok(d.get("cache_read_tokens"))
        st["input_t"] += i
        st["output_t"] += o
        st["cache_r"] += cr
        st["last_prompt_tokens"] = i + cr   # agy 的 input 不含 cache（同 CC 口径）
        st["last_cache_r"] = cr
        if ts is not None and st["turn_user_ts"] is not None and ts >= st["turn_user_ts"]:
            st["ttft_ms"] = int((ts - st["turn_user_ts"]) * 1000)   # 一轮只配一次
            st["turn_user_ts"] = None


_STATE_NUM = ("input_t", "output_t", "cache_r",
              "last_prompt_tokens", "last_cache_r")
_STATE_TS = ("first_ts", "ttft_ms", "turn_user_ts")


def _sanitize_state(st):
    """缓存值净化（R2-2）：token 类数值统一成 int（旧缓存/毒缓存里的 float 也
    截断），毒型归 0；时间戳字段只保证是有限数值（ttft_ms/时长语义保小数）。"""
    for k in _STATE_NUM:
        v = st.get(k)
        if (isinstance(v, bool) or not isinstance(v, (int, float))
                or (isinstance(v, float) and not math.isfinite(v)) or v < 0):
            st[k] = 0
        else:
            st[k] = int(v)
    for k in _STATE_TS:
        v = st.get(k)
        if v is not None and (isinstance(v, bool) or not isinstance(v, (int, float))
                              or (isinstance(v, float) and not math.isfinite(v))):
            st[k] = None
    return st


def scan_transcript(path, budget_s=SCAN_BUDGET_S):
    """按字节 offset 续读 agy transcript，聚合结果缓存到 $WREN_CACHE_DIR 下的
    agy-<sha1(path)[:16]>.json。

    机制照抄 wren-qc.py：流式读、只喂以 \\n 结尾的完整行、半行回退、tmp+replace
    原子写、毒缓存守卫、>200 清扫；无新增字节时不重写缓存、不触发清扫。
    缓存键带 agy- 前缀，与 cc/qc 共用目录也不串味。

    R2-3 运行时预算：每处理完一行检查一次耗时，超 budget_s 即 break——已聚合
    状态保留、offset 只记到完整行尾（半行回退不变），下次运行从 offset 续读；
    budget_s <= 0 时完全不读新字节，直接用缓存状态。
    """
    st = dict(ZERO_STATE)
    try:
        # R3-1：只接受普通文件（symlink 跟随）。/dev/zero 之类的设备会无限
        # 无换行流把 readline 拖死，FIFO 无写端时 open() 直接阻塞。
        if not os.path.isfile(path):
            return st
        size = os.path.getsize(path)
    except OSError:
        return st

    import hashlib   # 惰性：只有真正扫描 transcript 的路径才付这 5ms 启动成本
    cache_file = CACHE_DIR / f"agy-{hashlib.sha1(str(path).encode()).hexdigest()[:16]}.json"
    offset = 0
    resumed = False
    try:
        old_raw = cache_file.read_text() if cache_file.exists() else ""
    except OSError:
        old_raw = ""
    if old_raw:
        try:
            old = json.loads(old_raw)
        except Exception:
            old = None
        # offset 毒型（对齐 cc/qc）：只认 int（bool 排除）且落在文件范围内，
        # 非法即全量重算并覆写（resumed=False 才会触发下面的重写）。
        old_off = old.get("offset") if isinstance(old, dict) else None
        if (isinstance(old, dict) and old.get("path") == str(path)
                and isinstance(old_off, int) and not isinstance(old_off, bool)
                and 0 <= old_off <= size):
            offset = old_off
            resumed = True
            for k in st:
                if k in old:
                    st[k] = old[k]
            _sanitize_state(st)

    # 流式读（低占用）：readline(MAX_LINE) 逐段读，不把剩余段整段拉进内存；
    # 半行（无 \n）留给下次，offset 不前进。时间盒检查在「每处理完一行」之后
    # （非法 JSON 行也要检查，不能 continue 跳过）。
    # R3-1 超长单行（> MAX_LINE）：整行跳过不聚合，offset 只在整个行尾推进；
    # 跳过期间同样检查时间盒与 MAX_SKIP，未到行尾则 offset 不前进、下次重来。
    st["path"] = str(path)
    consumed = offset
    if budget_s > 0:
        deadline = time.monotonic() + budget_s
        try:
            with open(path, "rb") as fh:
                fh.seek(offset)
                while True:
                    if time.monotonic() >= deadline:
                        break
                    line_start = consumed
                    chunk = fh.readline(MAX_LINE)
                    if not chunk:
                        break                       # 行边界处 EOF
                    consumed += len(chunk)
                    if chunk.endswith(b"\n"):
                        line = chunk.decode("utf-8", "ignore")
                        try:
                            accumulate(st, json.loads(line))
                        except Exception:
                            pass
                        if time.monotonic() >= deadline:
                            break                       # 状态保留，offset 记到行尾
                        continue
                    if len(chunk) < MAX_LINE:
                        consumed = line_start           # EOF 半行：offset 不前进
                        break
                    # 超长行：跳到行尾，整行不聚合
                    skip_used = len(chunk)
                    skipped = False
                    while True:
                        if time.monotonic() >= deadline:
                            break                       # 超预算：下次从行首重来
                        more = fh.readline(MAX_LINE)
                        if not more:
                            break                       # EOF：仍算半行，offset 不前进
                        skip_used += len(more)
                        consumed += len(more)
                        if more.endswith(b"\n"):
                            if skip_used <= MAX_SKIP:
                                skipped = True
                            break
                        if skip_used >= MAX_SKIP:
                            break                       # 跳过量超限：本次停止
                    if not skipped:
                        consumed = line_start
                        break
                    # 整行已跳过：继续下一行
        except (OSError, TypeError, ValueError):
            return st
    if consumed == offset and (resumed or budget_s <= 0):
        return st   # 无新增字节 / 预算为零：不重写缓存、不触发清扫
    st["offset"] = consumed
    try:
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
        tmp = cache_file.with_suffix(".tmp")
        tmp.write_text(json.dumps(st))
        tmp.replace(cache_file)
        # 缓存清扫（与 cc/qc 同一条）：.json > 200 个时按 mtime 删最旧的。
        # 整个 try 域失败不影响渲染（缓存目录只读/损坏也必须照常出两行）。
        entries = [e for e in CACHE_DIR.iterdir() if e.suffix == ".json"]
        if len(entries) > 200:
            for e in sorted(entries, key=lambda x: x.stat().st_mtime)[:len(entries) - 200]:
                e.unlink(missing_ok=True)
    except Exception:
        pass
    return st


def thinking_level(model_obj):
    """思考等级：只用 agy 原生 model.effort（low..max，仅多档模型有）；缺失不显示。
    非字符串当缺失（对齐 cc 猎杀四轮 #2：int 会让 join 抛 TypeError）；
    _clean_text 负责剥 ANSI/bidi/控制字符（R2-1）。"""
    return _clean_text(model_obj.get("effort"))


MAX_STDIN = 8 * 1024 * 1024  # stdin 累计上限：防宿主喂超大 payload 时内存失控
MAX_LINE = 8 * 1024 * 1024   # transcript 单行上限（R3-1）：超过则整行跳过
MAX_SKIP = 64 * 1024 * 1024  # 单行跳过量上限：超过则本次停止扫描（offset 不前进）


def read_stdin(timeout=1.0):
    """带超时读取 stdin。agy 的 statusline runner 若不关 stdin，阻塞 read 会让状态栏挂死；
    读到 EOF / 超时 / 8 MiB 上限即返回，随后把 fd 换成 /dev/null 解除上游阻塞
    （对齐参考实现 `timeout 1 cat` + `exec 0</dev/null`）。
    sys.stdin 为 None / fd 无效 → 返回 ""。"""
    if sys.stdin is None:
        return ""
    try:
        fd = sys.stdin.fileno()
    except Exception:
        try:
            return sys.stdin.read(MAX_STDIN)
        except Exception:
            return ""
    try:
        import select
        chunks = []
        total = 0
        deadline = time.monotonic() + timeout
        while total < MAX_STDIN:
            remain = deadline - time.monotonic()
            if remain <= 0:
                break
            try:
                r, _, _ = select.select([fd], [], [], remain)
            except Exception:
                try:
                    return sys.stdin.read(MAX_STDIN)
                except Exception:
                    return ""
            if not r:
                break
            try:
                chunk = os.read(fd, min(65536, MAX_STDIN - total))
            except OSError:
                break
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
        return b"".join(chunks).decode("utf-8", "replace")
    finally:
        try:
            devnull = os.open(os.devnull, os.O_RDONLY)
            os.dup2(devnull, fd)
            os.close(devnull)
        except Exception:
            pass


def main():
    # R2-3：总预算自 main 第一行起算（宿主约 4.7s SIGKILL，连续失败会禁用状态栏）
    t0 = time.monotonic()

    def remaining():
        return TOTAL_BUDGET_S - (time.monotonic() - t0)

    raw = read_stdin(min(1.0, max(0.0, remaining())))
    dump = os.getenv("WREN_DEBUG_DUMP")
    if dump:
        try:
            Path(dump).write_text(raw)
        except Exception:
            pass
    try:
        data = json.loads(raw) if raw.strip() else {}
    except Exception:
        data = {}
    if not isinstance(data, dict):
        data = {}   # 顶层是数组/标量：按空 payload 降级

    # agy 把工作目录放在 workspace.current_dir；回退 cwd，最后 os.getcwd()。
    # 只认非空 str，控制字符压平（换行会顶飞两行契约）。
    ws = data.get("workspace")
    cwd = _clean_path(ws.get("current_dir")) if isinstance(ws, dict) else ""
    if not cwd:
        cwd = _clean_path(data.get("cwd"))
    if not cwd:
        try:
            cwd = _clean_path(os.getcwd())
        except OSError:
            pass
    if not cwd:
        cwd = "?"

    model_obj = data.get("model") if isinstance(data.get("model"), dict) else {}
    # R2-1：id/display_name 统一净化（剥 ESC/OSC/CSI、Cc、bidi、U+200B；
    # 保留 ZWNJ/ZWJ）。两者都净化后择一显示（display_name 优先，空则回落 id）。
    mid = _clean_text(model_obj.get("id"))
    dn = _clean_text(model_obj.get("display_name"))
    # 压平换行再切尾斜杠/后缀（对齐 cc 猎杀四轮 #4：注入 \n 会顶飞 2 行契约）；
    # 空则回落 no-model
    raw_name = (dn or mid) or "no-model"
    model_name = raw_name.split("/")[-1].replace(" Model", "").strip() or "no-model"

    cw = data.get("context_window") if isinstance(data.get("context_window"), dict) else {}
    # 窗口只认真实字段（>0）；未知时 ctx 段只显示百分比、不猜 200k
    # （旧版的 "[1m]" 模型名启发式已删——模型名不是窗口的可信来源）。
    _win = cw.get("context_window_size")
    win = _win if (isinstance(_win, int) and not isinstance(_win, bool) and _win > 0) else 0
    # ctx% 数据源净化（对齐 cc 的 _nt 纪律）：json.loads 接受非标 NaN/Infinity/
    # 负数/字符串（'500' 直接比较会 TypeError 走裸 cwd），逐项过 _num——非法
    # 一律当缺失走回落链；负 used_percentage 同判无效（不渲染 '▂-5%'）
    def _num(v):
        return v if (isinstance(v, (int, float)) and not isinstance(v, bool)
                     and (not isinstance(v, float) or math.isfinite(v)) and v > 0) else 0
    native_pct = _num(cw.get("used_percentage")) or None
    cu = cw.get("current_usage")
    cu = cu if isinstance(cu, dict) else {}   # agy: 最近一次请求用量
    native_prompt = (_num(cu.get("input_tokens")) + _num(cu.get("cache_read_input_tokens"))
                     + _num(cu.get("cache_creation_input_tokens")))
    native_cache_r = _num(cu.get("cache_read_input_tokens"))

    tp = data.get("transcript_path")
    transcript = tp if isinstance(tp, str) else ""   # 非 str 不扫描
    # ---- token / TTFT / 时长：agy transcript 增量解析（缓存 agy-<sha1>）----
    # R2-3：扫描预算取 min(SCAN_BUDGET_S, 剩余总预算)——超时不丢已聚合状态，
    # offset 续读收敛；总预算耗尽（remaining<=0）时直接用缓存状态。
    scan_budget = min(_scan_budget_s(), max(0.0, remaining()))
    st = scan_transcript(transcript, scan_budget) if transcript else dict(ZERO_STATE)

    # 家目录折叠只锚定路径前缀（对齐 cc Bug 猎杀 #3：无锚 replace 会把
    # /Users/spoon<x>… 的兄弟目录错折成 ~<x>…，显示不存在的路径）
    try:
        home = str(Path.home())
    except Exception:
        home = os.environ.get("HOME") or ""
    short_cwd = ("~" + cwd[len(home):]) if home and (cwd == home or cwd.startswith(home + "/")) else cwd

    # ---- git: 单次 porcelain v2（branch + ahead/behind + 增/删/改） ----
    # R2-3：agy 侧超时压到 1.5s（cc/qc 的 3s 在 4.7s 宿主硬杀下太险）；
    # 总预算快耗尽时进一步缩短，给两行输出留时间。
    branch, ab, dmg, dmg_plain = "", "", "", ""
    stg = sh(["git", "-C", cwd, "status", "--porcelain=v2", "--branch"],
             timeout=min(GIT_TIMEOUT_S, max(0.05, remaining())))
    if stg:
        added = modified = deleted = 0
        for ln in stg.splitlines():
            if ln.startswith("# branch.head "):
                # R3-2：git 允许分支名含 bidi/ESC（只禁 ASCII 控制字符），
                # 属视觉欺骗面——先过 _clean_text，再判 detached。
                head = _clean_text(ln[len("# branch.head "):])
                # detached 判定：porcelain v2 的 detached 形态是字面 "(detached)"；
                # 以 "(" 开头的真实分支名（合法创建）不误伤。dmg/ab 不随 branch
                # 空而丢（对齐 cc Bug 猎杀 #2：detached 的脏树计数也是铁律）。
                branch = "" if head == "(detached)" else head
            elif ln.startswith("# branch.ab "):
                p = ln[len("# branch.ab "):].split()
                if len(p) == 2:
                    ab = f" ↑{p[0].lstrip('+')}↓{p[1].lstrip('-')}"
            elif ln.startswith("? "):
                added += 1
            elif ln[:2] in ("1 ", "2 ", "u "):
                xy = ln.split(" ", 2)[1]
                if xy[0] == "A":
                    added += 1
                elif "D" in xy:
                    deleted += 1
                else:
                    modified += 1
        # 同时留一份无色文本：dwidth 不剥 ANSI，拿上色串量宽度会把转义字节算进去
        parts, plain_parts = [], []
        for mark, name, count in (("+", "green", added), ("~", "red", deleted), ("✱", "yellow", modified)):
            if count:
                plain_parts.append(f"{mark}{count}")
                parts.append(c(name, f"{mark}{count}"))
        dmg = " " + " ".join(parts) if parts else ""
        dmg_plain = " " + " ".join(plain_parts) if plain_parts else ""

    # ---- herdr 位置 ----
    # R2-1：环境变量同样只取净化后的文本（剥 ESC/控制字符，压平行界）。
    herdr_parts = [_clean_text(os.getenv("HERDR_WORKSPACE_ID")),
                   _clean_text((os.getenv("HERDR_TAB_ID") or "").split(":")[-1]),
                   _clean_text((os.getenv("HERDR_PANE_ID") or "").split(":")[-1])]
    herdr_tag = f"{':'.join(p for p in herdr_parts if p)}" if any(herdr_parts) else ""

    # ---- token 账本：transcript 累计优先，payload totals 只在无 transcript 时回退 ----
    # R2-2：payload 回退值进账本前转 int（token 计数是整数，不渲染 2.0）。
    input_t = st["input_t"] or int(_num(cw.get("total_input_tokens")))
    output_t = st["output_t"] or int(_num(cw.get("total_output_tokens")))
    cache_r = st["cache_r"] or int(native_cache_r)

    # 上下文占用: 原生 used_percentage → current_usage 的 in+cr+cw → transcript 末次请求。
    # win 未知（0）时不给百分比外的 /win 后缀；tokens 路径没有 win 可除 → 该段留空。
    ctx_pct = ""
    if native_pct is not None:
        ctx_pct = f"{native_pct:.2f}%" + (f"/{fmt(win)}" if win else "")
    elif win:
        ctx_tokens = native_prompt if native_prompt > 0 else st["last_prompt_tokens"]
        if ctx_tokens > 0:
            ctx_pct = f"{ctx_tokens / win * 100:.2f}%/{fmt(win)}"

    # CH: 最近一次请求的缓存效率。agy 的 current_usage 与 CC 同口径
    # （input 不含 cache，read/write 单列），故 prompt = input + read + write
    ch_prompt, ch_cache = st["last_prompt_tokens"], st["last_cache_r"]
    if native_prompt > 0:
        ch_prompt, ch_cache = native_prompt, native_cache_r
    ch = f"CH{ch_cache / ch_prompt * 100:.2f}%" if ch_prompt > 0 and ch_cache > 0 else ""

    # 时长 = transcript 首条 created_at → now（宿主 payload 没有时长字段）；
    # 负值/异常（时钟回拨、毒缓存）不显示，绝不渲染 "-3m"。
    duration = ""
    first_ts = st["first_ts"]
    if isinstance(first_ts, (int, float)) and not isinstance(first_ts, bool):
        age = time.time() - first_ts
        if math.isfinite(age) and age >= 0:
            duration = fmt_duration(int(age * 1000))

    thinking = thinking_level(model_obj)

    # ---- cost（agy: total_usd → total_cost_usd 回退；estimated → ~；subagent → | sub:）----
    def _money(v):
        if isinstance(v, bool):
            return None
        if isinstance(v, (int, float)):
            return float(v) if math.isfinite(v) and v >= 0 else None
        if isinstance(v, str):
            try:
                f = float(v)
                return f if math.isfinite(f) and f >= 0 else None
            except ValueError:
                return None
        return None

    def _money_s(v):
        return f"${v:.2f}" if v >= 0.005 else ("<$0.01" if v > 0 else "$0.00")

    cost_obj = data.get("cost") if isinstance(data.get("cost"), dict) else {}
    cost_total = _money(cost_obj.get("total_usd"))
    if cost_total is None:
        cost_total = _money(cost_obj.get("total_cost_usd"))
    cost_sub = _money(cost_obj.get("subagent_usd")) or 0.0
    cost_est = cost_obj.get("estimated") in (True, "true")
    cost_s = ""
    if cost_total is not None:
        cost_s = ("~" if cost_est else "") + _money_s(cost_total)
        if cost_sub > 0:
            cost_s += f" | sub:{_money_s(cost_sub)}"

    # ---- 行1 ----
    # 宽度探测链（真机探针，见 README「宽度链」）：COLUMNS 优先 → 控制终端
    # （agy 的 sh -c 不导出 COLUMNS，但 statusline 由 pane 内 agy 拉起、控制
    # 终端即 pane PTY，从第一帧就准）→ payload.terminal_width（启动首帧可能
    # 陈旧成 80，只能垫底）→ 兜底 80。顺序反了会让窄 pane 首帧按 80 排版换行错位。
    term_w = 80
    _cols = 0
    try:
        _cols = int(os.environ.get("COLUMNS") or 0)
    except (TypeError, ValueError):
        _cols = 0
    if _cols > 0:
        term_w = _cols
    else:
        got_tty = False
        try:
            _fd = os.open(os.ctermid(), os.O_RDONLY)
            try:
                _sz = os.get_terminal_size(_fd)
                if _sz.columns > 0:
                    term_w = _sz.columns
                    got_tty = True
            finally:
                os.close(_fd)
        except Exception:
            pass
        if not got_tty:
            _tw = data.get("terminal_width")
            if isinstance(_tw, int) and not isinstance(_tw, bool) and _tw > 0:
                term_w = _tw
    # agy 有真实宽度通道（COLUMNS / 控制终端 / payload.terminal_width），窄档正常启用
    narrow = term_w <= 55
    if narrow:
        # 地板不钳 24（对齐 cc：钳 24 会让 COLUMNS<29 的行按 24 格排版、实际
        # 超终端宽。钳 4 = 段级丢段可工作的最小值）
        term_w = max(4, term_w - 5)
    # 行1 梯子（宽窄档统一，与 cc 同一条）：永不丢 dmg / herdr 坐标 / agy 徽标；
    # 溢出让位顺序：ahead-behind → 分支六档（24→20→16→12→8→4）→ 时长
    # → cwd 折叠（地板 16→8→4）。时长按 9 格上界常量计入（不随数值抖动）。
    dur_s = f" {c('comment', '·')} {c('fg', duration)}" if duration else ""
    dur_w = 9 if duration else 0  # dwidth(" · 99h59m")
    herdr_w = dwidth(f" | {herdr_tag}") if herdr_tag else 0

    def git_w(blen, with_ab):
        """git 段宽度探针：按「分支折叠后真实宽度」计（虚记会把短分支多折一级）。
        git 段各件全空时返回 0——非 git cwd 不留 3 格幻影宽，目录预算不被偷。"""
        if not (branch or ab or dmg_plain):
            return 0
        core = (fold_branch(branch, blen) if branch else "") \
            + (ab if with_ab else "") + dmg_plain
        if not core:
            return 0  # 折到 0 档（物理极限区）后核心空，" | " 前缀也不进（终审 9-1 幻影宽）
        return dwidth(f" | {core}")

    # 让位顺序（穷举搜索，循环序表达优先级；决策 2 调序）：时长 → ahead-behind
    # → 分支六档 → cwd 地板。外层是「更晚牺牲」——with_dur 在最外意味着分支/
    # ab/cwd 全折完仍不够才丢时长；with_ab 提到 floor 外层 = ab 恒在优先于 cwd
    # 地板（旧序 floor 在外层会在 46-51 列带选「地板 16 + 丢 ab」而非「地板 8 +
    # 保 ab」，窗口加宽反而丢 ab、拖动时闪灭——非单调带）。cwd 地板 16→8→4
    # 最先牺牲（提前折短）。窄档 keep_duration 恒 False。
    keep_duration = bool(duration) and not narrow
    b_budget, drop_ab, cwd_floor = 24, False, 16
    found = False
    for with_dur in ([True, False] if keep_duration else [False]):
        for with_ab in ([True, False] if ab else [False]):
            for blen in (24, 20, 16, 12, 8, 4):
                for floor in (16, 8, 4):
                    w = git_w(blen, with_ab) + herdr_w + dwidth(" | agy") \
                        + (dur_w if with_dur else 0) + floor
                    if w <= term_w:
                        b_budget, keep_duration, drop_ab = blen, with_dur, (not with_ab and bool(ab))
                        cwd_floor = floor
                        found = True
                        break
                if found:
                    break
            if found:
                break
        if found:
            break
    if not found:
        # 物理极限区（对齐 cc）：最小配置仍放不下时逐段再丢 git 计数段
        # （dmg 是铁律但物理不可容时最后让位）——dmg 之后才轮到 herdr 坐标，
        # agy 徽标与坐标间至少留 " | agy" 5 格永不钝刀。
        b_budget, drop_ab, keep_duration, cwd_floor = 4, bool(ab), False, 4
        if git_w(b_budget, False) + herdr_w + dwidth(" | agy") + 4 > term_w:
            dmg = dmg_plain = ""
        if git_w(b_budget, False) + herdr_w + dwidth(" | agy") + 4 > term_w:
            b_budget, ab = 0, ""  # git 段整体让位（空时 git_w 已返回 0）
    if drop_ab:
        ab = ""
    rest = git_w(b_budget, bool(ab)) + herdr_w + dwidth(" | agy") + (dur_w if keep_duration else 0)
    # 地板随命中的 floor 走（对齐 cc CR-B：floor=4 命中时仍顶回 8 会让赤字带
    # 整行超宽、truncate 砍行尾 agy 徽标）
    path_budget = max(cwd_floor, term_w - rest)
    display_cwd = fold_path(short_cwd, path_budget)
    # detached HEAD：分支名不显示（设计），ab/dmg 照常——dmg 是铁律。
    # 空判用 strip_ansi(...).strip()（终审 9-1：物理极限区清到 b_budget=0/ab=""/dmg=""
    # 时 colored_git 是纯 ANSI 包裹的空串，.strip() 剥不掉转义 → 判非空 → 行内
    # 幻影 " | " 空槽 + git_w 幻影 3 格偷 cwd 预算——NO_COLOR 用例全绿是因
    # 无色档下 c() 原样返回空串，恰好掩盖）；但赋值必须保留原色串 + lstrip
    # （剥色赋值会把 dmg 三段色码剥掉——cc 同坑已修）。
    colored_git = ((c("purple", fold_branch(branch, b_budget)) if branch else "")
                   + (c("fg", ab) if ab else "") + dmg)
    colored_git = colored_git.lstrip() if strip_ansi(colored_git).strip() else ""
    # 悬空尾：预算内按段拼，超预算按段丢而非钝刀切字符。两遍策略：先按自然序
    # （git→herdr→agy→dur）拼；agy 徽标没进来才换徽标优先序重拼（铁律高于视觉）。
    # 段对 (colored, plain) 同 build2：量宽只看 plain——dwidth 不剥 ANSI。
    def assemble_l1(order):
        line = c("comment", display_cwd)
        used = dwidth(display_cwd)
        for part, part_p in order:
            if used + dwidth(part_p) <= term_w:
                line += part
                used += dwidth(part_p)
        return line

    natural = []
    agy_part = (f" {c('comment', '|')} {c('comment', 'agy')}", " | agy")
    if colored_git:
        natural.append((f" {c('comment', '|')} {colored_git}", f" | {strip_ansi(colored_git)}"))
    if herdr_tag:
        natural.append((f" {c('comment', '|')} {c('comment', herdr_tag)}", f" | {herdr_tag}"))
    natural.append(agy_part)
    if keep_duration:
        natural.append((dur_s, " · " + duration))
    line1 = assemble_l1(natural)
    # 徽标保住判定不能拿子串 "agy" 猜——cwd 折叠后可能恰好含子串 → 误判已
    # 保住、跳过 rescue；assemble 返回行同时报每个 part 是否入选，直接看徽标。
    def assemble_l1_report(order):
        line = c("comment", display_cwd)
        used = dwidth(display_cwd)
        taken = []
        for idx, (part, part_p) in enumerate(order):
            if used + dwidth(part_p) <= term_w:
                line += part
                used += dwidth(part_p)
                taken.append(idx)
        return line, taken

    line1, taken = assemble_l1_report(natural)
    if natural.index(agy_part) not in taken:
        # agy 没保住：agy 最优先重拼（herdr/git 争剩余）
        rescue = [agy_part] + [p for p in natural if p is not agy_part]
        line1 = assemble_l1(rescue)

    # ---- 行2: 账本 | 状态 | 身份 | cost ----
    # 状态组 = ctx%/win + TTFT；身份组 = 模型 · 思考（时长已上行1）。
    # TTFT 读存量：等待期/轮初显示上一轮值（cc/pi/qc 同语义）。
    ttft_s = fmt_ttft(st["ttft_ms"]) if st["ttft_ms"] is not None else ""
    # TTFT 预算宽度用上界常量占位（TTFT 99m59s = 11 格），实际值短只让行偏短、不改变折叠决策
    ttft_budget_s = "TTFT 99m59s"
    pct_val = 0.0
    try:
        pct_val = float(ctx_pct.split("%")[0]) if ctx_pct else 0.0
    except ValueError:
        pass
    pct_name = "green" if pct_val <= 70 else ("yellow" if pct_val <= 90 else "red")

    sep = c("comment", "|")
    # 窄档短形（用户裁定，与 cc 同款）：↑in↓out 去 ↑/↓ 前缀与空格（31.2M/643K）、
    # CH→◈ 前缀、ctx% 整数 + 四分位块高图标（▂0-25 ▄25-50 ▆50-75 █75-100，与
    # 三档色阈值 70/90 解耦——图标说「占了几成」，颜色说「风险等级」，两维正交）、
    # TTFT 换 ⏱ 前缀（计宽按 2 格防御 iOS 表情宽——dwidth 对 U+23F1（EAW=N）只算
    # 1 格，预算串用 ⏱⏱ 双占位补足）、R 窄档不进段表、紧分隔 |。
    if narrow:
        pct_icon = "▂" if pct_val < 25 else ("▄" if pct_val < 50 else ("▆" if pct_val < 75 else "█"))
        ch_s = "◈" + ch[2:] if ch else ch
        ctx_s = f"{pct_icon}{pct_val:.0f}%" if ctx_pct else ""
        ttft_s_n = "⏱" + ttft_s[len("TTFT "):] if ttft_s else ""
        ttft_budget = "⏱⏱99m59s"  # 首个 ⏱ 计真实 1 格，第二个补 iOS 表情宽的第
        # 2 格；99m59s 是 fmt_ttft 的 6 字符上界形，iOS 实显 ⏱2格+6=8 格，
        # 预算按最宽计（对齐 cc CR 三轮：旧 7 格漏第 8 格）
    else:
        ch_s, ctx_s, ttft_s_n, ttft_budget = ch, ctx_pct, ttft_s, ttft_budget_s

    def build2(use_ttft, use_ch, use_cost):
        """按存活段拼行2；返回 (上色串, 预算无色串)。预算串里 TTFT 用上界占位。
        预算串必须全程无色——dwidth 按 char 记宽，混入 ANSI 会让 truecolor
        档预算虚高 ~23 格/段，梯子把不超宽的 TTFT 误丢（色档不得影响折叠）。
        段列表 (colored, plain) 成对收集，出口统一 join——窄/宽档只差分隔符
        与成员（窄档 R 不进、账本短形、紧排 |）。agy 无压缩标记 → 没有 CP 段。"""
        if narrow:
            head_s = head_p = f"{fmt(input_t)}/{fmt(output_t)}"
        else:
            head_s = head_p = f"↑{fmt(input_t)} ↓{fmt(output_t)}"
        segs = [(c("fg", head_s), head_p)]
        ledger = "" if narrow else f"R{fmt(cache_r)}"
        ledger_p = ledger
        if use_ch and ch_s:
            ledger += " " + c("cyan", ch_s) if ledger else c("cyan", ch_s)
            ledger_p += " " + ch_s if ledger_p else ch_s
        if ledger:
            segs.append((ledger, ledger_p))
        stat = stat_p = ""
        if ctx_s:
            stat, stat_p = c(pct_name, ctx_s), ctx_s
        if use_ttft and ttft_s_n:
            t = c(ttft_color(st["ttft_ms"]), ttft_s_n)
            stat = f"{stat} {t}" if stat else t
            stat_p = f"{stat_p} {ttft_budget}" if stat_p else ttft_budget
        if stat:
            segs.append((stat, stat_p))
        # 窄档身份组缩短（用户裁定：⏱ 升铁律后腾格子）：模型名去 [1m] 后缀、
        # 思考等级按 _THINK_SHORT 缩写（未知值保留原样）；宽档原样。
        m_name = model_name.replace("[1m]", "") if narrow else model_name
        t_name = (_THINK_SHORT.get(thinking, thinking) if narrow else thinking)
        ident_c = [c("pink", m_name)] + ([c("cyan", t_name)] if t_name else [])
        if ident_c:  # 窄档身份组也进（用户裁定：模型·思考不可丢）
            segs.append((" · ".join(ident_c),
                         " · ".join([m_name] + ([t_name] if t_name else []))))
        if use_cost and cost_s:
            # 中性色 fg：金额是信息不是告警，不与黄/红/绿这些语义色抢注意力
            segs.append((c("fg", cost_s), cost_s))
        j = "|" if narrow else f" {sep} "   # 窄档紧分隔：3 个分隔省 6 格
        jp = "|" if narrow else " | "        # plain 用无色分隔（预算串全程无色）
        return (j.join(s[0] for s in segs), jp.join(s[1] for s in segs))

    # 折叠梯子: 溢出按序丢弃（宽档 cost→TTFT→CH 新段先丢；窄档 cost→CH——
    # ⏱ 升铁律，与 cc/pi 同步：TTFT 永不剔；R 已不进窄档段表）；
    # 再溢出 truncate_display 兜底
    flags = dict(use_ttft=True, use_ch=True, use_cost=True)
    line2, plain2 = build2(**flags)
    order = ("use_cost", "use_ch") if narrow else ("use_cost", "use_ttft", "use_ch")
    for key in order:
        if dwidth(plain2) <= term_w:
            break
        flags[key] = False
        line2, plain2 = build2(**flags)

    # 出口兜底：折叠只保证「算出来不超宽」，这里保证「输出不超宽」（truncate）。
    # 主动 flush 把断管拉进可捕获域（对齐 cc 猎杀四轮 #6：行短时 write 只进
    # 缓冲，断管在解释器退出 flush 阶段才炸——main 域 try 不到、RC=120）。
    sys.stdout.write(f"{truncate_display(line1, term_w)}\n{truncate_display(line2, term_w)}")
    sys.stdout.flush()


def emit_fallback():
    """最后兜底：两行（短 cwd / agy），不查 git、不碰网络；自己再炸也静默。"""
    if sys.stdout is None:
        return
    try:
        home = str(Path.home())
    except Exception:
        home = os.environ.get("HOME") or ""
    try:
        cwd = _clean_path(os.getcwd()) or "?"
    except Exception:
        cwd = "?"
    line1 = ("~" + cwd[len(home):]) if home and (cwd == home or cwd.startswith(home + "/")) else cwd
    try:
        sys.stdout.write(f"{line1}\nagy")
        sys.stdout.flush()
    except BaseException:
        pass


if __name__ == "__main__":
    # stdout 编码兜底：宿主 locale 可能不是 UTF-8（LC_ALL=C），不兜会让 ↑/◈/⏱
    # 在写出时抛 UnicodeEncodeError → 空输出被 agy 计为失败。
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    # R8：宿主打断（SIGTERM/SIGHUP/SIGINT）时先杀 git 整棵进程树，再输出
    # 兜底两行并 rc=0——既不漏孤儿，也不以信号死亡（agy 不记一次失败）。
    # 平台不支持某个信号时跳过；装处理器失败也绝不能让脚本崩。
    for _sig_name in ("SIGTERM", "SIGHUP", "SIGINT"):
        _sig = getattr(signal, _sig_name, None)
        if _sig is None:
            continue
        try:
            signal.signal(_sig, _on_signal)
        except Exception:
            pass
    try:
        main()
    except BrokenPipeError:
        # 下游早关（| true / >&-）：静默退出（对齐 cc 猎杀四轮 #6）。os._exit
        # 双跳：解释器退出时还会 flush 一次 sys.stdout（再遇断管打噪音且 RC=120），
        # 只有 os._exit 跳过解释器收尾。
        try:
            devnull = os.open(os.devnull, os.O_WRONLY)
            os.dup2(devnull, sys.stdout.fileno())
            sys.stdout = os.fdopen(devnull, "w")  # 换掉缓冲对象，exit flush 落 devnull
        except Exception:
            pass
        os._exit(0)
    except BaseException:
        # 任何异常都退化到两行兜底，rc=0、stderr 为空——agy 连续失败会自动
        # 禁用自定义状态栏，绝不能把 traceback 漏到 stderr。
        try:
            emit_fallback()
        except BaseException:
            pass
        os._exit(0)
