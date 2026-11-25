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
# 运行时预算（R9）：硬墙钟 3.0s，自**进程创建**起算（含 sh / pyenv shim /
# 解释器启动）——agy 的 runner 实测约 5.0s SIGKILL 并从进程创建起算，且新触发
# 会静默 SIGKILL 上一条还在跑的命令。setitimer 看门狗到点杀 git、输出兜底两行、
# rc=0，永远抢在宿主之前；连续 30 次失败会自动禁用状态栏。
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

# ---- 运行时预算（R9）----
# 宿主实测（agy 1.5.13 真机探针）：约 5.0s SIGKILL，且从**进程创建**起算
# （含 sh / pyenv shim / 解释器启动）。所以硬墙钟必须从进程创建时刻算，
# 由 setitimer 看门狗执行（不依赖各阶段传参），git 超时比 cc/qc 的 3s 短。
HARD_LIMIT_S = 3.0        # 自进程创建起算；宿主约 5.0s SIGKILL，留 ~2s 余量
STDIN_TIMEOUT_S = 1.0     # 以下四个是各阶段软上限，实际取 min(软上限, 剩余预算)
GIT_TIMEOUT_S = 1.5
SCAN_BUDGET_S = 1.0
REAP_TIMEOUT_S = 1.0
SLOW_LOG_WAIT_S = 0.25    # 慢日志最多拖住退出这么久；日志卡死也照常出两行并退出
STARTUP_MAX_S = 60.0      # 状态栏进程活不过宿主的 5s；超过这个数的「启动耗时」只可能是量错了
_IMPORT_EPOCH = time.time()


def _linux_start_ticks(stat_bytes):
    """/proc/<pid>/stat 的 starttime（第 22 字段，自开机起的 clock tick）。
    comm 字段可能含空格与括号，所以从**最后一个** ')' 之后切分。返回 int 或 None。"""
    try:
        fields = stat_bytes.rsplit(b")", 1)[1].split()
        return int(fields[19])   # 第 3 字段是 state，starttime 是其后第 20 个
    except Exception:
        return None


def _proc_start_epoch():
    """本进程的创建时刻（epoch 秒）；取不到返回 None。
    Darwin: proc_pidinfo(PROC_PIDTBSDINFO) 尾部是 pbi_start_tvsec / pbi_start_tvusec，
            但结构体长度随 macOS 版本变过（SDK 头 128B/tvsec@112，Darwin 24 实测 136B/tvsec@120），
            所以不写死偏移，在尾部按「像 epoch 秒、后一个 u64 像微秒」找。
    Linux: /proc/self/stat 第 22 字段 starttime（自开机起的 clock tick）与 /proc/uptime 相减。"""
    import struct
    try:
        sysname = os.uname().sysname
        now = time.time()
        if sysname == "Darwin":
            import ctypes
            lib = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
            lib.proc_pidinfo.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64,
                                         ctypes.c_void_p, ctypes.c_int]
            lib.proc_pidinfo.restype = ctypes.c_int
            buf = ctypes.create_string_buffer(512)
            n = lib.proc_pidinfo(os.getpid(), 3, 0, buf, 512)      # 3 = PROC_PIDTBSDINFO
            if n < 32:
                return None
            for off in range((n - 16) & ~7, max(-1, n - 64), -8):
                sec, usec = struct.unpack_from("<QQ", buf.raw, off)
                if now - 86400 <= sec <= now + 2 and usec < 2_000_000:
                    return sec + usec / 1e6
            return None
        if sysname == "Linux":
            with open("/proc/self/stat", "rb") as fh:
                ticks = _linux_start_ticks(fh.read())
            with open("/proc/uptime") as fh:
                uptime = float(fh.read().split()[0])
            if ticks is None:
                return None
            return now - (uptime - ticks / os.sysconf("SC_CLK_TCK"))
    except Exception:
        pass
    return None


