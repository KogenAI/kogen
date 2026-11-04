package loop

import (
	"bytes"
	"context"
	"image"
	"image/color"
	"image/png"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"testing"
	"time"

	"kogen-loop/provider"
	"kogen-loop/tools"
)

// Overlap changes when calls run, not what a round means: the same responses give the same
// conversation, bounds, terminal handling and errors as the serial order of a hooked round,
// legacy requesters work, and no public field, dependency or timing policy changed.
func TestToolOverlapCompatibility(t *testing.T) {
	t.Parallel()
	var lines strings.Builder
	for i := 0; i < 3000; i++ {
		lines.WriteString("line of the large file\n")
	}
	pixel := func() []byte {
		img := image.NewRGBA(image.Rect(0, 0, 1, 1))
		img.Set(0, 0, color.RGBA{R: 1, G: 2, B: 3, A: 255})
		var buf bytes.Buffer
		if err := png.Encode(&buf, img); err != nil {
			t.Fatal(err)
		}
		return buf.Bytes()
	}()
	// world is a fresh root with the files the script touches, and tools over it.
	world := func(t *testing.T) (Round, string) {
		root := t.TempDir()
		for name, data := range map[string][]byte{"big.txt": []byte(lines.String()), "small.txt": []byte("small\n"), "img.png": pixel, "locked.txt": []byte("locked\n")} {
			if err := os.WriteFile(filepath.Join(root, name), data, 0o644); err != nil {
				t.Fatal(err)
			}
		}
		repo := newOLRepo(t)
		repo.openAll() // every Git call answers at once
		tl := olTools(root, repo, nil)
		tl.Protected = []string{"locked.txt"}
		return Round{Tools: tl}, root
	}
	script := func() [][]map[string]any {
		return [][]map[string]any{{
			olCall("big", "read_file", map[string]any{"path": "big.txt"}),
			fcall("t1", "finish", `{"summary":"first"}`),
			olWrite("w", "out.txt", "written"),
			olCall("img", "view_image", map[string]any{"path": "img.png"}),
			olList("ls", "."),
			olCall("nope", "mystery", map[string]any{}),
			olWrite("locked", "locked.txt", "x"),
			olShell("sh", "echo shell"),
			olCall("bad", "read_file", map[string]any{"path": "../outside"}),
			fcall("t2", "finish", `{"summary":"second"}`),
		}}
	}
	hooked := Hooks{BeforeCall: func(context.Context, tools.Call, []any) error { return nil }}

	t.Run("same conversation as the serial order", func(t *testing.T) {

		t.Parallel()
		var results [2]Result
		var roots [2]string
		for i, h := range []Hooks{{}, hooked} {
			rd, root := world(t)
			rq := &scriptRequester{script: script()}
			res, err := Run(context.Background(), rd, []any{userMsg("go")}, rq, h)
			if err != nil {
				t.Fatal(err)
			}
			results[i], roots[i] = res, root
			if b, err := os.ReadFile(filepath.Join(root, "out.txt")); err != nil || string(b) != "written" {
				t.Fatalf("a call after the first terminal did not run: %q %v", b, err)
			}
		}
		if a, b := marshal(t, results[0]), marshal(t, results[1]); a != b {
			t.Fatalf("overlapped round\n%s\nserial round\n%s", a, b)
		}
		res := results[0]
		if res.Ending != EndTerminal || res.Terminal == nil || res.Terminal.CallID() != "t2" || res.Requests != 1 {
			t.Fatalf("last terminal call must win: %+v", res)
		}
		outs := map[string]any{}
		var order []string
		for _, it := range res.Input {
			if m, ok := it.(map[string]any); ok && m["type"] == "function_call_output" {
				outs[m["call_id"].(string)] = m["output"]
				order = append(order, m["call_id"].(string))
			}
		}
		if !reflect.DeepEqual(order, []string{"big", "w", "img", "ls", "nope", "locked", "sh", "bad"}) {
			t.Fatalf("outputs %v: terminal calls append none, the rest keep call order", order)
		}
		big, _ := outs["big"].(string)
		full := tools.Cut(numberedLines(3000))
		if len(big) > 16384 || big != full || !strings.Contains(big, "bytes omitted") {
			t.Fatalf("output bound changed: %d bytes", len(big))
		}
		if parts, ok := outs["img"].([]any); !ok || len(parts) != 2 || parts[1].(map[string]any)["type"] != "input_image" {
			t.Fatalf("typed output %v", outs["img"])
		}
		if outs["nope"] != "error: unknown tool mystery" || outs["w"] != "ok" || outs["sh"] != "exit status: 0\nshell\n" ||
			!strings.HasPrefix(outs["locked"].(string), "refused: locked.txt") || !strings.HasPrefix(outs["bad"].(string), "error: ../outside") {
			t.Fatalf("tool text changed: %v", outs)
		}
		if b, _ := os.ReadFile(filepath.Join(roots[0], "locked.txt")); string(b) != "locked\n" {
			t.Fatalf("a protected file changed: %q", b)
		}
	})

	t.Run("no call and legacy requester", func(t *testing.T) {

		t.Parallel()
		rd, _ := world(t)
		rq := &scriptRequester{script: [][]map[string]any{prose("all done")}}
		res, err := Run(context.Background(), rd, []any{userMsg("go")}, rq, Hooks{})
		if err != nil || res.Ending != EndNoCall || res.Terminal != nil || res.Requests != 1 ||
			marshal(t, res.Input) != marshal(t, []any{userMsg("go"), prose("all done")[0]}) {
			t.Fatalf("%+v %v", res, err)
		}
		// Without tools every call is an unknown tool and terminal calls still end the round.
		rq = &scriptRequester{script: [][]map[string]any{{olSearch("a", "x"), fcall("t", "finish", `{}`)}}}
		res, err = Run(context.Background(), Round{}, nil, rq, Hooks{})
		if err != nil || res.Ending != EndTerminal || marshal(t, res.Input) != marshal(t, []any{olSearch("a", "x"), fcall("t", "finish", `{}`), fout("a", "error: unknown tool search_text")}) {
			t.Fatalf("%+v %v", res, err)
		}
	})

	// A cancelled context is still returned as the context's error with a legacy requester.
	t.Run("cancelled before the calls", func(t *testing.T) {
		t.Parallel()
		rd, _ := world(t)
		ctx, cancel := context.WithCancel(context.Background())
		rq := cancelAfterRequest{cancel: cancel, items: []map[string]any{olSearch("a", "x")}}
		res, err := Run(ctx, rd, nil, rq, Hooks{})
		if err != context.Canceled || res.Input != nil {
			t.Fatalf("%+v %v", res, err)
		}
	})

	t.Run("no new public field, dependency or timing policy", func(t *testing.T) {

		t.Parallel()
		fields := func(v any) []string {
			rt := reflect.TypeOf(v)
			var names []string
			for i := 0; i < rt.NumField(); i++ {
				names = append(names, rt.Field(i).Name)
			}
			return names
		}
		for _, c := range []struct {
			v    any
			want []string
		}{
			{Request{}, []string{"Owner", "Role", "Instructions", "Input", "Tools"}},
			{Direct{}, []string{"Client", "Session", "Observer", "CacheID", "Cache", "Condensed", "terminal"}},
			{Round{}, []string{"Owner", "Role", "Instructions", "Definitions", "Tools", "Terminal"}},
			{Hooks{}, []string{"BeforeRequest", "AfterResponse", "BeforeCall", "HandleCall", "AfterCall"}},
			{Handled{}, []string{"Handled", "Output", "Terminal"}},
			{Result{}, []string{"Ending", "Terminal", "Input", "Response", "Requests"}},
			{provider.Request{}, []string{"Role", "Instructions", "Input", "Tools", "ToolChoice", "Single", "CacheID", "Scope", "Cache", "Context"}},
			{provider.Response{}, []string{"Items", "Usage", "Known", "UsageState", "ID", "Model", "Effort", "CacheStatus", "OperationID", "Metadata"}},
			{provider.Client{}, []string{"HTTP", "Now", "Sleep", "Cache", "Locker", "Input", "Version", "ResponseBudget", "httpOnce", "defHTTP"}},
			{tools.Tools{}, []string{"Root", "Session", "Repo", "Enabled", "Protected", "Excluded", "Probe", "Documentation", "ShellAfter", "shells"}},
			{tools.Output{}, []string{"Text", "Parts", "Rule"}},
		} {
			if got := fields(c.v); !reflect.DeepEqual(got, c.want) {
				t.Errorf("%T fields %v, want %v", c.v, got, c.want)
			}
		}
		mod, err := os.ReadFile("../go.mod")
		if err != nil || strings.Contains(string(mod), "require") {
			t.Errorf("go.mod must stay free of dependencies: %q %v", mod, err)
		}
		if provider.ResponseBudget != 30*time.Minute || provider.InputBudgetBytes != 524288 || len(tools.Cut(strings.Repeat("x", 20000))) > 16384 {
			t.Error("a limit changed")
		}
	})
}

// numberedLines is read_file's text of a file of n identical lines.
func numberedLines(n int) string {
	var b strings.Builder
	for i := 1; i <= n; i++ {
		if i > 1 {
			b.WriteByte('\n')
		}
		b.WriteString(strconv.Itoa(i) + "\t" + "line of the large file")
	}
	return b.String()
}

type cancelAfterRequest struct {
	cancel context.CancelFunc
	items  []map[string]any
}

func (c cancelAfterRequest) Request(ctx context.Context, r Request) (*provider.Response, []any, error) {
	c.cancel()
	return &provider.Response{Items: c.items}, r.Input, nil
}
