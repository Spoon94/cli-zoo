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

// 分支折叠：尾重头轻（头 8 / 尾 15），与 wren.py 的 fold_branch 同规则
export function foldBranch(b: string, maxLen = 24): string {
	return visibleWidth(b) <= maxLen ? b : sliceCells(b, 8, false) + "…" + sliceCells(b, 15, true);
}

// 999_500~999_999 走 Math.round(n/1000) 会得到 1000K，必须显示 1.0M
// （与 wren.py / wren-pi.ts / ccstatusline 同一规则）
export function fmtTokens(n: number): string {
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
	width: number;
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
	const width = i.width > 0 ? i.width : 80;

	// ---------- 行1 ----------
	const home = i.home;
	let cwd = i.cwd;
	if (home && (cwd === home || cwd.startsWith(home + "/"))) cwd = "~" + cwd.slice(home.length);

	const durText = i.durationMs != null ? fmtDurationElapsed(Math.max(0, i.durationMs)) : "";
	const hasBranch = !!i.branch && i.head !== "" && !i.head.startsWith("(");
	const gitRest = hasBranch ? visibleWidth(` | ${foldBranch(i.branch!)}${i.ab}`) + countsWidth(i) : 0;
	const herdrRest = i.herdr ? visibleWidth(` | ${i.herdr}`) : 0;
	const baseRest = gitRest + herdrRest + visibleWidth(" | oc");
	let keepDuration = durText !== "";
	let rest = baseRest + (keepDuration ? DUR_BUDGET : 0);
	if (keepDuration && width - rest < 16) {
		keepDuration = false;
		rest = baseRest;
	}
	const maxPath = Math.max(16, width - rest);
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

	const line1: Segment[] = [{ text: displayPath, tone: "comment" }];
	if (hasBranch) {
		line1.push(sep, { text: foldBranch(i.branch!), tone: "purple" });
		if (i.ab) line1.push({ text: i.ab, tone: "fg" });
	}
	const counts: Segment[] = [];
	if (i.added) counts.push({ text: `+${i.added}`, tone: "green" });
	if (i.deleted) counts.push({ text: `~${i.deleted}`, tone: "red" });
	if (i.modified) counts.push({ text: `✱${i.modified}`, tone: "yellow" });
	counts.forEach((seg) => {
		line1.push({ text: " ", tone: "fg" }, seg);
	});
	if (i.herdr) line1.push(sep, { text: i.herdr, tone: "comment" });
	line1.push(sep, { text: "oc", tone: "comment" });
	if (keepDuration) line1.push({ text: " · ", tone: "comment" }, { text: durText, tone: "fg" });

	// ---------- 行2 ----------
	const chText =
		i.cacheRead > 0 && i.inputTokens + i.cacheRead + i.cacheWrite > 0
			? `CH${((i.cacheRead / (i.inputTokens + i.cacheRead + i.cacheWrite)) * 100).toFixed(2)}%`
			: "";
	const cpText = i.compactions > 0 ? `CP${i.compactions}` : "";
	const ctxText = i.ctxWindow > 0 ? `${i.ctxPercent != null ? `${i.ctxPercent.toFixed(2)}%` : "?"}/${fmtTokens(i.ctxWindow)}` : "";
	const ttftText = i.ttftMs != null ? fmtTtft(i.ttftMs) : "";
	const identity: Segment[] = [{ text: i.model, tone: "pink" }];
	if (i.thinking) identity.push({ text: " · ", tone: "fg" }, { text: i.thinking, tone: "cyan" });

	const assemble = (k: { ttft: boolean; ch: boolean; cp: boolean }): Segment[] => {
		const out: Segment[] = [{ text: `↑${fmtTokens(i.inputTokens)} ↓${fmtTokens(i.outputTokens)}`, tone: "fg" }];
		out.push(sep, { text: `R${fmtTokens(i.cacheRead)}`, tone: "fg" });
		if (k.ch) out.push({ text: " ", tone: "fg" }, { text: chText, tone: "cyan" });
		if (k.cp) out.push({ text: " ", tone: "fg" }, { text: cpText, tone: "comment" });
		if (ctxText) out.push(sep, { text: ctxText, tone: ctxTone(i.ctxPercent) });
		if (k.ttft) out.push({ text: " ", tone: "fg" }, { text: ttftText, tone: ttftColor(i.ttftMs) });
		out.push(sep, ...identity);
		return out;
	};
	const budget = (k: { ttft: boolean; ch: boolean; cp: boolean }): number => {
		const used = visibleWidth(plain(assemble(k)));
		return used + (k.ttft ? Math.max(0, TTFT_BUDGET - visibleWidth(ttftText)) : 0);
	};
	let keep = { ttft: !!ttftText, ch: !!chText, cp: !!cpText };
	for (const drop of ["ttft", "ch", "cp"] as const) {
		if (budget(keep) <= width) break;
		keep = { ...keep, [drop]: false };
	}

	return [truncateSegments(line1, width), truncateSegments(assemble(keep), width)];
}

function countsWidth(i: OcInput): number {
	let w = 0;
	if (i.added) w += 1 + visibleWidth(`+${i.added}`);
	if (i.deleted) w += 1 + visibleWidth(`~${i.deleted}`);
	if (i.modified) w += 1 + visibleWidth(`✱${i.modified}`);
	return w;
}
