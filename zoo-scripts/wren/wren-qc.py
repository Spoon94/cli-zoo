#!/usr/bin/env python3
# wren for Qoder CLI（两行版 v6-dracula，与 wren.py / wren.ts 逐字同构）
# 布局:
#   行1: ~/cwd | branch ↑a↓b +增 ~删 ✱改 | ws:tab:pane | qc · 时长
#   行2: ↑in ↓out | R cacheR CH% CPn | ctx%/win TTFT | 模型名 · 思考等级
#
# 与 wren.py（Claude Code 侧）的差异只有数据来源，渲染/配色/折叠规则完全一致：
#   - cwd:        workspace.current_dir 优先，回退 cwd（CC 只有 cwd）
#   - ↑in/↓out:   transcript 累计（与 wren.py 同源同式。qoder 原生
#                 total_input_tokens 是「最近一次请求」的上下文占用，官方文档
#                 明确 NOT a session total；total_output_tokens 宿主从不发送，
#                 两者都不能当累计用）
#   - ctx%:       context_window.used_percentage 原生给出（整数）；缺失回落
#                 total_input_tokens（= 当前占用）→ postTokens → transcript 末次请求
#   - CH:         **qoder 的 usage.input_tokens 已含 cache**，故 CH = cache_read / input_tokens，
#                 不能套 wren.py 的 read/(input+read+write)（那是 CC 的口径）
#   - TTFT:       本轮首条落盘 assistant.ts − 同轮真 user.ts（排除 tool_result
#                 回填的 type:user 记录，否则测到的是工具往返）。口径=落盘延迟
#                 （含 thinking 整段耗时），见 docs/wren-ttft-design.md §2
#   - 思考等级:    transcript 的 runtime-config 记录（真实 payload 无顶层字段，
#                 顶层 / model.preferences 路径仅作兼容保留）
#   - 时长:       transcript 推算的会话年龄（首条记录 ts → now；宿主不发
#                 total_duration_ms）。v6 上移行1 尾与徽标合并，预算按 9 格
#                 上界常量（dwidth(" · 99h59m")），超界先丢时长退裸徽标
#   - 宿主徽标:   qc · 时长
#   - 折叠梯子:   行2 溢出按 TTFT→CH→CP 丢弃（新段先丢），TTFT 预算按 11 格
#                 上界常量（TTFT 99m59s），折叠决策不随数值抖动；truncate_display 兜底
# 色板/降级与两侧一致：NO_COLOR → 裸文本；COLORTERM∈{truecolor,24bit} → truecolor；否则 256。
# 假定深色终端底色（Dracula 为暗底设计）。
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
    "input_t": 0, "output_t": 0, "cache_r": 0, "cache_w": 0,
    "compactions": 0, "triggers": {"auto": 0, "manual": 0, "unknown": 0},
    "last_prompt_tokens": 0, "last_cache_r": 0,
    "first_ts": None, "effort": "", "post_tokens": None,
    # TTFT：ttft_ms 是配对成功时落下的存量（等待期/新轮显示上一轮旧值，
    # 与 cc/pi、CH 压缩后同语义）；turn_* 两字段只作配对，不参与渲染
    "ttft_ms": None, "turn_user_ts": None, "turn_first_ts": None,
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


def _is_prompt_user(d):
    """真用户提示才算轮首：tool_result 回填也是 type=user，不重开窗口。
    空串 content 不算轮首（猎杀七轮 BUG6，对齐 cc F2：bool(content)）——
    否则空消息记录 + 5s 后 assistant 会凭空显示一个 TTFT。"""
    m = d.get("message") or {}
    ct = m.get("content")
    if isinstance(ct, str):
        return bool(ct)
    if isinstance(ct, list):
        return any(isinstance(b, dict) and b.get("type") != "tool_result" for b in ct)
    return False


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


def one_line(s):
    """压平换行（对齐 cc 猎杀四轮 #4）：宿主按行渲染 statusline，字段里的
    \\n/\\r/Unicode 行界会把 2 行契约顶成 3+ 行。display_name/effort/herdr 用。"""
    if not isinstance(s, str):
        return s
    return "".join(ch for ch in s if ch not in "\n\r\v\f\x1c\x1d\x1e\x85\u2028\u2029")


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