def _sane_since(s):
    """进程年龄合理性：0 <= s <= STARTUP_MAX_S 才采信，否则 None（当作量不到，
    退回 import 时刻）。状态栏进程活不过宿主的约 5 秒，算出超过 60 秒的年龄只
    可能是量错了。Linux 侧 /proc/uptime 与 starttime 的时钟域是否一致（休眠时间
    是否计入）随内核版本而异，本项目没有在真实 Linux 上验证过；这道上界是防御性
    加固，避免万一算错时每一帧都判定预算耗尽、只出兜底两行。"""
    try:
        ok = 0 <= s <= STARTUP_MAX_S
    except TypeError:
        ok = False
    return s if ok else None


# 模块级（import 时算一次）：解释器 + shim 的启动耗时（R9 的核心输入）。
_PROC_START = _proc_start_epoch()
_since = _sane_since(time.time() - _PROC_START) if _PROC_START is not None else None
if _since is None:
    _PROC_START = None
_STARTUP_S = _since if _PROC_START is not None else 0.0

# 阶段耗时记账（慢运行日志用）；_PHASE 由 main 在进入各阶段时更新，
# _PHASE_T0 是该阶段的起点（看门狗中途触发时由 _close_phase 结算）。
_T = {"stdin": 0.0, "scan": 0.0, "git": 0.0}
_PHASE = "startup"
_PHASE_T0 = None
_F = {"git_skipped": False, "git_timeout": False,
      "stdin_timeout": False, "scan_budget_hit": False}
_TRANSCRIPT_KIND = 0   # 0=payload 没有 transcript_path；1=有但不是普通文件；2=普通文件


def _hard_limit_s():
    """硬墙钟：默认 HARD_LIMIT_S；WREN_AGY_HARD_LIMIT（秒）可覆盖并钳在
    [0.2, 4.0]；非法/非有限值回落 3.0（测试专用，正常用户不设）。"""
    raw = os.environ.get("WREN_AGY_HARD_LIMIT")
    if not raw:
        return HARD_LIMIT_S
    try:
        v = float(raw)
    except (TypeError, ValueError):
        return HARD_LIMIT_S
    if not math.isfinite(v):
        return HARD_LIMIT_S
    return min(4.0, max(0.2, v))


def _start_epoch():
    """预算起点：能读到进程创建时刻就用它（含 shim/解释器启动）；否则退回
    模块 import 时刻（与 R8 及更早的行为等价，不更差）。"""
    return _PROC_START if _PROC_START is not None else _IMPORT_EPOCH


def _since_start():
    return time.time() - _start_epoch()


def remaining():
    return _hard_limit_s() - _since_start()


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


def _write_slow_log(path, body):
    """慢日志原子写：临时文件带 pid（同一目录下并发帧不会互相截断同名 tmp），
    os.replace 保证读者只看到完整的旧文件或完整的新文件。失败时尽力清掉
    临时文件并返回 False，交给调用方回落。"""
    tmp = path.with_name("%s.%d.tmp" % (path.name, os.getpid()))
    try:
        tmp.write_text(body, encoding="utf-8")
        os.replace(str(tmp), str(path))
        return True
    except Exception:
        try:
            tmp.unlink()
        except Exception:
            pass
        return False


