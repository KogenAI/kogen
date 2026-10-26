package build

import (
	"bytes"
	"encoding/json"
	"slices"
	"strconv"
	"strings"

	"kogen-loop/provider"
	"kogen/project"
	"kogen/verify"
)

// Tokens is a token total, as a Build's run record and checkpoint hold it. A count is nil
// (JSON null, shown as "unknown") once a request did not report it: unknown stays unknown
// in every sum.
type Tokens struct {
	Input     *int `json:"input"`
	Cached    *int `json:"cached"`
	Output    *int `json:"output"`
	Reasoning *int `json:"reasoning"`
}

// count is a known token count.
func count(n int) *int { return &n }

// zeroTokens is the total of no requests.
func zeroTokens() Tokens { return Tokens{count(0), count(0), count(0), count(0)} }

func addCounts(a, b *int) *int {
	if a == nil || b == nil {
		return nil
	}
	return count(*a + *b)
}

func (t Tokens) plus(u Tokens) Tokens {
	return Tokens{addCounts(t.Input, u.Input), addCounts(t.Cached, u.Cached), addCounts(t.Output, u.Output), addCounts(t.Reasoning, u.Reasoning)}
}

func fromUsage(u provider.Usage) Tokens {
	return Tokens{count(u.Input), count(u.Cached), count(u.Output), count(u.Reasoning)}
}

// responseTokens is what one response adds to the totals. Anthropic reports no reasoning
// count and may omit any other, so its totals come from the validated analytical usage; the
// other routes' compatible totals are always integers.
func responseTokens(role project.Role, resp *provider.Response) Tokens {
	if provider.Name(providerRole(role)) == "anthropic" {
		k := resp.Known
		return Tokens{k.Input, k.Cached, k.Output, k.Reasoning}
	}
	return fromUsage(resp.Usage)
}

func countText(n *int) string {
	if n == nil {
		return "unknown"
	}
	return strconv.Itoa(*n)
}

// Line is the progress text `input=… cached=… output=… reasoning=…`.
func (t Tokens) Line() string {
	return "input=" + countText(t.Input) + " cached=" + countText(t.Cached) + " output=" + countText(t.Output) + " reasoning=" + countText(t.Reasoning)
}

// Total is input plus output, or "unknown".
func (t Tokens) Total() string {
	if t.Input == nil || t.Output == nil {
		return "unknown"
	}
	return strconv.Itoa(*t.Input + *t.Output)
}

func (t Tokens) valid() bool {
	for _, n := range []*int{t.Input, t.Cached, t.Output, t.Reasoning} {
		if n != nil && *n < 0 {
			return false
		}
	}
	return true
}

// ReviewRecord is the latest review: its number, verdict ("approve", "changes", "pending" or
// "invalid"), findings (as the reviewer submitted them: path, line, severity, message) and the
// candidate tree it judged.
type ReviewRecord struct {
	N        int              `json:"n"`
	Verdict  string           `json:"verdict"`
	Findings []map[string]any `json:"findings"`
	Tree     string           `json:"tree,omitempty"`
}

// HistoryRef names an archived working-context window: its path and SHA-256.
type HistoryRef struct {
	Path   string `json:"path"`
	SHA256 string `json:"sha256"`
}

// OwnerContext is the working context of one conversation owner ("build" or "review"): the
// mandatory opening messages, the observations kept across resets and the archived windows.
type OwnerContext struct {
	Mandatory    []any        `json:"mandatory"`
	Observations []any        `json:"observations"`
	History      []HistoryRef `json:"history"`
	// InlineMaterial and SourceTree belong to the review owner while the candidate's source
	// still rides inline in its opening message: the material that message was made from and
	// the tree it describes (nil for a message of a checkpoint that predates the binding).
	// Under pressure that source relocates to pinned parts instead of being rebuilt from the
	// checkout. Both are dropped once the source is pinned.
	InlineMaterial *materialSet `json:"inline_material,omitempty"`
	SourceTree     *string      `json:"source_tree,omitempty"`
}

