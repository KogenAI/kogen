/**
 * planner-guard.ts — Pi enforcement: restrict planner to read-only operations.
 *
 * Mirrors: templates/shared/hooks/planner-guard.sh
 * Event: tool_call (PreToolUse equivalent)
 * Matcher: bash, write, edit
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import {
  deny,
  parseAgentType,
  debugLog,
  isCodegenLogWrite,
  stripHeredocBodies,
} from "../lib/hook-helpers";

export const HANDLER_META = {
  name: "planner-guard",
  event: "tool_call",
  matcher: "bash|write|edit",
} as const;

function isPlannerAgent(agentType: string): boolean {
  return agentType === "planner" || agentType.startsWith("planner-");
}

export function register(pi: ExtensionAPI): void {
  pi.on("tool_call", async (event) => {
    const agentType = parseAgentType();
    if (!isPlannerAgent(agentType)) return;

    debugLog("planner-guard", `tool=${event.toolName} agent=${agentType}`);

    // Write is always blocked for planners
    if (event.toolName === "write") {
      return deny(
        `BLOCKED by planner-guard: tool write forbidden for planner (planner never creates files — edit the session log via edit)`,
      );
    }

    // Edit only allowed on codegen/logging/ session log files
    if (event.toolName === "edit") {
      const filePath: string =
        (event.input as { path?: string; file_path?: string }).path ??
        (event.input as { path?: string; file_path?: string }).file_path ??
        "";
      // Allow relative path: codegen/logging/<file>.md
      const relativeOk = /^codegen\/logging\/[^/]+\.md$/.test(filePath);
      // Allow absolute path: /…/codegen/logging/<file>.md
      const absoluteOk = /^\/.+\/codegen\/logging\/[^/]+\.md$/.test(filePath);
      if (!relativeOk && !absoluteOk) {
        return deny(
          `BLOCKED by planner-guard: planner may only edit session log files under codegen/logging/ (got: ${filePath})`,
        );
      }
      return; // allowed
    }

    // Bash: block specific patterns
    if (event.toolName === "bash") {
      const command: string =
        (event.input as { command?: string }).command ?? "";

      // codegen-log carve-out (mirrors session-log-writer-only.ts): the plan
      // body is written via a piped or heredoc-fed `codegen-log section
      // --body @-` call, so the body is arbitrary plan prose that may
      // legitimately contain gate tokens, git verbs, redirect chars, or
      // ../ traversal sequences. isCodegenLogWrite() is INVOCATION-anchored,
      // not spelling-anchored — a command that merely SPELLS codegen-log
      // while running something else is correctly NOT exempt. Exit-allow
      // BEFORE the broad scans below so a real codegen-log invocation is
      // never denied by prose in its own body. The body is DATA to
      // codegen-log, never executed.
      if (isCodegenLogWrite(command)) {
        return;
      }

      // Fail-closed subject transform ahead of every raw-command scan
      // below: stripHeredocBodies() removes heredoc BODIES (arbitrary plan
      // prose, never shell content — see the carve-out above) so a gated
      // token sitting only inside a legitimate heredoc body never trips
      // these scans.
      const plannerCmd = stripHeredocBodies(command);

      // Path traversal
      if (/\.\.\//.test(plannerCmd)) {
        return deny(
          `BLOCKED by planner-guard: relative path traversal (..) forbidden — use absolute paths only`,
        );
      }

      // mix test
      if (/\bmix\s+test\b/.test(plannerCmd)) {
        return deny(
          `BLOCKED by planner-guard: mix test is forbidden for planner`,
        );
      }

      // mix ecto state-modifying
      if (/\bmix\s+ecto\.(migrate|reset|drop)\b/.test(plannerCmd)) {
        return deny(
          `BLOCKED by planner-guard: mix ecto.migrate/reset/drop is forbidden for planner`,
        );
      }

      // make ci/llm variants
      if (
        /\bmake\s+(ci|ci-fast|llm|llm-phoenix|llm-phoenix-seed|llm-summary|llm-retry|llm-kill)\b/.test(
          plannerCmd,
        )
      ) {
        return deny(
          `BLOCKED by planner-guard: make ci/llm/llm-phoenix/llm-phoenix-seed is forbidden for planner`,
        );
      }

      // git state modification
      if (
        /\bgit\s+(add|commit|rm|mv|stash|reset|checkout\s+\S+|branch\s+(-[dDmcC]|[^-]))\b/.test(
          plannerCmd,
        )
      ) {
        return deny(
          `BLOCKED by planner-guard: git state modification is forbidden for planner`,
        );
      }

      // mv — both src and dst must be under /tmp/ or codegen/logging/
      const mvMatch = plannerCmd.match(/\bmv\s+(\S+)\s+(\S+)/);
      if (mvMatch) {
        const src = mvMatch[1];
        const dst = mvMatch[2];
        for (const arg of [src, dst]) {
          if (!arg.startsWith("/tmp/") && !arg.startsWith("codegen/logging/")) {
            return deny(
              `BLOCKED by planner-guard: mv argument "${arg}" outside /tmp/ or codegen/logging/ is forbidden for planner`,
            );
          }
        }
        return; // allowed
      }

      // Shell redirect outside /tmp/ or codegen/logging/
      // Strip stderr tokens first
      const redirectCheck = plannerCmd
        .replace(/2>&1/g, "")
        .replace(/2>\/dev\/null/g, "");
      if (/>\s*[^/\s]|>\s*\//.test(redirectCheck)) {
        if (!/>\s*(codegen\/logging\/|\/tmp\/)/.test(redirectCheck)) {
          return deny(
            `BLOCKED by planner-guard: shell redirect to file outside /tmp/ or codegen/logging/ is forbidden for planner`,
          );
        }
      }

      // All other bash commands are allowed for planners (read-only investigation)
      return;
    }

    // Read: block implementer-only rule files
    if (event.toolName === "read") {
      const filePath: string =
        (event.input as { path?: string; file_path?: string }).path ??
        (event.input as { path?: string; file_path?: string }).file_path ??
        "";
      if (!filePath) return;

      const basename = filePath.split("/").pop() ?? "";
      const forbidden = new Set([
        "testing.md",
        "testing-liveview.md",
        "developer.md",
        "reviewer.md",
        "committer.md",
      ]);
      if (forbidden.has(basename)) {
        return deny(
          `BLOCKED by planner-guard: planner must not load implementer rules (${basename})`,
        );
      }
    }
  });
}
