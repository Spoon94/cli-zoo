// wren 的 opencode 侧 payload：TUI 插件，注册 app_bottom slot 渲染两行 statusline。
//
// opencode v1（1.18.x）的 TUI 插件 API：模块 `export default { id, tui(api) }`，
// `api.slots.register({ slots: { app_bottom() {...} } })`，渲染是进程内 OpenTUI/Solid JSX。
// 不是 cc/qc 的 stdin→stdout statusline 协议，故排版核心拆到 wren-oc.ts（纯函数、可测）。
//
// 安装：wren install oc → 本文件与 core 被拷到 $OPENCODE_CONFIG_DIR/plugins/，
// 并在 tui.json(c) 的 plugin 数组里加 "./plugins/wren-oc.tsx"。
//
// 注意：slot 渲染抛异常会把整个 TUI 打到崩溃页（1.18.33 实测），所以取数与排版全部 try/catch 兜底。
/** @jsxImportSource @opentui/solid */
import type { TuiPluginModule } from "@opencode-ai/plugin/tui"
import { execFile } from "node:child_process"
import { homedir } from "node:os"
import { createSignal } from "solid-js"
import { buildLines, type OcInput, type Segment, type Tone } from "./wren-oc.ts"

// Dracula 色板（与 cc/pi/qc 同表）；opencode 侧直接给 RGB 十六进制，由宿主决定降档
const DRACULA: Record<Tone, string> = {
	fg: "#f8f8f2",
	comment: "#6272a4",
	purple: "#bd93f9",
	green: "#50fa7b",
	red: "#ff5555",
	yellow: "#f1fa8c",
	pink: "#ff79c6",
	cyan: "#8be9fd",
};

type GitState = {
	repo: boolean;
	head: string;
	branch: string;
	ab: string;
	added: number;
	modified: number;
	deleted: number;
};

const EMPTY_GIT: GitState = { repo: false, head: "", branch: "", ab: "", added: 0, modified: 0, deleted: 0 };

// porcelain v2 解析：与 wren-cc.py / wren-pi.ts 同一套规则（detached 由 `# branch.head` 的 "(" 判定）
function parsePorcelain(out: string): GitState {
	const st: GitState = { ...EMPTY_GIT, repo: true };
	for (const ln of out.split("\n")) {
		if (ln.startsWith("# branch.head ")) st.head = ln.slice("# branch.head ".length).trim();
		else if (ln.startsWith("# branch.ab ")) {
			const p = ln.slice("# branch.ab ".length).trim().split(/\s+/);
			if (p.length === 2) st.ab = ` ↑${p[0].replace(/^\+/, "")}↓${p[1].replace(/^-/, "")}`;
		} else if (ln.startsWith("? ")) st.added += 1;
		else if (/^[12u] /.test(ln)) {
			const xy = ln.split(" ")[1] ?? "";
			if (xy[0] === "A") st.added += 1;
			else if (xy.includes("D")) st.deleted += 1;
			else st.modified += 1;
		}
	}
	// porcelain 的 branch.head 对 detached HEAD 给 "(detached)"，以 "(" 开头 = 无分支
	st.branch = st.head === "" || st.head.startsWith("(") ? "" : st.head;
	return st;
}

