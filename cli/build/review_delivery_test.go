package build

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"image"
	"image/color"
	"image/png"
	"math/rand"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"kogen-loop/tools"
	"kogen/agent"
)

// The reviewer's working-window resets keep the native delivery facts of its pinned source
// parts and images (KOGEN-048, Studio Build 543748f1): a reviewer that re-reads whatever it
// cannot confirm was delivered otherwise rebuilds the same evidence in every window.

// noisePNG is an opaque RGB PNG of side×side random pixels, which barely compresses.
func noisePNG(t *testing.T, seed int64, side int) []byte {
	t.Helper()
	r := rand.New(rand.NewSource(seed))
	img := image.NewRGBA(image.Rect(0, 0, side, side))
	for y := 0; y < side; y++ {
		for x := 0; x < side; x++ {
			img.Set(x, y, color.RGBA{R: uint8(r.Intn(256)), G: uint8(r.Intn(256)), B: uint8(r.Intn(256)), A: 255})
		}
	}
	var b bytes.Buffer
	if err := png.Encode(&b, img); err != nil {
		t.Fatal(err)
	}
	return b.Bytes()
}

// resetHandoff is the working-window reset message a request carries, or nil.
func resetHandoff(t *testing.T, req map[string]any) map[string]any {
	t.Helper()
	for _, it := range requestInput(req) {
		m, _ := it.(map[string]any)
		s, ok := m["content"].(string)
		if !ok || !strings.HasPrefix(s, "Local working-window reset\n") {
			continue
		}
		var reset map[string]any
		if err := json.Unmarshal([]byte(strings.TrimPrefix(s, "Local working-window reset\n")), &reset); err != nil {
			t.Fatal(err)
		}
		return reset
	}
	return nil
}

// pinnedOf is the pinned source parts a review request's catalog lists, or nil while the
// source is still inline.
func pinnedOf(req map[string]any) []string {
	blocks, _ := requestInput(req)[0].(map[string]any)["content"].([]any)
	if len(blocks) != 2 {
		return nil
	}
	text, _ := blocks[1].(map[string]any)["text"].(string)
	_, rest, ok := strings.Cut(text, "# Pinned complete candidate source evidence\n")
	if !ok {
		return nil
	}
	line, _, _ := strings.Cut(rest, "\n")
	var catalog map[string]any
	if json.Unmarshal([]byte(line), &catalog) != nil {
		return nil
	}
	return catalogParts(catalog)
}

// inWindow is what a request's own window holds: the paths of its completed read_file calls
// and the number of images it carries.
func inWindow(req map[string]any) (read map[string]bool, images int) {
	calls := map[any]string{}
	read = map[string]bool{}
	for _, it := range requestInput(req) {
		m, _ := it.(map[string]any)
		switch m["type"] {
		case "function_call":
			if m["name"] == "read_file" {
				path, _ := tools.DecodeArguments(m["arguments"].(string))["path"].(string)
				calls[m["call_id"]] = path
			}
		case "function_call_output":
			if path, ok := calls[m["call_id"]]; ok {
				read[path] = true
			}
			if parts, ok := m["output"].([]any); ok && len(parts) == 2 {
				if p, _ := parts[1].(map[string]any); p["type"] == "input_image" {
					images++
				}
			}
		}
	}
	return read, images
}

// confirmingReviewer models the reviewer of Build 543748f1: in every window it reads (four at
// a time) the pinned parts it cannot confirm were delivered, from the window itself or the
// reset's native delivery facts, then views every screenshot, then approves.
func confirmingReviewer(t *testing.T, f *fakeProvider, shots []string) handler {
	return func(w http.ResponseWriter, r *http.Request) {
		reqs := f.reviewRequests()
		req := reqs[len(reqs)-1]
		known, images := inWindow(req)
		parts := pinnedOf(req)
		if reset := resetHandoff(t, req); reset != nil {
			if d, ok := reset["review_delivery"].(map[string]any); ok {
				if source, ok := d["source"].(map[string]any); ok && source["current"] == true {
					unread := map[int]bool{}
					for _, n := range source["unread"].([]any) {
						unread[int(n.(float64))] = true
					}
					for i, p := range parts {
						if !unread[i+1] {
							known[p] = true
						}
					}
				}
			}
		}
		var pairs []any
		for _, p := range parts {
			if !known[p] && len(pairs) < 8 {
				pairs = append(pairs, "read_file", map[string]any{"path": p})
			}
		}
		switch {
		case len(pairs) > 0:
			f.calls(pairs...)(w, r)
		case images < len(shots):
			for _, s := range shots {
				pairs = append(pairs, "view_image", map[string]any{"path": s})
			}
			f.calls(pairs...)(w, r)
		default:
			submit(f, "approve")(w, r)
		}
	}
}

