// 自定义 footer：还原内置两行布局，模型位置显示可读名
// 行1: ~/cwd | branch ↑a↓b +增 ~删 ✱改 | ws:tab:pane | pi   行2: ↑in ↓out R CH CP | ctx%/win | 模型 · 思考 · 时长（行内布局，与 wren.py 同构）
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

	const install = (ctx: any) => {
		const sessionStart = Date.now();
		const herdrId = [
			process.env.HERDR_WORKSPACE_ID,
			process.env.HERDR_TAB_ID?.split(":").pop(),
			process.env.HERDR_PANE_ID?.split(":").pop(),
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
		const fmtDuration = (ms: number) => {
			const s = Math.floor(ms / 1000);
			const h = Math.floor(s / 3600);
			return h > 0 ? `${h}h${Math.floor((s % 3600) / 60)}m` : `${Math.floor(s / 60)}m`;
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
			// 分支折叠：与 wren.py 的 fold_branch 同规则（>24 字符截中段保头尾）。
			// 路径折叠已有（render 内 segs 逻辑），分支此前不折叠、长分支会把
			// 行2 模型段挤掉（truncateToWidth 砍尾）。
			// 分支折叠：尾重头轻（head 8 / tail 15），与 wren.py 的 fold_branch 同规则
			const foldBranch = (b: string, maxLen = 24) =>
				visibleWidth(b) <= maxLen
					? b
					: sliceCells(b, 8, false) + "…" + sliceCells(b, 15, true);
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
					const hasBranch = !!branch && git.head !== "" && !git.head.startsWith("(");
					// 路径折叠：预算驱动逐级降级（与 wren.py 的 fold_path 同规则）。
					// 行1 预算 = render width − 其余段真实可见宽（CR 轮 10：固定 −40
					// 在长分支+多脏文件+herdr 场景不够，整行可 88 > 80、徽标被截）
					const rest =
						(hasBranch ? visibleWidth(` | ${foldBranch(branch)}${git.ab}${git.counts}`) : 0) +
						(herdrTag ? visibleWidth(` | ${herdrTag}`) : 0) +
						visibleWidth(" | pi");
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
					const coloredGit = hasBranch
						? c("purple", foldBranch(branch)) + c("fg", git.ab) + git.counts
						: "";
					// 行1 尾的宿主徽标：同屏多个 agent 时区分 CC / pi（词汇表复用 wren install 的目标名）
					const left1 = c("comment", displayPath)
						+ (coloredGit ? ` ${sep1} ${coloredGit}` : "")
						+ (herdrTag ? ` ${sep1} ${c("comment", herdrTag)}` : "")
						+ ` ${sep1} ${c("comment", "pi")}`;
					// 行内布局（与 wren.py 一致）：herdr 段已在 left1 里以 " | " 拼接，
					// 不做右对齐/pad。truncateToWidth 保留防溢出。
					let line1 = truncateToWidth(left1, width);

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
							input += m.usage.input;
							output += m.usage.output;
							cacheRead += m.usage.cacheRead ?? 0;
							cacheWrite += m.usage.cacheWrite ?? 0;
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
					const ctxPercent = ctxUsage?.percent != null ? `${ctxUsage.percent.toFixed(2)}%` : "?";
					const ctxPercentText = `${ctxPercent}/${fmt(ctxWindowSize)}`;
					const ctxColorName = ctxUsage?.percent != null
						? ctxUsage.percent > 90 ? "red" : ctxUsage.percent > 70 ? "yellow" : "green"
						: "comment";
					// 最新缓存命中率：公式与 pi 内置 footer 相同（最后一条 assistant 的
					// cacheRead/prompt，prompt 不含 output）。位数取两位小数与 Claude Code
					// 侧的 wren.py 对齐；pi 内置 footer 用的是一位，此处有意不跟。
					let ch = "";
					if (last) {
						const u = last.usage;
						const promptTokens = u.input + (u.cacheRead ?? 0) + (u.cacheWrite ?? 0);
						// 无缓存会话不显示 CH（与 wren.py 的 ch_cache > 0 条件统一；
						// CR 轮 7 指出旧的 promptTokens>0 会挂一个恒 0 的 CH0.00%）
						if (promptTokens > 0 && (u.cacheRead ?? 0) > 0)
							ch = ` CH${((u.cacheRead / promptTokens) * 100).toFixed(2)}%`;
					}
					const cp = compactions > 0 ? ` CP${compactions}` : "";
					// Dracula: token 白、R 白、CH 青、CP 灰、ctx% 三档（>70 黄、>90 红，pi 语义）
					const sep2 = c("comment", "|");
					const tokGroup2 = `R${fmt(cacheRead)}` + (ch ? " " + c("cyan", ch.trim()) : "") + (cp ? " " + c("comment", cp.trim()) : "");
					const left = c("fg", `↑${fmt(input)} ↓${fmt(output)}`) + ` ${sep2} ` + tokGroup2
						+ ` ${sep2} ${c(ctxColorName, ctxPercentText)}`;

					// Dracula: 模型粉 · 思考青 · 时长白。分隔符 · 与 thinking 缺省隐藏均与 wren.py 一致
					const raw = model?.name || model?.id || "no-model";
					const display = raw.includes("/") ? raw.split("/").pop()! : raw;
					const rightParts = [c("pink", display)];
					if (ctx.thinkingLevel) rightParts.push(c("cyan", ctx.thinkingLevel));
					rightParts.push(c("fg", fmtDuration(Date.now() - sessionStart)));
					const right = rightParts.join(" · ");

					// 行内布局（与 wren.py 一致）：右段直接接在 " | " 后，无 pad/右对齐
					const line2 = truncateToWidth(`${left} ${sep2} ${right}`, width);
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