def accumulate(st, d):
    """把一条 transcript 记录并入聚合状态。"""
    # 压缩统计: 数 compact_boundary，排除 sidechain
    if (d.get("type") == "system" and d.get("subtype") == "compact_boundary"
            and d.get("isSidechain") is not True):
        st["compactions"] += 1
        meta = d.get("compactMetadata") or {}
        trig = meta.get("trigger")
        tr = st["triggers"]
        tr[trig if trig in tr else "unknown"] += 1
        post = meta.get("postTokens")
        st["post_tokens"] = post if isinstance(post, int) else None
    # qoder 的 runtime-config 记录里带 reasoningEffort（CC 没有这种记录类型）
    if d.get("type") == "runtime-config":
        e = d.get("reasoningEffort")
        if not e:
            gen = d.get("generation") or {}
            r = gen.get("reasoning")
            if isinstance(r, dict):
                e = r.get("effort")
        if isinstance(e, str) and e:  # 非字符串当缺失（对齐 cc 猎杀四轮 #2）
            st["effort"] = one_line(e)
    if d.get("type") == "user" and _is_prompt_user(d) and d.get("isSidechain") is not True:
        # 轮首：真 user 提示开窗（tool_result 回填不开，见 _is_prompt_user）。
        # turn_first_ts 不在这里清——保留上一轮已完成配对，直到新一轮首片
        # 落盘才被覆盖；等待期渲染读 ttft_ms 存量显示旧值（方案 B，不闪烁）
        uts = _epoch(d.get("timestamp"))
        if uts is not None:
            st["turn_user_ts"] = uts
    if d.get("type") == "assistant" and "message" in d:
        m = d["message"]
        u = m.get("usage", {}) or {}

        def tok(v):
            """token 字段净化（对齐 cc 猎杀四轮 #1）：json.loads 接受非标
            NaN/Infinity，直接累加会让 fmt 的 round() 抛 ValueError/OverflowError
            走裸 cwd；负数/非数（str/dict/bool）一律当 0。"""
            if isinstance(v, bool) or not isinstance(v, (int, float)):
                return 0
            if isinstance(v, float) and not math.isfinite(v):
                return 0
            return v if v > 0 else 0

        st["input_t"] += tok(u.get("input_tokens", 0))
        st["output_t"] += tok(u.get("output_tokens", 0))
        st["cache_r"] += tok(u.get("cache_read_input_tokens", 0))
        # cache_creation 可能是对象（ephemeral_5m/1h），与旧 qoder 脚本同口径
        cw_v = tok(u.get("cache_creation_input_tokens", 0))
        if not cw_v:
            cc_obj = u.get("cache_creation")
            if isinstance(cc_obj, dict):
                cw_v = tok(cc_obj.get("ephemeral_5m_input_tokens") or 0) \
                    + tok(cc_obj.get("ephemeral_1h_input_tokens") or 0)
        st["cache_w"] += cw_v
        # qoder 的 input_tokens 已含 cache → prompt 直接取 input_tokens；
        # 若某版本不含（input 明显小于 cache_r），补回 CC 口径
        inp = tok(u.get("input_tokens", 0))
        cr = tok(u.get("cache_read_input_tokens", 0))
        st["last_prompt_tokens"] = inp if inp >= cr else (inp + cr + cw_v)
        st["last_cache_r"] = cr
        st["post_tokens"] = None  # 压缩后已有真实请求 → postTokens 过期
        e = d.get("effort")
        if isinstance(e, str) and e:  # 非字符串当缺失（对齐 cc 猎杀四轮 #2）
            st["effort"] = one_line(e)
        ats = _epoch(d.get("timestamp") or m.get("timestamp"))
        if st["first_ts"] is None and ats is not None:
            st["first_ts"] = ats
        # TTFT 窗口：本轮首条落盘 assistant 定 first_ts（含 thinking 的落盘延迟）。
        # 窗口开着 = 尚无与当前 turn_user_ts 配对的首片——上一轮的 turn_first_ts
        # 仍留着但比新 user_ts 旧，所以用比较判开，而不是清空标志。配对成功即把
        # 差值落进 ttft_ms 存量，等待期（新轮开窗、首片未落）渲染读存量显示
        # 上一轮值，与 cc/pi 同语义；派生不进渲染路径
        if (st["turn_user_ts"] is not None and ats is not None
                and (st["turn_first_ts"] is None or st["turn_first_ts"] < st["turn_user_ts"])):
            st["turn_first_ts"] = ats
            if ats >= st["turn_user_ts"]:
                st["ttft_ms"] = int((ats - st["turn_user_ts"]) * 1000)


