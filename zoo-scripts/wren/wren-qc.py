#!/usr/bin/env python3
# wren for Qoder CLI（两行版 v5-dracula，与 wren.py / wren.ts 逐字同构）
# 布局:
#   行1: ~/cwd | branch ↑a↓b +增 ~删 ✱改 | ws:tab:pane | qc
#   行2: ↑in ↓out | R cacheR CH% CPn | ctx%/win | 模型名 · 思考等级 · 时长
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
#   - 思考等级:    transcript 的 runtime-config 记录（真实 payload 无顶层字段，
#                 顶层 / model.preferences 路径仅作兼容保留）
#   - 时长:       cost.total_duration_ms（宿主目前不发送）→ 回落 transcript 首条时间戳
#   - 宿主徽标:   qc
#
# 色板/降级与两侧一致：NO_COLOR → 裸文本；COLORTERM∈{truecolor,24bit} → truecolor；否则 256。
# 假定深色终端底色（Dracula 为暗底设计）。
import hashlib
import json
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
    return f"{h}h{(s % 3600)//60}m" if h > 0 else f"{s//60}m"


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
    """分支折叠：超长截中段，尾重头轻（head 8 / tail 15，均按显示格计）。"""
    if dwidth(b) <= max_len:
        return b
    return slice_cells(b, 8) + "…" + slice_cells(b, 15, from_end=True)


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
        if e:
            st["effort"] = e
    if d.get("type") == "assistant" and "message" in d:
        m = d["message"]
        u = m.get("usage", {}) or {}
        st["input_t"] += u.get("input_tokens", 0)
        st["output_t"] += u.get("output_tokens", 0)
        st["cache_r"] += u.get("cache_read_input_tokens", 0)
        # cache_creation 可能是对象（ephemeral_5m/1h），与旧 qoder 脚本同口径
        cw_v = u.get("cache_creation_input_tokens", 0)
        if not cw_v:
            cc = u.get("cache_creation")
            if isinstance(cc, dict):
                cw_v = (cc.get("ephemeral_5m_input_tokens") or 0) + (cc.get("ephemeral_1h_input_tokens") or 0)
        st["cache_w"] += cw_v or 0
        # qoder 的 input_tokens 已含 cache → prompt 直接取 input_tokens；
        # 若某版本不含（input 明显小于 cache_r），补回 CC 口径
        inp = u.get("input_tokens", 0)
        cr = u.get("cache_read_input_tokens", 0)
        st["last_prompt_tokens"] = inp if inp >= cr else (inp + cr + (cw_v or 0))
        st["last_cache_r"] = cr
        st["post_tokens"] = None  # 压缩后已有真实请求 → postTokens 过期
        e = d.get("effort")
        if e:
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
    """按字节 offset 续读 transcript，聚合结果缓存到 $WREN_CACHE_DIR 下的 <hash>.json。"""
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
        # offset 超出当前长度 = 文件被重建，从头再来
        if isinstance(old, dict) and old.get("path") == str(path) and 0 <= old.get("offset", 0) <= size:
            offset = old["offset"]
            for k in st:
                if k in old:
                    st[k] = old[k]

    try:
        with open(path, "rb") as fh:
            fh.seek(offset)
            chunk = fh.read()
    except OSError:
        return st

    cut = chunk.rfind(b"\n")  # 末尾可能写了一半，留在下次
    st["path"] = str(path)
    st["offset"] = offset + cut + 1 if cut >= 0 else offset
    if cut < 0:
        return st
    chunk = chunk[:cut + 1]
    for line in chunk.decode("utf-8", "ignore").splitlines():
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


