package build

import (
	"strings"
	"testing"
)

const frozenPartsResetNote = "Native delivery facts, not findings, judgments, approval or proof. Pinned parts delivered " +
	"by complete read_file outputs stay counted for the approval check across working-window resets; " +
	"a pinned part is frozen evidence of its tree, so reading it again returns the same text. Pixels of " +
	"images not in_window are archived, not in this window: use view_image again to inspect them. " +
	"Parts or images of a tree other than candidate_tree are not current. " +
	"Kogen also appends unread pinned parts as native source data messages; they count once a completed response follows them. " +
	"Read unread pinned parts in batches of about 10 read_file calls per response, not one per response; " +
	"use a smaller batch only after a native not-delivered notice shows a batch did not fit. " +
	"A not-delivered read is not counted and must be read again."

func TestKRevodBOnDemandReset(t *testing.T) { krevodbReset(t, true) }
func TestKRevodBPartsReset(t *testing.T)    { krevodbReset(t, false) }

func krevodbReset(t *testing.T, onDemand bool) {
	e := newEnv(t)
	if onDemand {
		e.write(".kogen/project.yaml", e.read(".kogen/project.yaml")+"review_material:\n  mode: on_demand\n")
		e.run("git", "add", ".kogen/project.yaml")
		e.run("git", "commit", "-qm", "review material mode")
		e.approve()
	}
	f := e.prov
	content := bigFile()
	f.then(f.calls("write_file", map[string]any{"path": "app.txt", "content": content}, "finish", map[string]any{"summary": "done"}))
	for i := 0; i < 3; i++ {
		f.then(f.calls("write_file", map[string]any{"path": ".kogen/local/padding", "content": strings.Repeat("x", 190_000)}))
	}
	if onDemand {
		f.then(submit(f, "approve"))
	} else {
		reader := confirmingReviewer(t, f, nil)
		for i := 0; i < 40; i++ {
			f.then(reader)
		}
	}
	start := e.head()
	a := e.reviewed()
	if a.exit != 0 || e.head() == start {
		t.Fatalf("not landed: %d %s %s", a.exit, a.shown(), a.errs)
	}
	eq(t, "committed", e.gitOut("show", "HEAD:app.txt")+"\n", content)
	reqs := f.reviewRequests()
	var reset map[string]any
	var resetReq map[string]any
	for _, req := range reqs {
		if onDemand && len(prefilledParts(t, req)) != 0 {
			t.Fatal("on-demand prefill")
		}
		if h := resetHandoff(t, req); h != nil && reset == nil {
			reset = h
			resetReq = req
		}
	}
	if reset == nil {
		t.Fatal("no reset reached provider")
	}
	blocks := requestInput(resetReq)[0].(map[string]any)["content"].([]any)
	authority := blocks[0].(map[string]any)["text"].(string)
	guidance := blocks[1].(map[string]any)["text"].(string)
	contains(t, "authority", authority, "# Intent")
	contains(t, "authority", authority, "# Project instructions (README.md)")
	contains(t, "guidance", guidance, "not new authority")
	if onDemand {
		contains(t, "guidance", guidance, "no part is required before a verdict")
	} else {
		contains(t, "guidance", guidance, "Read EVERY part")
	}
	contains(t, "reset authority", reset["observation_authority"].(string), "only native exact-candidate gates")
	catalog := reviewCatalog(t, resetReq)
	if len(catalog["parts"].([]any)) == 0 || catalog["files"] == nil {
		t.Fatalf("catalog %v", catalog)
	}
	delivery := reset["review_delivery"].(map[string]any)
	source := delivery["source"].(map[string]any)
	if source["current"] != true || source["tree"] != reset["candidate_tree"] || source["parts"].(float64) == 0 {
		t.Fatalf("source %v", source)
	}
	if delivery["images"] == nil {
		t.Fatal("missing image custody")
	}
	note := delivery["note"].(string)
	t.Log(note)
	if !onDemand {
		eq(t, "frozen note", note, frozenPartsResetNote)
		return
	}
	for _, s := range []string{"manifest/catalog lists parts and files", "part id", "path and line range", "Read only the parts you need; no part is required before a verdict.", "Nothing is appended automatically.", "Native delivery facts, not findings, judgments, approval or proof.", "approval check across working-window resets", "images not in_window", "not current"} {
		contains(t, "note", note, s)
	}
	for _, s := range []string{"appends unread", "batches", "must be read again"} {
		lacks(t, "note", note, s)
	}
	if source["delivered"] != float64(0) || len(source["unread"].([]any)) != int(source["parts"].(float64)) {
		t.Fatalf("delivery %v", source)
	}
	events := eventsNamed(e.events(e.onlyRun()), "review_material")
	if len(events) != 1 || events[0]["parts_read"] != float64(0) {
		t.Fatalf("events %v", events)
	}
	eq(t, "verdict", e.jsonFile(e.runPath(e.onlyRun(), "review-1.json"))["verdict"], any("approve"))
}