def scan_transcript(path):
    """按字节 offset 续读 transcript，聚合结果缓存到 $WREN_CACHE_DIR 下的 <hash>.json。"""
    st = dict(ZERO_STATE)
    st["triggers"] = dict(ZERO_STATE["triggers"])
    try:
        size = os.path.getsize(path)
    except OSError:
        return st

    # 缓存键掺宿主标识（猎杀七轮 BUG5）：cc/qc 共用 ~/.cache/wren 且此前键同为
    # sha1(path)[:16]——同一 transcript 两宿主先后读，后读方继承先写方的
    # last_prompt_tokens 语义（两宿主 CH 口径不同，实测 80.39%→44.57%）。
    # 键格式：qc-<sha1(path)[:16]>.json（cc 侧对齐为 cc-<同式>）
    cache_file = CACHE_DIR / f"qc-{hashlib.sha1(str(path).encode()).hexdigest()[:16]}.json"
    offset = 0
    if cache_file.exists():
        try:
            old = json.loads(cache_file.read_text())
        except Exception:
            old = None
        # offset 毒型（对齐 cc 猎杀四轮 #5：str "50"/float 6.5 会让比较或 seek 抛
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
    # 按 \n 切而不是 splitlines()（对齐 cc 猎杀四轮 #3）：splitlines 按 Unicode
    # 全套行界切（U+2028/2029/0085），transcript 里的 JSON 字符串含这些字符时
    # 半行 json.loads 失败被吞 → 记录静默丢失、token 永久少记。JSONL 行界只有 \n。
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
        # 缓存清扫（决策 3）：目录里 .json 超过 200 个时按 mtime 删最旧的
        # （cc-*/qc-*/旧无前缀死文件三种都盖——模式就是全部 *.json）。
        # try 域内失败不影响渲染（本块整体在 except pass 下）。
        entries = [e for e in CACHE_DIR.iterdir() if e.suffix == ".json"]
        if len(entries) > 200:
            for e in sorted(entries, key=lambda x: x.stat().st_mtime)[:len(entries) - 200]:
                e.unlink(missing_ok=True)
    except Exception:
        pass
    return st


def thinking_level(data, tr_effort, model_id):
    """思考等级：顶层 reasoningEffort → model.preferences[id].reasoning.effort → transcript。
    出口 isinstance(str) 净化（猎杀五轮 B-qc-1：prefs/顶层 reasoning 的 effort
    非字符串时 join 抛 TypeError 走裸 cwd——transcript 路径已守，stdin 两路漏）。"""
    prefs = ((data.get("model") or {}).get("preferences") or {}).get(model_id) or {}
    r = prefs.get("reasoning") or {}
    if r.get("enabled") is False:
        return ""
    e = r.get("effort")
    for key in ("reasoningEffort", "effort", "reasoning"):
        v = data.get(key)
        if isinstance(v, str) and v:
            e = e or v
            break
        if isinstance(v, dict):
            e = e or v.get("effort") or v.get("level")
            break
    e = e if isinstance(e, str) else ""
    return one_line(e or tr_effort or "")