def _log_slow(reason):
    """慢运行日志：一行 JSON 追加到 CACHE_DIR/agy-slow.log（目录不可写时退到
    系统临时目录）；超过 40 行只留最后 40 行。字段不含任何路径/邮箱。
    日志失败绝不影响输出（全程 try/except）。
    注意：这里可能阻塞（日志位置是 FIFO / 文件系统卡死），只经
    _log_slow_async 在收尾阶段带超时调用。"""
    try:
        rec = {
            "ts": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
            "reason": reason,
            "phase": _PHASE,
            "since_start": round(_since_start(), 3),
            "startup": round(_STARTUP_S, 3),
            "stdin": round(_T["stdin"], 3),
            "scan": round(_T["scan"], 3),
            "git": round(_T["git"], 3),
            "py": "%d.%d.%d" % sys.version_info[:3],
            "transcript": _TRANSCRIPT_KIND,
            "git_skipped": bool(_F["git_skipped"]),
            "git_timeout": bool(_F["git_timeout"]),
            "stdin_timeout": bool(_F["stdin_timeout"]),
            "scan_budget_hit": bool(_F["scan_budget_hit"]),
        }
        line = json.dumps(rec, ensure_ascii=True)
        try:
            CACHE_DIR.mkdir(parents=True, exist_ok=True)
            path = CACHE_DIR / "agy-slow.log"
        except Exception:
            path = None
        try:
            old = (path.read_text(encoding="utf-8", errors="replace").splitlines()
                   if path is not None else [])
        except Exception:
            old = []
        body = "\n".join((old + [line])[-40:]) + "\n"
        if path is not None and _write_slow_log(path, body):
            return
        import tempfile
        alt = Path(tempfile.gettempdir()) / "wren-agy-slow.log"
        if alt != path:
            _write_slow_log(alt, body)
    except Exception:
        pass


def _log_slow_async(reason):
    """慢日志不得拖住退出：日志线程最多等 SLOW_LOG_WAIT_S 秒，超时照常往下走
    （daemon 线程随 os._exit 一起消失）。只在收尾阶段调用——git 跑起来之前
    不能有线程（preexec_fn 在多线程下不安全）。"""
    try:
        import threading          # subprocess 已经 import 过，这里不付启动成本
        t = threading.Thread(target=_log_slow, args=(reason,), daemon=True)
        t.start()
        t.join(SLOW_LOG_WAIT_S)
    except Exception:
        pass


def _maybe_log_slow():
    """正常运行收尾时的触发条件：慢启动、接近墙钟，或任一阶段降级。"""
    if (_since_start() >= 1.5 or _STARTUP_S >= 1.0 or _F["git_skipped"]
            or _F["git_timeout"] or _F["stdin_timeout"] or _F["scan_budget_hit"]):
        _log_slow_async("slow")


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
        p.communicate(timeout=min(REAP_TIMEOUT_S, max(0.05, remaining())))
    except Exception:
        pass


def _pdeathsig():
    """Linux：wren 被 SIGKILL 时内核连带杀掉 git 本体（PR_SET_PDEATHSIG）。
    macOS 没有等价机制（README 如实注明）。任何异常都不能影响 git 启动。"""
    try:
        import ctypes
        ctypes.CDLL(None).prctl(1, signal.SIGKILL, 0, 0, 0)   # PR_SET_PDEATHSIG
    except Exception:
        pass


def _git_child_setup(timeout):
    """fork 出来的子进程里、exec git 之前跑（Popen 的 preexec_fn）。两道保险：
    - 所有 POSIX：alarm(int(timeout) + 1)，1.5s 软超时 → 2s。定时器跨 exec 保留、
      处置恢复默认（终止）。父进程被 SIGKILL 时没人再替 git 收尾，它到点自己死，
      不会成为孤儿。必须大于传给 sh() 的软超时：父进程活着时永远由父进程先杀，
      alarm 只是父进程已死时的兜底。
    - Linux：PR_SET_PDEATHSIG —— 父进程一死内核立即带走 git（比 alarm 更快）。
    任何异常都不能影响 git 启动。preexec_fn 只在单线程进程里安全：本脚本的线程
    只在收尾阶段（git 之后）才起，这个前提不要破坏。"""
    try:
        signal.alarm(max(1, int(timeout) + 1))
    except Exception:
        pass
    try:
        if os.uname().sysname == "Linux":
            _pdeathsig()
    except Exception:
        pass


