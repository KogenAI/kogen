// Package executor is Kogen's executor contract v1 (docs/executor-contract.md): what a Build
// role backend (the native kogen-loop adapter, the Claude Code adapter) must provide, and
// what it can never decide. A round result is a claim; approval, protected-baseline
// detection, verification, review and the commit stay with Kogen.
package executor

import (
	"context"
	"strconv"
	"time"

	"kogen-loop/sys"
)

// Contract is the contract id every executor's Descriptor must carry.
const Contract = "kogen.executor/v1"

// Executor names.
const (
	Native     = "native"
	ClaudeCode = "claude-code"
)

// Roles an executor may serve. v1: build only.
const RoleBuild = "build"

// Resume capabilities.
const (
	ResumeExact = "exact" // Kogen checkpoint at every tool boundary (native)
	ResumeNone  = "none"  // resume of this executor's checkpoint is refused
)

// Usage sources.
const (
	UsageProvider = "provider" // exact provider-reported fields
	UsageHarness  = "harness"  // reported by the external harness; not independently verified
	UsageNone     = "none"
)

// Usage states (same words as kogen-loop's api).
const (
	UsageComplete = "complete"
	UsagePartial  = "partial"
	UsageUnknown  = "unknown"
)

// Prevention mechanisms (best effort, executor-specific; never a substitute for detection).
const (
	PreventWriteTool    = "write_tool_refusal"
	PreventPreToolWrite = "pretool_hook_write_edit"
)

// Capabilities are what an executor actually provides. Missing means unsupported.
type Capabilities struct {
	Roles        []string `json:"roles"`
	Resume       string   `json:"resume"`
	Continuation bool     `json:"continuation"` // feedback rounds reuse the same session
	Usage        string   `json:"usage"`
	Prevention   []string `json:"prevention"`
	Blocker      bool     `json:"blocker"` // builder-reported protected-contract blocker
	Images       bool     `json:"images"`  // Kogen-custodied image input
	// MaxRounds is the default round cap Kogen applies (0: unlimited).
	MaxRounds int `json:"max_rounds"`
}

// Descriptor identifies an executor and its exact version.
type Descriptor struct {
	Name         string       `json:"name"`
	Contract     string       `json:"contract"`
	Version      string       `json:"version"`
	Capabilities Capabilities `json:"capabilities"`
}

// Brief is the task as Kogen renders it: the stable authority (source provenance, Intent,
// acceptance feature, model, README, testing rules, navigation, configured commands,
// protected paths) and the dynamic evidence behind it (the file list). Exact bytes.
type Brief struct {
	Stable  string `json:"stable"`
	Dynamic string `json:"dynamic"`
}

// Task is one Build role's work for an executor.
type Task struct {
	Role      string    `json:"role"`
	Root      string    `json:"root"` // the checkout the candidate is produced in
	Brief     Brief     `json:"brief"`
	Protected []string  `json:"protected"` // approved baseline paths, repository-relative
	Excluded  []string  `json:"excluded"`
	Model     string    `json:"model"`
	Effort    string    `json:"effort"`
	Approval  string    `json:"approval"`   // exact approval SHA-256 (identity only)
	StartTree string    `json:"start_tree"` // HEAD the Build started from
	RunID     string    `json:"run_id"`
	Deadline  time.Time `json:"deadline"` // zero: none
	MaxRounds int       `json:"max_rounds"`
	// Home is the user's HOME for locating the harness's own sign-in; it is never read for
	// secrets by Kogen.
	Home string `json:"home"`
	// Dir is a private (0700) Kogen-owned directory for this executor's artifacts: raw event
	// stream, hook policy and hook log. It is run custody, never authority.
	Dir string `json:"dir"`
}

// Input is a round's input: empty Feedback for the first round (the Brief is the task),
// otherwise Kogen's deterministic feedback for the same session.
type Input struct {
	Feedback string `json:"feedback"`
}

// Endings: claims, not completion.
type Ending string

const (
	EndFinish  Ending = "finish"
	EndNoCall  Ending = "no_call"
	EndBlocker Ending = "blocker"
)

// BlockerClaim is a builder-reported protected-contract contradiction; Kogen validates it.
type BlockerClaim struct {
	Paths    []string `json:"paths"`
	Reason   string   `json:"reason"`
	Evidence string   `json:"evidence"`
}

// Usage of one round. Nil fields were not reported. CostUSD is a harness's own estimate,
// never a bill.
type Usage struct {
	Input     *int     `json:"input"`
	Cached    *int     `json:"cached"`
	Output    *int     `json:"output"`
	Reasoning *int     `json:"reasoning"`
	State     string   `json:"state"`
	Source    string   `json:"source"`
	CostUSD   *float64 `json:"cost_usd,omitempty"`
	Model     string   `json:"model,omitempty"` // model the harness reported using
}

// Handle identifies a session for the run log and checkpoint.
type Handle struct {
	Executor  string `json:"executor"`
	Version   string `json:"version"`
	SessionID string `json:"session_id"`
	Resume    string `json:"resume"`
}

// RoundResult is one round's outcome as claimed by the executor.
type RoundResult struct {
	Ending  Ending        `json:"ending"`
	Claim   string        `json:"claim"` // untrusted model text, bounded by the adapter
	Blocker *BlockerClaim `json:"blocker,omitempty"`
	Usage   Usage         `json:"usage"`
	Handle  Handle        `json:"handle"`
}

// Sink receives run-log events (maps with an "event" key, executor_* names).
type Sink func(event map[string]any)

// Executor is a Build role backend.
type Executor interface {
	Describe() Descriptor
	// Start validates availability, version and auth route without model work.
	Start(ctx context.Context, t Task, emit Sink) (Session, error)
}

// Session is one executor conversation within a Build.
type Session interface {
	Round(ctx context.Context, in Input) (RoundResult, error)
	Handle() Handle
	Close() error
}

// Error reasons (class "executor").
const (
	ReasonUnavailable = "unavailable"
	ReasonAuthRefused = "auth_refused"
	ReasonFailed      = "failed"
	ReasonProtocol    = "protocol"
	ReasonDeadline    = "deadline"
	// ReasonInterrupted: the round context was cancelled (a sys.Interrupted from a signal
	// keeps its own exit code and may be returned instead).
	ReasonInterrupted = "interrupted"
)

// Fail is an executor stop.
func Fail(reason, detail string) *sys.Error { return sys.Fail("executor", reason, detail, 1) }

// RoundLimit is the Build stop when a non-native executor exceeds its round cap.
func RoundLimit(rounds int) *sys.Error {
	return sys.Fail("candidate", "executor_round_limit",
		"the executor used its "+strconv.Itoa(rounds)+" rounds without a verified, reviewed candidate; the candidate is left in place", 1)
}

// Validate checks a descriptor against this contract.
func (d Descriptor) Validate() error {
	if d.Contract != Contract {
		return Fail(ReasonUnavailable, "executor "+d.Name+" implements "+d.Contract+", not "+Contract)
	}
	for _, r := range d.Capabilities.Roles {
		if r == RoleBuild {
			return nil
		}
	}
	return Fail(ReasonUnavailable, "executor "+d.Name+" does not serve the build role")
}
