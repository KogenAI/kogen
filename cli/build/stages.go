package build

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"

	"kogen-loop/sys"
	"kogen/project"
	"kogen/verify"
)

// Staged Builds: one approved Intent built in ordered, verified stages (the optional
// `## Stages` plan). Progress is durable and bound to the tree each stage gate verified, the
// stages are gated by their own scoped checks only, and after the last one the whole
// Intent still goes through the full gates, an independent review and one commit. Stage
// evidence is historical for its recorded tree and never delivery.

// stageDef is one stage of the approved plan as the checkpoint keeps it.
type stageDef struct {
	ID     string   `json:"id"`
	Title  string   `json:"title"`
	Goal   string   `json:"goal"`
	Checks []string `json:"checks"`
}

func stageDefs(plan []project.Stage) []stageDef {
	if plan == nil {
		return nil
	}
	out := make([]stageDef, len(plan))
	for i, s := range plan {
		out[i] = stageDef{ID: s.ID, Title: s.Title, Goal: s.Goal, Checks: slices.Clone(s.Checks)}
	}
	return out
}

func (d stageDef) value() map[string]any {
	checks := make([]any, len(d.Checks))
	for i, c := range d.Checks {
		checks[i] = c
	}
	return map[string]any{"id": d.ID, "title": d.Title, "goal": d.Goal, "checks": checks}
}

// The phases of a staged Build: "stage" while scoped stages remain, then "final" (whole
// gates), "review" and "landed".
const (
	phaseStage  = "stage"
	phaseFinal  = "final"
	phaseReview = "review"
	phaseLanded = "landed"
)

// StageProgress is the durable position of a staged Build: how many stages there are, which
// are verified, which is active (nil after the last) and the phase.
type StageProgress struct {
	Total     int      `json:"total"`
	Completed []string `json:"completed"`
	Active    *string  `json:"active"`
	Phase     string   `json:"phase"`
}

func (p StageProgress) clone() StageProgress {
	p.Completed = slices.Clone(p.Completed)
	if p.Completed == nil {
		p.Completed = []string{}
	}
	return p
}

func (p StageProgress) value() map[string]any {
	completed := make([]any, len(p.Completed))
	for i, c := range p.Completed {
		completed[i] = c
	}
	var active any
	if p.Active != nil {
		active = *p.Active
	}
	return map[string]any{"total": p.Total, "completed": completed, "active": active, "phase": p.Phase}
}

func initialProgress(plan []stageDef) *StageProgress {
	if plan == nil {
		return nil
	}
	first := plan[0].ID
	return &StageProgress{Total: len(plan), Completed: []string{}, Active: &first, Phase: phaseStage}
}

// StageCustody names a stage's private evidence file and its SHA-256.
type StageCustody struct {
	Path   string `json:"path"`
	SHA256 string `json:"sha256"`
}

// StageEvidence is one scoped stage gate's result: the verification pass (checks named
// stage-<id>-<n>), the stage and its position, the approved contract it ran under and the
// private file keeping it.
type StageEvidence struct {
	Pass     verify.Pass
	StageID  string
	Index    int
	Contract string
	Custody  *StageCustody
}

// fileValue is the evidence as the private file holds it (no custody).
func (e StageEvidence) fileValue() (map[string]any, error) {
	raw, err := json.Marshal(e.Pass)
	if err != nil {
		return nil, err
	}
	m, err := decodeJSONNumbers(raw)
	if err != nil {
		return nil, err
	}
	doc := m.(map[string]any)
	doc["stage_id"], doc["stage_index"], doc["contract"] = e.StageID, json.Number(strconv.Itoa(e.Index)), e.Contract
	return doc, nil
}

func (e StageEvidence) MarshalJSON() ([]byte, error) {
	doc, err := e.fileValue()
	if err != nil {
		return nil, err
	}
	if e.Custody != nil {
		doc["custody"] = e.Custody
	}
	return json.Marshal(doc)
}

func (e *StageEvidence) UnmarshalJSON(data []byte) error {
	var pass verify.Pass
	if err := json.Unmarshal(data, &pass); err != nil {
		return err
	}
	var rest struct {
		StageID  string        `json:"stage_id"`
		Index    int           `json:"stage_index"`
		Contract string        `json:"contract"`
		Custody  *StageCustody `json:"custody"`
	}
	if err := json.Unmarshal(data, &rest); err != nil {
		return err
	}
	*e = StageEvidence{Pass: pass, StageID: rest.StageID, Index: rest.Index, Contract: rest.Contract, Custody: rest.Custody}
	return nil
}

// summary is the evidence as staged navigation lists it.
func (e StageEvidence) summary() map[string]any {
	m := map[string]any{
		"stage_id": e.StageID, "stage_index": e.Index, "tree": e.Pass.Tree, "green": e.Pass.Green,
		"failing": stringList(e.Pass.Failing), "not_run": stringList(e.Pass.NotRun),
	}
	if e.Custody != nil {
		m["custody"] = map[string]any{"path": e.Custody.Path, "sha256": e.Custody.SHA256}
	}
	return m
}

