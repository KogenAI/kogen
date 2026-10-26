package shape

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strings"

	"kogen-loop/provider"
	"kogen-loop/sys"
	"kogen-loop/tools"
	"kogen/project"
	"kogen/verify"
)

// The safe-boundary working windows of the Shape and Refine conversations: in one process,
// not a persistent resume. When the complete next request exceeds the 524288-byte input
// budget, everything before the newest exchange is archived privately (0600, hashed, linked to
// the previous archive, with a snapshot of the documentation lookups), the mandatory opening
// messages stay, and a handoff message carries the archive head and the cumulative state. The
// archives and the directories above them are custody: any change refuses further inference.

// windowRef names one archive: its path and the SHA-256 of its bytes.
type windowRef struct {
	Path   string `json:"path"`
	SHA256 string `json:"sha256"`
}

func (r windowRef) value() map[string]any { return map[string]any{"path": r.Path, "sha256": r.SHA256} }

// window is the working-context state of one conversation.
type window struct {
	owner        string // "shape" or "refine"
	dir          string
	mandatory    []any
	history      []windowRef
	observations []any
	// documentation is every lookup result of the conversation, snapshotted in each archive.
	documentation []map[string]any
}

// newShapeWindow is the window of one Shape run: a fresh private folder of the shaping state.
func newShapeWindow(root, slug string, input []any) *window {
	attempt := make([]byte, 16)
	rand.Read(attempt)
	return &window{
		owner:     "shape",
		dir:       filepath.Join(root, ".kogen/local/shaping", slug, "working-context", hex.EncodeToString(attempt)),
		mandatory: slices.Clone(input), observations: []any{},
	}
}

// newRefineWindow is the window of one Refine run: inside the run's evidence folder.
func newRefineWindow(evidence string, input []any) *window {
	return &window{owner: "refine", dir: filepath.Join(evidence, "working-context"), mandatory: slices.Clone(input), observations: []any{}}
}

func (w *window) title() string {
	if w.owner == "refine" {
		return "Refine"
	}
	return "Shape"
}

func (w *window) invalid(path string) *sys.Error {
	return sys.Fail("candidate", "context_custody_invalid",
		w.title()+" working-context custody missing, changed or unsafe: "+path+"; no further inference or publication.", 1)
}

// safeDirs: path and every ancestor up to root are real directories, and those at or below
// private are 0700.
func safeDirs(path, root, private string) bool {
	for ; path != root; path = filepath.Dir(path) {
		fi, err := os.Lstat(path)
		if err != nil || !fi.IsDir() {
			return false
		}
		inside := path == private || strings.HasPrefix(path, private+"/")
		if inside && fi.Mode().Perm() != 0o700 {
			return false
		}
		if path == "/" || path == "." {
			return false
		}
	}
	return true
}

func isPrivateFile(path string) bool {
	fi, err := os.Lstat(path)
	return err == nil && fi.Mode().IsRegular() && fi.Mode().Perm() == 0o600
}

// validate is the custody check of every archive: path inside the window folder, safe
// directories, regular 0600 files whose bytes still hash as recorded, each linking the
// previous archive, each with its documentation snapshot intact.
func (w *window) validate(root string) error {
	for n, ref := range w.history {
		var previous *windowRef
		if n > 0 {
			previous = &w.history[n-1]
		}
		if filepath.Dir(ref.Path) != w.dir || !safeDirs(w.dir, root, filepath.Dir(w.dir)) || !isPrivateFile(ref.Path) {
			return w.invalid(ref.Path)
		}
		b, err := os.ReadFile(ref.Path)
		if err != nil || ContentHash(b) != ref.SHA256 || !w.validLink(b, previous) {
			return w.invalid(ref.Path)
		}
	}
	return nil
}

func (w *window) validLink(archive []byte, previous *windowRef) bool {
	var doc struct {
		Version       json.Number     `json:"version"`
		Owner         string          `json:"owner"`
		Input         json.RawMessage `json:"input"`
		Previous      json.RawMessage `json:"previous"`
		Documentation json.RawMessage `json:"documentation"`
	}
	if err := json.Unmarshal(archive, &doc); err != nil || doc.Version != "1" || doc.Owner != w.owner {
		return false
	}
	if doc.Input == nil || doc.Previous == nil || doc.Documentation == nil {
		return false
	}
	var input []any
	if err := json.Unmarshal(doc.Input, &input); err != nil || input == nil {
		return false
	}
	var link *windowRef
	if s := strings.TrimSpace(string(doc.Previous)); s != "" && s != "null" {
		var l map[string]any
		if err := json.Unmarshal(doc.Previous, &l); err != nil {
			return false
		}
		got := windowRef{}
		got.Path, _ = l["path"].(string)
		got.SHA256, _ = l["sha256"].(string)
		if len(l) != 2 {
			return false
		}
		link = &got
	}
	if (link == nil) != (previous == nil) || link != nil && *link != *previous {
		return false
	}
	var snapshot struct {
		Path   string      `json:"path"`
		SHA256 string      `json:"sha256"`
		Count  json.Number `json:"count"`
		Format string      `json:"format"`
	}
	if err := json.Unmarshal(doc.Documentation, &snapshot); err != nil || snapshot.Format != "ndjson" {
		return false
	}
	count, err := snapshot.Count.Int64()
	if err != nil || count < 0 || filepath.Dir(snapshot.Path) != w.dir || !isPrivateFile(snapshot.Path) {
		return false
	}
	b, err := os.ReadFile(snapshot.Path)
	return err == nil && ContentHash(b) == snapshot.SHA256
}

