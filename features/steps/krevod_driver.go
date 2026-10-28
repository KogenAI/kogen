package build

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"os"
	"regexp"
	"strings"
	"testing"

	"kogen-loop/sys"
	"kogen/project"
)

// Observation only: installed package tests supply the real Build/fake-provider fixture.
// This file is mounted as a test with go -overlay; it changes no production source.

const krevodBody = "0123456789abcdef-line"

// krevodTail is the guidance that follows the catalog line of a pinned-parts review today.
const krevodTail = `This catalog is evidence for this candidate, not new authority. Read EVERY part
with read_file before approving, using each complete single-line JSON result.
Concatenate review_source.text in listed part order to recover the exact full
diff and changed-file text. No bytes were clipped. Each part fits the text tool
cap. A read result must reach a completed reviewer continuation before it counts;
requesting reads and approval in one response does not deliver that text.
Paths/modes/blob IDs and SHA-256 identify additions, modifications and deletions;
deleted contents remain available at the pinned start HEAD through git show.
Inspect other repository context as needed. Do not infer capture or approval
from this catalog, or import builder conversation, reasoning or judgments.
`

var (
	// abbreviated (7+) and full commit hashes and other digests are normalized
	krevodHex = regexp.MustCompile(`[0-9a-f]{7,64}`)
	// the per-run temporary folder (the fixture's accept.sh path) differs between two envs
	krevodTmp = regexp.MustCompile(`[^"\s]*TestKRevodObservation[0-9]+/[0-9]+/`)
)

// krevodNorm is the one normalization applied to every cross-mode comparison:
// temporary paths become "T/", then runs of 7..64 lowercase hex digits become "H".
// The two modes run in separate repositories (different start HEAD and temp folder),
// so raw bytes or raw hashes are only comparable within one run.
func krevodNorm(s string) string {
	return krevodHex.ReplaceAllString(krevodTmp.ReplaceAllString(s, "T/"), "H")
}

func krevodKeys(m map[string]any) []string {
	keys := []string{}
	for k := range m {
		keys = append(keys, k)
	}
	// insertion sort keeps the driver free of extra imports
	for i := 1; i < len(keys); i++ {
		for j := i; j > 0 && keys[j] < keys[j-1]; j-- {
			keys[j], keys[j-1] = keys[j-1], keys[j]
		}
	}
	return keys
}