func stringList(list []string) []any {
	out := make([]any, len(list))
	for i, s := range list {
		out[i] = s
	}
	return out
}

// navigation is the staged plan's progress as the builder and reviewer see it (empty for an
// Intent without stages): the progress, the active stage, and the evidence, which is
// historical for its recorded tree and not current whole-Intent proof.
func (s *State) navigation() string {
	p := s.StageProgress
	if p == nil {
		return ""
	}
	progress, _ := project.EncodeJSON(p.value())
	var active *stageDef
	if p.Active != nil {
		for i := range s.StagePlan {
			if s.StagePlan[i].ID == *p.Active {
				active = &s.StagePlan[i]
			}
		}
	}
	var where string
	if active != nil {
		encoded, _ := project.EncodeJSON(active.value())
		where = fmt.Sprintf("Active stage %d/%d: %s\n", len(p.Completed)+1, p.Total, encoded)
	} else {
		where = "All scoped stages completed. Continue whole-Intent " + p.Phase + ".\n"
	}
	evidence := make([]any, len(s.StageEvidence))
	for i, e := range s.StageEvidence {
		evidence[i] = e.summary()
	}
	history, _ := project.EncodeJSON(evidence)
	return "\nStaged plan progress: " + string(progress) + "\n" + where +
		"Stage evidence is historical for its recorded tree, not current whole-Intent proof.\nHistorical stage evidence: " + string(history) + "\n"
}

// navigationIn is the navigation the Build would show in the given phase.
func (s *State) navigationIn(phase string) string {
	if s.StageProgress == nil {
		return ""
	}
	t := *s
	t.setPhase(phase)
	return t.navigation()
}

// setPhase moves a staged Build to a phase (no effect without stages).
func (s *State) setPhase(phase string) {
	if s.StageProgress != nil {
		p := s.StageProgress.clone()
		p.Phase = phase
		s.StageProgress = &p
	}
}

// retainStage writes the evidence as a private, durable file in the run folder (exclusive
// 0600, synced) and returns it with its custody.
func (b *Attempt) retainStage(e StageEvidence) (StageEvidence, error) {
	var nonce [8]byte
	if _, err := rand.Read(nonce[:]); err != nil {
		return e, err
	}
	path := filepath.Join(b.Run.Dir, "stage-"+strconv.Itoa(e.Pass.N)+"-"+hex.EncodeToString(nonce[:])+".json")
	doc, err := e.fileValue()
	if err != nil {
		return e, err
	}
	raw, err := project.EncodeJSON(doc)
	if err != nil {
		return e, err
	}
	raw = append(raw, '\n')
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return e, err
	}
	werr := f.Chmod(0o600)
	if werr == nil {
		_, werr = f.Write(raw)
	}
	if werr == nil {
		werr = f.Sync()
	}
	if cerr := f.Close(); werr == nil {
		werr = cerr
	}
	if werr != nil {
		return e, werr
	}
	e.Custody = &StageCustody{Path: path, SHA256: hashHex(raw)}
	return e, nil
}

// validateStages refuses a Build whose stage progress or evidence no longer fits the
// approved plan or its private custody.
func (b *Attempt) validateStages() error { return b.validateStagesAs(b.Continuation) }

// validateStagesAs is validateStages for the continuation the caller is working under (a
// request's tool boundary is not the builder's own).
func (b *Attempt) validateStagesAs(c Continuation) error {
	st := b.State
	st.Continuation = c
	if !st.stagesValid() {
		return sys.Fail("candidate", "resume_refused",
			"stage progress/evidence inconsistent with approved plan or private custody", 1)
	}
	return nil
}

var (
	stageFileName = regexp.MustCompile(`^stage-[0-9]+-[a-f0-9]{16}\.json$`)
	runIDName     = regexp.MustCompile(`^[a-f0-9]{8}$`)
)

// stageBound is whether the evidence's file is where, as and what its custody says: under the
// runs folder in a run folder, private (0700 folder, 0600 file), holding exactly the evidence.
func (s *State) stageBound(e StageEvidence) bool {
	if e.Custody == nil {
		return false
	}
	path := e.Custody.Path
	runs := filepath.Join(s.Root, ".kogen/local/runs")
	rel, err := filepath.Rel(runs, path)
	if err != nil {
		return false
	}
	parts := strings.Split(rel, string(filepath.Separator))
	if len(parts) != 2 || !runIDName.MatchString(parts[0]) || !stageFileName.MatchString(parts[1]) ||
		parts[1][:len("stage-"+strconv.Itoa(e.Pass.N)+"-")] != "stage-"+strconv.Itoa(e.Pass.N)+"-" ||
		path != filepath.Join(runs, parts[0], parts[1]) {
		return false
	}
	for _, dir := range []string{s.Root, filepath.Join(s.Root, ".kogen"), filepath.Join(s.Root, ".kogen/local"), runs, filepath.Dir(path)} {
		if st, err := os.Lstat(dir); err != nil || !st.IsDir() {
			return false
		}
	}
	if st, err := os.Lstat(filepath.Dir(path)); err != nil || st.Mode().Perm() != 0o700 {
		return false
	}
	st, err := os.Lstat(path)
	if err != nil || st.Mode().Type() != 0 || st.Mode().Perm() != 0o600 || st.Mode()&fs.ModeSymlink != 0 {
		return false
	}
	raw, err := os.ReadFile(path)
	if err != nil || hashHex(raw) != e.Custody.SHA256 {
		return false
	}
	want, err := e.fileValue()
	if err != nil {
		return false
	}
	return sameJSON(raw, want)
}

