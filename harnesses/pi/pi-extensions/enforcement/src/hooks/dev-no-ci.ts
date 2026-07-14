/**
 * dev-no-ci.ts — Pi enforcement: deny gate commands for developer-* agents.
 *
 * Mirrors: templates/shared/hooks/dev-no-ci.sh
 * Event: tool_call (PreToolUse equivalent)
 * Matcher: bash
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import {
  deny,
  parseAgentType,
  debugLog,
  isCodegenLogWrite,
} from "../lib/hook-helpers";

export const HANDLER_META = {
  name: "dev-no-ci",
  event: "tool_call",
  matcher: "bash",
} as const;

export function register(pi: ExtensionAPI): void {
  pi.on("tool_call", async (event) => {
    if (event.toolName !== "bash") return;

    const agentType = parseAgentType();
    if (!/^developer-/.test(agentType)) return;

    const command: string = (event.input as { command?: string }).command ?? "";
    debugLog("dev-no-ci", `agent=${agentType} cmd=${command}`);

    // A codegen-log write narrates gated phrases in its heredoc body; it is
    // never the gated action itself. Bypass before any phrase match or
    // counter increment.
    if (isCodegenLogWrite(command)) return;

    // Deny: make ci-fast / ci-cover / predeploy / llm / llm-phoenix / llm-all
    // (make ci / make test are the loop's own gate command — NOT denied; the
    // loop threads this exact command into the dev's own prompt and expects
    // it to be run in-session; see orchestration_loop.ex build_prompt/2.)
    if (
      /^\s*make\s+(ci-fast|ci-cover|predeploy|llm|llm-phoenix|llm-all)(\s|$)/.test(
        command,
      )
    ) {
      return deny(
        "Dev MUST NOT run this gate command. Use the loop's delegated gate command (typically `make test`) to iterate — see the loop's LoopGate (do_gate_loop/9). Specific test files are OK: `mix test test/path/file.exs`. For the LLM suite specifically, use `make llm-single FILE=<path>` to iterate on one file.",
      );
    }

    // Deny: genuinely-unowned expensive full-suite targets — real LLM calls,
    // multi-minute, pre-deploy-gate-only. Not the loop's per-cycle gate command.
    // test-hermetic is included (component of `make test`, but not the exact
    // string threaded into the dev's prompt — only `make test` itself is,
    // per GATE_COMMAND in .claude/gate-config.sh).
    if (
      /^\s*make\s+(test|test-all|test-hermetic|test-coverage|test-stacks(-claude|-pi)?|bench)(\s|$)/.test(
        command,
      )
    ) {
      return deny(
        "Dev MUST NOT run this full-suite target — it is slow and owned by the loop's LoopGate (do_gate_loop/9 in orchestration_loop.ex), which runs after your turn. Use targeted checks like `mix test test/path/file.exs` / `make hook-parity` / `make enforce-registry-parity` to iterate.",
      );
    }

    // Deny: full-suite coverage formatters — unconditional (no single-file form).
    if (/\bcoveralls\.(html|json)\b|\bmix\s+coveralls\b/.test(command)) {
      return deny(
        "Dev MUST NOT run coverage formatters (coveralls.html, coveralls.json, mix coveralls). Coverage runs the full suite — use the loop's delegated gate command instead.",
      );
    }

    // Deny: bare `mix test --cover` (no path) — full-suite coverage.
    // Allow `mix test --cover test/path/file.exs` as single-file aid.
    if (/(^|\s)--cover(\s|$)/.test(command)) {
      const hasPath = /[^\s]+\.exs|[^\s]+\/[^\s]+/.test(command);
      if (!hasPath) {
        return deny(
          "Bare `mix test --cover` runs full-suite coverage — dev MUST NOT. Use the loop's delegated gate command instead. A single file is OK: `mix test --cover test/path/file.exs`.",
        );
      }
    }

    // Deny: bare `mix test`
    if (/^\s*mix\s+test\s*$/.test(command)) {
      return deny(
        "Bare `mix test` runs full suite — dev MUST NOT. Use `mix test test/path/file.exs` for specific files.",
      );
    }

    // Deny: `mix test` with only flags (no path)
    if (/^\s*mix\s+test\s+--/.test(command)) {
      const hasPath = /[^\s]+\.exs|[^\s]+\/[^\s]+/.test(
        command.replace(/^\s*mix\s+test\s+/, ""),
      );
      if (!hasPath) {
        return deny(
          "`mix test` with only flags (no path) runs full suite — dev MUST NOT. Specify a test file path, e.g. `mix test test/path/file.exs`.",
        );
      }
    }
  });
}