func TestAReviewWhosePartsAndScreenshotsCannotShareAWindowConvergesOnItsDeliveredParts(t *testing.T) {
	t.Parallel()
	// Direct core repair (KOGEN-048, Studio Build 543748f1): the review reset reports what was delivered.
	e := newEnv(t)
	var shots []string
	imageBytes := 0
	for i := 0; i < 3; i++ {
		data := noisePNG(t, int64(i+1), 170)
		if len(data) > 131_072 {
			t.Fatalf("screenshot %d is %d bytes", i, len(data))
		}
		shot := ".kogen/local/shot-" + itoa(i+1) + ".png"
		writeFile(t, filepath.Join(e.root, shot), string(data), 0o644)
		shots = append(shots, shot)
		imageBytes += base64.StdEncoding.EncodedLen(len(data))
	}
	f := e.prov
	content := strings.Repeat("0123456789abcdef-line\n", 4_100)
	f.then(f.calls("write_file", map[string]any{"path": "app.txt", "content": content}, "finish", map[string]any{"summary": "done"}))
	shared := confirmingReviewer(t, f, shots)
	for i := 0; i < 60; i++ {
		f.then(shared)
	}
	a := e.reviewed()
	if a.exit != 0 {
		t.Fatalf("exit %d after %d review requests\n%s\n%s", a.exit, len(f.reviewRequests()), a.shown(), a.errs)
	}
	id := e.onlyRun()
	reqs := f.reviewRequests()
	parts := pinnedOf(reqs[len(reqs)-1])
	if len(parts) < 16 {
		t.Fatalf("%d pinned parts", len(parts))
	}
	// The reading and the screenshots cannot share one window.
	partBytes := 0
	for _, p := range parts {
		st, err := os.Stat(p)
		if err != nil {
			t.Fatal(err)
		}
		partBytes += int(st.Size())
	}
	if partBytes+imageBytes <= tools.InputBudgetBytes {
		t.Fatalf("parts %d + screenshots %d bytes fit one window", partBytes, imageBytes)
	}
	for _, req := range f.requests() {
		raw, _ := json.Marshal(req)
		if len(raw) > tools.InputBudgetBytes+4096 {
			t.Fatalf("a request of %d bytes", len(raw))
		}
		read, images := inWindow(req)
		if images == len(shots) && len(read) == len(parts) {
			t.Fatal("one window held every part and every screenshot")
		}
	}
	// Bounded: each part is delivered once, the screenshots at most twice.
	resets := strings.Count(a.errs.String(), "kogen: review local reset ")
	if resets < 2 || resets > 4 || len(reqs) > len(parts)/8+8 {
		t.Fatalf("%d resets, %d review requests for %d parts", resets, len(reqs), len(parts))
	}
	reads := 0
	for _, ev := range eventsNamed(e.events(id), "review_tool_call") {
		if ev["name"] == "read_file" {
			reads++
		}
	}
	eq(t, "part reads", reads, len(parts))
	// Every pinned handoff counts the parts delivered so far, never fewer than before, and the
	// last one names every screenshot, current and archived.
	var last map[string]any
	delivered, handoffs := -1.0, 0
	for _, req := range reqs {
		h := resetHandoff(t, req)
		if h == nil || last != nil && len(h["history"].([]any)) == len(last["history"].([]any)) {
			continue
		}
		handoffs++
		delivery := h["review_delivery"].(map[string]any)
		eq(t, "review", delivery["review"], any(float64(1)))
		source := delivery["source"].(map[string]any)
		eq(t, "parts", source["parts"], any(float64(len(parts))))
		eq(t, "source current", source["current"], any(true))
		eq(t, "source tree", source["tree"], h["candidate_tree"])
		n := source["delivered"].(float64)
		if n < delivered || int(n)+len(source["unread"].([]any)) != len(parts) {
			t.Fatalf("delivered %v after %v, unread %v", n, delivered, source["unread"])
		}
		delivered, last = n, h
	}
	if delivered <= 0 || handoffs != resets {
		t.Fatalf("%d handoffs for %d resets; last counted %v delivered parts", handoffs, resets, delivered)
	}
	images := last["review_delivery"].(map[string]any)["images"].([]any)
	eq(t, "images", len(images), len(shots))
	for i, x := range images {
		m := x.(map[string]any)
		eq(t, "image path", m["path"], any(shots[i]))
		eq(t, "image current", m["current"], any(true))
		if _, ok := m["in_window"].(bool); !ok || m["sha256"] == "" {
			t.Fatalf("image %v", m)
		}
	}
	review := e.jsonFile(e.runPath(id, "review-1.json"))
	eq(t, "verdict", review["verdict"], any("approve"))
	eq(t, "committed", e.gitOut("show", "HEAD:app.txt")+"\n", content)
}

