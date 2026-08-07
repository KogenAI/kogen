// tools.ts — generates log_section_<role>/log_append_<role> tool pairs from
// roles.ts, plus registers the role-less gate_status/log_read readers.
//
// Role never crosses the tool boundary as an argument — it is baked into
// which tool the caller was granted (per-role .md.j2 tools: frontmatter is
// the offered-tool gate; see AGENTS.md pitch probe #7). Each generated
// writer hardcodes `--role <that-role>` server-side.

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { runCodegenLog, runCodegenAdvise } from "./exec";
import { readGateStatus, readLog, LogView } from "./readers";
import {
  ROLES,
  RoleSpec,
  appendToolName,
  sectionToolName,
  MarkerKind,
} from "./roles";

function errorResult(message: string) {
  return { content: [{ type: "text" as const, text: message }], isError: true };
}

function okResult(text: string) {
  return { content: [{ type: "text" as const, text }] };
}

function toArgs(base: string[], slug?: string): string[] {
  return slug ? [...base, "--slug", slug] : base;
}

function registerSectionTool(server: McpServer, spec: RoleSpec) {
  server.registerTool(
    sectionToolName(spec.role),
    {
      title: `Write ${spec.role} cycle-log section`,
      description:
        `Append this step's ev:role body (and optionally ev:learned) for role "${spec.role}" ` +
        `to the active cycle log. Role is fixed to "${spec.role}" — never passed as an argument.`,
      inputSchema: {
        body: z
          .string()
          .min(1)
          .describe("Free-form prose body for this role's ev:role event."),
        learned: z
          .string()
          .optional()
          .describe("Optional ev:learned text appended in the same call."),
        slug: z
          .string()
          .optional()
          .describe("Cycle slug; omit to resolve via .active."),
      },
    },
    async ({ body, learned, slug }) => {
      const args = toArgs(["section", spec.role], slug);
      if (learned) args.push("--learned", learned);
      const result = runCodegenLog(args, body);
      if (!result.ok)
        return errorResult(`codegen-log section failed: ${result.stderr}`);
      return okResult(result.stdout || `wrote ev:role for ${spec.role}`);
    },
  );
}

const MARKER_FLAG: Record<MarkerKind, string> = {
  learned: "--learned",
  no_learning: "--no-learning",
  died: "--died",
  verdict: "--verdict",
  files_to_touch: "--files-to-touch",
  files_modified: "--files-modified",
};

function registerAppendTool(server: McpServer, spec: RoleSpec) {
  const allowedKinds: MarkerKind[] = [
    "learned",
    "no_learning",
    "died",
    ...spec.extraKinds,
  ];

  server.registerTool(
    appendToolName(spec.role),
    {
      title: `Append ${spec.role} cycle-log marker event`,
      description:
        `Append a typed marker event (learned/no_learning/died${spec.extraKinds.length ? "/" + spec.extraKinds.join("/") : ""}) ` +
        `for role "${spec.role}". Role is fixed to "${spec.role}" — never passed as an argument.`,
      inputSchema: {
        kind: z
          .enum(allowedKinds as [MarkerKind, ...MarkerKind[]])
          .describe("Which marker event to append."),
        text: z
          .string()
          .optional()
          .describe("Text payload for learned/no_learning/died --cause."),
        body: z
          .string()
          .optional()
          .describe(
            "Raw text/JSON payload for files_to_touch/files_modified (piped via stdin).",
          ),
        died_kind: z
          .enum(["interrupted", "aborted"])
          .optional()
          .describe("Required when kind=died."),
        verdict_value: z
          .enum(["clear", "failed", "inconclusive"])
          .optional()
          .describe("Required when kind=verdict."),
        slug: z
          .string()
          .optional()
          .describe("Cycle slug; omit to resolve via .active."),
      },
    },
    async ({ kind, text, body, died_kind, verdict_value, slug }) => {
      if (!allowedKinds.includes(kind)) {
        return errorResult(
          `role "${spec.role}" is not granted marker kind "${kind}"`,
        );
      }
      const args = toArgs(["append", spec.role], slug);
      let stdinBody: string | undefined;

      switch (kind) {
        case "learned":
        case "no_learning":
          if (!text) return errorResult(`kind=${kind} requires "text"`);
          args.push(MARKER_FLAG[kind], text);
          break;
        case "died":
          if (!died_kind) return errorResult('kind=died requires "died_kind"');
          args.push("--died", died_kind);
          if (text) args.push("--cause", text);
          break;
        case "verdict":
          if (!verdict_value)
            return errorResult('kind=verdict requires "verdict_value"');
          args.push("--verdict", verdict_value);
          break;
        case "files_to_touch":
        case "files_modified":
          if (!body)
            return errorResult(
              `kind=${kind} requires "body" (piped via stdin)`,
            );
          args.push(MARKER_FLAG[kind], "@-");
          stdinBody = body;
          break;
      }

      const result = runCodegenLog(args, stdinBody);
      if (!result.ok)
        return errorResult(`codegen-log append failed: ${result.stderr}`);
      return okResult(result.stdout || `wrote ev:${kind} for ${spec.role}`);
    },
  );
}