def main():
    raw = sys.stdin.read()
    dump = os.getenv("WREN_DEBUG_DUMP")
    if dump:
        try:
            Path(dump).write_text(raw)
        except Exception:
            pass
    try:
        data = json.loads(raw) if raw.strip() else {}
    except json.JSONDecodeError:
        data = {}

    # qoder 把工作目录放在 workspace.current_dir；回退 cwd
    cwd = ((data.get("workspace") or {}).get("current_dir")
           or data.get("cwd") or os.getcwd())

    model_obj = data.get("model") or {}
    model_id = model_obj.get("id") or ""
    # one_line 先压平换行再切尾斜杠/后缀（对齐 cc 猎杀四轮 #4：注入 \n 会顶飞
    # 2 行契约）；空则回落 no-model
    raw_name = one_line(model_obj.get("display_name") or model_id) or "no-model"
    model_name = raw_name.split("/")[-1].replace(" Model", "").strip() or "no-model"

    cw = data.get("context_window") or {}
    # 窗口净化（猎杀五轮 B-qc-2）：json.loads 接受非标 NaN/Infinity，
    # used_percentage 在时 fmt(win) → int(nan) ValueError 走裸 cwd。非法回落默认窗。
    _win = cw.get("context_window_size")
    win = _win if (isinstance(_win, int) and _win > 0) else (1_000_000 if "[1m]" in model_name else 200_000)
    # ctx% 数据源净化（交叉审 Q1/Q2，对齐 cc 的 _nt 纪律）：注释此前声称盖了
    # used_percentage，实际只守了窗口大小。json.loads 接受非标 NaN/Infinity/负数/
    # 字符串（'500' 直接比较会 TypeError 走裸 cwd），逐项过 _num——非法一律当
    # 缺失走回落链；负 used_percentage 同判无效（Q2：不渲染 '▂-5%'）
    def _num(v):
        return v if (isinstance(v, (int, float)) and not isinstance(v, bool)
                     and (not isinstance(v, float) or math.isfinite(v)) and v > 0) else 0
    native_pct = _num(cw.get("used_percentage")) or None
    ctx_native_tokens = _num(cw.get("total_input_tokens"))
    cu = cw.get("current_usage") or {}   # 兼容 CC 式字段（qoder 不提供时为空）
    native_prompt = native_cache_r = 0
    if isinstance(cu, dict) and cu:
        native_prompt = (_num(cu.get("input_tokens", 0)) + _num(cu.get("cache_read_input_tokens", 0))
                         + _num(cu.get("cache_creation_input_tokens", 0)))
        native_cache_r = _num(cu.get("cache_read_input_tokens", 0))

    transcript = data.get("transcript_path", "")

    home = str(Path.home())
    # 家目录折叠只锚定路径前缀（对齐 cc Bug 猎杀 #3：无锚 replace 会把
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
    herdr_parts = [one_line(os.getenv("HERDR_WORKSPACE_ID") or ""),
                   one_line((os.getenv("HERDR_TAB_ID") or "").split(":")[-1]),
                   one_line((os.getenv("HERDR_PANE_ID") or "").split(":")[-1])]
    herdr_tag = f"{':'.join(p for p in herdr_parts if p)}" if any(herdr_parts) else ""

    # ---- token / 压缩统计（增量解析） ----
    st = scan_transcript(transcript) if transcript else dict(ZERO_STATE)
    # ↑in/↓out：transcript 累计（qoder 原生字段不是累计量，见文件头注释）
    input_t, output_t, cache_r = st["input_t"], st["output_t"], st["cache_r"]
    compactions = st["compactions"]

    # 上下文占用: 原生 used_percentage → 压缩后 postTokens → transcript 末次请求
    # native_pct 已过 _num 净化（Q1/Q2）：非法/非正当 None，走回落链
    ctx_pct = ""
    if native_pct is not None:
        ctx_pct = f"{native_pct:.2f}%/{fmt(win)}"
    else:
        if ctx_native_tokens > 0:
            ctx_tokens = ctx_native_tokens
        elif st["post_tokens"]:
            ctx_tokens = st["post_tokens"]
        else:
            ctx_tokens = st["last_prompt_tokens"]
        if ctx_tokens > 0:
            ctx_pct = f"{ctx_tokens / win * 100:.2f}%/{fmt(win)}"

    # CH: 最近一次请求的缓存效率。qoder 的 input_tokens 已含 cache，
    # 故 prompt 直接用 last_prompt_tokens（accumulate 里已按含/不含自适应）
    ch_prompt, ch_cache = st["last_prompt_tokens"], st["last_cache_r"]
    if native_prompt > 0:
        ch_prompt, ch_cache = native_prompt, native_cache_r
    ch = f"CH{ch_cache / ch_prompt * 100:.2f}%" if ch_prompt > 0 and ch_cache > 0 else ""

    # 时长 = transcript 推算的会话年龄（首条记录 ts → now；宿主不发
    # total_duration_ms，语义见设计文档 §1.1-3）
    duration = ""
    if st["first_ts"]:
        import time
        duration = fmt_duration(int((time.time() - st["first_ts"]) * 1000))

    thinking = thinking_level(data, st["effort"], model_id)

    # ---- 行1 ----
    # 宽度探测链（终审十轮·任务 3）：qoder 宿主执行 statusLine.command 时不把
    # 终端宽放进 COLUMNS 环境变量（1.1.65 二进制实证：payload 无宽度字段、
    # spawn env 原样继承宿主进程环境、无任何注入），stdout 又是管道 isatty 恒
    # false。权威通道不存在 → COLUMNS env 有则用；无则读控制终端
    # （os.ctermid()，statusline 由 pane 内 qodercli 拉起、控制终端即 pane PTY）；
    # 都失败兜底 80。
    term_w = 80
    try:
        _w = int(os.environ.get("COLUMNS") or 0)
        if _w > 0:
            term_w = _w
        else:
            try:
                _fd = os.open(os.ctermid(), os.O_RDONLY)
                try:
                    _sz = os.get_terminal_size(_fd)
                    if _sz.columns > 0:
                        term_w = _sz.columns
                finally:
                    os.close(_fd)
            except OSError:
                pass
    except ValueError:
        pass
    # 窄档默认关闭（用户裁定：qoder 宿主拉起 statusline 时不给任何宽度通道——
    # COLUMNS 不传、控制终端不继承、fd 全管道，探针实测 /dev/tty ENXIO——
    # 探测链永远兜底 80，窄档在真身进程不可达）。代码与测试保留（T109/T140
    # 显式设 COLUMNS 驱动），等 qoder 官方给 statusline payload 加宽度字段后
    # 删掉本开关即恢复。显式开关：WREN_QC_NARROW=1 强制按 COLUMNS 判档。
    narrow = (os.environ.get("WREN_QC_NARROW") == "1") and term_w <= 55
    if narrow:
        # 地板不钳 24（对齐 cc：钳 24 会让 COLUMNS<29 的行按 24 格排版、实际
        # 超终端宽。钳 4 = 段级丢段可工作的最小值）
        term_w = max(4, term_w - 5)
    # 行1 梯子（宽窄档统一，与 cc 同一条）：永不丢 dmg / herdr 坐标 / qc 徽标；
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
                    w = git_w(blen, with_ab) + herdr_w + dwidth(" | qc") \
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
        # qc 徽标与坐标间至少留 " | qc" 5 格永不钝刀。
        b_budget, drop_ab, keep_duration, cwd_floor = 4, bool(ab), False, 4
        if git_w(b_budget, False) + herdr_w + dwidth(" | qc") + 4 > term_w:
            dmg = dmg_plain = ""
        if git_w(b_budget, False) + herdr_w + dwidth(" | qc") + 4 > term_w:
            b_budget, ab = 0, ""  # git 段整体让位（空时 git_w 已返回 0）
    if drop_ab:
        ab = ""
    rest = git_w(b_budget, bool(ab)) + herdr_w + dwidth(" | qc") + (dur_w if keep_duration else 0)
    # 地板随命中的 floor 走（对齐 cc CR-B：floor=4 命中时仍顶回 8 会让赤字带
    # 整行超宽、truncate 砍行尾 qc 徽标）
    path_budget = max(cwd_floor, term_w - rest)
    display_cwd = fold_path(short_cwd, path_budget)
    # detached HEAD：分支名不显示（设计），ab/dmg 照常——dmg 是铁律。
    # 空判用 strip_ansi(...).strip()（终审 9-1：物理极限区清到 b_budget=0/ab=""/dmg=""
    # 时 colored_git 是纯 ANSI 包裹的空串，.strip() 剥不掉转义 → 判非空 → 行内
    # 幻影 " | " 空槽 + git_w 幻影 3 格偷 cwd 预算——NO_COLOR 用例全绿是因
    # 无色档下 c() 原样返回空串，恰好掩盖）；但赋值必须保留原色串 + lstrip
    # （剥色赋值会把 dmg 三段色码剥掉，T55 真色档断言直接红——cc 同坑已修）。
    colored_git = ((c("purple", fold_branch(branch, b_budget)) if branch else "")
                   + (c("fg", ab) if ab else "") + dmg)
    colored_git = colored_git.lstrip() if strip_ansi(colored_git).strip() else ""
    # 悬空尾：预算内按段拼，超预算按段丢而非钝刀切字符。两遍策略：先按自然序
    # （git→herdr→qc→dur）拼；qc 徽标没进来才换 qc 优先序重拼（铁律高于视觉）。
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
    qc_part = (f" {c('comment', '|')} {c('comment', 'qc')}", " | qc")
    if colored_git:
        natural.append((f" {c('comment', '|')} {colored_git}", f" | {strip_ansi(colored_git)}"))
    if herdr_tag:
        natural.append((f" {c('comment', '|')} {c('comment', herdr_tag)}", f" | {herdr_tag}"))
    natural.append(qc_part)
    if keep_duration:
        natural.append((dur_s, " · " + duration))
    line1 = assemble_l1(natural)
    # 徽标保住判定不能拿子串 "qc" 猜（猎杀七轮 BUG1：cwd=/tmp/xqc 折叠后
    # '…qc' 含子串 → 误判已保住、跳过 rescue，24 列实测丢徽标）——
    # assemble 返回行同时报每个 part 是否入选，直接看徽标本身（对齐 cc 7ee3794）。
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
    if natural.index(qc_part) not in taken:
        # qc 没保住：qc 最优先重拼（herdr/git 争剩余）
        rescue = [qc_part] + [p for p in natural if p is not qc_part]
        line1 = assemble_l1(rescue)

    # ---- 行2: 账本 | 状态 | 身份 ----
    # 状态组 = ctx%/win + TTFT；身份组 = 模型 · 思考（时长已上行1）。
    # TTFT 读存量：等待期/轮初显示上一轮值（cc/pi 同语义）。
    # 旧缓存只有配对字段没有 ttft_ms（v6 早期形态）→ 现场回填一次
    if (st["ttft_ms"] is None and st["turn_first_ts"] is not None
            and st["turn_user_ts"] is not None
            and st["turn_first_ts"] >= st["turn_user_ts"]):
        st["ttft_ms"] = int((st["turn_first_ts"] - st["turn_user_ts"]) * 1000)
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
    cp_s = f"CP{compactions}" if compactions else ""
    # 窄档短形（用户裁定，与 cc 同款）：↑in↓out 去 ↑/↓ 前缀与空格（31.2M/643K）、
    # CH→◈ 前缀、ctx% 整数 + 四分位块高图标（▂0-25 ▄25-50 ▆50-75 █75-100，与
    # 三档色阈值 70/90 解耦——图标说「占了几成」，颜色说「风险等级」，两维正交；
    # qc 的 ctx 数据源是原生 used_percentage 整数优先，图标按四分位算）、TTFT
    # 换 ⏱ 前缀（计宽按 2 格防御 iOS 表情宽——dwidth 对 U+23F1（EAW=N）只算
    # 1 格，预算串用 ⏱⏱ 双占位补足）、R/CP 窄档不进段表、紧分隔 |。
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

    def build2(use_ttft, use_ch, use_cp):
        """按存活段拼行2；返回 (上色串, 预算无色串)。预算串里 TTFT 用上界占位。
        预算串必须全程无色——dwidth 按 char 记宽，混入 ANSI 会让 truecolor
        档预算虚高 ~23 格/段，梯子把不超宽的 TTFT 误丢（色档不得影响折叠）。
        段列表 (colored, plain) 成对收集，出口统一 join——窄/宽档只差分隔符
        与成员（窄档 R/CP 不进、账本短形、紧排 |）。"""
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
        if use_cp and cp_s and not narrow:
            ledger += " " + c("comment", cp_s)
            ledger_p += " " + cp_s
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
        j = "|" if narrow else f" {sep} "   # 窄档紧分隔：3 个分隔省 6 格
        jp = "|" if narrow else " | "        # plain 用无色分隔（预算串全程无色）
        return (j.join(s[0] for s in segs), jp.join(s[1] for s in segs))

    # 折叠梯子: 溢出按序丢弃（宽档 TTFT→CH→CP 新段先丢；窄档 CP→CH——
    # ⏱ 升铁律，与 cc/pi 同步：TTFT 永不剔；R/CP 已不进段表，CP 空操作）；
    # 再溢出 truncate_display 兜底
    flags = dict(use_ttft=True, use_ch=True, use_cp=True)
    line2, plain2 = build2(**flags)
    order = ("use_cp", "use_ch") if narrow else ("use_ttft", "use_ch", "use_cp")
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


if __name__ == "__main__":
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
    except Exception:
        # statusline 宁可退化也不能空/挂住。stdout 为 None（>&-）时兜底自己别再炸
        if sys.stdout is not None:
            try:
                sys.stdout.write(os.getcwd().replace(str(Path.home()), "~"))
            except Exception:
                pass