def sh(args, timeout=3):
    """单次外部命令（git）。Popen + 独立会话：超时/异常先杀整棵树再返回 ""。
    正常路径返回值语义不变（stdout.strip()）。子进程 exec 前挂 alarm 兜底
    （父进程被宿主 SIGKILL 后 git 到点自灭），Linux 另有 parent-death signal。"""
    global _GIT
    p = None
    try:
        kwargs = {"start_new_session": True} if hasattr(os, "killpg") else {}
        kwargs["preexec_fn"] = lambda: _git_child_setup(timeout)
        p = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             text=True, **kwargs)
        _GIT = p
        out, _ = p.communicate(timeout=timeout)
        return out.strip()
    except subprocess.TimeoutExpired:
        _F["git_timeout"] = True
        _kill_git()
        return ""
    except Exception:
        _kill_git()
        return ""
    finally:
        _GIT = None


def _block_signals():
    """屏蔽本线程后续信号（防重入）：宿主关 pane 时会连发多次 SIGHUP，处理器
    重入会重复输出兜底两行；正常收尾也要挡住 pend 的 SIGALRM 再兜底一次。
    平台没有 pthread_sigmask 时静默跳过。"""
    mask = getattr(signal, "pthread_sigmask", None)
    if mask is None:
        return
    sigs = set()
    for _name in ("SIGALRM", "SIGTERM", "SIGHUP", "SIGINT"):
        _sig = getattr(signal, _name, None)
        if _sig is not None:
            sigs.add(_sig)
    try:
        mask(signal.SIG_BLOCK, sigs)
    except Exception:
        pass


def _close_phase():
    """看门狗在某个阶段中途触发时结算该阶段的耗时（否则慢日志里它恒为 0）。"""
    global _PHASE_T0
    if _PHASE in _T and _PHASE_T0 is not None:
        _T[_PHASE] = time.monotonic() - _PHASE_T0
        _PHASE_T0 = None      # 防重复结算


def _expire(reason):
    """看门狗到期：屏蔽信号 → 杀 git → 结算被打断阶段的耗时 → 先出帧（兜底两行）
    → 再记慢日志（最多等 SLOW_LOG_WAIT_S，日志卡死也照常退出）→ rc=0。
    必须抢在宿主约 5.0s 的 SIGKILL 之前（SIGKILL 本身拦不住）。"""
    _block_signals()
    _kill_git()
    _close_phase()
    emit_fallback()
    _log_slow_async(reason)
    os._exit(0)


def _on_alarm(signum, frame):
    _expire("watchdog")


def _arm_watchdog():
    """进程创建起算的硬中断：setitimer 到点走 _expire。平台没有 setitimer 时
    静默跳过——装看门狗失败绝不能把脚本搞崩。
    提前 20ms 到点：各阶段软上限取的是「剩余预算」，挂住的 git 会与硬墙钟
    精确撞线；看门狗必须是实际生效的那一刀（宿主 SIGKILL 拦不住）。"""
    setitimer = getattr(signal, "setitimer", None)
    if setitimer is None:
        return
    left = remaining()
    if left <= 0.05:
        _expire("watchdog")
        return
    try:
        signal.signal(signal.SIGALRM, _on_alarm)
        setitimer(signal.ITIMER_REAL, max(0.01, left - 0.02))
    except Exception:
        pass


def _on_signal(signum, frame):
    """被宿主打断（重载/关闭状态栏、退出、Ctrl-C）：先屏蔽信号防重入，再清掉
    git 进程树，输出兜底两行，rc=0——既不漏进程，也不以信号死亡（agy 不把它
    记成一次失败）。"""
    _block_signals()
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
                        _F["scan_budget_hit"] = True
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
                            _F["scan_budget_hit"] = True
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
                            _F["scan_budget_hit"] = True
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