def thinking_level(data, tr_effort, model_id):
    """思考等级：顶层 reasoningEffort → model.preferences[id].reasoning.effort → transcript。"""
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
    return e or tr_effort or ""


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
    raw_name = model_obj.get("display_name") or model_id or "no-model"
    model_name = raw_name.split("/")[-1].replace(" Model", "").strip() or "no-model"

    cw = data.get("context_window") or {}
    win = cw.get("context_window_size") or (1_000_000 if "[1m]" in model_name else 200_000)
    # ctx% 数据源：原生 used_percentage 优先；缺失时 total_input_tokens 本身就是
    # 当前上下文占用（qoder 文档注明非累计），可直接当分子
    native_pct = cw.get("used_percentage")
    ctx_native_tokens = cw.get("total_input_tokens") or 0
    cu = cw.get("current_usage") or {}   # 兼容 CC 式字段（qoder 不提供时为空）
    native_prompt = native_cache_r = 0
    if cu:
        native_prompt = (cu.get("input_tokens", 0) + cu.get("cache_read_input_tokens", 0)
                         + cu.get("cache_creation_input_tokens", 0))
        native_cache_r = cu.get("cache_read_input_tokens", 0)

    transcript = data.get("transcript_path", "")

    home = str(Path.home())
    short_cwd = cwd.replace(home, "~")

    # ---- git: 单次 porcelain v2（branch + ahead/behind + 增/删/改） ----
    branch, ab, dmg, dmg_plain = "", "", "", ""
    stg = sh(["git", "-C", cwd, "status", "--porcelain=v2", "--branch"])
    if stg:
        added = modified = deleted = 0
        for ln in stg.splitlines():
            if ln.startswith("# branch.head "):
                head = ln[len("# branch.head "):].strip()
                branch = "" if head.startswith("(") else head  # detached 不显示
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
    colored_git = ""
    if branch:
        colored_git = c("purple", fold_branch(branch, 24)) + c("fg", ab) + dmg

    # ---- herdr 位置 ----
    herdr_parts = [os.getenv("HERDR_WORKSPACE_ID"),
                   (os.getenv("HERDR_TAB_ID") or "").split(":")[-1],
                   (os.getenv("HERDR_PANE_ID") or "").split(":")[-1]]
    herdr_tag = f"{':'.join(p for p in herdr_parts if p)}" if any(herdr_parts) else ""

    # ---- token / 压缩统计（增量解析） ----
    st = scan_transcript(transcript) if transcript else dict(ZERO_STATE)
    # ↑in/↓out：transcript 累计（qoder 原生字段不是累计量，见文件头注释）
    input_t, output_t, cache_r = st["input_t"], st["output_t"], st["cache_r"]
    compactions = st["compactions"]

    # 上下文占用: 原生 used_percentage → 压缩后 postTokens → transcript 末次请求
    ctx_pct = ""
    if isinstance(native_pct, (int, float)):
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

    # 时长: 原生 cost.total_duration_ms → 回退 transcript 首条时间
    duration = ""
    total_ms = (data.get("cost") or {}).get("total_duration_ms")
    if isinstance(total_ms, (int, float)) and total_ms > 0:
        duration = fmt_duration(int(total_ms))
    elif st["first_ts"]:
        import time
        duration = fmt_duration(int((time.time() - st["first_ts"]) * 1000))

    thinking = thinking_level(data, st["effort"], model_id)

    # ---- 行1 ----
    try:
        term_w = int(os.environ.get("COLUMNS") or 80)
    except ValueError:
        term_w = 80
    rest = 0
    if branch:
        rest += dwidth(f" | {fold_branch(branch, 24)}{ab}{dmg_plain}")
    if herdr_tag:
        rest += dwidth(f" | {herdr_tag}")
    rest += dwidth(" | qc")
    path_budget = max(16, term_w - rest)
    display_cwd = fold_path(short_cwd, path_budget)
    line1 = (c("comment", display_cwd)
             + (f" {c('comment', '|')} {colored_git}" if colored_git else "")
             + (f" {c('comment', '|')} {c('comment', herdr_tag)}" if herdr_tag else "")
             + f" {c('comment', '|')} {c('comment', 'qc')}")

    # ---- 行2 ----
    sep = c("comment", "|")
    tok_group2 = f"R{fmt(cache_r)}"
    if ch:
        tok_group2 += " " + c("cyan", ch)
    if compactions:
        tok_group2 += " " + c("comment", f"CP{compactions}")
    tok = f"{c('fg', f'↑{fmt(input_t)} ↓{fmt(output_t)}')} {sep} {tok_group2}"
    right_parts = [c("pink", model_name)]
    if thinking:
        right_parts.append(c("cyan", thinking))
    if duration:
        right_parts.append(c("fg", duration))
    colored_ctx = ""
    if ctx_pct:
        try:
            pct_val = float(ctx_pct.split("%")[0])
        except ValueError:
            pct_val = 0.0
        pct_name = "green" if pct_val <= 70 else ("yellow" if pct_val <= 90 else "red")
        colored_ctx = f" {sep} " + c(pct_name, ctx_pct)
    line2 = tok + colored_ctx + f" {sep} " + " · ".join(right_parts)

    sys.stdout.write(f"{truncate_display(line1, term_w)}\n{truncate_display(line2, term_w)}")


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # statusline 宁可退化也不能空/挂住
        sys.stdout.write(os.getcwd().replace(str(Path.home()), "~"))