const tui = async (api: any) => {
	const [git, setGit] = createSignal<GitState>(EMPTY_GIT);
	const [compactions, setCompactions] = createSignal(0);

	// 慢变量（git 子进程 + compaction 计数）走 15s 轮询；token/ctx 等走 api.state 的响应式 store
	const refreshGit = () => {
		try {
			const directory = api.state?.path?.directory;
			if (!directory) return;
			execFile("git", ["-C", directory, "status", "--porcelain=v2", "--branch"], { timeout: 3000 }, (err, stdout) => {
				try {
					setGit(err ? EMPTY_GIT : parsePorcelain(String(stdout)));
				} catch {
					/* 轮询回调里抛异常只会污染事件循环，静默保底 */
				}
			});
		} catch {
			/* git 不可用（未安装 / 非 git 目录）时保持空态 */
		}
	};
	const countCompactions = () => {
		try {
			const route = api.route?.current;
			const sessionID = route?.name === "session" ? route.params?.sessionID : undefined;
			if (typeof sessionID !== "string" || !sessionID) {
				setCompactions(0);
				return;
			}
			let n = 0;
			for (const m of api.state.session.messages(sessionID)) {
				for (const part of api.state.part(m.id)) if (part?.type === "compaction") n += 1;
			}
			setCompactions(n);
		} catch {
			setCompactions(0);
		}
	};
	const poll = () => {
		refreshGit();
		countCompactions();
	};
	poll();
	const timer = setInterval(poll, 15000);
	api.lifecycle?.onDispose?.(() => clearInterval(timer));

	// TTFT 存量制（与 cc/qc 同语义）：最近一条 assistant 还没落 part 时保留上一轮值，不闪空白。
	// 会话切换时清空，避免把上一个会话的值带过来。
	let ttftCache: { session: string; ms: number | null } = { session: "", ms: null };

	const snapshot = (): OcInput => {
		const route = api.route?.current;
		const sessionID = route?.name === "session" && typeof route.params?.sessionID === "string" ? route.params.sessionID : undefined;
		const session = sessionID ? api.state.session.get(sessionID) : undefined;
		const messages = sessionID ? api.state.session.messages(sessionID) : [];
		let last: any = null;
		for (let k = messages.length - 1; k >= 0; k--) {
			if (messages[k]?.role === "assistant") {
				last = messages[k];
				break;
			}
		}
		const provider = (api.state.provider ?? []).find((p: any) => p.id === last?.providerID);
		const model = last ? provider?.models?.[last.modelID] : undefined;
		const limit = model?.limit?.context ?? 0;
		const total = last?.tokens?.total ?? 0;
		const homeModel = (): string => {
			const configured = api.state.config?.model;
			if (typeof configured !== "string" || !configured) return "no-model";
			return configured.includes("/") ? configured.split("/").pop()! : configured;
		};

		const parts = last ? api.state.part(last.id) : [];
		let firstStart = Infinity;
		for (const part of parts) {
			if (typeof part?.time?.start === "number" && part.time.start < firstStart) firstStart = part.time.start;
		}
		let ttft: number | null = null;
		if (last && firstStart !== Infinity) ttft = firstStart - last.time.created;
		const key = sessionID ?? "";
		if (ttftCache.session !== key) ttftCache = { session: key, ms: null };
		if (ttft != null) ttftCache.ms = ttft;

		const g = git();
		const herdr = [
			process.env.HERDR_WORKSPACE_ID,
			process.env.HERDR_TAB_ID?.split(":").pop(),
			process.env.HERDR_PANE_ID?.split(":").pop(),
		]
			.filter(Boolean)
			.join(":");

		return {
			width: Number(api.renderer?.width) || 80,
			cwd: String(api.state.path?.directory ?? process.cwd()),
			home: homedir(),
			branch: g.branch || null,
			head: g.head,
			ab: g.ab,
			added: g.added,
			modified: g.modified,
			deleted: g.deleted,
			herdr,
			durationMs: session?.time?.created ? Date.now() - session.time.created : null,
			inputTokens: session?.tokens?.input ?? 0,
			outputTokens: session?.tokens?.output ?? 0,
			cacheRead: session?.tokens?.cache?.read ?? 0,
			cacheWrite: session?.tokens?.cache?.write ?? 0,
			compactions: compactions(),
			ctxPercent: last && limit > 0 ? (total / limit) * 100 : null,
			ctxWindow: limit,
			model: model?.name ?? last?.modelID ?? homeModel(),
			thinking: last?.variant ?? "",
			ttftMs: ttftCache.ms,
		};
	};

	const lines = (): Segment[][] => {
		try {
			return buildLines(snapshot());
		} catch {
			// 取数失败时只留一行裸 cwd + 徽标，绝不把异常抛回 slot（那会崩 TUI）
			return [[{ text: `${api.state?.path?.directory ?? ""} | oc`, tone: "comment" }]];
		}
	};

	// 必须是 JSX 表达式里的调用：Solid 的组件体只执行一次，写在组件体的常量不会随信号重算
	const Footer = () => (
		<box flexDirection="column">
			{lines().map((segments) =>
				process.env.NO_COLOR ? (
					// NO_COLOR：不指定 fg，交给宿主/终端默认前景色（不是把 Dracula 白当"无色"）
					<text wrapMode="none">{segments.map((seg) => seg.text).join("")}</text>
				) : (
					<box flexDirection="row">
						{segments.map((seg) => (
							<text wrapMode="none" fg={DRACULA[seg.tone] ?? DRACULA.fg}>{seg.text}</text>
						))}
					</box>
				),
			)}
		</box>
	);

	api.slots.register({
		slots: {
			// app_bottom：活动路由下方的整宽区块。v1 没有 statusline 专用 slot，
			// 这是唯一能常驻显示两行的地方（v2 才有 prompt.footer.status）。
			app_bottom: () => <Footer />,
		},
	});
};

const plugin: TuiPluginModule & { id: string } = { id: "wren.oc", tui };
export default plugin;
