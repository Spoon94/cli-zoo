#!/usr/bin/env python3
# pi-footer 同款 statusline for Claude Code（两行版 v4）
# 布局:
#   行1: ~/cwd | branch ↑a↓b +增 ~删 ✱改
#   行2: ↑in ↓out R cacheR CH% CPn | ctx%/win | 模型名 · 思考等级 · 时长 | ws:tab:pane
# v3 变更: ↑↓0 不隐藏；W0 不跳过；模型名 · 思考等级 · 时长；CP 用 compact_boundary 计数（同 ccstatusline）
# v4 变更: 原生字段优先（context_window/cost/effort/prompt_cache 式 CH）；压缩后 ctx 用
#          compact_boundary.postTokens 重置；transcript 增量解析 + 缓存；git 合成单次调用
# v5 变更: Dracula 主题配色。NO_COLOR=非空 → 裸文本；COLORTERM∈{truecolor,24bit} →
#          truecolor 精确色值；否则 256 色近似（两档均按 pi 宿主的 rgbTo256 算法预计算）。
#          假定深色终端底色（Dracula 为暗底设计，白底下黄/前景/绿/青对比度 <1.5:1 不可读）
import hashlib
import json
import math
import os
import re
import subprocess
import sys
import unicodedata
from pathlib import Path