// sameJSON is whether the encoded document and the value are the same parsed JSON.
func sameJSON(raw []byte, want any) bool {
	got, err := decodeJSONNumbers(raw)
	if err != nil {
		return false
	}
	wanted, err := json.Marshal(want)
	if err != nil {
		return false
	}
	reread, err := decodeJSONNumbers(wanted)
	return err == nil && canonical(got) == canonical(reread)
}

// stagesValid is the consistency of a Build's stage state with its approved Intent: no plan
// means no stage state at all; a plan means progress that fits the plan, the continuation
// owner and the recorded evidence (each green stage's clean, complete, scoped evidence in
// order, bound to its private file and to this approval).
func (s *State) stagesValid() bool {
	plan, err := project.ParseStages(s.IntentText)
	if err != nil {
		return false
	}
	if plan == nil {
		return s.StageProgress == nil && s.StagePlan == nil && len(s.StageEvidence) == 0
	}
	return s.progressValid(stageDefs(plan))
}

func (s *State) phaseValid(phase string) bool {
	c := s.Continuation
	switch c.Stage {
	case StageStartup, StageBuilder, StageBuilderVerify:
		return phase == phaseStage || phase == phaseFinal
	case StageTool:
		// A tool boundary the builder's own loop saved; the one a request saved names no
		// stage owner and is not a valid staged state.
		if c.Request {
			return false
		}
		switch c.Owner {
		case "build":
			return phase == phaseStage || phase == phaseFinal
		case "review":
			return phase == phaseReview
		}
		return false
	case StageReview, StageReviewVerify, StageReviewRetry, StageCommit:
		return phase == phaseReview
	case StageLanded:
		return phase == phaseLanded
	}
	return false
}

func (s *State) progressValid(plan []stageDef) bool {
	p := s.StageProgress
	if p == nil || !s.phaseValid(p.Phase) || p.Total != len(plan) || !slices.EqualFunc(s.StagePlan, plan, stageEqual) {
		return false
	}
	ids := make([]string, len(plan))
	for i, d := range plan {
		ids[i] = d.ID
	}
	done := len(p.Completed)
	if done > len(ids) || !slices.Equal(p.Completed, ids[:done]) {
		return false
	}
	switch {
	case done < len(ids):
		if p.Active == nil || *p.Active != ids[done] || p.Phase != phaseStage {
			return false
		}
	default:
		if p.Active != nil || !slices.Contains([]string{phaseFinal, phaseReview, phaseLanded}, p.Phase) {
			return false
		}
	}
	var greens []string
	for _, e := range s.StageEvidence {
		if e.Pass.Green {
			greens = append(greens, e.StageID)
		}
	}
	if !slices.Equal(nonNil(greens), nonNil(p.Completed)) {
		return false
	}
	index := 1
	for _, e := range s.StageEvidence {
		if e.Index != index {
			return false
		}
		if e.Pass.Green {
			index++
		}
	}
	if index != done+1 {
		return false
	}
	for _, e := range s.StageEvidence {
		if e.Index < 1 || e.Index > len(plan) {
			return false
		}
		stage := plan[e.Index-1]
		if stage.ID != e.StageID || e.Contract != s.ApprovalBytes || !s.stageBound(e) || e.Pass.Tree == "" {
			return false
		}
		if e.Pass.Green && !s.scopedGreen(e, stage) {
			return false
		}
	}
	return true
}

func stageEqual(a, b stageDef) bool {
	return a.ID == b.ID && a.Title == b.Title && a.Goal == b.Goal && slices.Equal(a.Checks, b.Checks)
}

// scopedGreen is whether a green stage record really is a clean pass of exactly the stage's
// setup and checks, all successful.
func (s *State) scopedGreen(e StageEvidence, stage stageDef) bool {
	p := e.Pass
	if !p.Clean || len(p.Moved) != 0 || len(p.Failing) != 0 || len(p.NotRun) != 0 || s.Config == nil {
		return false
	}
	if len(p.Checks) != len(stage.Checks) || len(p.Setup) != len(s.Config.Setup) {
		return false
	}
	for i, c := range stage.Checks {
		if p.Checks[i].Command != c || p.Checks[i].Status != 0 {
			return false
		}
	}
	for i, c := range s.Config.Setup {
		if p.Setup[i].Command != c || p.Setup[i].Status != 0 {
			return false
		}
	}
	return true
}