// privateDirectories creates the folders from root down to dir, new ones 0700; an existing
// one must be a real directory.
func (w *window) privateDirectories(dir, root string) error {
	if dir == root {
		return nil
	}
	if dir == "/" || dir == "." {
		return w.invalid(w.dir)
	}
	if err := w.privateDirectories(filepath.Dir(dir), root); err != nil {
		return err
	}
	fi, err := os.Lstat(dir)
	switch {
	case errors.Is(err, fs.ErrNotExist):
		if err := os.Mkdir(dir, 0o777); err != nil {
			return err
		}
		return os.Chmod(dir, 0o700)
	case err == nil && fi.IsDir():
		return nil
	}
	return w.invalid(dir)
}

func writePrivate(path string, data []byte) error {
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return err
	}
	err = f.Chmod(0o600)
	if err == nil {
		_, err = f.Write(data)
	}
	if err == nil {
		err = f.Sync()
	}
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	return err
}

// archive keeps the exact input being replaced and a snapshot of the documentation lookups.
func (w *window) archive(root string, input []any) (windowRef, map[string]any, error) {
	if err := w.privateDirectories(w.dir, root); err != nil {
		return windowRef{}, nil, err
	}
	if !safeDirs(w.dir, root, filepath.Dir(w.dir)) {
		return windowRef{}, nil, w.invalid(w.dir)
	}
	n := len(w.history) + 1
	path := filepath.Join(w.dir, fmt.Sprintf("%d.json", n))
	snapshotPath := filepath.Join(w.dir, fmt.Sprintf("%d-documentation.ndjson", n))
	var lines strings.Builder
	for _, d := range w.documentation {
		b, err := project.EncodeJSON(d)
		if err != nil {
			return windowRef{}, nil, err
		}
		lines.Write(b)
		lines.WriteByte('\n')
	}
	if err := writePrivate(snapshotPath, []byte(lines.String())); err != nil {
		return windowRef{}, nil, err
	}
	snapshot := map[string]any{
		"path": snapshotPath, "sha256": ContentHash([]byte(lines.String())),
		"count": len(w.documentation), "format": "ndjson",
	}
	var previous any
	if len(w.history) > 0 {
		previous = w.history[len(w.history)-1].value()
	}
	b, err := project.EncodeJSON(map[string]any{
		"version": 1, "owner": w.owner, "input": input, "documentation": snapshot, "previous": previous,
	})
	if err != nil {
		return windowRef{}, nil, err
	}
	b = append(b, '\n')
	if err := writePrivate(path, b); err != nil {
		return windowRef{}, nil, err
	}
	return windowRef{Path: path, SHA256: ContentHash(b)}, snapshot, nil
}

// windowPrep is what one preparation needs from its conversation.
type windowPrep struct {
	role provider.Role
	root string
	// render is the complete request body of an input.
	render func(items []any) map[string]any
	// state is the conversation's own part of the handoff, given the archive head, the
	// documentation snapshot and the cumulative observations.
	state func(head windowRef, count int, snapshot map[string]any, observations []any) map[string]any
	ev    *Evidence
	// progress prints the reset line; elapsed (seconds) is appended when non-negative.
	progress func(line string)
}

