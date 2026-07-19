// codegen-tools.ts — Pi twin of harnesses/claude/mcp-server/. Registers the
// IDENTICAL tool set (role-baked cycle-log writers + role-less gate/log
// readers) via pi.registerTool instead of MCP, since Pi has no MCP config.
// Handlers exec the same codegen-log binary via array-argv execFileSync with
// body on stdin — the same load-bearing correctness property as the Claude
// server: never a shell string, never argv-interpolated.
//
// Tool names here are BARE (no mcp__codegen__ prefix) — templates/generator/
// config.yaml's tools.pi.tool_map maps each shared .md.j2 frontmatter
// mcp__codegen__<x> entry to this exact bare name, so per-role grant stays
// in the ONE shared frontmatter source; this file only supplies the runtime
// implementation Pi calls into.

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { execFileSync } from "node:child_process";
import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";
import { Type, type Static } from "@sinclair/typebox";

// ── roles.ts port (kept in sync by hand — separate npm package, no cross-import) ──

type MarkerKind =
    | "learned"
    | "no_learning"
    | "died"
    | "verdict"
    | "plan"
    | "plan_gate"
    | "files_to_touch"
    | "files_modified";

interface RoleSpec {
    role: string;
    extraKinds: MarkerKind[];
    readers: boolean;
}

const ROLES: RoleSpec[] = [
    { role: "planner-phoenix", extraKinds: ["plan", "plan_gate", "files_to_touch"], readers: false },
    { role: "planner-static", extraKinds: ["plan", "plan_gate", "files_to_touch"], readers: false },
    { role: "developer-phoenix-backend", extraKinds: ["files_modified"], readers: false },
    { role: "developer-phoenix-frontend", extraKinds: ["files_modified"], readers: false },
    { role: "developer-static", extraKinds: ["files_modified"], readers: false },
    { role: "reviewer-phoenix", extraKinds: [], readers: true },
    { role: "reviewer-static", extraKinds: [], readers: true },
    { role: "context-curator", extraKinds: [], readers: true },
    { role: "committer", extraKinds: [], readers: true },
];

function sectionToolName(role: string): string {
    return `log_section_${role.replace(/-/g, "_")}`;
}
function appendToolName(role: string): string {
    return `log_append_${role.replace(/-/g, "_")}`;
}

// ── exec.ts port ─────────────────────────────────────────────────────────────

interface ExecResult {
    ok: boolean;
    stdout: string;
    stderr: string;
}

function runCodegenLog(args: string[], stdinBody?: string): ExecResult {
    try {
        const stdout = execFileSync("codegen-log", args, {
            input: stdinBody ?? "",
            encoding: "utf8",
            stdio: ["pipe", "pipe", "pipe"],
        });
        return { ok: true, stdout, stderr: "" };
    } catch (err: unknown) {
        const e = err as { stdout?: Buffer | string; stderr?: Buffer | string; message?: string };
        const stdout = e.stdout ? e.stdout.toString() : "";
        const stderr = e.stderr ? e.stderr.toString() : (e.message ?? String(err));
        return { ok: false, stdout, stderr };
    }
}

// ── readers.ts port ──────────────────────────────────────────────────────────

interface GateStatus {
    verdict: string;
    exit: number | null;
    diff_files_count: number | null;
    ended: string | null;
    witness: string;
}

function readGateStatus(cwd: string): GateStatus {
    const path = join(cwd, "codegen", "gate-pending", "gate-result.json");
    if (!existsSync(path)) {
        throw new Error(`no gate-result.json at ${path} — no gate has run yet in this cwd`);
    }
    const raw = JSON.parse(readFileSync(path, "utf8"));
    return {
        verdict: raw.verdict ?? "",
        exit: typeof raw.exit === "number" ? raw.exit : null,
        diff_files_count: typeof raw.diff_files_count === "number" ? raw.diff_files_count : null,
        ended: raw.ended ?? null,
        witness: raw.witness ?? "",
    };
}