// Continuation stages. The stages that are boundaries whose effects cannot be told after an
// interruption ("startup", "tool", "commit") are not resumable.
const (
	StageStartup       = "startup"
	StageBuilder       = "builder"
	StageBuilderVerify = "builder_verify"
	StageTool          = "tool"
	StageCommit        = "commit"
	StageLanded        = "landed"
	StageReview        = "review"
	StageReviewVerify  = "review_verify"
	StageReviewRetry   = "review_retry_verify"
)

// Completed is a tool call that ran and the result it gave.
type Completed struct {
	Call   map[string]any `json:"call"`
	Result any            `json:"result"`
}

// Continuation is where a Build can continue from: the stage and what the stage needs.
type Continuation struct {
	Stage string `json:"stage"`
	// Input is the builder's conversation (stages builder, builder_verify and tool).
	Input []any `json:"input,omitempty"`
	// Finish is the builder's finish call that opened a builder_verify stage.
	Finish map[string]any `json:"finish,omitempty"`
	// Owner is who owned the tool boundary ("build" or "review").
	Owner     string           `json:"owner,omitempty"`
	Completed *Completed       `json:"completed,omitempty"`
	Response  []map[string]any `json:"response,omitempty"`
	// Request marks a tool boundary that a model request saved (the response is in
	// Response), as opposed to one a tool loop saved.
	Request bool `json:"request,omitempty"`
	// Tree is the tree being committed (stage commit).
	Tree string `json:"tree,omitempty"`
	// Commit is the landed commit (stage landed).
	Commit string `json:"commit,omitempty"`
	// Pass and Review belong to the review stages: the green pass under review and the
	// reviewer's own session state, which only the review code interprets.
	Pass   *verify.Pass    `json:"pass,omitempty"`
	Review json.RawMessage `json:"review,omitempty"`
}

// State is everything a Build keeps and a checkpoint records (the `state` of a version 4
// checkpoint).
type State struct {
	Root            string            `json:"root"`
	Slug            string            `json:"slug"`
	Config          *project.Config   `json:"config"`
	IntentText      string            `json:"intent_text"`
	Start           string            `json:"start"`
	Baseline        []string          `json:"baseline"`
	BaselineDigests map[string]string `json:"baseline_digests"`
	Excluded        []string          `json:"excluded"`
	Run             *Run              `json:"run"`
	GitIndex        string            `json:"git_index"`
	StartTree       string            `json:"start_tree"`
	Phase           string            `json:"phase"` // "startup" or "building"
	// T0 is when this run started, in Unix milliseconds.
	T0               int64                          `json:"t0"`
	Usage            Tokens                         `json:"usage"`
	Round            int                            `json:"round"`
	Pass             int                            `json:"pass"`
	Review           int                            `json:"review"`
	Repairs          int                            `json:"repairs"`
	LastPass         *verify.Pass                   `json:"last_pass"`
	LastReview       *ReviewRecord                  `json:"last_review"`
	Blocker          map[string]any                 `json:"blocker"`
	Continuation     Continuation                   `json:"continuation"`
	ApprovalBytes    string                         `json:"approval_bytes"` // base64
	Parent           *string                        `json:"parent"`
	RootRun          *string                        `json:"root_run"`
	ModelActiveMS    int64                          `json:"model_active_ms"`
	UnknownRequests  int                            `json:"unknown_requests"`
	AttemptUsage     Tokens                         `json:"attempt_usage"`
	WorkingContext   map[string]*OwnerContext       `json:"working_context"`
	SourceProvenance *project.SourceRef             `json:"source_provenance"`
	PromptCache      map[string]provider.CacheState `json:"prompt_cache_states"`
	// CacheIDs are the prompt-cache identities of the Build's model conversations, by
	// conversation ("build", "review-<n>"): created when a conversation starts, kept for every
	// later request of it, in resets and in an explicit resume.
	CacheIDs map[string]string `json:"cache_ids,omitempty"`
	// The staged plan, its durable progress and the evidence of each stage gate; all absent
	// for an Intent without a `## Stages` plan.
	StagePlan     []stageDef      `json:"stage_plan,omitempty"`
	StageProgress *StageProgress  `json:"stage_progress,omitempty"`
	StageEvidence []StageEvidence `json:"stage_evidence,omitempty"`
	// Executor identifies the external executor that produced the candidate and what it
	// reported (docs/executor-contract.md); nil for the native builder, so a native checkpoint
	// keeps its bytes. A checkpoint that has it is never resumed.
	Executor *ExecutorState `json:"executor,omitempty"`
}

