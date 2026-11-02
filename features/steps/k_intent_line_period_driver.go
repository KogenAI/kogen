package shape

import (
	"context"
	"encoding/json"
	"os"
	"strings"
	"testing"

	"kogen-loop/sys"
	"kogen/project"
	"kogen/verify"
)

// Observation only: it mounts as a test with go -overlay and changes no production source. It
// drives the real Intent check (project.CheckIntent) on synthetic Tests and Decisions lines, and
// the real native Shape path with a scripted provider followed by the real approval card.
const (
	klpDecision = "- Non-integers raise TypeError. (source: request)"
	klpTest     = "- is_even returns True for even integers: add test_is_even in tests/test_calc.py (unit)"
)

type klpLine struct {
	Section string `json:"section"`
	Line    string `json:"line"`
}

type klpInput struct {
	Mode  string    `json:"mode"`
	Lines []klpLine `json:"lines"`
}

// klpIntent is the valid is-even Intent with its one Decisions line and one Tests line replaced
// by the given lines of each section (a section without lines keeps its valid line).
func klpIntent(lines []klpLine) string {
	var decisions, tests []string
	for _, l := range lines {
		switch l.Section {
		case "Decisions":
			decisions = append(decisions, l.Line)
		case "Tests":
			tests = append(tests, l.Line)
		}
	}
	if decisions == nil {
		decisions = []string{klpDecision}
	}
	if tests == nil {
		tests = []string{klpTest}
	}
	intent := strings.Replace(shpIntentMD, klpDecision+"\n", strings.Join(decisions, "\n")+"\n", 1)
	return strings.Replace(intent, klpTest+"\n", strings.Join(tests, "\n")+"\n", 1)
}

func klpProblems(err error) []string {
	problems := []string{}
	if err == nil {
		return problems
	}
	if e, ok := sys.AsError(err); ok && len(e.Lines) > 0 {
		return append(problems, e.Lines...)
	}
	return append(problems, "ERROR: "+err.Error())
}

func TestKLinePeriodObservation(t *testing.T) {
	var in klpInput
	if err := json.Unmarshal([]byte(os.Getenv("KOGEN_KLP_INPUT")), &in); err != nil {
		t.Fatalf("KOGEN_KLP_INPUT: %v", err)
	}
	out := map[string]any{"mode": in.Mode}
	write := func() {
		raw, _ := json.Marshal(out)
		if err := os.WriteFile(os.Getenv("KOGEN_KLP_OUTPUT"), raw, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	switch in.Mode {
	case "lint":
		// Each line is checked alone, in an otherwise valid Intent.
		root := t.TempDir()
		cases := []any{}
		for _, l := range in.Lines {
			overlay := map[string][]byte{
				project.IntentMDPath(shpSlug):     []byte(klpIntent([]klpLine{l})),
				project.FeaturePath(shpSlug):      []byte(shpFeature),
				"features/steps/is_even_steps.js": []byte(shpSteps),
			}
			_, _, err := project.CheckIntent(root, shpSlug, overlay)
			cases = append(cases, map[string]any{"section": l.Section, "line": l.Line, "problems": klpProblems(err)})
		}
		out["cases"] = cases
	case "shape":
		submitted := klpIntent(in.Lines)
		files := shpFiles()
		files["files"].([]any)[0] = map[string]any{"path": ".kogen/intents/is-even/intent.md", "content": submitted}
		f := newShpFx(t, shpSubmit("c1", files))
		f.setReport("PASSED", 0)
		tools := verify.Tools{Node: os.Getenv("KOGEN_NODE"), Quint: os.Getenv("KOGEN_QUINT"), Cucumber: os.Getenv("KOGEN_CUCUMBER")}
		f.newSession()
		exit, err := Shape(context.Background(), f.S, ShapeInput{Project: f.Root, Slug: shpSlug, Request: "Add calc.is_even(n). Non-integers raise TypeError.", Client: f.Client, Tools: tools})
		out["submitted"] = submitted
		out["exit"] = exit
		out["error_text"] = ""
		if err != nil {
			out["error_text"] = err.Error() + "\n" + strings.Join(klpProblems(err), "\n")
		}
		out["shaper_requests"] = len(f.Prov.requests())
		out["refused"] = []any{}
		if f.exists(".kogen/local/shaping/is-even/events.ndjson") {
			if r := shpNamed(f.events(), "submission_refused"); r != nil {
				out["refused"] = r
			}
		}
		out["published"] = err == nil && exit == 0 && f.exists(".kogen/intents/is-even/intent.md")
		out["intent"] = ""
		out["card_exit"] = -1
		out["card"] = ""
		if out["published"] == true {
			out["intent"] = f.read(".kogen/intents/is-even/intent.md")
			f.newSession()
			code, cerr := Approve(context.Background(), f.S, ApproveInput{Project: f.Root, Slug: shpSlug, Tools: tools})
			out["card_exit"] = code
			out["card"] = f.Stdout.String()
			if cerr != nil {
				out["card"] = out["card"].(string) + "\nERROR: " + cerr.Error() + "\n" + strings.Join(klpProblems(cerr), "\n")
			}
		}
	default:
		t.Fatalf("unknown mode %q", in.Mode)
	}
	write()
}