func krevodRun(t *testing.T, mode string, big bool, script []string) map[string]any {
	e := newEnv(t)
	if mode != "" {
		e.write(".kogen/project.yaml", e.read(".kogen/project.yaml")+"review_material:\n  mode: "+mode+"\n")
		e.run("git", "add", ".kogen/project.yaml")
		e.run("git", "commit", "-qm", "review material mode")
		e.approve()
	}
	f := e.prov
	content := "changed\n"
	if big {
		content = bigFile()
	}
	f.then(f.calls("write_file", map[string]any{"path": "app.txt", "content": content},
		"write_file", map[string]any{"path": "extra.txt", "content": "one\ntwo\nthree\n"},
		"finish", map[string]any{"summary": "done"}))
	partsOf := func() []string { return catalogParts(reviewCatalog(f.t, f.reviewRequests()[0])) }
	for _, s := range script {
		switch s {
		case "approve":
			f.then(submit(f, "approve"))
		case "read-first":
			f.then(func(w http.ResponseWriter, r *http.Request) {
				f.calls("read_file", map[string]any{"path": partsOf()[0]})(w, r)
			})
		case "read-first-and-range":
			f.then(func(w http.ResponseWriter, r *http.Request) {
				f.calls("read_file", map[string]any{"path": partsOf()[0]},
					"read_file", map[string]any{"path": "app.txt", "start_line": 100, "end_line": 110})(w, r)
			})
		case "read-all-approve":
			var parts []string
			next := 0
			shared := func(w http.ResponseWriter, r *http.Request) {
				if parts == nil {
					parts = partsOf()
				}
				if next >= len(parts) {
					submit(f, "approve")(w, r)
					return
				}
				var pairs []any
				for _, p := range parts[next:min(next+15, len(parts))] {
					pairs = append(pairs, "read_file", map[string]any{"path": p})
				}
				next += 15
				f.calls(pairs...)(w, r)
			}
			for i := 0; i < 30; i++ {
				f.then(shared)
			}
		default:
			t.Fatalf("unknown step %q", s)
		}
	}
	start := e.head()
	a := e.reviewed()
	reqs := f.reviewRequests()
	out := map[string]any{"exit": a.exit, "head_changed": e.head() != start, "output": a.shown(), "requests": len(reqs)}

	feedback := []string{}
	seen := map[string]bool{}
	reads := map[string]string{}
	for _, req := range reqs {
		items := requestInput(req)
		args := map[string]string{}
		for _, it := range items {
			m, _ := it.(map[string]any)
			if m["type"] == "function_call" {
				id, _ := m["call_id"].(string)
				args[id], _ = m["arguments"].(string)
			}
		}
		for _, it := range items {
			m, _ := it.(map[string]any)
			if m["type"] != "function_call_output" {
				continue
			}
			id, _ := m["call_id"].(string)
			text, _ := m["output"].(string)
			if strings.HasPrefix(text, "invalid verdict") && !seen[id] {
				seen[id] = true
				feedback = append(feedback, text)
			}
			a := args[id]
			switch {
			case strings.Contains(a, "start_line"):
				if _, ok := reads["range"]; !ok {
					reads["range"] = text
				}
			case strings.Contains(a, "/1.json\""):
				if _, ok := reads["part1"]; !ok {
					reads["part1"] = text
				}
			}
		}
	}
	out["feedback"] = feedback
	out["reads"] = reads

	id := e.onlyRun()
	out["outcome"] = e.result(id)["outcome"]
	material := eventsNamed(e.events(id), "review_material")
	if material == nil {
		material = []map[string]any{}
	}
	out["material_events"] = material
	out["evidence_events"] = len(eventsNamed(e.events(id), "review_source_evidence"))
	if len(reqs) == 0 {
		return out
	}
	first := requestText(reqs[0])
	out["has_body"] = strings.Contains(first, krevodBody)
	out["first_len"] = len(first)
	out["normalized"] = krevodNorm(first)
	blocks := requestInput(reqs[0])[0].(map[string]any)["content"].([]any)
	authority := krevodNorm(blocks[0].(map[string]any)["text"].(string))
	out["authority_sha"] = hashHex([]byte(authority))
	text := blocks[1].(map[string]any)["text"].(string)
	out["source_text"] = text
	if big {
		catalog := reviewCatalog(t, reqs[0])
		out["catalog"] = catalog
		out["catalog_keys"] = krevodKeys(catalog)
		files, _ := catalog["files"].([]any)
		out["file_keys"] = []string{}
		if len(files) > 0 {
			out["file_keys"] = krevodKeys(files[0].(map[string]any))
		}
		list, _ := catalog["parts"].([]any)
		out["part_keys"] = []string{}
		if len(list) > 0 {
			out["part_keys"] = krevodKeys(list[0].(map[string]any))
		}
		// within this run the raw SHA-256 of every part file must equal the catalog hash;
		// across runs only the SHA-256 of each part's normalized bytes is comparable
		disk := true
		norms := []string{}
		for _, p := range list {
			m := p.(map[string]any)
			raw, err := os.ReadFile(m["path"].(string))
			sum := sha256.Sum256(raw)
			if err != nil || hex.EncodeToString(sum[:]) != m["sha256"] {
				disk = false
			}
			norms = append(norms, hashHex([]byte(krevodNorm(string(raw)))))
		}
		out["parts_match_disk"] = disk
		out["part_norm_sha"] = norms
		out["tail_exact"] = strings.HasSuffix(text, "\n\n"+krevodTail) &&
			strings.HasPrefix(text, "# Check results of the final pass\nacceptance: passed")
	}
	return out
}

func krevodConfig(yaml string) map[string]any {
	_, err := project.ParseConfig("version: 1\n"+yaml, "project.yaml")
	out := map[string]any{"ok": err == nil, "error": ""}
	if err != nil {
		msg := err.Error()
		if e, ok := sys.AsError(err); ok {
			msg = e.Render()
		}
		out["error"] = msg
	}
	return out
}

func TestKRevodObservation(t *testing.T) {
	var in struct {
		Scenario string `json:"scenario"`
	}
	raw, err := os.ReadFile(os.Getenv("KOGEN_KREVOD_INPUT"))
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(raw, &in); err != nil {
		t.Fatal(err)
	}
	var out any
	switch in.Scenario {
	case "default-overflow":
		out = krevodRun(t, "", true, []string{"approve", "read-all-approve"})
	case "on-demand-none":
		out = krevodRun(t, "on_demand", true, []string{"approve"})
	case "on-demand-one":
		out = krevodRun(t, "on_demand", true, []string{"read-first", "approve"})
	case "reads":
		out = map[string]any{
			"parts":     krevodRun(t, "", true, []string{"read-first-and-range", "read-all-approve"}),
			"on_demand": krevodRun(t, "on_demand", true, []string{"read-first-and-range", "approve"}),
		}
	case "inline":
		out = map[string]any{
			"default":   krevodRun(t, "", false, []string{"approve"}),
			"on_demand": krevodRun(t, "on_demand", false, []string{"approve"}),
		}
	case "config":
		out = map[string]any{
			"absent":    krevodConfig(""),
			"parts":     krevodConfig("review_material:\n  mode: parts\n"),
			"on_demand": krevodConfig("review_material:\n  mode: on_demand\n"),
			"bad_value": krevodConfig("review_material:\n  mode: sometimes\n"),
			"bad_key":   krevodConfig("review_material:\n  mode: parts\n  extra: 1\n"),
			"scalar":    krevodConfig("review_material: parts\n"),
		}
	default:
		t.Fatalf("unknown scenario %q", in.Scenario)
	}
	data, err := json.Marshal(out)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(os.Getenv("KOGEN_KREVOD_OUTPUT"), data, 0o600); err != nil {
		t.Fatal(err)
	}
}