// ExecutorState is an external executor's identity and its running totals in a Build:
// harness-reported figures, never provider-exact and never a bill.
type ExecutorState struct {
	Name      string        `json:"name"`
	Version   string        `json:"version"`
	SessionID string        `json:"session_id"`
	Rounds    int           `json:"rounds"`
	Usage     ExecutorUsage `json:"usage"`
}

// ExecutorUsage sums the usage the executor reported over the rounds. A count is nil once a
// round did not report it (unknown stays unknown); CostUSD is the harness's own estimate.
type ExecutorUsage struct {
	Input     *int     `json:"input"`
	Cached    *int     `json:"cached"`
	Output    *int     `json:"output"`
	Reasoning *int     `json:"reasoning"`
	State     string   `json:"state"`
	Source    string   `json:"source"`
	CostUSD   *float64 `json:"cost_usd,omitempty"`
}

// requiredStateKeys are the fields a checkpoint state must carry.
var requiredStateKeys = []string{
	"root", "slug", "config", "intent_text", "start", "baseline", "baseline_digests", "excluded",
	"run", "git_index", "start_tree", "phase", "t0", "usage", "round", "pass", "review", "repairs",
	"last_pass", "last_review", "blocker", "continuation", "approval_bytes", "parent", "root_run",
	"model_active_ms", "unknown_requests", "attempt_usage", "working_context", "source_provenance",
	"prompt_cache_states",
}

