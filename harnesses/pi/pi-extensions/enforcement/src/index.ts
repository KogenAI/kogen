/**
 * index.ts — Combobulate Pi enforcement extension entry point.
 *
 * Registers Pi event handlers that mirror Claude Code hook enforcement.
 * Hooks are dispatched by tool name to per-hook modules.
 *
 * Event mapping (Claude → Pi):
 *   PreToolUse      → tool_call     (can return { block: true, reason })
 *   PostToolUseFailure → tool_result with isError=true  (observe only)
 *   SubagentStop    → session_shutdown  (cleanup / gate enforcement)
 *   Stop            → session_shutdown  (stop-cycle guards)
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

// PreToolUse / tool_call handlers (blocking)
import { register as registerBuildNoSuccessBeforeCommit } from "./hooks/build-no-success-before-commit";
import { register as registerBuildWorkerCwdGuard } from "./hooks/build-worker-cwd-guard";
import { register as registerCommitterNoTrailerGuard } from "./hooks/committer-no-trailer-guard";
import { register as registerCommitterSingleLineGuard } from "./hooks/committer-single-line-guard";
import { register as registerCommitterSubjectLength } from "./hooks/committer-subject-length";
import { register as registerContextIndexParity } from "./hooks/context-index-parity";
import { register as registerDevNoCi } from "./hooks/dev-no-ci";
import { register as registerDeveloperNoSelfGate } from "./hooks/developer-no-self-gate";
import { register as registerEnvVarSampleConsistency } from "./hooks/env-var-sample-consistency";
import { register as registerLlmSuiteGuard } from "./hooks/llm-suite-guard";
import { register as registerLlmTestGuard } from "./hooks/llm-test-guard";
import { register as registerOrchestratorReadDiscipline } from "./hooks/orchestrator-read-discipline";
// BEGIN-GENERATED-ENFORCEMENT-BLOCK
import { register as registerNoCatPipe } from "./hooks/no-cat-pipe";
import { register as registerNoGitStash } from "./hooks/no-git-stash";
import { register as registerNoPythonJson } from "./hooks/no-python-json";
import { register as registerReviewerGuardSessionLogWrite } from "./hooks/reviewer-guard-session-log-write";
// END-GENERATED-ENFORCEMENT-BLOCK
import { register as registerPhoenixBackendDeveloperGuard } from "./hooks/phoenix-backend-developer-guard";
import { register as registerPhoenixFrontendDeveloperGuard } from "./hooks/phoenix-frontend-developer-guard";
import { register as registerPlannerGuard } from "./hooks/planner-guard";
import { register as registerPreCommitGuard } from "./hooks/pre-commit-guard";
import { register as registerReviewerGuard } from "./hooks/reviewer-guard";
import { register as registerSessionLogSectionIntegrity } from "./hooks/session-log-section-integrity";
import { register as registerStaticSiteExGuard } from "./hooks/static-site-ex-guard";
import { register as registerSubagentAllowlist } from "./hooks/subagent-allowlist";
import { register as registerTrackSubagentEdits } from "./hooks/track-subagent-edits";
import { register as registerUsageRulesGrepGuard } from "./hooks/usage-rules-grep-guard";

// PostToolUseFailure / tool_result error tracking (observe only)
import { register as registerTrackToolFailures } from "./hooks/track-tool-failures";

// SubagentStop+Stop / session_shutdown handlers
import { register as registerDeveloperNoSelfGateReset } from "./hooks/developer-no-self-gate-reset";
import { register as registerLlmPendingSweep } from "./hooks/llm-pending-sweep";
import { register as registerPhoenixDevGate } from "./hooks/phoenix-dev-gate";
import { register as registerPostDeveloperFormat } from "./hooks/post-developer-format";
import { register as registerStaticSiteBuildCheck } from "./hooks/static-site-build-check";
import { register as registerStepLogCompleteness } from "./hooks/step-log-completeness";
import { register as registerStopCycleGuard } from "./hooks/stop-cycle-guard";
import { register as registerStopResume } from "./hooks/stop-resume";

export default function (pi: ExtensionAPI): void {
  // PreToolUse / tool_call (blocking)
  registerBuildNoSuccessBeforeCommit(pi);
  registerBuildWorkerCwdGuard(pi);
  registerCommitterNoTrailerGuard(pi);
  registerCommitterSingleLineGuard(pi);
  registerCommitterSubjectLength(pi);
  registerContextIndexParity(pi);
  registerDevNoCi(pi);
  registerDeveloperNoSelfGate(pi);
  registerEnvVarSampleConsistency(pi);
  registerLlmSuiteGuard(pi);
  registerLlmTestGuard(pi);
  registerOrchestratorReadDiscipline(pi);
  // BEGIN-GENERATED-ENFORCEMENT-BLOCK
  registerNoCatPipe(pi);
  registerNoGitStash(pi);
  registerNoPythonJson(pi);
  registerReviewerGuardSessionLogWrite(pi);
  // END-GENERATED-ENFORCEMENT-BLOCK
  registerPhoenixBackendDeveloperGuard(pi);
  registerPhoenixFrontendDeveloperGuard(pi);
  registerPlannerGuard(pi);
  registerPreCommitGuard(pi);
  registerReviewerGuard(pi);
  registerSessionLogSectionIntegrity(pi);
  registerStaticSiteExGuard(pi);
  registerSubagentAllowlist(pi);
  registerTrackSubagentEdits(pi);
  registerUsageRulesGrepGuard(pi);

  // PostToolUseFailure / tool_result (observe only)
  registerTrackToolFailures(pi);

  // SubagentStop+Stop / session_shutdown
  registerDeveloperNoSelfGateReset(pi);
  registerLlmPendingSweep(pi);
  registerPhoenixDevGate(pi);
  registerPostDeveloperFormat(pi);
  registerStaticSiteBuildCheck(pi);
  registerStepLogCompleteness(pi);
  registerStopCycleGuard(pi);
  registerStopResume(pi);
}