function registerReaders(server: McpServer) {
  server.registerTool(
    "gate_status",
    {
      title: "Read gate verdict",
      description:
        "Read the current codegen/gate-pending/gate-result.json verdict, exit code, and witness.",
      inputSchema: {
        cwd: z
          .string()
          .describe(
            "Absolute cwd of the active build (contains codegen/gate-pending/).",
          ),
      },
    },
    async ({ cwd }) => {
      try {
        const status = readGateStatus(cwd);
        return okResult(JSON.stringify(status, null, 2));
      } catch (err) {
        return errorResult(String(err instanceof Error ? err.message : err));
      }
    },
  );

  server.registerTool(
    "log_read",
    {
      title: "Read cycle log projection",
      description:
        "Read the active cycle log filtered by view: manifest (the loop's files_to_touch), " +
        "retro (ev:learned events), or full (every event).",
      inputSchema: {
        cwd: z
          .string()
          .describe(
            "Absolute cwd of the active build (contains codegen/logging/).",
          ),
        view: z
          .enum(["manifest", "retro", "full"])
          .describe("Which projection to return."),
        slug: z
          .string()
          .optional()
          .describe("Cycle slug; omit to resolve via .active."),
        role: z.string().optional().describe("Filter to one role's events."),
      },
    },
    async ({ cwd, view, slug, role }) => {
      try {
        const result = readLog(cwd, view as LogView, slug, role);
        return okResult(JSON.stringify(result, null, 2));
      } catch (err) {
        return errorResult(String(err instanceof Error ? err.message : err));
      }
    },
  );

  // Current build harness is baked in server-side — the caller never picks
  // it. codegen-advise maps it to a STRONGER model of the SAME harness.
  server.registerTool(
    "advise",
    {
      title: "Ask a stronger model before you guess",
      description:
        "Call this when you are UNSURE, not just when something has already failed: " +
        "choosing between two approaches with no stated reason to prefer one, unable to " +
        "state the correctness of what you are about to write as a testable claim, relying " +
        "on a tool or language mechanism whose behavior you have assumed but not verified, " +
        "or about to depart from a numbered decision in the pitch you were handed. Also use " +
        "it on repeated gate failures or a rework attempt that keeps failing the same way. " +
        "Shells codegen-advise, which asks a stronger model of the SAME harness, with clean " +
        "context, for a recovery plan. This is a full LLM call — expect it to take tens of " +
        "seconds.",
      inputSchema: {
        context: z
          .string()
          .min(1)
          .describe(
            "Describe what you are unsure about — the mechanism you assumed, the choice " +
              "you're weighing, or a failure, if there is one — but there does not need to " +
              "be one. The more concrete, the better the plan.",
          ),
      },
    },
    async ({ context }) => {
      const result = runCodegenAdvise("claude_code", context);
      if (!result.ok) {
        return errorResult(result.stderr || "codegen-advise failed");
      }
      return okResult(result.stdout);
    },
  );
}

export function registerAllTools(server: McpServer) {
  for (const spec of ROLES) {
    registerSectionTool(server, spec);
    registerAppendTool(server, spec);
  }
  registerReaders(server);
}
