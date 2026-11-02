package conformance

import (
	"context"
	"os/exec"
	"reflect"
	"strings"
	"testing"

	"kogen-loop/api"
	"kogen-loop/loop"
	"kogen-loop/tools"
)

func userTexts(t *testing.T, body map[string]any) []string {
	t.Helper()
	var out []string
	for _, it := range body["input"].([]any) {
		if m, ok := it.(map[string]any); ok && m["role"] == "user" {
			out = append(out, m["content"].(string))
		}
	}
	return out
}

// A small repository's first round opens with the task and the snapshot; a later round adds
// only its feedback.
func TestSessionOpensASmallRepositoryWithTheSnapshot(t *testing.T) {
	t.Parallel()
	w := newWorld(t).signIn().seed(map[string]string{"a.txt": "a\n", "dir/b.txt": "b\n"})
	for _, args := range [][]string{{"init", "-q"}, {"add", "-A"}} {
		cmd := exec.Command("git", args...)
		cmd.Dir = w.root
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
	}
	f := newFakeProvider(t, []exchange{
		{Items: []map[string]any{message("one")}},
		{Items: []map[string]any{message("two")}},
	})
	var events []api.Event
	s, err := loop.NewSession(sessionConfig(w, f, &events))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.Round(context.Background(), "task"); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Round(context.Background(), "feedback"); err != nil {
		t.Fatal(err)
	}
	snapshot := userTexts(t, f.requests()[0])
	if len(snapshot) != 2 || snapshot[0] != "task" || !strings.HasPrefix(snapshot[1], tools.SnapshotHeader+"\n\nlist_files:\na.txt\ndir/b.txt\n\nread_file \"a.txt\":\n1\ta") {
		t.Fatalf("opening %q", snapshot)
	}
	if got := userTexts(t, f.requests()[1]); !reflect.DeepEqual(got, []string{"task", snapshot[1], "feedback"}) {
		t.Errorf("second round %q", got)
	}
}

// A root that is not a Git repository opens with the task alone.
func TestSessionOpensANonRepositoryWithTheTaskAlone(t *testing.T) {
	t.Parallel()
	w := newWorld(t).signIn().seed(map[string]string{"a.txt": "a\n"})
	f := newFakeProvider(t, []exchange{{Items: []map[string]any{message("one")}}})
	var events []api.Event
	s, err := loop.NewSession(sessionConfig(w, f, &events))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.Round(context.Background(), "task"); err != nil {
		t.Fatal(err)
	}
	if got := userTexts(t, f.requests()[0]); !reflect.DeepEqual(got, []string{"task"}) {
		t.Errorf("opening %q", got)
	}
}