function resolveLogPath(cwd: string, slug?: string, envLogPath?: string): string {
    const loggingDir = join(cwd, "codegen", "logging");

    if (envLogPath && existsSync(envLogPath)) return envLogPath;

    if (slug) {
        if (!existsSync(loggingDir)) {
            throw new Error(`no cycle log matches slug "${slug}" — ${loggingDir} does not exist`);
        }
        const matches = readdirSync(loggingDir).filter((f) => f.endsWith(`_${slug}_cycle.jsonl`));
        if (matches.length === 0) {
            throw new Error(`no cycle log matches slug "${slug}"`);
        }
        matches.sort();
        return join(loggingDir, matches[matches.length - 1]);
    }

    const activeSentinel = join(loggingDir, ".active");
    if (existsSync(activeSentinel)) {
        const pointed = readFileSync(activeSentinel, "utf8").trim();
        if (pointed && existsSync(pointed)) return pointed;
    }

    if (existsSync(loggingDir)) {
        const candidates = readdirSync(loggingDir)
            .filter((f) => f.endsWith("_cycle.jsonl"))
            .map((f) => join(loggingDir, f));
        if (candidates.length > 0) {
            candidates.sort((a, b) => statSync(b).mtimeMs - statSync(a).mtimeMs);
            return candidates[0];
        }
    }

    throw new Error("no cycle log found (no CODEGEN_LOG_PATH, no slug match, no .active, no logs on disk)");
}

interface LogEvent {
    ev: string;
    role?: string;
    [key: string]: unknown;
}

function readEvents(logPath: string): LogEvent[] {
    const raw = readFileSync(logPath, "utf8");
    return raw
        .split("\n")
        .filter((line) => line.trim().length > 0)
        .map((line) => JSON.parse(line) as LogEvent);
}

type LogView = "manifest" | "retro" | "full";

function readLog(cwd: string, view: LogView, slug?: string, role?: string): { logPath: string; view: LogView; events: LogEvent[] } {
    const logPath = resolveLogPath(cwd, slug, process.env.CODEGEN_LOG_PATH);
    let events = readEvents(logPath);

    if (view === "manifest") {
        events = events.filter((e) => ["plan", "plan_gate", "files_to_touch"].includes(e.ev));
    } else if (view === "retro") {
        events = events.filter((e) => e.ev === "learned");
    }

    if (role) {
        events = events.filter((e) => e.role === role);
    }

    return { logPath, view, events };
}

// ── tool registration ────────────────────────────────────────────────────────

const MARKER_FLAG: Record<MarkerKind, string> = {
    learned: "--learned",
    no_learning: "--no-learning",
    died: "--died",
    verdict: "--verdict",
    plan: "--plan",
    plan_gate: "--plan-gate",
    files_to_touch: "--files-to-touch",
    files_modified: "--files-modified",
};

// Pi's AgentTool.execute contract: "Throw on failure instead of encoding
// errors in content" (pi-agent-core types.d.ts). Never swallow — every
// non-ok codegen-log exit surfaces as a thrown Error carrying stderr.
function okResult(text: string) {
    return { content: [{ type: "text" as const, text }], details: undefined };
}

function registerSectionTool(pi: ExtensionAPI, spec: RoleSpec) {
    const SectionParams = Type.Object({
        body: Type.String({ description: "Free-form prose body for this role's ev:role event." }),
        learned: Type.Optional(Type.String({ description: "Optional ev:learned text appended in the same call." })),
        slug: Type.Optional(Type.String({ description: "Cycle slug; omit to resolve via .active." })),
    });

    pi.registerTool({
        name: sectionToolName(spec.role),
        label: `Write ${spec.role} cycle-log section`,
        description:
            `Append this step's ev:role body (and optionally ev:learned) for role "${spec.role}" ` +
            `to the active cycle log. Role is fixed to "${spec.role}" — never passed as an argument.`,
        parameters: SectionParams,
        async execute(_toolCallId, params: Static<typeof SectionParams>) {
            const args = ["section", spec.role];
            if (params.slug) args.push("--slug", params.slug);
            if (params.learned) args.push("--learned", params.learned);
            const result = runCodegenLog(args, params.body);
            if (!result.ok) throw new Error(`codegen-log section failed: ${result.stderr}`);
            return okResult(result.stdout || `wrote ev:role for ${spec.role}`);
        },
    });
}

