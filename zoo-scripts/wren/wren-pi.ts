// 自定义 footer：还原内置两行布局，模型位置显示可读名
// 行1: ~/cwd | branch ↑a↓b +增 ~删 ✱改 | ws:tab:pane | pi · 时长
// 行2: ↑in ↓out | R CH CP | ctx%/win TTFT | 模型 · 思考（行内布局，与 wren.py / wren-qc.py 同构）
// 时长上行1 尾、TTFT 归状态组，见 docs/wren-ttft-design.md
// /footer 命令切换自定义/内置
// 基于官方示例 examples/extensions/custom-footer.ts
import type { AssistantMessage } from "@earendil-works/pi-ai";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { execFile } from "node:child_process";
import { homedir } from "node:os";
import { truncateToWidth, visibleWidth } from "@earendil-works/pi-tui";

// Dracula 色板两档（与 wren.py 同表；256 档按 pi 宿主 rgbTo256 算法预计算）
const DRACULA: Record<string, [string, string]> = {
	fg: ["38;2;248;248;242", "38;5;231"],
	comment: ["38;2;98;114;164", "38;5;61"],
	purple: ["38;2;189;147;249", "38;5;141"],
	green: ["38;2;80;250;123", "38;5;84"],
	red: ["38;2;255;85;85", "38;5;203"],
	yellow: ["38;2;241;250;140", "38;5;228"],
	pink: ["38;2;255;121;198", "38;5;212"],
	cyan: ["38;2;139;233;253", "38;5;117"],
};
const RESET = "\x1b[0m";

// 按显示格取头/尾片段，结果不超过 maxW 格。
// 不按码点切：13 个汉字的分支是 26 格 / 13 码点，按码点切会切出两倍预算，
// 与 wren.py 的 slice_cells 不同构（CR 轮 11）。
function sliceCells(s: string, maxW: number, fromEnd: boolean): string {
	const chars = Array.from(s);
	if (fromEnd) chars.reverse();
	let w = 0;
	const out: string[] = [];
	for (const ch of chars) {
		const cw = visibleWidth(ch);
		if (w + cw > maxW) break;
		out.push(ch);
		w += cw;
	}
	return fromEnd ? out.reverse().join("") : out.join("");
}

// 预算上界常量（设计 §1.1-2 / §4）：按上界预留而不是当前值宽度，折叠决策才不随数值抖动。
// TTFT 上界 `TTFT 99m59s` = 11 格；时长段上界 ` · 99h59m` = 9 格（含 " · " 分隔符 3 格）。
// TTFT 显示值（秒）：<10s 保留一位小数，≥10s 四舍五入到整秒（与 fmtTtft 同口径）。
// 色档判定用它而非原始 ms —— 否则「TTFT 20s」在 19.6s~20.4s 之间会白黄跳。
// <10s 档必须直接取「显示器渲染出来的那个数」（toFixed(1)），不能用
// Math.round(ms/100)/10：后者是半进、而 toFixed 作用在 double 上（如 150ms：
// toFixed→0.1 而 round→0.2），会与同屏显示的 "TTFT 0.1s" 不同步。
function ttftSecs(ms: number | null | undefined): number | null {
	if (ms == null) return null;
	if (ms < 10_000) return Number((ms / 1000).toFixed(1));
	return Math.round(ms / 1000);
}

// TTFT 四档着色（与 ctx% 同为突变式，不做渐变）：绿 <5s、白 5-20s、黄 20-60s、
// 红 >60s。判据取 ttftSecs（显示器渲染值），保证同屏同值同色。三侧同一张表。
function ttftColor(ms: number | null | undefined): string {
	const v = ttftSecs(ms);
	if (v == null) return "fg";
	if (v < 5) return "green";
	if (v <= 20) return "fg";
	if (v <= 60) return "yellow";
	return "red";
}

// TTFT 预算上界占位串（宽档 11 格）；窄档用 `⏱⏱99m59s`（8 格，见 build2）。
const TTFT_BUDGET_S = "TTFT 99m59s";
const DUR_BUDGET = visibleWidth(" · 99h59m");

// 窄档思考等级缩写（十轮裁定，与 cc 的 _THINK_SHORT 同表）：给 ⏱ 腾格；
// 未知值原样。宽档不缩。
const THINK_SHORT: Record<string, string> = { xhigh: "xh", high: "hi", medium: "med", low: "low", max: "max" };

