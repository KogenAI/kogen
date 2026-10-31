package build

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"kogen/executor"
	"kogen/executor/conformance"
	"kogen/project"
)

// The native builder stops on no tool-call repeats of a red verification pass (noprogress.go),
// never on repeated tool calls: four identical continuing reads followed by finish complete.
func TestNativeBuilderRepeatedCallsContinue(t *testing.T) {
	t.Parallel()
	raw, _ := json.Marshal(project.Role{Model: "gpt-6.1-sol", Effort: "medium"})
	if string(raw) != `{"Provider":"","Model":"gpt-6.1-sol","Effort":"medium"}` {
		t.Fatalf("default role JSON %s", raw)
	}
	root := conformance.NewCheckout(t)
	home := physical(t, t.TempDir())
	seedLogin(t, home)
	prov := newFakeProvider(t)
	for i := 0; i < 4; i++ {
		prov.then(respondWith([]map[string]any{prov.call("read_file", map[string]any{"path": "a"})}, nil))
	}
	prov.then(respondWith([]map[string]any{prov.call("finish", map[string]any{"summary": "done"})}, nil))
	b := newConformanceAttempt(t, root, home, prov, true)
	session, _ := nativeExecutor{b: b}.Start(context.Background(), executor.Task{Brief: executor.Brief{Stable: "s", Dynamic: "d"}}, nil)
	if _, err := session.(*nativeSession).Round(context.Background(), executor.Input{}); err != nil || prov.count() != 5 {
		t.Fatalf("%v %d", err, prov.count())
	}
	data, err := os.ReadFile(filepath.Join(b.Run.Dir, "checkpoint.json"))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(strings.ToLower(string(data)), "noprogress") {
		t.Fatalf("checkpoint retains a fingerprint option: %s", data)
	}
	log, err := os.ReadFile(b.Run.LogPath)
	if err != nil || strings.Contains(string(log), "native_no") {
		t.Fatalf("log %s %v", log, err)
	}
}