def read_stdin(timeout=STDIN_TIMEOUT_S):
    """带超时读取 stdin。agy 的 statusline runner 若不关 stdin，阻塞 read 会让状态栏挂死；
    读到 EOF / 超时 / 8 MiB 上限即返回，随后把 fd 换成 /dev/null 解除上游阻塞
    （对齐参考实现 `timeout 1 cat` + `exec 0</dev/null`）。
    timeout <= 0（预算已耗尽）时不等 select，直接返回 ""。
    sys.stdin 为 None / fd 无效 → 返回 ""。"""
    if sys.stdin is None:
        return ""
    if timeout <= 0:
        _F["stdin_timeout"] = True
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
                _F["stdin_timeout"] = True
                break
            try:
                r, _, _ = select.select([fd], [], [], remain)
            except Exception:
                try:
                    return sys.stdin.read(MAX_STDIN)
                except Exception:
                    return ""
            if not r:
                _F["stdin_timeout"] = True
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
    global _PHASE, _PHASE_T0, _TRANSCRIPT_KIND
    # R9：预算自**进程创建**起算（含 shim/解释器启动），看门狗负责硬中断；
    # 任何阶段都取 min(软上限, 剩余预算)。
    _arm_watchdog()

    _PHASE = "stdin"
    _PHASE_T0 = time.monotonic()
    raw = read_stdin(min(STDIN_TIMEOUT_S, max(0.0, remaining())))
    _T["stdin"] = time.monotonic() - _PHASE_T0
    _PHASE_T0 = None
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
    # R9：扫描预算取 min(SCAN_BUDGET_S, 剩余硬墙钟)——超时不丢已聚合状态，
    # offset 续读收敛；硬墙钟耗尽时直接用缓存状态、不再读新字节。
    _PHASE = "scan"
    _PHASE_T0 = time.monotonic()
    if not transcript:
        _TRANSCRIPT_KIND = 0
    else:
        try:
            _TRANSCRIPT_KIND = 2 if os.path.isfile(transcript) else 1
        except Exception:
            _TRANSCRIPT_KIND = 1
    scan_budget = min(_scan_budget_s(), max(0.0, remaining()))
    st = scan_transcript(transcript, scan_budget) if transcript else dict(ZERO_STATE)
    _T["scan"] = time.monotonic() - _PHASE_T0
    _PHASE_T0 = None

    # 家目录折叠只锚定路径前缀（对齐 cc Bug 猎杀 #3：无锚 replace 会把
    # /Users/spoon<x>… 的兄弟目录错折成 ~<x>…，显示不存在的路径）
    try:
        home = str(Path.home())
    except Exception:
        home = os.environ.get("HOME") or ""
    short_cwd = ("~" + cwd[len(home):]) if home and (cwd == home or cwd.startswith(home + "/")) else cwd

    # ---- git: 单次 porcelain v2（branch + ahead/behind + 增/删/改） ----
    # R9：agy 侧软上限 1.5s；剩余预算 <= 0.05s 时不启动 git（直接当空输出），
    # 绝不在硬墙钟边缘再赌一次子进程启动。
    _PHASE = "git"
    _PHASE_T0 = time.monotonic()
    branch, ab, dmg, dmg_plain = "", "", "", ""
    rem = remaining()
    if rem <= 0.05:
        stg = ""
        _F["git_skipped"] = True
    else:
        stg = sh(["git", "-C", cwd, "status", "--porcelain=v2", "--branch"],
                 timeout=min(GIT_TIMEOUT_S, rem))
    _T["git"] = time.monotonic() - _PHASE_T0
    _PHASE_T0 = None
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

    _PHASE = "render"

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
    # R9：收尾先屏蔽信号（挡掉 pend 的 SIGALRM 再兜底一次），输出后按触发
    # 条件记慢日志，最后 os._exit(0)——不走解释器正常退出。
    _PHASE = "output"
    _block_signals()
    sys.stdout.write(f"{truncate_display(line1, term_w)}\n{truncate_display(line2, term_w)}")
    sys.stdout.flush()
    _maybe_log_slow()
    os._exit(0)


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
        # 禁用自定义状态栏，绝不能把 traceback 漏到 stderr。R9：先屏蔽信号，
        # 防止异常处理期间 pend 的 SIGALRM/宿主信号再触发一次兜底。
        _block_signals()
        try:
            emit_fallback()
        except BaseException:
            pass
        os._exit(0)