// TTFT 显示分档（设计 §3）：<10s 一位小数 / ≥10s 整数 / ≥60s `TTFT 1m05s` / ≥1h `TTFT 1h40m`。
// 统一带 `TTFT ` 前缀（用户定稿：裸 T 前缀不直观）。上界 11 格（`TTFT 99m59s`），与
// TTFT_BUDGET_S 对齐；超 99h 钳到 `TTFT 99h+`（9 格）保住上界。
function fmtTtft(ms: number): string {
	if (ms < 10_000) return `TTFT ${(ms / 1000).toFixed(1)}s`;
	const total = Math.round(ms / 1000);
	if (total < 60) return `TTFT ${total}s`;
	const pad = (n: number) => String(n).padStart(2, "0");
	if (total < 3600) return `TTFT ${Math.floor(total / 60)}m${pad(total % 60)}s`;
	const h = Math.floor(total / 3600);
	if (h > 99) return "TTFT 99h+";
	return `TTFT ${h}h${pad(Math.floor((total % 3600) / 60))}m`;
}

// 时长（行1 尾，设计 §3）：沿用原 fmtDuration 的 `1h5m` 式（与 T53 一致），
// >99h59m 钳到 `99h+` —— 渲染上界因此落在 ` · 99h59m` = 9 格，与 DUR_BUDGET 一致。
function fmtDurationElapsed(ms: number): string {
	const s = Math.floor(ms / 1000);
	const h = Math.floor(s / 3600);
	const m = Math.floor((s % 3600) / 60);
	if (h > 99 || (h === 99 && m > 59)) return "99h+";
	return h > 0 ? `${h}h${m}m` : `${m}m`;
}

