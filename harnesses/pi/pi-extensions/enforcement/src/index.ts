/**
 * index.ts — Pi enforcement extension entry point.
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

// NOT-YET-MIGRATED: context-index-parity has role: unset (non-standard token);
// deferred until schema accepts or normalises the unset sentinel.
import { register as registerContextIndexParity } from "./hooks/context-index-parity";
// NOT-YET-MIGRATED: context-file-size-gate has role: unset (non-standard token);
// deferred until schema accepts or normalises the unset sentinel.
import { register as registerContextFileSizeGate } from "./hooks/context-file-size-gate";

// BEGIN-GENERATED-ENFORCEMENT-BLOCK
import { register as registerBuildNoSuccessBeforeCommit } from "./hooks/build-no-success-before-commit";
import { register as registerBuildWorkerCwdGuard } from "./hooks/build-worker-cwd-guard";
import { register as registerCommitterBashAllowlist } from "./hooks/committer-bash-allowlist";
import { register as registerCommitterNoRevertPriorCommit } from "./hooks/committer-no-revert-prior-commit";
import { register as registerCommitterNoTrailerGuard } from "./hooks/committer-no-trailer-guard";
import { register as registerCommitterSingleLineGuard } from "./hooks/committer-single-line-guard";
import { register as registerCommitterSubjectLength } from "./hooks/committer-subject-length";
import { register as registerCommitterWriteAllowlist } from "./hooks/committer-write-allowlist";
import { register as registerContextCuratorGuard } from "./hooks/context-curator-guard";
import { register as registerCuratorBeforeCommitter } from "./hooks/curator-before-committer";
import { register as registerCuratorFormat } from "./hooks/curator-format";
import { register as registerCuratorLearningCommitted } from "./hooks/curator-learning-committed";
import { register as registerDevNoCi } from "./hooks/dev-no-ci";
import { register as registerDeveloperNoSelfGate } from "./hooks/developer-no-self-gate";
import { register as registerDeveloperNoSelfGateReset } from "./hooks/developer-no-self-gate-reset";
import { register as registerDeveloperStaticNoBuildOutputProbe } from "./hooks/developer-static-no-build-output-probe";
import { register as registerDeveloperStaticNoManualBuild } from "./hooks/developer-static-no-manual-build";
import { register as registerEnvVarSampleConsistency } from "./hooks/env-var-sample-consistency";
import { register as registerLlmPendingSweep } from "./hooks/llm-pending-sweep";
import { register as registerLlmSuiteGuard } from "./hooks/llm-suite-guard";
import { register as registerLlmTestGuard } from "./hooks/llm-test-guard";
import { register as registerNoCatPipe } from "./hooks/no-cat-pipe";
import { register as registerNoGitStash } from "./hooks/no-git-stash";
import { register as registerNoPythonJson } from "./hooks/no-python-json";
import { register as registerOperatorSubagentAllowlist } from "./hooks/operator-subagent-allowlist";
import { register as registerOrchestratorNoCi } from "./hooks/orchestrator-no-ci";
import { register as registerOrchestratorReadDiscipline } from "./hooks/orchestrator-read-discipline";
import { register as registerOrchestratorSessionLogNameGuard } from "./hooks/orchestrator-session-log-name-guard";
import { register as registerPhoenixBackendDeveloperGuard } from "./hooks/phoenix-backend-developer-guard";
import { register as registerPhoenixDevGate } from "./hooks/phoenix-dev-gate";
import { register as registerPhoenixFrontendDeveloperGuard } from "./hooks/phoenix-frontend-developer-guard";
import { register as registerPitchFormatValidator } from "./hooks/pitch-format-validator";
import { register as registerPitchShippedBeforeStop } from "./hooks/pitch-shipped-before-stop";
import { register as registerPlannerGuard } from "./hooks/planner-guard";
import { register as registerPostDeveloperFormat } from "./hooks/post-developer-format";
import { register as registerPreCommitGuard } from "./hooks/pre-commit-guard";
import { register as registerReviewerGuard } from "./hooks/reviewer-guard";
import { register as registerReviewerGuardSessionLogWrite } from "./hooks/reviewer-guard-session-log-write";
import { register as registerSessionLogNoDuplicateSection } from "./hooks/session-log-no-duplicate-section";
import { register as registerSessionLogSectionIntegrity } from "./hooks/session-log-section-integrity";
import { register as registerStaticSiteBuildCheck } from "./hooks/static-site-build-check";
import { register as registerStaticSiteExGuard } from "./hooks/static-site-ex-guard";
import { register as registerStepLogCompleteness } from "./hooks/step-log-completeness";
import { register as registerStepLogMissingGuard } from "./hooks/step-log-missing-guard";
import { register as registerStepLogSectionBeforeSpawn } from "./hooks/step-log-section-before-spawn";
import { register as registerStopCycleGuard } from "./hooks/stop-cycle-guard";
import { register as registerStopResume } from "./hooks/stop-resume";
import { register as registerStopVerifyPlannerGate } from "./hooks/stop-verify-planner-gate";
import { register as registerSubagentRetrospectiveGuard } from "./hooks/subagent-retrospective-guard";
import { register as registerTrackSubagentEdits } from "./hooks/track-subagent-edits";
import { register as registerTrackToolFailures } from "./hooks/track-tool-failures";
import { register as registerUsageRulesGrepGuard } from "./hooks/usage-rules-grep-guard";
// END-GENERATED-ENFORCEMENT-BLOCK

export default function (pi: ExtensionAPI): void {
  // NOT-YET-MIGRATED: context-index-parity — hand-wired outside generated block.
  registerContextIndexParity(pi);
  // NOT-YET-MIGRATED: context-file-size-gate — hand-wired outside generated block.
  registerContextFileSizeGate(pi);

  // BEGIN-GENERATED-ENFORCEMENT-BLOCK
  registerBuildNoSuccessBeforeCommit(pi);
  registerBuildWorkerCwdGuard(pi);
  registerCommitterBashAllowlist(pi);
  registerCommitterNoRevertPriorCommit(pi);
  registerCommitterNoTrailerGuard(pi);
  registerCommitterSingleLineGuard(pi);
  registerCommitterSubjectLength(pi);
  registerCommitterWriteAllowlist(pi);
  registerContextCuratorGuard(pi);
  registerCuratorBeforeCommitter(pi);
  registerCuratorFormat(pi);
  registerCuratorLearningCommitted(pi);
  registerDevNoCi(pi);
  registerDeveloperNoSelfGate(pi);
  registerDeveloperNoSelfGateReset(pi);
  registerDeveloperStaticNoBuildOutputProbe(pi);
  registerDeveloperStaticNoManualBuild(pi);
  registerEnvVarSampleConsistency(pi);
  registerLlmPendingSweep(pi);
  registerLlmSuiteGuard(pi);
  registerLlmTestGuard(pi);
  registerNoCatPipe(pi);
  registerNoGitStash(pi);
  registerNoPythonJson(pi);
  registerOperatorSubagentAllowlist(pi);
  registerOrchestratorNoCi(pi);
  registerOrchestratorReadDiscipline(pi);
  registerOrchestratorSessionLogNameGuard(pi);
  registerPhoenixBackendDeveloperGuard(pi);
  registerPhoenixDevGate(pi);
  registerPhoenixFrontendDeveloperGuard(pi);
  registerPitchFormatValidator(pi);
  registerPitchShippedBeforeStop(pi);
  registerPlannerGuard(pi);
  registerPostDeveloperFormat(pi);
  registerPreCommitGuard(pi);
  registerReviewerGuard(pi);
  registerReviewerGuardSessionLogWrite(pi);
  registerSessionLogNoDuplicateSection(pi);
  registerSessionLogSectionIntegrity(pi);
  registerStaticSiteBuildCheck(pi);
  registerStaticSiteExGuard(pi);
  registerStepLogCompleteness(pi);
  registerStepLogMissingGuard(pi);
  registerStepLogSectionBeforeSpawn(pi);
  registerStopCycleGuard(pi);
  registerStopResume(pi);
  registerStopVerifyPlannerGate(pi);
  registerSubagentRetrospectiveGuard(pi);
  registerTrackSubagentEdits(pi);
  registerTrackToolFailures(pi);
  registerUsageRulesGrepGuard(pi);
  // END-GENERATED-ENFORCEMENT-BLOCK
}
