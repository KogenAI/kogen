package conformance

import (
	"bytes"
	"context"
	"encoding/json"
	"go/ast"
	"go/parser"
	"go/token"
	"image"
	"image/png"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"kogen-loop/api"
	"kogen-loop/loop"
	"kogen-loop/provider"
	"kogen-loop/tools"
)

// removedLevers are the exported names of the queued experimental levers and of the support
// that only they used. None may be declared anywhere in the public packages.
var removedLevers = []string{
	"PrefixLog", "EndPrefixLog", "PrefixEvent",
	"ReadLedger", "NewReadLedger", "Continuation", "ReadOK",
	"TerminalReminders", "TerminalReminder", "EventTerminalReminder",
	"CompactDescriptions", "OmitViewImage",
}

// declaredNames lists every identifier the non-test sources of a package declare: types,
// functions, methods, constants, variables and struct or interface members.
func declaredNames(t *testing.T, dir string) map[string]bool {
	t.Helper()
	pkgs, err := parser.ParseDir(token.NewFileSet(), dir, func(fi os.FileInfo) bool {
		return !strings.HasSuffix(fi.Name(), "_test.go")
	}, 0)
	if err != nil {
		t.Fatal(err)
	}
	names := map[string]bool{}
	for _, pkg := range pkgs {
		for _, file := range pkg.Files {
			ast.Inspect(file, func(n ast.Node) bool {
				switch d := n.(type) {
				case *ast.TypeSpec:
					names[d.Name.Name] = true
				case *ast.FuncDecl:
					names[d.Name.Name] = true
				case *ast.ValueSpec:
					for _, id := range d.Names {
						names[id.Name] = true
					}
				case *ast.Field:
					for _, id := range d.Names {
						names[id.Name] = true
					}
				}
				return true
			})
		}
	}
	return names
}

func TestQueuedLeversRemoved(t *testing.T) {
	for _, c := range []struct {
		typ   reflect.Type
		field string
	}{
		{reflect.TypeOf(provider.Client{}), "PrefixLog"},
		{reflect.TypeOf(loop.Round{}), "ReadLedger"},
		{reflect.TypeOf(loop.Round{}), "TerminalReminders"},
		{reflect.TypeOf(loop.SessionConfig{}), "TerminalReminders"},
		{reflect.TypeOf(loop.Hooks{}), "TerminalReminder"},
		{reflect.TypeOf(tools.Tools{}), "CompactDescriptions"},
		{reflect.TypeOf(tools.Tools{}), "OmitViewImage"},
		{reflect.TypeOf(tools.Output{}), "ReadOK"},
	} {
		if _, ok := c.typ.FieldByName(c.field); ok {
			t.Errorf("%s.%s still exists", c.typ, c.field)
		}
	}
	if _, ok := reflect.TypeOf(&provider.Client{}).MethodByName("EndPrefixLog"); ok {
		t.Error("provider.Client.EndPrefixLog still exists")
	}
	if api.Protocol == "" {
		t.Fatal("api.Protocol is empty")
	}

	// Public exported-symbol inspection: no deleted type, function, constant or member is
	// declared by any package, including ReadLedger/NewReadLedger/Continuation and PrefixEvent.
	for _, dir := range []string{"../api", "../loop", "../provider", "../tools", "../sys", "../cmd/kogen-loop"} {
		names := declaredNames(t, dir)
		for _, name := range removedLevers {
			if names[name] {
				t.Errorf("%s still declares %s", dir, name)
			}
		}
	}

	// What the levers sat beside stays.
	for _, c := range []struct {
		typ   reflect.Type
		field string
	}{
		{reflect.TypeOf(provider.Client{}), "Cache"},
		{reflect.TypeOf(provider.Request{}), "ToolChoice"},
		{reflect.TypeOf(loop.Round{}), "Terminal"},
		{reflect.TypeOf(loop.SessionConfig{}), "Terminal"},
		{reflect.TypeOf(tools.Tools{}), "Enabled"},
	} {
		if _, ok := c.typ.FieldByName(c.field); !ok {
			t.Errorf("%s.%s must remain", c.typ, c.field)
		}
	}
}

func TestQueuedLeverCleanup(t *testing.T) {
	for _, gone := range []string{
		"provider/prefixlog_test.go", "loop/read_ledger_test.go", "tools/l_tooldesc_test.go",
		"tools/l_image_test.go", "tools/testdata/defs_compact_golden.json",
		"provider/prefixlog.go", "loop/read_ledger.go",
	} {
		if _, err := os.Stat(filepath.Join("..", gone)); !os.IsNotExist(err) {
			t.Errorf("%s must be deleted (stat error %v)", gone, err)
		}
	}

	words := append([]string{"round.terminal_reminder", "read_ledger", "Call one of these terminal tools"}, removedLevers...)
	// Current documentation neither names nor demonstrates a removed setting.
	for _, doc := range []string{"../README.md", "../docs/contract/loop-v1.md"} {
		b, err := os.ReadFile(doc)
		if err != nil {
			t.Fatal(err)
		}
		for _, w := range words {
			if strings.Contains(string(b), w) {
				t.Errorf("%s still mentions %s", doc, w)
			}
		}
	}
	// The changelog may record the removal, in removal entries only.
	b, err := os.ReadFile("../CHANGELOG.md")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(b), "```") {
		t.Error("CHANGELOG.md carries a code example")
	}
	recorded := false
	for _, line := range strings.Split(string(b), "\n") {
		for _, w := range words {
			if !strings.Contains(line, w) {
				continue
			}
			recorded = true
			if !strings.HasPrefix(line, "- Remove ") {
				t.Errorf("CHANGELOG.md mentions %s outside a removal entry: %q", w, line)
			}
		}
	}
	if !recorded {
		t.Error("CHANGELOG.md does not record the removal")
	}

	// The reminder-specific test cases are gone; no source retains the reminder message.
	for _, p := range []string{"../loop/loop.go", "../loop/session.go", "../loop/terminal_reminders_test.go"} {
		b, err := os.ReadFile(p)
		if err != nil {
			t.Fatal(err)
		}
		if strings.Contains(string(b), "terminal tools to end this round") || strings.Contains(string(b), "TerminalReminder") {
			t.Errorf("%s still carries the reminder", p)
		}
	}
}

