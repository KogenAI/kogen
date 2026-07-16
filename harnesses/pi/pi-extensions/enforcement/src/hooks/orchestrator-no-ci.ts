/**
 * orchestrator-no-ci.ts — Pi enforcement: deny gate commands for the orchestrator.
 *
 * Mirrors: harnesses/claude/hooks/orchestrator-no-ci.sh
 * Event: tool_call
 * Matcher: bash
 *
 * Only enforces when AGENT_TYPE is empty AND AGENT_ID is empty (orchestrator level).
 * Subagents (any non-empty AGENT_TYPE or AGENT_ID) pass through.
 * ops/experiment/babysit mode (CLAUDE_ROLE / PI_ROLE) bypasses — full gate-command access.
 * ops runs on live boxes; experiment is a standalone source-writable dev session;
 * babysit dispatches the existing codegen-build --queue drain.
 *
 * Blocks:
 *   make ci / ci-cover / predeploy
 *   make llm / llm-phoenix / llm-all / llm-phoenix-seed / llm-phoenix-validate
 *        / llm-retry / llm-summary / llm-kill
 *   bare mix test (no path), mix test flags-only, mix test --cover, mix coveralls*
 *   any mix test (orchestrator MUST NOT run tests per roles/orchestrator.md)
 *
 * Allows (early-return before block regex):
 *   make gate-status / gate-logs / gate-kill
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { deny, debugLog, isCodegenLogWrite } from "../lib/hook-helpers";

export const HANDLER_META = {
  name: "orchestrator-no-ci",
  event: "tool_call",
  matcher: "bash",
} as const;

export function register(pi: ExtensionAPI): void {
  pi.on("tool_call", async (event) => {
    if (event.toolName !== "bash") return;

    const agentType = process.env["AGENT_TYPE"] ?? "";
    const agentId = process.env["AGENT_ID"] ?? "";

    debugLog(
      "orchestrator-no-ci",
      `agent_type=${agentType} agent_id=${agentId}`,
    );

    // ops/experiment/babysit bypass — full gate-command access on live boxes
    // (ops), standalone source-writable dev sessions (experiment), or the
    // drain supervisor dispatching codegen-build (babysit).
    const piRole = process.env["PI_ROLE"] ?? "";
    const claudeRole = process.env["CLAUDE_ROLE"] ?? "";
    if (
      piRole === "ops" ||
      claudeRole === "ops" ||
      piRole === "experiment" ||
      claudeRole === "experiment" ||
      piRole === "babysit" ||
      claudeRole === "babysit"
    ) {
      debugLog("orchestrator-no-ci", "skip: ops/experiment/babysit bypass");
      return;
    }

    // Only enforce for orchestrator level (both AGENT_TYPE and AGENT_ID empty).
    if (agentType !== "" || agentId !== "") {
      debugLog(
        "orchestrator-no-ci",
        `skip: subagent (agent_type=${agentType} agent_id=${agentId})`,
      );
      return;
    }

    const command: string =
      (event.input as { command?: string }).command ?? "";

    debugLog("orchestrator-no-ci", `cmd=${command}`);

    // A codegen-log write narrates gated phrases in its heredoc body; it is
    // never the gated action itself. Bypass before any phrase match or
    // counter increment.
    if (isCodegenLogWrite(command)) return;

    const denyMsg =
      "orchestrator-no-ci: the main-agent session MUST NOT run gate commands directly. Gate runs via the loop (non-interactive builds) or a SubagentStop hook (interactive-session fallback) after developer-* completes. To inspect a running gate, use `make gate-status`. To trigger a gate, delegate to a developer-* subagent.";

    // Allowlist: gate-status / gate-logs / gate-kill — early return before block.
    if (/^\s*make\s+(gate-status|gate-logs|gate-kill)(\s|$)/.test(command)) {
      debugLog("orchestrator-no-ci", "allow: gate management command");
      return;
    }

    // Block: make ci / ci-cover / predeploy
    if (
      /^\s*make\s+(ci|ci-cover|predeploy)(\s|$|\s*2>&1)/.test(command)
    ) {
      debugLog("orchestrator-no-ci", "DENY: make ci/ci-cover/predeploy");
      return deny(denyMsg);
    }

    // Block: make llm / llm-phoenix / llm-all / llm-phoenix-seed / llm-phoenix-validate
    //              / llm-retry / llm-summary / llm-kill
    if (
      /^\s*make\s+(llm|llm-phoenix|llm-all|llm-phoenix-seed|llm-phoenix-validate|llm-retry|llm-summary|llm-kill)(\s|$)/.test(
        command,
      )
    ) {
      debugLog("orchestrator-no-ci", "DENY: make llm*");
      return deny(denyMsg);
    }

    // Block: coverage flags / mix coveralls (any variant)
    if (
      /(^|\s)--cover(\s|$)|\bcoveralls\.(html|json)\b|\bmix\s+coveralls\b/.test(
        command,
      )
    ) {
      debugLog("orchestrator-no-ci", "DENY: coverage command");
      return deny(denyMsg);
    }

    // Block: bare mix test (no path)
    if (/^\s*mix\s+test\s*$/.test(command)) {
      debugLog("orchestrator-no-ci", "DENY: bare mix test");
      return deny(denyMsg);
    }

    // Block: any mix test — orchestrator MUST NOT run tests (per roles/orchestrator.md).
    if (/^\s*mix\s+test(\s|$)/.test(command)) {
      debugLog(
        "orchestrator-no-ci",
        "DENY: mix test (orchestrator must not run tests)",
      );
      return deny(denyMsg);
    }
  });
}