CACHE_DIR = Path(os.getenv("WREN_CACHE_DIR") or (Path.home() / ".cache" / "wren"))

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
    statusline 的 stdout 接 CC 本体不是 tty，isatty() 恒 false，不能用来判。"""
    if os.environ.get("NO_COLOR"):
        return "none"
    ct = os.environ.get("COLORTERM", "")
    return "truecolor" if ct in ("truecolor", "24bit") else "256"


_C = _color_mode()


def c(name, text):
    """按当前色档给 text 上色；无色档原样返回。"""
    if _C == "none":
        return text
    return f"\033[{_DRACULA[name][0 if _C == 'truecolor' else 1]}m{text}\033[0m"

# ---- 行1 预算常量（上界预留，不随数值抖动，见 docs/wren-ttft-design.md §1.1-2） ----
# 时长按 `dwidth(" · 99h59m")` = 9 格（含 ` · ` 分隔符 3 格）计入 rest；
# TTFT 的预算宽度用上界占位串 `TTFT 99m59s` = 11 格（行2 梯子用）。
DUR_REST_W = 9
TTFT_BUDGET_S = "TTFT 99m59s"

ZERO_STATE = {
    "input_t": 0, "output_t": 0, "cache_r": 0, "cache_w": 0,
    "compactions": 0, "triggers": {"auto": 0, "manual": 0, "unknown": 0},
    "last_prompt_tokens": 0, "last_cache_r": 0,
    "first_ts": None, "effort": "", "post_tokens": None,
    "ttft_ms": None,   # 最近一次真实 user → 首条 assistant 的落盘延迟（ms）
    "turn_user_ts": None,  # 轮窗口：真实 user 记录的时间戳（排除 tool_result）
}


def sh(args):
    try:
        r = subprocess.run(args, capture_output=True, text=True, timeout=3)
        return r.stdout.strip()
    except Exception:
        return ""


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
    if h > 99:  # 钳制：99h59m 之上统一 99h+，预算上界 9 格（设计文档 §1.1-2）
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


def dwidth(s):
    """显示宽度：CJK 全角字符占 2 格（与 pi 侧 visibleWidth 口径一致）。
    只用于折叠预算的计算，不影响输出内容。"""
    w = 0
    for ch in s:
        w += 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1
    return w


def slice_cells(s, maxw, from_end=False):
    """按显示宽取头/尾片段，结果不超过 maxw 格。
    CR 轮 11：预算以格计、切片以码点计，两者混用会让 CJK 段切出两倍预算。"""
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


def one_line(s):
    """压平换行（猎杀四轮 #4）：宿主按行渲染 statusline，字段里的 \\n/\\r/
    Unicode 行界会把 2 行契约顶成 3+ 行。display_name/effort/herdr env 用。"""
    if not isinstance(s, str):
        return s
    return "".join(ch for ch in s if ch not in "\n\r\v\f\x1c\x1d\x1e\x85  ")


def truncate_display(s, maxw):
    """按显示宽度硬截断整行，ANSI 转义原样保留、宽度记 0。
    地位与 pi 侧的 truncateToWidth 相同：折叠公式算偏了也不会溢出。
    CR 轮 11：py 侧原先只有「公式算准」这一条防线，公式一错整行就超宽
    （实测 88 > 80），而 ts 侧有宿主兜底所以天然不犯。"""
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
    """路径折叠：给定预算逐级降级（头2+尾2 → 头1+尾2 → 尾2 → 尾1），末级对尾段字符截断。
    触发按总长，不设段数门槛（CR 轮 9：'段少但段长'的路径在段数门槛下完全不折）。
    返回值保证显示宽 ≤ budget，末级字符截断也按显示格切（CR 轮 11）。"""
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
    # 最后一档仍超：对尾段做字符截断
    last = "…/" + segs[-1]
    if dwidth(last) <= budget:
        return last
    keep = budget - 2  # "…" + 至少 1 格
    if keep < 1:
        return slice_cells(p, max(0, budget))
    return "…" + slice_cells(segs[-1], keep, from_end=True)


def fold_branch(b, max_len=24):
    """分支折叠：max_len 驱动（行1 梯子逐级传 24→20→16→12→8→4）。
    24 档与 qc/pi/oc 三侧同构（head 8 / tail 15，CR 轮 9 的尾重头轻结论）；
    <24 档是 cc 窄档私有档位，头尾三七开（head≈30%、尾吃剩余）。
    CR 轮 11：触发条件与切片都改按显示格，此前 py 按格、ts 按码点，
    13 个汉字的分支（26 格 / 13 码点）在 cc 折、在 pi 不折。"""
    if dwidth(b) <= max_len:
        return b
    if max_len >= 24:  # 宽档默认档：三侧同构 8/15（d0dca44 曾误改三七开致跨实现分叉）
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


def accumulate(st, d):
    """把一条 transcript 记录并入聚合状态。"""
    # 压缩统计: 同 ccstatusline — 数 compact_boundary，排除 sidechain
    if (d.get("type") == "system" and d.get("subtype") == "compact_boundary"
            and d.get("isSidechain") is not True):
        st["compactions"] += 1
        meta = d.get("compactMetadata") or {}
        trig = meta.get("trigger")
        tr = st["triggers"]
        tr[trig if trig in tr else "unknown"] += 1
        post = meta.get("postTokens")
        st["post_tokens"] = post if isinstance(post, int) else None
    # 轮窗口起点：真实 user 记录（排除 tool_result 回填 —— 那种 type=user
    # 但 content 是 tool_result 的记录，取它会测出 0.078s 级的工具往返，不是 TTFT）。
    # 方案 B：新 user 只更新窗口起点，不清旧 ttft_ms —— 轮进行中 statusline
    # 显示的是上一轮已完成的首片延迟，不闪烁；新 assistant 首片落盘时才覆盖。
    if d.get("type") == "user" and d.get("isSidechain") is not True:
        content = (d.get("message") or {}).get("content")
        # 对齐 qc 的 _is_prompt_user：纯 tool_result 回填、空 content、
        # 无 message 字段都不算轮首（后两者 cc 旧版会开一个假窗口，产出
        # 一轮错误 TTFT 后被下次真配对覆盖——F2，交叉评审第三轮）
        if isinstance(content, str):
            opens = bool(content)
        elif isinstance(content, list):
            opens = any(isinstance(x, dict) and x.get("type") != "tool_result" for x in content)
        else:
            opens = False
        if opens:
            t = _epoch(d.get("timestamp"))
            if t is not None:
                st["turn_user_ts"] = t
    if d.get("type") == "assistant" and "message" in d:
        m = d["message"]
        u = m.get("usage", {}) or {}

        def tok(key):
            """token 字段净化（猎杀四轮 #1）：json.loads 接受非标 NaN/Infinity，
            直接累加会让 fmt 的 round() 抛 ValueError/OverflowError 走裸 cwd；
            负数/非数（str/dict/bool）一律当 0。"""
            v = u.get(key, 0)
            if isinstance(v, bool) or not isinstance(v, (int, float)):
                return 0
            if isinstance(v, float) and not math.isfinite(v):
                return 0
            return v if v > 0 else 0

        st["input_t"] += tok("input_tokens")
        st["output_t"] += tok("output_tokens")
        st["cache_r"] += tok("cache_read_input_tokens")
        st["cache_w"] += tok("cache_creation_input_tokens")
        st["last_prompt_tokens"] = (tok("input_tokens")
                                    + tok("cache_read_input_tokens")
                                    + tok("cache_creation_input_tokens"))
        st["last_cache_r"] = tok("cache_read_input_tokens")
        st["post_tokens"] = None  # 压缩后已有真实请求 → postTokens 过期
        # TTFT：本轮首条 assistant 落盘 − 本轮真实 user 提交。首片常为 thinking 块，
        # 所以这是「首片延迟」语义（含 thinking 耗时），不是严格首 token。
        # 一轮只配一次对：配对完成后 turn_user_ts 清零，同轮后续 assistant
        # （tool_use 续片等）不再改写 ttft_ms。
        t_a = _epoch(d.get("timestamp") or m.get("timestamp"))
        if t_a is not None and st["turn_user_ts"] is not None and t_a >= st["turn_user_ts"]:
            st["ttft_ms"] = int((t_a - st["turn_user_ts"]) * 1000)
            st["turn_user_ts"] = None
        e = d.get("effort")
        if isinstance(e, str) and e:  # 非字符串当缺失（猎杀四轮 #2，与 stdin 侧同守）
            st["effort"] = e
        if st["first_ts"] is None:
            ts = d.get("timestamp") or m.get("timestamp")
            if ts:
                from datetime import datetime
                try:
                    st["first_ts"] = datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp()
                except Exception:
                    pass


def scan_transcript(path):
    """按字节 offset 续读 transcript，聚合结果缓存到 $WREN_CACHE_DIR（默认 ~/.cache/wren）下的 <hash>.json。"""
    st = dict(ZERO_STATE)
    st["triggers"] = dict(ZERO_STATE["triggers"])
    try:
        size = os.path.getsize(path)
    except OSError:
        return st

    cache_file = CACHE_DIR / f"{hashlib.sha1(str(path).encode()).hexdigest()[:16]}.json"
    offset = 0
    if cache_file.exists():
        try:
            old = json.loads(cache_file.read_text())
        except Exception:
            old = None
        # offset 毒型（猎杀四轮 #5：str "50"/float 6.5 会让比较或 seek 抛
        # TypeError，崩在缓存重写之前 → 毒文件永不清除、每次渲染裸 cwd）：
        # 只认 int（bool 排除），非法即全量重算并覆写。
        old_off = old.get("offset") if isinstance(old, dict) else None
        if (isinstance(old, dict) and old.get("path") == str(path)
                and isinstance(old_off, int) and not isinstance(old_off, bool)
                and 0 <= old_off <= size):
            offset = old_off
            for k in st:
                if k in old:
                    st[k] = old[k]

    try:
        with open(path, "rb") as fh:
            fh.seek(offset)
            chunk = fh.read()
    except (OSError, TypeError, ValueError):
        return st

    cut = chunk.rfind(b"\n")  # 末尾可能写了一半，留在下次
    st["path"] = str(path)
    st["offset"] = offset + cut + 1 if cut >= 0 else offset
    if cut < 0:
        return st
    chunk = chunk[:cut + 1]
    # 按 \n 切而不是 splitlines()（猎杀四轮 #3）：splitlines 按 Unicode 全套行界
    # 切（U+2028/2029/0085），用户粘贴含行分隔符的网页/JS 文本时（CC 落盘
    # ensure_ascii=False 原样写）半行 json.loads 失败被吞 → 记录静默丢失、
    # token 永久少记。JSONL 的行界只有 \n。
    for line in chunk.decode("utf-8", "ignore").split("\n"):
        try:
            accumulate(st, json.loads(line))
        except Exception:
            continue

    try:
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
        tmp = cache_file.with_suffix(".tmp")
        tmp.write_text(json.dumps(st))
        tmp.replace(cache_file)
    except Exception:
        pass
    return st


def main():
    data = json.load(sys.stdin)
    dump = os.getenv("WREN_DEBUG_DUMP")
    if dump:
        try:
            Path(dump).write_text(json.dumps(data, ensure_ascii=False, indent=2))
        except Exception:
            pass

    cwd = data.get("cwd", os.getcwd())
    model = data.get("model", {})
    raw = model.get("display_name") or model.get("id", "?")
    # 尾斜杠（"prefix/"）切出空段会留悬空 | 尾（Bug 猎杀 #4）；空则回落 "?"；
    # 换行压平（猎杀四轮 #4：注入 \n 会顶飞 2 行契约）
    model_name = one_line(raw).split("/")[-1] or "?"

    # 上下文窗口 / 最近一次请求用量: 优先原生字段（context_window.current_usage 在
    # /compact 后为 null，正是需要用 compactMetadata.postTokens 兜底的时候）
    cw = data.get("context_window") or {}
    cu = cw.get("current_usage") or {}
    # 窗口净化（猎杀五轮 B-qc-2 的 cc 同款洞）：NaN/Infinity 会让 fmt 的
    # int() 炸（native_prompt>0 时触发）。非法回落默认窗。
    _cw_size = cw.get("context_window_size")
    ctx_window = _cw_size if (isinstance(_cw_size, int) and _cw_size > 0) else (1_000_000 if "[1m]" in model_name else 200_000)
    native_prompt = native_cache_r = 0
    if cu:
        # 同 tok() 纪律（猎杀五轮）：stdin native usage 的 NaN/Infinity 同炸
        _nt = lambda k: (lambda v: v if isinstance(v, (int, float)) and not isinstance(v, bool)
                         and (not isinstance(v, float) or math.isfinite(v)) and v > 0 else 0)(cu.get(k, 0))
        native_prompt = _nt("input_tokens") + _nt("cache_read_input_tokens") + _nt("cache_creation_input_tokens")
        native_cache_r = _nt("cache_read_input_tokens")

    transcript = data.get("transcript_path", "")

    home = str(Path.home())
    # 家目录折叠只锚定路径前缀（Bug 猎杀 #3：无锚 replace 会把
    # /Users/spoon<x>… 的兄弟目录错折成 ~<x>…，显示不存在的路径）
    short_cwd = ("~" + cwd[len(home):]) if cwd == home or cwd.startswith(home + "/") else cwd

    # ---- git: 单次 porcelain v2（branch + ahead/behind + 增/删/改） ----
    branch, ab, dmg, dmg_plain = "", "", "", ""
    stg = sh(["git", "-C", cwd, "status", "--porcelain=v2", "--branch"])
    if stg:
        added = modified = deleted = 0
        for ln in stg.splitlines():
            if ln.startswith("# branch.head "):
                head = ln[len("# branch.head "):].strip()
                # detached 判定：porcelain v2 的 detached 形态是字面 "(detached)"；
                # 以 "(" 开头的真实分支名（合法创建）不误伤。dmg/ab 不随 branch
                # 空而丢（Bug 猎杀 #2：旧把 dmg 门控在 branch 下，detached 的
                # 脏树计数整段消失，违反「dmg 铁律」）。
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
        # 同时留一份无色文本：dwidth 不剥 ANSI，拿上色串量宽度会把转义字节算进去，
        # 同一个路径在色开/色关下就折出不同结果（CR 轮 11 实测 62 vs 79）。
        parts, plain_parts = [], []
        for mark, name, count in (("+", "green", added), ("~", "red", deleted), ("✱", "yellow", modified)):
            if count:
                plain_parts.append(f"{mark}{count}")
                parts.append(c(name, f"{mark}{count}"))
        dmg = " " + " ".join(parts) if parts else ""
        dmg_plain = " " + " ".join(plain_parts) if plain_parts else ""

    # ---- herdr 位置 ----
    herdr_parts = [one_line(os.getenv("HERDR_WORKSPACE_ID") or ""),
                   one_line((os.getenv("HERDR_TAB_ID") or "").split(":")[-1]),
                   one_line((os.getenv("HERDR_PANE_ID") or "").split(":")[-1])]
    herdr_tag = f"{':'.join(p for p in herdr_parts if p)}" if any(herdr_parts) else ""

    # ---- token / 压缩统计（增量解析） ----
    st = scan_transcript(transcript) if transcript else dict(ZERO_STATE)
    input_t, output_t, cache_r = st["input_t"], st["output_t"], st["cache_r"]
    compactions, compact_triggers = st["compactions"], st["triggers"]

    # 上下文占用: 原生 → 压缩后 postTokens → transcript 末次请求
    if native_prompt > 0:
        ctx_tokens, ctx_cache_r = native_prompt, native_cache_r
    elif st["post_tokens"]:
        ctx_tokens, ctx_cache_r = st["post_tokens"], 0
    else:
        ctx_tokens, ctx_cache_r = st["last_prompt_tokens"], st["last_cache_r"]

    ctx_pct = ""
    if ctx_tokens > 0:
        ctx_pct = f"{ctx_tokens / ctx_window * 100:.2f}%/{fmt(ctx_window)}"

    # CH 与 ctx% 的数据源脱钩：CH 永远取「最近一次请求」的缓存效率 ——
    # native 优先，否则 transcript 末次（压缩后就是压缩前那次，显示旧值而非消失；
    # 与 pi 内置 footer 的压缩后语义一致：ctx% 怕误导走 "?"，CH 描述的是上次
    # 请求的效率，旧值仍是最新真实测量，压缩后首请求会自我修正）。
    ch_prompt, ch_cache = (native_prompt, native_cache_r) if native_prompt > 0 \
        else (st["last_prompt_tokens"], st["last_cache_r"])
    ch = f"CH{ch_cache / ch_prompt * 100:.2f}%" if ch_prompt > 0 and ch_cache > 0 else ""

    # 时长: 原生 cost.total_duration_ms → 回退 transcript 首条时间（cc 侧是宿主实测）。
    # json.load 接受非标 Infinity（isinstance 过、int(inf) 抛 OverflowError 走裸 cwd
    # 降级——Bug 猎杀 #6）；isfinite 同时挡 ±inf 与 nan。
    duration = ""
    total_ms = (data.get("cost") or {}).get("total_duration_ms")
    if isinstance(total_ms, (int, float)) and total_ms > 0 and math.isfinite(total_ms):
        duration = fmt_duration(int(total_ms))
    elif st["first_ts"]:
        import time
        duration = fmt_duration(int((time.time() - st["first_ts"]) * 1000))

    # TTFT（首片延迟）：transcript 配对的真实 user → 首条 assistant，含 thinking
    ttft = fmt_ttft(st["ttft_ms"]) if st["ttft_ms"] is not None else ""

    # effort.level 非字符串（int 等）会让 " · ".join 抛 TypeError 走裸 cwd
    # 降级（Bug 猎杀 #5）——非字符串一律当缺失；换行压平（猎杀四轮 #4）。
    thinking = (data.get("effort") or {}).get("level")
    thinking = one_line(thinking) if isinstance(thinking, str) else ""
    thinking = thinking or one_line(st["effort"])

    # ---- 行1: 目录 + git + herdr 位置（Dracula: 灰底座 + 紫分支 + 增删改三色） ----
    # dmg 的 +/~/✱ 三段在 git 解析处已各自上色；分支（紫）与 ab（白）在行1
    # 梯子处按预算拼装（下方 b_budget 驱动），此处不预拼。
    # 行1 尾的宿主徽标：同屏多个 agent 时区分 CC / pi（词汇表复用 wren install 的目标名）。
    # 长路径/长分支折叠：行1 是信息密度最低的行，溢出时优先压缩它保住行2 和徽标。
    # CC 宿主对超宽行是直接砍尾，不折叠的话丢的是 herdr/徽标段。
    # 宽度来源：CC 的 stdin JSON 不带终端宽度 → COLUMNS 有则用，无则 80 兜底
    # （CR 轮 9：与 pi 侧 render(width) 同一套折叠规则，只是宽度来源不同宿主）
    try:
        term_w = int(os.environ.get("COLUMNS") or 80)
    except ValueError:
        term_w = 80
    # 窄档（≤55 列；移动端 herdr 会把 pane PTY 拖成 51 列）：CC 给 statusline 的
    # 实绘宽 ≈ COLUMNS−5（左缩进 2 + 尾部留白/省略号），预算按实绘宽收，否则满宽
    # 输出被宿主钝刀切尾、先丢的总是行尾徽标与身份组。窄档行2 按用户裁定取舍：
    # R/CP 丢（低频里程数）、CH 两位小数原样、TTFT 换秒表图标 ⏱（计宽按 2 格
    # 防御 iOS 表情宽）、ctx% 简化整数、模型·思考保、分隔符紧排（| 不带空格）——
    # 铁律项全在时 44 格，51 列实绘 46 格内放得下。
    narrow = term_w <= 55
    if narrow:
        # 地板不再钳 24（Bug 猎杀后续：钳 24 让 COLUMNS<29 的行按 24 格排版/截断，
        # 实际输出超终端宽 9 格，宿主切行换行炸版）。钳 4 = 段级丢段可工作的最小值。
        term_w = max(4, term_w - 5)
    # 行1 梯子（宽窄档统一，用户裁定）：永不丢 dmg / herdr 坐标 / cc 徽标；
    # 溢出让位顺序（CR 三轮实测）：ahead-behind → 分支六档折叠
    # （24→20→16→12→8→4，… 省略中段，用户裁定「分支长度压缩」）→ 时长
    # → cwd 折叠（头尾 … 省略，「目录长度压缩」）。所有段都有 … 化路径，
    # 无整段消失，无 truncate 钝刀（物理极限区除外）。
    dur_s = f" {c('comment', '·')} {c('fg', duration)}" if duration else ""
    dur_w = DUR_REST_W if duration else 0
    herdr_w = dwidth(f" | {herdr_tag}") if herdr_tag else 0

    def git_w(blen, with_ab):
        """git 段宽度探针：按「分支折叠后真实宽度」计，不按档位上界虚记
        （虚记会把 21 格短分支也多折一级，CR 实测 fea…tier）。git 段各件
        全空时返回 0——line1 只在 colored_git 非空时渲染该段（含 " | " 前缀），
        非 git cwd 若仍记 3 格幻影宽，目录预算被偷（CR 实测 rest 19 vs 17）。"""
        if not (branch or ab or dmg_plain):
            return 0
        return dwidth(f" | {fold_branch(branch, blen) if branch else ''}"
                     f"{ab if with_ab else ''}{dmg_plain}")

    # 让位顺序（穷举搜索，靠循环序表达优先级）：时长 → 分支六档 → ab → cwd
    # 地板 16→8→4。注意循环序的语义：外层是「更晚牺牲」——with_dur 在第二层
    # 意味着分支六档与 ab 全折完仍不够才丢时长（CR 三轮实测序：ab 先于分支
    # 压缩消失，时长最后丢；与注释的历史版本相反，此处以实测为准）。
    # cwd 地板 8/4 = "…/尾段截断"（用户裁定「目录长度压缩」优先于丢铁律段）。
    # ≤31 列极端叠加为物理极限区，交 truncate 兜底。
    keep_duration = bool(duration) and not narrow  # 窄档裁定不渲染时长
    b_budget, drop_ab, cwd_floor = 24, False, 16
    found = False
    for floor in (16, 8, 4):
        for with_dur in ([True, False] if keep_duration else [False]):
            for blen in (24, 20, 16, 12, 8, 4):
                for with_ab in ([True, False] if ab else [False]):
                    w = git_w(blen, with_ab) + herdr_w + dwidth(" | cc") \
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
        # 物理极限区（实测 ASCII 坐标 24-37 列 / CJK 坐标 24-42 列，Bug 猎杀 #1）：
        # 最小配置（分支 4 档、丢 ab/时长、cwd 地板 4）仍放不下时，逐段再丢
        # git 计数段（dmg 是铁律但物理不可容时最后让位）——顺序 dmg 之后才轮到
        # herdr 坐标，cc 徽标与坐标间至少留 " | cc" 5 格永不钝刀。
        b_budget, drop_ab, keep_duration, cwd_floor = 4, bool(ab), False, 4
        if git_w(b_budget, False) + herdr_w + dwidth(" | cc") + 4 > term_w:
            dmg = dmg_plain = ""
        if git_w(b_budget, False) + herdr_w + dwidth(" | cc") + 4 > term_w:
            b_budget, ab = 0, ""  # git 段整体让位（空时 git_w 已返回 0）
    if drop_ab:
        ab = ""
    rest = git_w(b_budget, bool(ab)) + herdr_w + dwidth(" | cc") + (dur_w if keep_duration else 0)
    # 地板随命中的 floor 走（子代理 CR-B）：floor=4 命中时若仍顶回 8，赤字带整行
    # 超宽、truncate 砍行尾 cc 徽标（56 列实测）；!found 时地板 4（最小配置的一部分）。
    path_budget = max(cwd_floor, term_w - rest)
    display_cwd = fold_path(short_cwd, path_budget)
    # detached HEAD：分支名不显示（设计），ab/dmg 照常——dmg 是铁律
    colored_git = ((c("purple", fold_branch(branch, b_budget)) if branch else "")
                   + (c("fg", ab) if ab else "") + dmg)
    colored_git = colored_git.lstrip() if colored_git.strip() else ""
    # Bug 猎杀 #1 悬空尾：预算内就按段拼，超预算按段丢而非钝刀切字符——
    # 尾分隔符永远跟着它的段走，不孤立。两遍策略：先按自然序（git→herdr→cc→dur，
    # 徽标收尾的常规视觉）拼；cc 徽标没进来才换 cc 优先序重拼（铁律高于视觉，
    # 24 列实测自然序下 herdr 在前把 cc 挤出预算）。段对 (colored, plain) 同
    # build2：量宽只看 plain——dwidth 不剥 ANSI，拿带色段量宽会让 truecolor
    # 每段虚记 ~24 格、段全被误丢（T45 实测复犯）。
    def assemble_l1(order):
        line = c("comment", display_cwd)
        used = dwidth(display_cwd)
        for part, part_p in order:
            if used + dwidth(part_p) <= term_w:
                line += part
                used += dwidth(part_p)
        return line

    natural = []
    cc_part = (f" {c('comment', '|')} {c('comment', 'cc')}", " | cc")
    if colored_git:
        natural.append((f" {c('comment', '|')} {colored_git}", f" | {strip_ansi(colored_git)}"))
    if herdr_tag:
        natural.append((f" {c('comment', '|')} {c('comment', herdr_tag)}", f" | {herdr_tag}"))
    natural.append(cc_part)
    if keep_duration:
        natural.append((dur_s, " · " + duration))
    line1 = assemble_l1(natural)
    # 徽标保住判定不能拿子串 "cc" 猜（CR 交叉审 T2：cwd=/tmp/acc 会误判已保住、
    # 跳过 rescue）——assemble 返回行同时报每个 part 是否入选，直接看徽标本身。
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
    if natural.index(cc_part) not in taken:
        # cc 没保住：cc 最优先重拼（herdr/git 争剩余）
        rescue = [cc_part] + [p for p in natural if p is not cc_part]
        line1 = assemble_l1(rescue)

    # ---- 行2: 账本 | 状态 | 身份 ----
    # 组间 |、组内空格；仅尾部身份组用 ·。状态组 = ctx%/win + TTFT。
    # 与 qc/pi 同一套「段列表 + 逐段剔」：丢序 TTFT → CH → CP（新段先丢），
    # 永不剔除 ↑in↓out / ctx% / 模型名。
    pct_val = 0.0
    if ctx_pct:
        try:
            pct_val = float(ctx_pct.split("%")[0])
        except ValueError:
            pct_val = 0.0
    pct_name = "green" if pct_val <= 70 else ("yellow" if pct_val <= 90 else "red")
    sep = c("comment", "|")
    cp_s = f"CP{compactions}" if compactions else ""
    # 窄档短形（用户裁定）：↑in↓out 去 ↑/↓ 前缀与空格（31.2M/643K）、CH 前缀
    # CH→◈、ctx% 整数 + 四分位块高图标（▂0-25 ▄25-50 ▆50-75 █75-100，等宽
    # 四分位=几何体积，与三档色阈值（70/90）解耦——图标说「占了几成」，颜色说
    # 「风险等级」，两维信息正交；块元素族 U+2580 终端渲染最稳）、TTFT 换 ⏱
    # 前缀。三段图标 EAW=N/A 不触发 iOS emoji；◈/块高按实显 1 格，
    # ⏱ 按 2 格防御 iOS 表情宽——dwidth 对 U+23F1（EAW=N）只算 1 格，
    # 预算串用 ⏱⏱ 双占位补足（CR 实证单格口径双向出错）；R/CP 窄档不进段表。
    if narrow:
        pct_icon = "▂" if pct_val < 25 else ("▄" if pct_val < 50 else ("▆" if pct_val < 75 else "█"))
        ch_s = "◈" + ch[2:] if ch else ch
        ctx_s = f"{pct_icon}{pct_val:.0f}%" if ctx_pct else ""
        ttft_s = "⏱" + ttft[len("TTFT "):] if ttft else ""
        ttft_budget = "⏱⏱""99m59s"  # 首个 ⏱ 计真实 1 格，第二个补 iOS 表情宽的
        # 第 2 格；99m59s 是 fmt_ttft 的 6 字符上界形（59m59s/99h00m 同宽），
        # iOS 实显 ⏱2格+6=8 格，预算按最宽计（CR 三轮：旧 7 格漏第 8 格）
    else:
        ch_s, ctx_s, ttft_s, ttft_budget = ch, ctx_pct, ttft, TTFT_BUDGET_S

    def build2(use_ttft, use_ch, use_cp):
        """按存活段拼行2；返回 (上色串, 预算无色串)。预算串里 TTFT 用上界占位。
        预算串必须全程无色——dwidth 按 char 记宽，混入 ANSI 会让 truecolor
        档预算虚高 ~23 格/段，梯子把不超宽的 TTFT 误丢（色档不得影响折叠）。"""
        # 段列表（colored, plain）成对收集，出口统一 join——窄/宽档只差分隔符
        # 与成员（窄档 R/CP 不进、账本短形、紧排 |），不再各写一套拼接分支。
        # 窄档账本短形（用户裁定「in out 可简化」）：去 ↑/↓ 前缀与中间空格，
        # 31.2M/643K 用 / 分向（12 格 → 10 格），方向靠位置约定：/ 前 in 后 out。
        if narrow:
            head_s, head_p = f"{fmt(input_t)}/{fmt(output_t)}", f"{fmt(input_t)}/{fmt(output_t)}"
        else:
            head_s = head_p = f"↑{fmt(input_t)} ↓{fmt(output_t)}"
        segs = []
        segs.append((c("fg", head_s), head_p))
        ledger = "" if narrow else f"R{fmt(cache_r)}"
        ledger_p = ledger
        if use_ch and ch_s:
            ledger += " " + c("cyan", ch_s) if ledger else c("cyan", ch_s)
            ledger_p += " " + ch_s if ledger_p else ch_s
        if use_cp and cp_s and not narrow:
            ledger += " " + c("comment", cp_s)
            ledger_p += " " + cp_s
        if ledger:
            segs.append((ledger, ledger_p))
        stat = stat_p = ""
        if ctx_s:
            stat, stat_p = c(pct_name, ctx_s), ctx_s
        if use_ttft and ttft_s:
            t = c(ttft_color(st["ttft_ms"]), ttft_s)
            stat = f"{stat} {t}" if stat else t
            stat_p = f"{stat_p} {ttft_budget}" if stat_p else ttft_budget
        if stat:
            segs.append((stat, stat_p))
        ident_c = [c("pink", model_name)] + ([c("cyan", thinking)] if thinking else [])
        if ident_c:  # 窄档身份组也进（用户裁定：模型·思考不可丢）
            segs.append((" · ".join(ident_c),
                         " · ".join([model_name] + ([thinking] if thinking else []))))
        j = "|" if narrow else f" {sep} "   # 窄档紧分隔：3 个分隔省 6 格
        jp = "|" if narrow else " | "        # plain 用无色分隔（预算串必须全程无色）
        return (j.join(s[0] for s in segs), jp.join(s[1] for s in segs))

    # 折叠梯子: 溢出按序丢弃（宽档 TTFT→CH→CP 新段先丢；窄档 CP→TTFT→CH，
    # 保住独有指标）；再溢出 truncate_display 兜底
    flags = dict(use_ttft=True, use_ch=True, use_cp=True)
    line2, plain2 = build2(**flags)
    order = ("use_cp", "use_ttft", "use_ch") if narrow else ("use_ttft", "use_ch", "use_cp")
    for key in order:
        if dwidth(plain2) <= term_w:
            break
        flags[key] = False
        line2, plain2 = build2(**flags)

    # 出口兜底：折叠只保证「算出来不超宽」，这里保证「输出不超宽」。
    # 与 pi 侧 render 里的 truncateToWidth 同一地位。
    # 猎杀四轮 #6 收尾：行短时 write 只进缓冲，断管在解释器退出 flush 阶段
    # （TextIOWrapper.__del__）才炸——main 域 try 不到、顶层 except 接不住，
    # RC=120 + stderr 噪音。这里主动 flush 把 BrokenPipeError 拉进可捕获域。
    sys.stdout.write(f"{truncate_display(line1, term_w)}\n{truncate_display(line2, term_w)}")
    sys.stdout.flush()


if __name__ == "__main__":
    try:
        main()
    except BrokenPipeError:
        # 下游早关（| true / >&-）：静默退出（猎杀四轮 #6——此前顶层兜底
        # 会再 write 一次 None/断管 stdout，RC=1 + traceback 上 stderr）。
        # os._exit 双跳：解释器退出时还会 flush 一次 sys.stdout（再遇断管
        # 打 "Exception ignored ... BrokenPipeError" 且 RC=120），只有
        # os._exit 跳过解释器收尾。
        try:
            devnull = os.open(os.devnull, os.O_WRONLY)
            os.dup2(devnull, sys.stdout.fileno())
            sys.stdout = os.fdopen(devnull, "w")  # 换掉缓冲对象，exit flush 落 devnull
        except Exception:
            pass
        os._exit(0)
    except Exception:
        # statusline 宁可退化也不能空/挂住。stdout 为 None（>&-）时
        # 兜底自己别再炸（同猎杀 #6：AttributeError → RC1 + traceback）
        if sys.stdout is not None:
            try:
                sys.stdout.write(os.getcwd().replace(str(Path.home()), "~"))
            except Exception:
                pass