// decodeState reads a version 4 state; ok is false for a missing required field or a value of
// the wrong type.
func decodeState(raw json.RawMessage) (*State, bool) {
	var present map[string]json.RawMessage
	if json.Unmarshal(raw, &present) != nil {
		return nil, false
	}
	for _, k := range requiredStateKeys {
		if _, ok := present[k]; !ok {
			return nil, false
		}
	}
	for _, k := range []string{"usage", "attempt_usage"} {
		var counts map[string]json.RawMessage
		if json.Unmarshal(present[k], &counts) != nil {
			return nil, false
		}
		for _, name := range []string{"input", "cached", "output", "reasoning"} {
			if _, ok := counts[name]; !ok {
				return nil, false
			}
		}
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	st := &State{}
	if dec.Decode(st) != nil {
		return nil, false
	}
	return st, true
}

// configJSON is the canonical JSON of a configuration, to compare two of them.
func configJSON(c *project.Config) string {
	b, err := json.Marshal(c)
	if err != nil {
		return ""
	}
	return string(b)
}

// sameConfig reports whether two configurations are equal.
func sameConfig(a, b *project.Config) bool {
	if a == nil || b == nil {
		return a == b
	}
	return configJSON(a) == configJSON(b)
}

// intent rebuilds the Intent from the text the Build was started with.
func (s *State) intent() (*project.Intent, error) {
	return project.ReadIntent(s.Root, s.Slug, map[string][]byte{project.IntentMDPath(s.Slug): []byte(s.IntentText)})
}

// title is the Intent's title, the commit message's subject.
func (s *State) title() string {
	i, err := s.intent()
	if err != nil {
		return ""
	}
	return i.Title
}

// validContinuation is the shape check of a continuation.
func (c *Continuation) valid() bool {
	switch c.Stage {
	case StageBuilder:
		return validItems(c.Input)
	case StageBuilderVerify:
		return validItems(c.Input)
	case StageReview, StageReviewVerify, StageReviewRetry:
		return c.Pass != nil && c.Pass.Valid() && len(c.Review) > 0
	case StageLanded:
		return c.Commit != ""
	case StageStartup, StageTool, StageCommit:
		return true
	}
	return false
}

func validItems(items []any) bool {
	for _, it := range items {
		if _, ok := it.(map[string]any); !ok {
			return false
		}
	}
	return true
}

// expectedScenarios parses the Intent's feature for the completeness check of a green pass.
func (s *State) expectedScenarios() ([]project.Scenario, bool) {
	feature, err := readFile(s.Root, project.FeaturePath(s.Slug))
	if err != nil {
		return nil, false
	}
	expected, err := project.ParseGherkin(string(feature))
	return expected, err == nil
}

// completePass is whether a recorded green pass proves every required gate (VER-7).
func (s *State) completePass(p *verify.Pass, model *project.ModelSpec) bool {
	expected, ok := s.expectedScenarios()
	return ok && p.Complete(s.Config, expected, model)
}

// valid is the structural check of a decoded state against its checkpoint envelope.
func (s *State) valid(doc *Checkpoint) bool {
	if s.Phase != "startup" && s.Phase != "building" {
		return false
	}
	if s.Root == "" || s.Slug == "" || s.Start == "" || s.GitIndex == "" || s.StartTree == "" || s.ApprovalBytes == "" {
		return false
	}
	if s.Run == nil || s.Run.ID == "" || s.Run.Dir == "" || s.Run.LogPath == "" || s.Config == nil {
		return false
	}
	intent, err := s.intent()
	if err != nil || intent.Title == "" || intent.Model == nil {
		return false
	}
	if s.LastPass != nil {
		if !s.LastPass.Valid() || (s.LastPass.Green && !s.completePass(s.LastPass, intent.Model)) {
			return false
		}
	}
	if !s.validWorkingContext() || !validSource(s.SourceProvenance) {
		return false
	}
	if r := s.LastReview; r != nil && !slices.Contains([]string{"approve", "changes", "pending", "invalid"}, r.Verdict) {
		return false
	}
	if !provider.ValidCacheStates(s.PromptCache) || !validCacheIDs(s.CacheIDs) {
		return false
	}
	if !s.stagesValid() {
		return false
	}
	if s.Baseline == nil || !slices.Contains(s.Baseline, project.ConfigPath) || s.BaselineDigests == nil {
		return false
	}
	for _, p := range s.Baseline {
		if _, ok := s.BaselineDigests[p]; !ok {
			return false
		}
	}
	for _, n := range []int{s.Round, s.Pass, s.Review, s.Repairs, s.UnknownRequests, int(s.ModelActiveMS)} {
		if n < 0 {
			return false
		}
	}
	for _, t := range []Tokens{s.Usage, s.AttemptUsage} {
		if !t.valid() {
			return false
		}
	}
	if x := s.Executor; x != nil && (x.Name == "" || x.Rounds < 0) {
		return false
	}
	c := &s.Continuation
	if !c.valid() {
		return false
	}
	if c.Pass != nil && c.Pass.Green && !s.completePass(c.Pass, intent.Model) {
		return false
	}
	if c.Stage == StageLanded {
		if s.LastPass == nil || s.LastReview == nil || !s.LastPass.Green || s.LastReview.Verdict != "approve" || s.LastReview.Tree != s.LastPass.Tree {
			return false
		}
	}
	if !sameProgress(doc.StageProgress, s.StageProgress) {
		return false
	}
	return doc.Identity != "" && doc.Candidate != "" && doc.Approval == s.ApprovalBytes
}

func sameProgress(a, b *StageProgress) bool {
	if a == nil || b == nil {
		return a == b
	}
	return canonical(a.value()) == canonical(b.value())
}

// validCacheIDs is the checkpoint check of the conversation identities: at most
// provider.MaxCacheID characters each.
func validCacheIDs(ids map[string]string) bool {
	for k, id := range ids {
		if k == "" || id == "" || len(id) > provider.MaxCacheID {
			return false
		}
	}
	return true
}

func validSource(r *project.SourceRef) bool {
	return r == nil || (r.Path != "" && r.SHA256 != "" && r.ContractSHA256 != "")
}

func (s *State) validWorkingContext() bool {
	if s.WorkingContext == nil {
		return false
	}
	for owner, st := range s.WorkingContext {
		if (owner != "build" && owner != "review") || st == nil || st.Mandatory == nil || st.Observations == nil || st.History == nil {
			return false
		}
		if !validItems(st.Mandatory) {
			return false
		}
		for _, h := range st.History {
			if h.Path == "" || h.SHA256 == "" {
				return false
			}
		}
	}
	return true
}

func trimmed(s string) string { return strings.TrimSpace(s) }