func TestAReviewResetReportsEachImageAtItsNewestDeliveryOnlyForThisReview(t *testing.T) {
	// Direct core repair (KOGEN-048): delivery facts follow the candidate tree, never the reset.
	b, e, tree := windowAttempt(t)
	b.Review = 1
	shot := ".kogen/local/shot.png"
	writeFile(t, filepath.Join(e.root, shot), string(noisePNG(t, 7, 4)), 0o644)
	inline := materialSet{Authority: "exact approved authority", Source: "# Diff of existing/deleted paths\n" + strings.Repeat("s", 30_000), Files: []map[string]any{}}
	authority := materialOpening(inline.Authority, inline.Source, nil)[0]
	tl := &tools.Tools{Root: e.root, Session: b.s, Repo: agent.Git(b.repo), Enabled: reviewToolNames}
	calls := 0
	view := func() []any {
		calls++
		id := "view" + itoa(calls)
		arguments := `{"path":"` + shot + `"}`
		call := tools.Call{Item: map[string]any{"type": "function_call", "call_id": id, "name": "view_image",
			"arguments": arguments}, Name: "view_image", Arguments: arguments}
		out, err := tl.Call(call)
		if err != nil {
			t.Fatal(err)
		}
		return []any{call.Item, call.Output(out.Cut())}
	}
	pad, _ := json.Marshal(map[string]any{"path": "pad.txt", "content": strings.Repeat("x", 190_000)})
	pads := func() []any {
		var items []any
		for i := 0; i < 3; i++ {
			calls++
			id := "pad" + itoa(calls)
			items = append(items,
				map[string]any{"type": "function_call", "call_id": id, "name": "write_file", "arguments": string(pad)},
				map[string]any{"type": "function_call_output", "call_id": id, "output": "ok"})
		}
		return items
	}
	b.WorkingContext["review"] = &OwnerContext{Mandatory: []any{authority}, Observations: []any{}, History: []HistoryRef{},
		InlineMaterial: &inline, SourceTree: &tree}
	reset := func(input []any) ([]any, map[string]any) {
		t.Helper()
		got, err := b.prepareContext("review", defaultRole(), "policy", input, nil)
		if err != nil {
			t.Fatal(err)
		}
		return got, handoffOf(t, got)["review_delivery"].(map[string]any)
	}
	image := func(delivery map[string]any) map[string]any {
		t.Helper()
		images := delivery["images"].([]any)
		if len(images) != 1 {
			t.Fatalf("images %v", images)
		}
		return images[0].(map[string]any)
	}

	// The first reset pins the inline source: every part unread, the screenshot archived.
	got, delivery := reset(slices.Concat([]any{authority}, view(), pads()))
	source := delivery["source"].(map[string]any)
	eq(t, "source tree", source["tree"], any(tree))
	eq(t, "source current", source["current"], any(true))
	eq(t, "unread", len(source["unread"].([]any)), int(source["parts"].(float64)))
	if m := image(delivery); m["current"] != true || m["in_window"] != false || m["read_candidate"] != tree {
		t.Fatalf("image %v", m)
	}

	// The candidate changes: the same facts remain, no longer current.
	e.write("app.txt", "edited after the screenshot\n")
	got, delivery = reset(slices.Concat(got, pads()))
	source = delivery["source"].(map[string]any)
	eq(t, "source tree", source["tree"], any(tree))
	eq(t, "source current", source["current"], any(false))
	if m := image(delivery); m["current"] != false || m["read_candidate"] != tree {
		t.Fatalf("image %v after the edit", m)
	}

	// Viewed again at the new tree, the same screenshot is current again, and in the window
	// while its delivery is the newest exchange.
	got, delivery = reset(slices.Concat(got, pads(), view()))
	current := handoffOf(t, got)["candidate_tree"]
	if m := image(delivery); m["current"] != true || m["read_candidate"] != current || m["in_window"] != true {
		t.Fatalf("image %v after a new view at %v", m, current)
	}

	// The next review reports only its own deliveries: its parts, and no image yet.
	b.Review++
	next, err := b.materialPrepare(current.(string), materialSet{Authority: inline.Authority, Source: inline.Source + "second", Files: []map[string]any{}},
		defaultRole(), "policy", nil, nil, true)
	if err != nil {
		t.Fatal(err)
	}
	_, delivery = reset(slices.Concat(next, pads()))
	eq(t, "review", delivery["review"], any(float64(b.Review)))
	source = delivery["source"].(map[string]any)
	eq(t, "source current", source["current"], any(true))
	eq(t, "delivered", source["delivered"], any(float64(0)))
	eq(t, "images", len(delivery["images"].([]any)), 0)
}

// handoffOf is the reset message of a reduced input.
func handoffOf(t *testing.T, input []any) map[string]any {
	t.Helper()
	for _, it := range input {
		m, _ := it.(map[string]any)
		if s, ok := m["content"].(string); ok && strings.HasPrefix(s, "Local working-window reset\n") {
			var reset map[string]any
			if err := json.Unmarshal([]byte(strings.TrimPrefix(s, "Local working-window reset\n")), &reset); err != nil {
				t.Fatal(err)
			}
			return reset
		}
	}
	t.Fatal("no reset message")
	return nil
}