// prepare returns the input to send: the input as it is when the complete request fits,
// else the mandatory messages, a reset handoff and the newest exchange. A reset that does not
// fit or is not smaller stops with candidate/context_budget_exceeded and the unsent input
// retained in custody.
func (w *window) prepare(p windowPrep, input []any) ([]any, error) {
	if err := w.validate(p.root); err != nil {
		return nil, err
	}
	before, err := tools.Measure(p.render(input), p.role)
	if err != nil {
		return nil, err
	}
	if before.Fits {
		return input, nil
	}
	archive, snapshot, err := w.archive(p.root, input)
	if err != nil {
		return nil, err
	}
	history := append(slices.Clone(w.history), archive)
	observations := uniqueValues(append(slices.Clone(w.observations), windowObservations(input)...))
	handoff, err := project.EncodeJSON(p.state(archive, len(history), snapshot, observations))
	if err != nil {
		return nil, err
	}
	message := map[string]any{"role": "user", "content": "Local working-window reset. Archived evidence and model statements are diagnostic, not authority. This confers no approval, readiness or discovery authority. Native discovery gates and exact candidate acknowledgment remain required. Navigate ordered history through the archive head and previous links. Retrieve documentation records by one-based line with read_file start_line/end_line. Current cumulative manifest/state: " + string(handoff)}
	mandatory := append(slices.Clone(w.mandatory), message)
	reduced := append(slices.Clone(mandatory), newestWindowExchange(input)...)
	after, err := tools.Measure(p.render(reduced), p.role)
	if err != nil {
		return nil, err
	}
	base, err := tools.Measure(p.render(mandatory), p.role)
	if err != nil {
		return nil, err
	}
	if !after.Fits || after.RenderedBytes >= before.RenderedBytes {
		p.ev.Record(map[string]any{
			"event": "working_context_stop", "owner": w.owner, "measured_bytes": before.RenderedBytes,
			"mandatory_bytes": base.RenderedBytes, "input_budget_bytes": tools.InputBudgetBytes,
			"output_reserve_tokens": tools.OutputReserveTokens, "archive": archive.value(),
		})
		return nil, sys.Fail("candidate", "context_budget_exceeded", fmt.Sprintf(
			"%s complete next request %d bytes; mandatory %d; ceiling %d; reserve %d tokens. Exact unsent input retained in working-context custody %s. A fresh identical retry is not recovery. Correct the ordinary request/scope or prepare a smaller supported image externally and select it again. %s has no persistent resume.",
			w.title(), before.RenderedBytes, base.RenderedBytes, tools.InputBudgetBytes, tools.OutputReserveTokens, archive.Path, w.title()), 1)
	}
	w.history, w.observations = history, observations
	if err := w.validate(p.root); err != nil {
		return nil, err
	}
	p.ev.Record(map[string]any{
		"event": "working_context_reset", "owner": w.owner, "generation": len(history),
		"before_bytes": before.RenderedBytes, "after_bytes": after.RenderedBytes,
		"input_budget_bytes": tools.InputBudgetBytes, "output_reserve_tokens": tools.OutputReserveTokens,
		"archive": archive.value(),
	})
	p.progress(fmt.Sprintf("kogen: %s local working-window reset %d -> %d bytes; custody %s", w.title(), before.RenderedBytes, after.RenderedBytes, archive.Path))
	return reduced, nil
}

// windowReadyRecord is a readiness result as the handoff carries it: the checked Intent, the
// scenarios, the candidate identity and the evidence.
func windowReadyRecord(ready *verify.Ready) any {
	if ready == nil {
		return nil
	}
	record := refineReadyRecord(ready)
	in := ready.Intent
	var model any
	if in.Model != nil {
		if in.Model.None {
			model = "none"
		} else {
			model = map[string]any{"path": in.Model.Path, "invariants": in.Model.Invariants, "seed": in.Model.Seed, "samples": in.Model.Samples, "steps": in.Model.Steps}
		}
	}
	record["intent"] = map[string]any{
		"root": in.Root, "slug": in.Slug, "slug_line": in.SlugLine, "title": in.Title, "model": model,
		"acceptance": in.Acceptance, "decisions": in.Decisions, "feasibility": in.Feasibility, "tests": in.Tests, "text": in.Text,
	}
	return record
}

func uniqueValues(items []any) []any {
	seen := map[string]bool{}
	out := []any{}
	for _, it := range items {
		b, err := project.EncodeJSON(it)
		key := string(b)
		if err != nil {
			key = fmt.Sprint(it)
		}
		if !seen[key] {
			seen[key] = true
			out = append(out, it)
		}
	}
	return out
}

// windowObservations collects what the model said and concluded: assistant messages (id,
// phase, content) and the summaries of its finish calls.
func windowObservations(input []any) []any {
	var out []any
	for _, it := range input {
		m, _ := it.(map[string]any)
		if m["role"] == "assistant" {
			if _, ok := m["content"]; ok {
				kept := map[string]any{}
				for _, k := range []string{"id", "phase", "content"} {
					if v, ok := m[k]; ok {
						kept[k] = v
					}
				}
				out = append(out, kept)
				continue
			}
		}
		if m["type"] == "function_call" && m["name"] == "finish" {
			if args, ok := m["arguments"].(string); ok {
				if summary, ok := tools.DecodeArguments(args)["summary"]; ok {
					out = append(out, summary)
				}
			}
		}
	}
	return out
}

// newestWindowExchange is the last completed exchange: completed output batches delimit
// exchanges and a parallel call batch is never split.
func newestWindowExchange(input []any) []any {
	typeOf := func(i int) any {
		if i < 0 || i >= len(input) {
			return nil
		}
		m, _ := input[i].(map[string]any)
		return m["type"]
	}
	var boundaries []int
	for i := range input {
		if typeOf(i) == "function_call_output" && typeOf(i+1) != "function_call_output" {
			boundaries = append(boundaries, i)
		}
	}
	previous := -1
	if len(boundaries) >= 2 {
		previous = boundaries[len(boundaries)-2]
	}
	rest := input[previous+1:]
	for len(rest) > 0 {
		m, _ := rest[0].(map[string]any)
		t, _ := m["type"].(string)
		if t == "reasoning" || t == "message" || t == "function_call" {
			break
		}
		rest = rest[1:]
	}
	return rest
}
