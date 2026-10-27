package shape

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"kogen-loop/sys"
	"kogen/executor"
)

// Observation only: it mounts as a test with go -overlay, changes no production source and
// drives the real external Shape path with a scripted session (no process, no model).
func TestK12ShapeObservation(t *testing.T) {
	mode := os.Getenv("KOGEN_K12_MODE")
	f := newShpFx(t)
	f.useExternalShape(6)
	indexSum := func() string {
		b, err := os.ReadFile(filepath.Join(f.Root, ".git", "index"))
		if err != nil {
			return "absent"
		}
		s := sha256.Sum256(b)
		return hex.EncodeToString(s[:])
	}
	switch mode {
	case "stage-existing":
		f.write("notes-staged.txt", "staged by the session\n")
	case "keep-note-preexisting":
		f.write("notes-keep.txt", "mine\n")
	}
	var indexBefore, indexAfter string
	x := &shapeExec{t: t, rounds: []func(int, string) (executor.RoundResult, error){
		func(n int, root string) (executor.RoundResult, error) {
			indexBefore = indexSum()
			switch mode {
			case "stat-refresh":
				future := time.Now().Add(time.Hour)
				if err := os.Chtimes(filepath.Join(root, "calc.js"), future, future); err != nil {
					t.Fatal(err)
				}
				f.git("status", "--porcelain")
			case "stage-existing":
				f.git("add", "notes-staged.txt")
			case "keep-note", "keep-note-preexisting":
				f.write("features/steps/.keep-note", "left behind by the shaper\n")
			default:
				t.Fatalf("unknown mode %q", mode)
			}
			indexAfter = indexSum()
			return result(shpFiles())(n, root)
		},
		result(map[string]any{"files": []any{map[string]any{"path": ".kogen/intents/is-even/acceptance.feature", "content": shpFeature}}}),
	}}
	exit, err := f.shapeWith(x, "Add calc.is_even(n).")
	out := map[string]any{
		"mode": mode, "exit": exit, "error_class": "", "error_reason": "", "error_text": "",
		"index_changed_by_round": indexBefore != indexAfter,
		"published": f.exists(".kogen/intents/is-even/intent.md"),
		"keep_note_exists": f.exists("features/steps/.keep-note"),
		"preexisting_content": nil,
		"status": strings.Split(strings.TrimSpace(f.git("status", "--porcelain", "-uall")), "\n"),
		"removed_events": []any{},
	}
	if err != nil {
		out["error_text"] = err.Error()
		if se, ok := sys.AsError(err); ok {
			out["error_class"], out["error_reason"], out["error_text"] = se.Class, se.Reason, se.Render()
		}
	}
	if f.exists("notes-keep.txt") {
		out["preexisting_content"] = f.read("notes-keep.txt")
	}
	if b, rerr := os.ReadFile(filepath.Join(f.Root, ".kogen/local/shaping", shpSlug, "events.ndjson")); rerr == nil {
		var removed []any
		for _, line := range strings.Split(string(b), "\n") {
			var ev map[string]any
			if line != "" && json.Unmarshal([]byte(line), &ev) == nil && ev["event"] == "shape_untracked_removed" {
				removed = append(removed, ev)
			}
		}
		if removed != nil {
			out["removed_events"] = removed
		}
	}
	raw, _ := json.Marshal(out)
	if werr := os.WriteFile(os.Getenv("KOGEN_K12_OUTPUT"), raw, 0o600); werr != nil {
		t.Fatal(werr)
	}
}