func TestQueuedLeverDefaults(t *testing.T) {
	forbidden := func(t *testing.T, v any) {
		t.Helper()
		b, _ := json.Marshal(v)
		for _, w := range []string{"read_ledger", "terminal tools to end this round"} {
			if bytes.Contains(b, []byte(w)) {
				t.Errorf("injected %q in %s", w, b)
			}
		}
	}

	t.Run("no_call_after_a_read_ends_the_round", func(t *testing.T) {
		w := newWorld(t).seed(map[string]string{"a.txt": "alpha\nbeta\n"})
		rd := roundWith(t, w)
		rd.Tools.Enabled = []string{tools.ReadFileTool}
		rq := &scripted{responses: []*provider.Response{
			respond("r1", fakeCall("c1", "read_file", `{"path":"a.txt"}`)),
			respond("r2", message("all done")),
			respond("r3", fakeCall("c3", "finish", `{"summary":"never asked"}`)),
		}}
		res, err := loop.Run(context.Background(), rd, []any{userMessage("go")}, rq, loop.Hooks{})
		if err != nil {
			t.Fatal(err)
		}
		if res.Ending != loop.EndNoCall || res.Terminal != nil || res.Requests != 2 || len(rq.asked) != 2 {
			t.Fatalf("result %+v asked %d", res, len(rq.asked))
		}
		want := []string{"user", "call:c1", "out:c1", "assistant"}
		if got := ids(res.Input); !reflect.DeepEqual(got, want) {
			t.Fatalf("transcript %v", got)
		}
		if out := res.Input[2].(map[string]any)["output"]; out != "1\talpha\n2\tbeta" {
			t.Errorf("tool output %q", out)
		}
		if got := ids(rq.asked[1].Input); !reflect.DeepEqual(got, want[:3]) {
			t.Errorf("second request %v", got)
		}
		for _, a := range rq.asked {
			forbidden(t, a.Input)
		}
		forbidden(t, res.Input)
	})

	t.Run("first_response_no_call_through_a_session", func(t *testing.T) {
		w := newWorld(t).signIn()
		f := newFakeProvider(t, []exchange{
			{ID: "r1", Items: []map[string]any{message("nothing to call")}},
			{ID: "r2", Items: []map[string]any{message("never asked")}},
		})
		var events []api.Event
		s, err := loop.NewSession(sessionConfig(w, f, &events))
		if err != nil {
			t.Fatal(err)
		}
		res, err := s.Round(context.Background(), "open")
		if err != nil || res.Ending != loop.EndNoCall || res.Requests != 1 {
			t.Fatalf("%+v %v", res, err)
		}
		if got := len(f.requests()); got != 1 {
			t.Errorf("provider saw %d requests", got)
		}
		want := []string{"request.started", "request.attempt", "response", "round.ended"}
		if got := eventTypes(events); !reflect.DeepEqual(got, want) {
			t.Errorf("events %v", got)
		}
		forbidden(t, f.requests())
		forbidden(t, res.Input)
	})

	t.Run("full_definitions_and_view_image", func(t *testing.T) {
		names := []string{tools.ShellTool, tools.ViewImageTool, tools.ReadFileTool, tools.WriteFileTool, tools.ListFilesTool, tools.SearchTextTool, tools.DocumentationTool}
		data, err := os.ReadFile("../tools/testdata/defs_golden.json")
		if err != nil {
			t.Fatal(err)
		}
		var golden map[string]any
		if err := json.Unmarshal(data, &golden); err != nil {
			t.Fatal(err)
		}
		instance := &tools.Tools{Root: t.TempDir(), Enabled: names}
		for _, name := range names {
			def, ok := instance.Definition(name)
			if !ok {
				t.Fatalf("instance has no %s definition", name)
			}
			raw, _ := json.Marshal(def)
			var got any
			if err := json.Unmarshal(raw, &got); err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(got, golden[name]) {
				t.Errorf("%s differs from defs_golden.json: %s", name, raw)
			}
		}
	})

	t.Run("view_image_follows_the_enabled_allowlist", func(t *testing.T) {
		root := t.TempDir()
		var buf bytes.Buffer
		img := image.NewRGBA(image.Rect(0, 0, 2, 2))
		for i := 3; i < len(img.Pix); i += 4 {
			img.Pix[i] = 0xff // opaque pixels encode as RGB8
		}
		if err := png.Encode(&buf, img); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(root, "p.png"), buf.Bytes(), 0o600); err != nil {
			t.Fatal(err)
		}
		args := map[string]any{"path": "p.png"}
		enabled, err := (&tools.Tools{Root: root, Enabled: []string{tools.ViewImageTool}}).Run(tools.ViewImageTool, args)
		if err != nil || !enabled.Typed() {
			t.Fatalf("enabled view_image: %+v %v", enabled, err)
		}
		other, err := (&tools.Tools{Root: root, Enabled: []string{tools.ReadFileTool}}).Run(tools.ViewImageTool, args)
		if err != nil || other.Typed() || other.Text != "error: unknown tool view_image" {
			t.Fatalf("view_image outside Enabled: %+v %v", other, err)
		}
	})
}