function registerAppendTool(pi: ExtensionAPI, spec: RoleSpec) {
    const allowedKinds: MarkerKind[] = ["learned", "no_learning", "died", ...spec.extraKinds];

    const AppendParams = Type.Object({
        kind: Type.Union(
            allowedKinds.map((k) => Type.Literal(k)),
            { description: "Which marker event to append." },
        ),
        text: Type.Optional(Type.String({ description: "Text payload for learned/no_learning/died --cause." })),
        body: Type.Optional(
            Type.String({
                description:
                    "Raw text/JSON payload for plan/plan_gate/files_to_touch/files_modified (piped via stdin).",
            }),
        ),
        died_kind: Type.Optional(
            Type.Union([Type.Literal("interrupted"), Type.Literal("aborted")], {
                description: "Required when kind=died.",
            }),
        ),
        verdict_value: Type.Optional(
            Type.Union([Type.Literal("clear"), Type.Literal("failed"), Type.Literal("inconclusive")], {
                description: "Required when kind=verdict.",
            }),
        ),
        slug: Type.Optional(Type.String({ description: "Cycle slug; omit to resolve via .active." })),
    });

    pi.registerTool({
        name: appendToolName(spec.role),
        label: `Append ${spec.role} cycle-log marker event`,
        description:
            `Append a typed marker event (learned/no_learning/died${spec.extraKinds.length ? "/" + spec.extraKinds.join("/") : ""}) ` +
            `for role "${spec.role}". Role is fixed to "${spec.role}" — never passed as an argument.`,
        parameters: AppendParams,
        async execute(_toolCallId, params: Static<typeof AppendParams>) {
            const { kind, text, body, died_kind, verdict_value, slug } = params;
            if (!allowedKinds.includes(kind as MarkerKind)) {
                throw new Error(`role "${spec.role}" is not granted marker kind "${kind}"`);
            }
            const args = ["append", spec.role];
            if (slug) args.push("--slug", slug);
            let stdinBody: string | undefined;

            switch (kind) {
                case "learned":
                case "no_learning":
                    if (!text) throw new Error(`kind=${kind} requires "text"`);
                    args.push(MARKER_FLAG[kind], text);
                    break;
                case "died":
                    if (!died_kind) throw new Error('kind=died requires "died_kind"');
                    args.push("--died", died_kind);
                    if (text) args.push("--cause", text);
                    break;
                case "verdict":
                    if (!verdict_value) throw new Error('kind=verdict requires "verdict_value"');
                    args.push("--verdict", verdict_value);
                    break;
                case "plan":
                case "plan_gate":
                case "files_to_touch":
                case "files_modified":
                    if (!body) throw new Error(`kind=${kind} requires "body" (piped via stdin)`);
                    args.push(MARKER_FLAG[kind], "@-");
                    stdinBody = body;
                    break;
            }

            const result = runCodegenLog(args, stdinBody);
            if (!result.ok) throw new Error(`codegen-log append failed: ${result.stderr}`);
            return okResult(result.stdout || `wrote ev:${kind} for ${spec.role}`);
        },
    });
}

function registerReaders(pi: ExtensionAPI) {
    const GateStatusParams = Type.Object({
        cwd: Type.String({ description: "Absolute cwd of the active build (contains codegen/gate-pending/)." }),
    });

    pi.registerTool({
        name: "gate_status",
        label: "Read gate verdict",
        description: "Read the current codegen/gate-pending/gate-result.json verdict, exit code, and witness.",
        parameters: GateStatusParams,
        async execute(_toolCallId, params: Static<typeof GateStatusParams>) {
            const status = readGateStatus(params.cwd);
            return okResult(JSON.stringify(status, null, 2));
        },
    });

    const LogReadParams = Type.Object({
        cwd: Type.String({ description: "Absolute cwd of the active build (contains codegen/logging/)." }),
        view: Type.Union([Type.Literal("manifest"), Type.Literal("retro"), Type.Literal("full")], {
            description: "Which projection to return.",
        }),
        slug: Type.Optional(Type.String({ description: "Cycle slug; omit to resolve via .active." })),
        role: Type.Optional(Type.String({ description: "Filter to one role's events." })),
    });

    pi.registerTool({
        name: "log_read",
        label: "Read cycle log projection",
        description:
            "Read the active cycle log filtered by view: manifest (planner's plan/plan_gate/files_to_touch), " +
            "retro (ev:learned events), or full (every event).",
        parameters: LogReadParams,
        async execute(_toolCallId, params: Static<typeof LogReadParams>) {
            const result = readLog(params.cwd, params.view as LogView, params.slug, params.role);
            return okResult(JSON.stringify(result, null, 2));
        },
    });
}

/** Every bare tool name this module registers — for parity assertions. */
export const CODEGEN_TOOL_NAMES: string[] = (() => {
    const names: string[] = [];
    for (const spec of ROLES) {
        names.push(sectionToolName(spec.role));
        names.push(appendToolName(spec.role));
    }
    names.push("gate_status", "log_read");
    return names.sort();
})();

export function register(pi: ExtensionAPI): void {
    for (const spec of ROLES) {
        registerSectionTool(pi, spec);
        registerAppendTool(pi, spec);
    }
    registerReaders(pi);
}
