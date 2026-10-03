// wren opencode 侧的排版核心：纯函数，无宿主依赖，可被 node 直接 import（type stripping）。
//
// 被 wren-oc.tsx（opencode TUI 插件适配层）调用；渲染层只负责把 Segment 映射成 <text fg>。
// 段格式、折叠梯子、数值口径与 wren-cc.py / wren-pi.ts / wren-qc.py 同构：
//   行1: ~/cwd | branch ↑a↓b +增 ~删 ✱改 | 宿主徽标 · 时长
//   行2: ↑in ↓out | R CH CP | ctx%/win TTFT | 模型名 · 思考等级
// 与 pi 侧的差异只有数据来源（opencode 的 session/part/provider），排版逻辑逐字对齐。

export type Tone = "fg" | "comment" | "purple" | "green" | "red" | "yellow" | "pink" | "cyan";
export type Segment = { text: string; tone: Tone };

const ANSI = /\x1b\[[0-9;]*m/g;
// East Asian Wide / Fullwidth 常用区间（与 wren-pi.ts 的 stub、Python 侧 east_asian_width 在汉字上一致）
function isWide(cp: number): boolean {
	return (
		(cp >= 0x1100 && cp <= 0x115f) || (cp >= 0x2e80 && cp <= 0xa4cf) ||
		(cp >= 0xac00 && cp <= 0xd7a3) || (cp >= 0xf900 && cp <= 0xfaff) ||
		(cp >= 0xfe30 && cp <= 0xfe6f) || (cp >= 0xff00 && cp <= 0xff60) ||
		(cp >= 0xffe0 && cp <= 0xffe6) || (cp >= 0x1f300 && cp <= 0x1f64f) ||
		(cp >= 0x20000 && cp <= 0x3fffd)
	);
}

export function visibleWidth(s: string): number {
	let w = 0;
	for (const ch of String(s).replace(ANSI, "")) w += isWide(ch.codePointAt(0) ?? 0) ? 2 : 1;
	return w;
}

// 压平换行（B-2，与 cc 侧 one_line 同字符集）：\n \r \v \f \x1c \x1d \x1e \x85 \u2028 \u2029。
// 宿主按行渲染 statusline，herdr env 含行界会把 2 行契约顶破；tsx 的 herdr 三段用它。
const LINE_BREAKS = /[\n\r\v\f\x1c\x1d\x1e\x85\u2028\u2029]/g;
export function oneLine(s: string | undefined | null): string {
	return String(s ?? "").replace(LINE_BREAKS, "");
}

// 按显示格取头/尾片段（不按码点切：13 个汉字的分支是 26 格，按码点切会切出两倍预算）
export function sliceCells(s: string, maxW: number, fromEnd: boolean): string {
	const chars = Array.from(s);
	if (fromEnd) chars.reverse();
	let w = 0;
	const out: string[] = [];
	for (const ch of chars) {
		const cw = isWide(ch.codePointAt(0) ?? 0) ? 2 : 1;
		if (w + cw > maxW) break;
		out.push(ch);
		w += cw;
	}
	return fromEnd ? out.reverse().join("") : out.join("");
}

function plain(segs: Segment[]): string {
	return segs.map((s) => s.text).join("");
}

// 按显示格截断段列表（超过 width 的部分整段丢弃，末段按格切）
export function truncateSegments(segs: Segment[], width: number): Segment[] {
	const out: Segment[] = [];
	let used = 0;
	for (const seg of segs) {
		const w = visibleWidth(seg.text);
		if (used + w <= width) {
			out.push(seg);
			used += w;
			continue;
		}
		const keep = width - used;
		const cut = sliceCells(seg.text, keep, false);
		if (cut) out.push({ text: cut, tone: seg.tone });
		break;
	}
	return out;
}

// 分支折叠：maxLen 驱动（行1 梯子逐级传 24→20→16→12→8→4→0），与
// cc/qc/pi 的 fold_branch 逐字同构：24 档三侧同构 head8/…/tail15（CR 轮 9
// 尾重头轻）；<24 档头尾三七开（头≈30%、尾吃剩余，互踩时尾让位）；≤4 档
// 只剩 …+尾段；0 档 git 段整体让位。触发与切片都按显示格（CJK 分支 26 格/
// 13 码点按格折）。
// 旧单公式 head8+…+tail(maxLen−9) 在 <24 档违反预算（12 档折出 14 格、
// 8 档丢 … 省略标记，靠行1 出口硬截遮住）——决策落地：移植 cc 档位结构。
export function foldBranch(b: string, maxLen = 24): string {
	const w = visibleWidth(b);
	if (w <= maxLen) return b;
	if (maxLen >= 24) return sliceCells(b, 8, false) + "…" + sliceCells(b, 15, true);
	if (maxLen <= 0) return "";
	if (maxLen <= 4) return "…" + sliceCells(b, Math.max(2, maxLen - 1), true);
	const head = Math.max(3, Math.floor((maxLen * 3) / 10) - 1);
	let tail = Math.max(4, maxLen - head - 1);
	if (head + 1 + tail > maxLen) tail = Math.max(2, maxLen - head - 1);
	return sliceCells(b, head, false) + "…" + sliceCells(b, tail, true);
}

// 999_500~999_999 走 Math.round(n/1000) 会得到 1000K，必须显示 1.0M
// （与 wren.py / wren-pi.ts / ccstatusline 同一规则）
// 半偶舍入 + 2 位量化（第七轮 BUG2）：cc/qc 的 Python :.2f 是半偶（0.125 → 0.12），
// toFixed(2) 是半上（0.13）——CH 与 ctx% 宽档文本走量化，三侧同口径。
function roundHalfEven(v: number): number {
	const fl = Math.floor(v), d = v - fl;
	return d > 0.5 ? fl + 1 : d < 0.5 ? fl : fl % 2 === 0 ? fl : fl + 1;
}
function quantize2(v: number): number {
	return roundHalfEven(v * 100) / 100;
}

export function fmtTokens(n: number): string {
	if (!Number.isFinite(n) || n < 0) return "0"; // NaN/Infinity/-x 兜底（猎杀五轮 B-oc-3）
	if (n < 1000) return `${n}`;
	if (n < 1_000_000) {
		const k = Math.round(n / 1000);
		return k >= 1000 ? `${(n / 1_000_000).toFixed(1)}M` : `${k}K`;
	}
	const m = n / 1_000_000;
	return Number.isInteger(m) ? `${m}M` : `${m.toFixed(1)}M`;
}

// 时长：`1h5m` 式，>99h59m 钳到 `99h+`（渲染上界因此落在 ` · 99h59m` = 9 格）
export function fmtDurationElapsed(ms: number): string {
	const s = Math.floor(ms / 1000);
	const h = Math.floor(s / 3600);
	const m = Math.floor((s % 3600) / 60);
	if (h > 99 || (h === 99 && m > 59)) return "99h+";
	return h > 0 ? `${h}h${m}m` : `${m}m`;
}

// TTFT 显示值（秒）：<10s 保留一位小数，≥10s 四舍五入到整秒（色档判定用它，不用原始 ms）
export function ttftSecs(ms: number | null | undefined): number | null {
	if (ms == null) return null;
	if (ms < 10_000) return Number((ms / 1000).toFixed(1));
	return Math.round(ms / 1000);
}

// TTFT 四档突变着色：绿 <5s、白 5-20s、黄 20-60s、红 >60s（判据为屏幕显示值）
export function ttftColor(ms: number | null | undefined): Tone {
	const v = ttftSecs(ms);
	if (v == null) return "fg";
	if (v < 5) return "green";
	if (v <= 20) return "fg";
	if (v <= 60) return "yellow";
	return "red";
}

// TTFT 分档：<10s 一位小数 / ≥10s 整数 / ≥60s m+s / ≥1h h+m；上界 11 格（`TTFT 99m59s`）
export function fmtTtft(ms: number): string {
	if (ms < 10_000) return `TTFT ${(ms / 1000).toFixed(1)}s`;
	const total = Math.round(ms / 1000);
	if (total < 60) return `TTFT ${total}s`;
	const pad = (n: number) => String(n).padStart(2, "0");
	if (total < 3600) return `TTFT ${Math.floor(total / 60)}m${pad(total % 60)}s`;
	const h = Math.floor(total / 3600);
	if (h > 99) return "TTFT 99h+";
	return `TTFT ${h}h${pad(Math.floor((total % 3600) / 60))}m`;
}

// 预算上界常量：折叠决策按上界预留，不随数值宽度抖动
export const TTFT_BUDGET = 11;
export const DUR_BUDGET = visibleWidth(" · 99h59m");

export type OcInput = {
	/** 行2 的宽度预算（整行独占） */
	width: number;
	/** 行1 的宽度预算（与宿主 usage/快捷键同行时更窄）；缺省 = width */
	width1?: number;
	/** cwd 显示；空串 = 不渲染 cwd 段（宿主已在别处显示时用） */
	cwd: string;
	home: string;
	/** 显示用分支名；无分支（detached / 非 git）传 null */
	branch: string | null;
	/** porcelain 的 `# branch.head`（`(` 开头 = detached，判无分支用） */
	head: string;
	/** ` ↑a↓b`（含前导空格）或空串 */
	ab: string;
	added: number;
	modified: number;
	deleted: number;
	/** herdr 位置 `ws:tab:pane`，无则空串 */
	herdr: string;
	/** 会话时长；null = 无会话（home 路由），整段不显示 */
	durationMs: number | null;
	inputTokens: number;
	outputTokens: number;
	cacheRead: number;
	cacheWrite: number;
	compactions: number;
	/** 最近一次请求的上下文占用；null = 未知（显示 `?`） */
	ctxPercent: number | null;
	/** 上下文窗口大小；0 = 未知（整段不显示） */
	ctxWindow: number;
	/** 模型名；空串 = 不渲染身份组（宿主已在同一行显示时用） */
	model: string;
	thinking: string;
	ttftMs: number | null;
};

function ctxTone(percent: number | null): Tone {
	if (percent == null) return "comment";
	return percent > 90 ? "red" : percent > 70 ? "yellow" : "green";
}

export function buildLines(i: OcInput): Segment[][] {
	const sep: Segment = { text: " | ", tone: "comment" };
	const width = i.width1 ?? (i.width > 0 ? i.width : 80); // 行1 预算（与宿主 usage/快捷键同行）
	const width2 = i.width > 0 ? i.width : 80; // 行2 预算（整行独占）

	// ---------- 行1 ----------
	const home = i.home;
	let cwd = i.cwd;
	if (home && (cwd === home || cwd.startsWith(home + "/"))) cwd = "~" + cwd.slice(home.length);

	const durText = i.durationMs != null ? fmtDurationElapsed(Math.max(0, i.durationMs)) : "";
	const hasBranch = !!i.branch && i.head !== "" && i.head !== "(detached)"; // 字面 ( 开头的真分支不误判（猎杀五轮 B-2b）
	// 探针与渲染同纪律（猎杀五轮 B-oc-1 随修）：detached 时 counts/ab 照渲染，
	// gitRest 也必须计入——否则预算虚低、整行溢出交硬截断
	const _gitAny = hasBranch || i.ab !== "" || (i.added + i.deleted + i.modified) > 0;
	const gitRest = _gitAny
		? visibleWidth(` | ${hasBranch ? foldBranch(i.branch!) : ""}${i.ab}`) + countsWidth(i)
		: 0;
	// herdr 与徽标是固定宽度的段，放不下就整段丢，不能像路径/分支那样截半（底行预算比框内窄，
	// 窄到 54 格时会出现 "| w11:t1:" 这种半个 id）
	const badgeRest = visibleWidth(" | oc");
	const herdrRest = i.herdr ? visibleWidth(` | ${i.herdr}`) : 0;
	const minPath = 9;
	const keepHerdr = i.herdr ? width - gitRest - badgeRest >= herdrRest + minPath : false;
	const baseRest = gitRest + (keepHerdr ? herdrRest : 0) + badgeRest;
	let keepDuration = durText !== "";
	let rest = baseRest + (keepDuration ? DUR_BUDGET : 0);
	if (keepDuration && width - rest < minPath) {
		keepDuration = false;
		rest = baseRest;
	}
	const maxPath = Math.max(minPath, width - rest);
	const segs = cwd.split("/");
	let displayPath = cwd;
	if (visibleWidth(cwd) > maxPath) {
		const cands = [
			`${segs.slice(0, 2).join("/")}/…/${segs.slice(-2).join("/")}`,
			`${segs[0]}/…/${segs.slice(-2).join("/")}`,
			`…/${segs.slice(-2).join("/")}`,
			`…/${segs[segs.length - 1]}`,
		];
		displayPath = cands.find((c) => visibleWidth(c) <= maxPath) ?? cands[3];
		if (visibleWidth(displayPath) > maxPath) {
			const last = segs[segs.length - 1];
			const keep = maxPath - 2;
			displayPath = keep >= 1 ? `…${sliceCells(last, keep, true)}` : sliceCells(displayPath, maxPath, false);
		}
	}

	// 行1 尾部级联：整行放不下时先丢 git 计数（+4/~1/✱6），再硬截断——避免把 ↑0↓0 切成 ↑0↓
	// cwd 可省（宿主已在 prompt 框下沿显示它时，oc 侧传空串避重复）
	const line1With = (k: { counts: boolean; ab: boolean; cwd: boolean; herdr?: boolean; dur?: boolean; fold?: number }): Segment[] => {
		const segs: Segment[] = [];
		const g = (arr: Segment[]) => {
			if (!arr.length) return;
			if (segs.length) segs.push(sep);
			segs.push(...arr);
		};
		if (k.cwd && displayPath) g([{ text: displayPath, tone: "comment" }]);
		// detached HEAD：分支名不显（设计），ab/counts 照常——counts 是铁律
		// （猎杀五轮 B-oc-1，与 cc/pi/qc 同步：旧版 hasBranch 门控把整段吞掉）
		const git: Segment[] = [];
		if (hasBranch) git.push({ text: foldBranch(i.branch!, k.fold ?? 24), tone: "purple" });
		if (k.ab && i.ab) git.push({ text: i.ab, tone: "fg" });
		if (k.counts) {
			if (i.added) git.push({ text: " ", tone: "fg" }, { text: `+${i.added}`, tone: "green" });
			if (i.deleted) git.push({ text: " ", tone: "fg" }, { text: `~${i.deleted}`, tone: "red" });
			if (i.modified) git.push({ text: " ", tone: "fg" }, { text: `✱${i.modified}`, tone: "yellow" });
		}
		g(git);
		// herdr 坐标（面板位置）默认保到最后：级联里排在 cwd 之后丢（不用 keepHerdr 门，级联自己控制）
		if ((k.herdr ?? true) && i.herdr) g([{ text: i.herdr, tone: "comment" }]);
		const badge: Segment[] = [{ text: "oc", tone: "comment" }];
		if ((k.dur ?? keepDuration) && durText) badge.push({ text: " · ", tone: "comment" }, { text: durText, tone: "fg" });
		g(badge);
		return segs;
	};
	const line1Full = line1With({ counts: true, ab: true, cwd: true });
	// 级联优先级：段 > 分支长度 > cwd > 时长 > 计数 > ab > herdr。
	// 时长（`· 24h37m`）与 herdr 是面板身份信息，比 cwd 更后丢；
	// 分支按折叠档 24→20→16→12→8→4→0 从宽到窄试（4/0 档与 cc/qc/pi
	// 的六级梯子对齐）。全放不下才硬截断。
	const folds = [24, 20, 16, 12, 8, 4, 0] as const;
	const variants: Segment[][] = [];
	const pushVariants = (counts: boolean, ab: boolean, cwd: boolean, dur: boolean, herdr = true) => {
		for (const f of folds) variants.push(line1With({ counts, ab, cwd, dur, herdr, fold: f }));
	};
	pushVariants(true, true, true, true);
	pushVariants(true, true, false, true);
	pushVariants(true, true, false, false);
	pushVariants(false, true, false, false);
	pushVariants(false, false, false, false);
	pushVariants(false, false, false, false, false);
	const line1: Segment[] = variants.find((v) => visibleWidth(plain(v)) <= width) ?? line1Full;

	// ---------- 行2 ----------
	// 入口净化（猎杀五轮 B-oc-3）：NaN 是合法 number，token/ctx 混进来渲染
	// ↑NaNM、NaN%/200K 且色档比较全 false 落 green。非有限一律当 0/未知。
	const _n = (v: number | null | undefined) => (typeof v === "number" && Number.isFinite(v) ? v : 0);
	const inTok = _n(i.inputTokens), outTok = _n(i.outputTokens), rcTok = _n(i.cacheRead);
	const ctxPct = typeof i.ctxPercent === "number" && Number.isFinite(i.ctxPercent) ? i.ctxPercent : null;
	const ctxWin = _n(i.ctxWindow);
	const chText =
		rcTok > 0 && inTok + rcTok + _n(i.cacheWrite) > 0
			? `CH${quantize2((rcTok / (inTok + rcTok + _n(i.cacheWrite))) * 100).toFixed(2)}%`
			: "";
	const cpText = i.compactions > 0 ? `CP${i.compactions}` : "";
	// 上下文占用与 TTFT 也是「整段丢」的语义，窄到放不下就整段不显示，
	// 不能只留 `| 16.24%/1M` 或留个孤零零的 `TTFT`
	const ctxFull = ctxWin > 0 ? `${ctxPct != null ? `${quantize2(ctxPct).toFixed(2)}%` : "?"}/${fmtTokens(ctxWin)}` : "";
	const ctxShort = ctxWin > 0 && ctxPct != null ? `${Math.round(ctxPct)}%` : "";
	const ttftText = i.ttftMs != null ? fmtTtft(i.ttftMs) : "";
	const ctxBudget = ctxFull ? visibleWidth(`${sep.text}${ctxFull}`) : 0;
	const ttftBudget = ttftText ? 1 + visibleWidth(ttftText) : 0;
	const identity: Segment[] = i.model ? [{ text: i.model, tone: "pink" }] : [];
	if (identity.length && i.thinking) identity.push({ text: " · ", tone: "fg" }, { text: i.thinking, tone: "cyan" });

	type Keep = { ttft: boolean; ch: boolean; cp: boolean; ctx: boolean; ctxShort?: boolean };
	const assemble = (k: Keep): Segment[] => {
		const out: Segment[] = [{ text: `↑${fmtTokens(inTok)} ↓${fmtTokens(outTok)}`, tone: "fg" }];
		out.push(sep, { text: `R${fmtTokens(rcTok)}`, tone: "fg" });
		if (k.ch) out.push({ text: " ", tone: "fg" }, { text: chText, tone: "cyan" });
		if (k.cp) out.push({ text: " ", tone: "fg" }, { text: cpText, tone: "comment" });
		if (k.ctx) out.push(sep, { text: k.ctxShort ? ctxShort : ctxFull || ctxShort, tone: ctxTone(ctxPct) });
		if (k.ttft) out.push({ text: " ", tone: "fg" }, { text: ttftText, tone: ttftColor(i.ttftMs) });
		if (identity.length) out.push(sep, ...identity);
		return out;
	};
	const budget = (k: Keep): number => {
		const used = visibleWidth(plain(assemble(k)));
		return used + (k.ttft ? Math.max(0, TTFT_BUDGET - visibleWidth(ttftText)) : 0);
	};
	// 超宽时先把 ctx% 换成短形 `16%`（丢窗口大小、保住 CH/TTFT），仍不够再走梯子
	// TTFT → CH → CP → ctx%（顺序与 cc/pi 一致；ctx 永远在 CH/CP 之后、TTFT 之前）
	let keep: Keep = { ttft: !!ttftText, ch: !!chText, cp: !!cpText, ctx: !!ctxFull };
	if (budget(keep) > width2 && keep.ctx && ctxShort) {
		const shortKeep: Keep = { ...keep, ctxShort: true };
		if (budget(shortKeep) <= width2) keep = shortKeep;
	}
	for (const drop of ["ttft", "ch", "cp", "ctx"] as const) {
		if (budget(keep) <= width2) break;
		keep = { ...keep, [drop]: false };
	}

	return [truncateSegments(line1, width), truncateSegments(assemble(keep), width2)];
}

function countsWidth(i: OcInput): number {
	let w = 0;
	if (i.added) w += 1 + visibleWidth(`+${i.added}`);
	if (i.deleted) w += 1 + visibleWidth(`~${i.deleted}`);
	if (i.modified) w += 1 + visibleWidth(`✱${i.modified}`);
	return w;
}