// 剥 ANSI 转义（量宽用）：pi 的 visibleWidth 本身已剥，但段表纪律要求预算串
// 全程无色（与 cc 的 strip_ansi 同地位）——预算一律量 plain，色档不得影响折叠。
const ANSI_RE = /\x1b\[[0-9;]*m/g;
function stripAnsi(s: string): string {
	return s.replace(ANSI_RE, "");
}

// 压平换行（与 cc 的 one_line 同款）：宿主按行渲染 statusline，字段里的 \n/\r/
// Unicode 行界会把 2 行契约顶成 3+ 行。herdr env / 模型名 / 思考等级用；
// 压平后为空的段会被 filter(Boolean) 拆掉（cc 同法）。非字符串原样返回
// （与 cc 的 isinstance 门同语义）。
const ONE_LINE_RE = /[\n\r\v\f\x1c\x1d\x1e\x85\u2028\u2029]/g;
function oneLine(s: string | undefined): string | undefined {
	return typeof s === "string" ? s.replace(ONE_LINE_RE, "") : s;
}

// 半偶舍入（银行家）：cc/qc 窄档 ctx% 用 Python :.0f（74.5→74、50.5→50），
// JS toFixed(0)/Math.round 是半上（74.5→75）——手写对齐三侧，别单侧分叉
// （交叉审 P3）。仅窄档整数化用；宽档 .2f 残差是已记录的既有口径。
function roundHalfEven(v: number): number {
	const fl = Math.floor(v), d = v - fl;
	return d > 0.5 ? fl + 1 : d < 0.5 ? fl : fl % 2 === 0 ? fl : fl + 1;
}

// 2 位半偶量化（第七轮 BUG2/BUG3）：与 cc/qc 的 Python :.2f 同口径——
// 宽档 .2f、窄档整数化/色档阈值都先量化再走（cc 的 pct_val 同源同链）。
// toFixed(2) 是半上（0.125 → 0.13），Python :.2f 是半偶（0.12），三侧裁定统一半偶。
function quantize2(v: number): number {
	return roundHalfEven(v * 100) / 100;
}

// tok 净化（猎杀四轮 tok() 的 pi 侧等价物，第七轮 BUG4 补）：宿主字段可能是
// 字符串/负数/NaN/Infinity/undefined——裸 += 会串接（"0500"）、带负号进渲染
// （↑-50）、NaN 污染（↓NaNM）。非正有限数一律记 0。
const tok = (v: unknown): number => (typeof v === "number" && Number.isFinite(v) && v > 0 ? v : 0);

// 分支折叠六档（行1 梯子逐级传 24→20→16→12→8→4），与 wren-cc.py 的 fold_branch 同规则：
// ≥24 档三侧同构 head8/tail15（CR 轮 9 尾重头轻）；<24 档窄档私有（头≈30% 尾吃剩余）；
// ≤4 档只剩 …+尾2；0 档 git 段整体让位（物理极限区最后一级）。
function foldBranchAt(b: string, maxLen: number): string {
	if (visibleWidth(b) <= maxLen) return b;
	if (maxLen >= 24) return sliceCells(b, 8, false) + "…" + sliceCells(b, 15, true);
	if (maxLen <= 0) return "";
	if (maxLen <= 4) return "…" + sliceCells(b, Math.max(2, maxLen - 1), true);
	const head = Math.max(3, Math.floor((maxLen * 3) / 10) - 1);
	let tail = Math.max(4, maxLen - head - 1);
	if (head + 1 + tail > maxLen) tail = Math.max(2, maxLen - head - 1);
	return sliceCells(b, head, false) + "…" + sliceCells(b, tail, true);
}

// theme.getColorMode() 是 pi 宿主的公开 API（theme.d.ts）；NO_COLOR 优先于宿主判定。
function colorMode(theme: any): "truecolor" | "256" | "none" {
	if (process.env.NO_COLOR) return "none";
	const m = theme?.getColorMode?.();
	if (m === "truecolor") return "truecolor";
	if (m === "none") return "none";
	return "256"; // "256color" 与未知值都保守降 256
}

export default function (pi: ExtensionAPI) {
	let enabled = false;
	// timer/tuiRef 必须在 install() 外：此前是函数局部变量，第 N 次 install() 时
	// 守卫 if (timer) 看到的永远是本帧的 null，clearInterval 从不触发，
	// 每次 session_start / /footer 重开都泄漏一个 15s interval（每 15s 多起一个
	// git 子进程 + 对失效 tuiRef 的 requestRender）。CR 轮 12 实测 x3 次装 3 个残留。
	let timer: ReturnType<typeof setInterval> | null = null;
	let installedTui: any = null;

	// TTFT：事件流内存态（设计 §6，不落盘、不进 transcript 缓存）。
	// 注册必须在工厂里只做一次——放进 install() 会随 session_start / /footer 重开重复注册，
	// 与 timer 泄漏同一类坑（CR 轮 12）。
	let turnStartTs: number | null = null;
	let firstTokenTs: number | null = null;
	let lastTtftMs: number | null = null;
	pi.on("turn_start", (event: any) => {
		// TurnStartEvent.timestamp 由宿主在同一刻打下；缺失时回落本地时钟
		turnStartTs = typeof event?.timestamp === "number" ? event.timestamp : Date.now();
		firstTokenTs = null;
	});
	pi.on("message_update", () => {
		// 首个 message_update 即首片（与 cc/qc 的落盘口径不同，README 写死）
		if (turnStartTs === null || firstTokenTs !== null) return;
		firstTokenTs = Date.now();
		lastTtftMs = firstTokenTs - turnStartTs;
		installedTui?.requestRender();
	});

	const install = (ctx: any) => {
		const sessionStart = Date.now();
		const herdrId = [
			oneLine(process.env.HERDR_WORKSPACE_ID),
			oneLine(process.env.HERDR_TAB_ID?.split(":").pop()),
			oneLine(process.env.HERDR_PANE_ID?.split(":").pop()),
		]
			.filter(Boolean)
			.join(":");
		// 与 wren.py 一致：herdr 位置不加中括号（右对齐时代的残留样式）
		const herdrTag = herdrId;
		// git 状态：一次 `status --porcelain=v2 --branch` 全拿（分支 / ahead-behind / 增删改），
		// 与 Claude Code 侧的 wren.py 同一套解析，两侧输出才能逐字对齐。
		// 旧实现拆成 rev-parse + rev-list + status 三次子进程，且脏文件只数 porcelain 行数，
		// 不区分新增/删除/修改，还混进重命名。
		const git = { repo: false, ab: "", counts: "", head: "" };
		// 色档共享：footer 工厂重建时更新；refreshGit 拼接 counts 时读取。
		// 首帧（工厂未跑过前）默认无色，工厂跑完 requestRender 会再刷一帧补色
		const colorCache = { mode: "none" as "truecolor" | "256" | "none" };
		const cAt = (name: string, text: string, cache: { mode: string }) => {
			if (cache.mode === "none") return text;
			const codes = DRACULA[name] ?? DRACULA.fg;
			return `\x1b[${cache.mode === "truecolor" ? codes[0] : codes[1]}m${text}${RESET}`;
		};
		const gitRun = (args: string[], cb: (out: string | null) => void) =>
			execFile("git", args, { timeout: 3000 }, (err, stdout) => cb(err ? null : String(stdout).trim()));
		const refreshGit = () => {
			const cwd = process.cwd();
			gitRun(["-C", cwd, "status", "--porcelain=v2", "--branch"], (out) => {
				// 非 git 目录 / git 不可用时 porcelain 会失败，out 为 null
				git.repo = out !== null;
				if (out === null) {
					git.ab = "";
					git.counts = "";
					installedTui?.requestRender();
					return;
				}
				let ab = "";
				let head = "";
				let added = 0;
				let modified = 0;
				let deleted = 0;
				for (const ln of out.split("\n")) {
					if (ln.startsWith("# branch.head ")) {
						// detached HEAD 时 porcelain 给 "(detached)"，以 "(" 开头——
						// 与 wren.py 同一条规则判"无分支"。不用 getGitBranch() 的返回值判，
						// 因为 pi 对真 detached 和名为 detached 的真分支返回同一个
						// 字符串 "detached"（resolveGitBranchSync），两者无法区分。
						head = ln.slice("# branch.head ".length).trim();
					} else if (ln.startsWith("# branch.ab ")) {
						const p = ln.slice("# branch.ab ".length).trim().split(/\s+/);
						if (p.length === 2) {
							// porcelain 写的是 +ahead -behind，显示时去掉符号
							ab = ` ↑${p[0].replace(/^\+/, "")}↓${p[1].replace(/^-/, "")}`;
						}
					} else if (ln.startsWith("? ")) {
						added += 1;
					} else if (/^[12u] /.test(ln)) {
						const xy = ln.split(" ")[1] ?? "";
						if (xy[0] === "A") added += 1;
						else if (xy.includes("D")) deleted += 1;
						else modified += 1;
					}
				}
				// dmg 三段在拼接处上色（c() 定义在后但 render 闭包执行时已存在；
				// 这里在 refreshGit 回调里，用模块级 helper 保持无环依赖——见 cAt）
				const parts: string[] = [];
				if (added) parts.push(cAt("green", `+${added}`, colorCache));
				if (deleted) parts.push(cAt("red", `~${deleted}`, colorCache));
				if (modified) parts.push(cAt("yellow", `✱${modified}`, colorCache));
				git.ab = ab;
				git.counts = parts.length ? ` ${parts.join(" ")}` : "";
				git.head = head;
				installedTui?.requestRender();
			});
		};
		if (timer) clearInterval(timer);
		timer = setInterval(() => {
			refreshGit();
			installedTui?.requestRender();
		}, 15000);
		refreshGit();
		ctx.ui.setFooter((tui: any, theme: any, footerData: any) => {
			installedTui = tui;
			const unsub = footerData.onBranchChange(() => tui.requestRender());
			// Dracula 上色器：色档取 theme.getColorMode()，footer 工厂重建（含主题热切换）时
			// 重求值并同步进 colorCache（refreshGit 的 counts 拼接也用它）
			colorCache.mode = colorMode(theme);
			const c = (name: string, text: string) => cAt(name, text, colorCache);
			// 分支折叠（≥24 默认档）：foldBranchAt 提到模块级，行1 梯子逐级传更小档位
			const foldBranch = (b: string) => foldBranchAt(b, 24);
			return {
				dispose() {
					unsub();
					if (timer) {
						clearInterval(timer);
						timer = null;
					}
				},
				invalidate() {},
				render(width: number): string[] {
					// 行1: 目录（过长折叠中间段）+ git 分支 + ahead/behind + 脏文件数
					// 家目录折叠：用 os.homedir() 而不是硬编码 /Users/xxx，
					// Linux 的 /home/<user> 与自定义 HOME 才都能折叠。
					// pi 内部另有 formatCwdForFooter()，但它只从
					// modes/interactive/components/footer.js 这个内部路径导出，
					// 深引内部路径会随版本变动碎掉，故本地实现。
					const home = homedir();
					let cwd = process.cwd();
					if (home && (cwd === home || cwd.startsWith(home + "/"))) {
						cwd = "~" + cwd.slice(home.length);
					}
					const branch = footerData.getGitBranch();
					// 分支有无由 porcelain 的 # branch.head 判断（"(" 开头 = detached = 无分支），
					// 与 wren.py 完全同规则；getGitBranch() 只提供显示名与 onBranchChange 响应性
					const hasBranch = !!branch && git.head !== "" && git.head !== "(detached)"; // 字面 ( 开头的真分支不误判（猎杀五轮 B-2b）
					// 窄档（≤55 列，与 cc 同契约）：预算按实绘宽 width−5 收（宿主左缩进 +
					// 尾部留白/省略号），地板 max(4, …) 不钳 24——钳 24 会让更窄的行按 24 格
					// 排版/截断，实际输出超终端宽、宿主切行炸版。宽档（≥56）零变化。
					const narrow = width <= 55;
					const termW = narrow ? Math.max(4, width - 5) : width;
					// 行1 梯子（与 wren-cc.py 同一套穷举）：永不丢 dmg / herdr 坐标 / pi 徽标；
					// 溢出让位顺序（循环序 = 牺牲序，外层更晚牺牲，终审九轮 #2 与 cc/qc
					// 决策 2 定稿同序）：cwd 地板 16→8→4（… /尾段截断）→ 分支六档压缩
					// （24→20→16→12→8→4）→ ab（46-52 列带 ab 时恒在）→ 时长（窄档一律
					// 不渲染）。旧序 floor 最外/wab 最内 = ab 最先丢，46-52 列红带。
					// 宽度探针按「分支折叠后真实宽」计，不按档位上界虚记；git 各件全空时
					// 探针返 0（非 git cwd 若仍记 3 格幻影宽，目录预算被偷）。
					const durText = fmtDurationElapsed(Date.now() - sessionStart);
					const abRaw = git.ab;
					let dmgPlainEff = stripAnsi(git.counts); // pi 的 counts 在 refreshGit 里已上色，量宽用无色副本
					let abEff = abRaw;
					const gitW = (blen: number, withAb: boolean): number => {
						// 核空判（终审九轮 #1）：分支折到 0 档（空串）且无 ab/dmg 时
						// ' | ' 前缀也不进预算——旧判只看 hasBranch 会记 3 格幻影宽偷 cwd。
						const core = `${hasBranch ? foldBranchAt(branch, blen) : ""}${withAb ? abRaw : ""}${dmgPlainEff}`;
						if (!core) return 0;
						return visibleWidth(` | ${core}`);
					};
					const herdrW = herdrTag ? visibleWidth(` | ${herdrTag}`) : 0;
					const badgeW = visibleWidth(" | pi");
					const durW = durText ? DUR_BUDGET : 0;
					const canDur = !!durText && !narrow; // 窄档裁定不渲染时长（契约 #6）
					let keepDuration = canDur, bBudget = 24, dropAb = false, cwdFloor = 16, found = false;
					search:
					for (const wd of canDur ? [true, false] : [false]) {
						for (const wab of abRaw ? [true, false] : [false]) {
							for (const blen of [24, 20, 16, 12, 8, 4]) {
								for (const floor of [16, 8, 4]) {
									if (gitW(blen, wab) + herdrW + badgeW + (wd ? durW : 0) + floor <= termW) {
										bBudget = blen; keepDuration = wd; dropAb = !wab && !!abRaw; cwdFloor = floor;
										found = true;
										break search;
									}
								}
							}
						}
					}
					if (!found) {
						// 物理极限区（与 cc 同）：最小配置（分支 4 档、丢 ab/时长、cwd 地板 4）
						// 仍放不下 → 逐段再丢 git 计数（dmg 是铁律但物理不可容时最后让位）。
						bBudget = 4; dropAb = !!abRaw; keepDuration = false; cwdFloor = 4;
						if (gitW(bBudget, false) + herdrW + badgeW + 4 > termW) dmgPlainEff = "";
						if (gitW(bBudget, false) + herdrW + badgeW + 4 > termW) { bBudget = 0; abEff = ""; }
					}
					if (dropAb) abEff = "";
					const rest = gitW(bBudget, !!abEff) + herdrW + badgeW + (keepDuration ? durW : 0);
					const maxPath = Math.max(cwdFloor, termW - rest);
					const segs = cwd.split("/");
					let displayPath = cwd;
					if (visibleWidth(cwd) > maxPath) {
						const cands = [
							`${segs.slice(0, 2).join("/")}/…/${segs.slice(-2).join("/")}`,
							`${segs[0]}/…/${segs.slice(-2).join("/")}`,
							`…/${segs.slice(-2).join("/")}`,
							`…/${segs[segs.length - 1]}`,
						];
						displayPath = cands.find((c2) => visibleWidth(c2) <= maxPath) ?? cands[3];
						if (visibleWidth(displayPath) > maxPath) {
							// 末级：对尾段按显示格截断（与 wren.py 的 slice_cells 同规则）
							const last = segs[segs.length - 1];
							const keep = maxPath - 2;
							displayPath = keep >= 1 ? `…${sliceCells(last, keep, true)}` : sliceCells(displayPath, maxPath, false);
						}
					}
					// Dracula: cwd/分隔线/herdr 灰、分支紫、ab 白（counts 已在拼接处上色）
					const sep1 = c("comment", "|");
					// detached HEAD：分支名不显示（设计），ab/counts 照常——counts 是铁律
					// （Bug 猎杀 #2，与 wren-cc.py 同步：旧版 hasBranch 门控把脏树计数吞掉）。
					// 分支按梯子命中的 bBudget 折；counts 已在物理极限区被清时不再渲染。
					const coloredGit = ((hasBranch ? c("purple", foldBranchAt(branch, bBudget)) : "")
						+ (abEff ? c("fg", abEff) : "")
						+ (dmgPlainEff ? git.counts : "")).replace(/^ +/, "");
					// 色档空判（终审九轮 #1）：cAt 包空串是纯 ANSI 包裹，truthy/.trim()
					// 都剥不掉 → 行内幻影 ' | ' 空槽 + rest 幻影 3 格偷 cwd 预算；且首帧
					// colorCache='none' 时为空跳过、上色后幻影出现 → 跨帧闪烁。空核整段不进
					// 段表（cc 侧 strip_ansi 守卫同款）。
					// 段对 (colored, plain) 纪律（与 cc/build2 同）：量宽只看 plain——预算串
					// 全程无色，色档不得影响折叠。两遍策略（契约 #6）：先按自然序
					// （git→herdr→pi→dur）拼；徽标没保住才换徽标优先序重拼（铁律高于视觉）。
					// 徽标是否入列由 assembleL1 直接回报——不用 cc 的子串包含判断
					// （路径/分支里含 "pi" 时会误判已保住，此处比 cc 硬一点）。
					type Seg = { colored: string; plain: string };
					const badgeSeg: Seg = { colored: ` ${sep1} ${c("comment", "pi")}`, plain: " | pi" };
					const natural: Seg[] = [];
					if (stripAnsi(coloredGit).trim()) natural.push({ colored: ` ${sep1} ${coloredGit}`, plain: ` | ${stripAnsi(coloredGit)}` });
					if (herdrTag) natural.push({ colored: ` ${sep1} ${c("comment", herdrTag)}`, plain: ` | ${herdrTag}` });
					natural.push(badgeSeg);
					if (keepDuration) natural.push({ colored: ` ${c("comment", "·")} ${c("fg", durText)}`, plain: ` · ${durText}` });
					const assembleL1 = (order: Seg[]) => {
						let line = c("comment", displayPath), used = visibleWidth(displayPath), badgeIn = false;
						for (const s of order) {
							if (used + visibleWidth(s.plain) <= termW) {
								line += s.colored; used += visibleWidth(s.plain);
								if (s === badgeSeg) badgeIn = true;
							}
						}
						return { line, badgeIn };
					};
					let l1res = assembleL1(natural);
					let line1 = l1res.badgeIn
						? l1res.line
					: assembleL1([badgeSeg, ...natural.filter((s) => s !== badgeSeg)]).line;
					line1 = truncateToWidth(line1, termW);

					// 行2左: token 统计 + 上下文占用
					let input = 0,
						output = 0,
						cacheRead = 0,
						cacheWrite = 0,
						compactions = 0;
					let last: AssistantMessage | null = null;
					for (const e of ctx.sessionManager.getBranch()) {
						if (e.type === "compaction") compactions++;
						if (e.type === "message" && e.message.role === "assistant") {
							const m = e.message as AssistantMessage;
							input += tok(m.usage.input);
							output += tok(m.usage.output);
							cacheRead += tok(m.usage.cacheRead);
							cacheWrite += tok(m.usage.cacheWrite);
							last = m;
						}
					}
					const model: any = ctx.model;
					// 999_500~999_999 走 Math.round(n/1000) 会得到 1000K，
					// 必须改显示 1.0M（与 Claude Code 侧 wren.py、以及 ccstatusline
					// 的 format-tokens 同一规则）。pi 内置的 formatTokens 没有这道
					// 守卫，会渲染成 1000k，此处有意不跟。
					const fmt = (n: number) => {
						if (n < 1000) return `${n}`;
						if (n < 1_000_000) {
							const k = Math.round(n / 1000);
							return k >= 1000 ? `${(n / 1_000_000).toFixed(1)}M` : `${k}K`;
						}
						const m = n / 1_000_000;
						return Number.isInteger(m) ? `${m}M` : `${m.toFixed(1)}M`;
					};
					// 上下文占用直接取 pi 的权威值：它按 estimateContextTokens 算
					// （含 trailing 消息估算），并在压缩后没有有效 assistant 用量时
					// 返回 percent: null —— 那时显示 "?"，而不是像手算那样把压缩前的
					// 旧值一直挂在屏幕上。手算还会漏掉 cacheWrite。
					const ctxUsage = ctx.getContextUsage();
					const ctxWindowSize = ctxUsage?.contextWindow ?? model?.contextWindow ?? 0;
					// pctQ：量化后的占用值（第七轮 BUG2/BUG3）——宽档文本、色档阈值、
					// 窄档四分位/整数全读它（cc 的 pct_val = float(:.2f 串) 同源同链，
					// 原始 double 会在 25.499999→25、70.001→yellow 处与 cc 差一档）
					const pctQ = ctxUsage?.percent != null ? quantize2(ctxUsage.percent) : null;
					const ctxPercent = pctQ != null ? `${pctQ.toFixed(2)}%` : "?";
					const ctxPercentText = `${ctxPercent}/${fmt(ctxWindowSize)}`;
					const ctxColorName = pctQ != null
						? pctQ > 90 ? "red" : pctQ > 70 ? "yellow" : "green"
						: "comment";
					// 最新缓存命中率：公式与 pi 内置 footer 相同（最后一条 assistant 的
					// cacheRead/prompt，prompt 不含 output）。位数取两位小数与 Claude Code
					// 侧的 wren.py 对齐；pi 内置 footer 用的是一位，此处有意不跟。
					let ch = "";
					if (last) {
						const u = last.usage;
						const promptTokens = tok(u.input) + tok(u.cacheRead) + tok(u.cacheWrite);
						// 无缓存会话不显示 CH（与 wren.py 的 ch_cache > 0 条件统一；
						// CR 轮 7 指出旧的 promptTokens>0 会挂一个恒 0 的 CH0.00%）；
						// 第七轮 BUG4：tok 净化（负 cacheWrite 不再缩分母虚高 CH）
						if (promptTokens > 0 && tok(u.cacheRead) > 0)
							ch = ` CH${quantize2((tok(u.cacheRead) / promptTokens) * 100).toFixed(2)}%`;
					}
					const cp = compactions > 0 ? ` CP${compactions}` : "";
					// Dracula: token 白、R 白、CH 青、CP 灰、ctx% 三档（>70 黄、>90 红，pi 语义）
					const sep2 = c("comment", "|");

					// 身份组：模型粉 · 思考青（时长已上移行1，不再参与行2）；
					// 拼接移进 build2 的段表（窄/宽同构），这里只留名字解析。
					// 压平 + 尾斜杠空段回落（对齐 cc one_line(raw).split("/")[-1] or "?"）：
					// 注入 \n 顶飞 2 行契约；"prefix/" 切空段留悬空 "| ·" 尾（交叉审 P1/P2）
					const display = oneLine(model?.name || model?.id || "no-model")!.split("/").pop() || "?";

					// 行2 梯子（与 cc 同一套段表）：段列表 + 逐段剔，每段 (colored, plain)
					// 成对收集、量宽只看 plain（预算串全程无色，色档不得影响折叠）。
					// 宽档丢序 TTFT → CH → CP（新段先丢）；窄档 CP → CH（⏱ 升铁律，
					// 十轮裁定永不丢；CP 在窄档本就不进段表，首位丢弃是空操作）。
					// 永不剔除 in/out / ctx% / 模型·思考。
					// TTFT 预算用上界占位串而非「彩色串宽 + 差额」：宽档 `TTFT 99m59s`=11 格，
					// 窄档 `⏱⏱99m59s`=8 格（⏱ 计 1 格、iOS 实显 2 格，双占位补足——
					// visibleWidth 对 U+23F1（EAW=N）只算 1 格，单格口径双向出错）。
					const ttftText = lastTtftMs != null ? fmtTtft(lastTtftMs) : "";
					const chText = ch ? ch.trim() : "";
					const cpText = cp ? cp.trim() : "";
					// 窄档短形（契约 #3，与 cc 同）：in/out 去 ↑/↓ 前缀与中间空格、/ 分向
					// （31.2M/643K，方向靠位置约定：/ 前 in 后 out）；CH 前缀 CH→◈（两位
					// 小数原样）；ctx% 整数 + 四分位块高图标（▂<25 ▄<50 ▆<75 █≥75，等宽
					// 四分位=几何体积，与色档 70/90 解耦：图标说占了几成，颜色说风险）；
					// TTFT 前缀 TTFT→⏱；R/CP 不进段表；紧分隔 |（3 个分隔省 6 格）。
					// percent=null（压缩后未知）＝cc 的 ctx_pct 为空 → 窄档不渲染 ctx。
					// 窄档链 = 量化(2位) → 四分位/整数（第七轮 BUG3）：cc 先 :.2f 再 :.0f，
					// pi 拿原始 double 会差一档（25.499999 → 25 vs cc 26）
					const pctNum = pctQ;
					const chS = narrow ? (chText.startsWith("CH") ? "◈" + chText.slice(2) : chText) : chText;
					const ctxS = narrow
						? (pctNum == null ? "" : `${pctNum < 25 ? "▂" : pctNum < 50 ? "▄" : pctNum < 75 ? "▆" : "█"}${roundHalfEven(pctNum)}%`)
						: ctxPercentText;
					const ttftS = narrow ? (ttftText ? "⏱" + ttftText.slice(5) : "") : ttftText;
					const ttftBudgetS = narrow ? "⏱⏱" + "99m59s" : TTFT_BUDGET_S;
					const build2 = (k: { ttft: boolean; ch: boolean; cp: boolean }): [string, string] => {
						const head = narrow ? `${fmt(input)}/${fmt(output)}` : `↑${fmt(input)} ↓${fmt(output)}`;
						const segsC: string[] = [c("fg", head)];
						const segsP: string[] = [head];
						let ledgerC = narrow ? "" : `R${fmt(cacheRead)}`;
						let ledgerP = ledgerC;
						if (k.ch && chS) {
							ledgerC += (ledgerC ? " " : "") + c("cyan", chS);
							ledgerP += (ledgerP ? " " : "") + chS;
						}
						if (k.cp && cpText && !narrow) {
							ledgerC += (ledgerC ? " " : "") + c("comment", cpText);
							ledgerP += (ledgerP ? " " : "") + cpText;
						}
						if (ledgerC) { segsC.push(ledgerC); segsP.push(ledgerP); }
						let statC = "", statP = "";
						if (ctxS) { statC = c(ctxColorName, ctxS); statP = ctxS; }
						if (k.ttft && ttftS) {
							const t = c(ttftColor(lastTtftMs), ttftS);
							statC = statC ? `${statC} ${t}` : t;
							statP = statP ? `${statP} ${ttftBudgetS}` : ttftBudgetS;
						}
						if (statC) { segsC.push(statC); segsP.push(statP); }
						// 身份组窄档也进（契约：模型·思考不可丢），组内仍 · 分隔；
						// thinkingLevel 压平（交叉审 P1）：注入 \n 顶飞 2 行契约，压平后
						// 空串不进段表。窄档缩短（十轮裁定，与 cc 的 m_name/t_name 同款）：
						// model 去 '[1m]' 后缀、thinking 按 THINK_SHORT 缩写（未知原样），
						// 腾格给 ⏱；宽档不缩。
						const thinking = oneLine(ctx.thinkingLevel) ?? "";
						const mName = narrow ? display.split("[1m]").join("") : display;
						const tName = narrow ? (THINK_SHORT[thinking] ?? thinking) : thinking;
						const identC = [c("pink", mName)].concat(tName ? [c("cyan", tName)] : []);
						const identP = [mName].concat(tName ? [tName] : []);
						if (identC.length) { segsC.push(identC.join(" · ")); segsP.push(identP.join(" · ")); }
						return [segsC.join(narrow ? "|" : ` ${sep2} `), segsP.join(narrow ? "|" : " | ")];
					};
					let keep2 = { ttft: !!ttftS, ch: !!chS, cp: !!cpText };
					let [line2c, plain2] = build2(keep2);
					// 窄档 ⏱ 升铁律（十轮裁定，与 cc 的 order 同款）：丢序 CP→CH，TTFT 永不丢
					for (const drop of (narrow ? ["cp", "ch"] : ["ttft", "ch", "cp"]) as const) {
						if (visibleWidth(plain2) <= termW) break;
						keep2 = { ...keep2, [drop]: false };
						[line2c, plain2] = build2(keep2);
					}

					// 行内布局（与 cc 一致）：梯子之后仍溢出走硬截兜底；窄档预算已按
					// termW（width−5）收，硬截也按 termW
					const line2 = truncateToWidth(line2c, termW);
					return [line1, line2];
				},
			};
		});
	};

	pi.registerCommand("footer", {
		description: "切换自定义/内置 footer",
		handler: async (_args, ctx) => {
			enabled = !enabled;
			if (enabled) {
				install(ctx);
				ctx.ui.notify("自定义 footer 已开启", "info");
			} else {
				ctx.ui.setFooter(undefined);
				ctx.ui.notify("已恢复内置 footer", "info");
			}
		},
	});

	pi.on("session_start", async (_event, ctx) => {
		enabled = true;
		install(ctx);
	});
}
