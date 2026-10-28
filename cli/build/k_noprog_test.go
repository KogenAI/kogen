package build

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"kogen-loop/loop"
	"kogen-loop/tools"
	"kogen/executor"
	"kogen/executor/conformance"
	"kogen/project"
)

func TestKNoProgFingerprint(t *testing.T) {
	a := []tools.Call{{Name: "read_file", Arguments: `{"path":"a"}`}, {Name: "shell", Arguments: `{"command":"true"}`}}
	argHash := func(s string) string { h := sha256.Sum256([]byte(s)); return hex.EncodeToString(h[:]) }
	framed, _ := json.Marshal([][2]string{{a[0].Name, argHash(a[0].Arguments)}, {a[1].Name, argHash(a[1].Arguments)}})
	expected := sha256.Sum256(framed)
	got := nativeFingerprint(a)
	if got != hex.EncodeToString(expected[:]) || len(got) != 64 {
		t.Fatal(got)
	}
	variants := [][]tools.Call{
		{{Name: "read_file", Arguments: `{ "path":"a"}`}, a[1]},
		{{Name: "other", Arguments: a[0].Arguments}, a[1]},
		{a[1], a[0]},
	}
	for _, v := range variants {
		if nativeFingerprint(v) == got {
			t.Fatal("collision", v)
		}
	}
	a[0].Item = map[string]any{"id": "different", "result": "different"}
	if nativeFingerprint(a) != got {
		t.Fatal("item affected fingerprint")
	}
}

func noProgSession(t *testing.T, enabled bool, args ...string) (*nativeSession, *fakeProvider) {
	t.Helper()
	root := conformance.NewCheckout(t)
	home := physical(t, t.TempDir())
	seedLogin(t, home)
	prov := newFakeProvider(t)
	for _, arg := range args {
		prov.then(respondWith([]map[string]any{prov.call("read_file", map[string]any{"path": arg})}, nil))
	}
	prov.then(respondWith([]map[string]any{prov.call("finish", map[string]any{"summary": "done"})}, nil))
	b := newConformanceAttempt(t, root, home, prov, true)
	r := b.Config.Models["build"]
	r.NoProgress = enabled
	b.Config.Models["build"] = r
	session, _ := nativeExecutor{b: b}.Start(context.Background(), executor.Task{Brief: executor.Brief{Stable: "s", Dynamic: "d"}}, nil)
	return session.(*nativeSession), prov
}
func TestKNoProgBuilderRepeated(t *testing.T) {
	s, p := noProgSession(t, true, "a", "a", "a")
	_, err := s.Round(context.Background(), executor.Input{})
	var np *loop.NoProgressError
	if !errors.As(err, &np) || p.count() != 3 || len(np.Rounds) != 3 || np.Rounds[0] != 1 || np.Rounds[2] != 3 {
		t.Fatalf("%v requests %d", err, p.count())
	}

	b := s.b
	if err := b.repo.SaveIndex(filepath.Join(b.Run.Dir, "index-at-start")); err != nil {
		t.Fatal(err)
	}
	before := b.repo.Head()
	exit, finalErr := conclude(b.s, &b, err)
	if finalErr != nil || exit != 1 || b.repo.Head() != before {
		t.Fatalf("finalization exit=%d error=%v", exit, finalErr)
	}
	raw, readErr := os.ReadFile(filepath.Join(b.Run.Dir, "result.json"))
	if readErr != nil {
		t.Fatal(readErr)
	}
	var result map[string]any
	if json.Unmarshal(raw, &result) != nil {
		t.Fatal(string(raw))
	}
	details, ok := result["native_no_progress"].(map[string]any)
	if !ok || result["outcome"] != "native_no_progress" || details["fingerprint"] != np.Fingerprint || details["count"] != float64(3) || !reflect.DeepEqual(details["rounds"], []any{float64(1), float64(2), float64(3)}) {
		t.Fatalf("result %s", raw)
	}
	raw, readErr = os.ReadFile(b.Run.LogPath)
	if readErr != nil || !strings.Contains(string(raw), `"event":"native_no_progress"`) || !strings.Contains(string(raw), `"fingerprint":"`+np.Fingerprint+`"`) || !strings.Contains(string(raw), `"count":3`) || !strings.Contains(string(raw), `"rounds":[1,2,3]`) || strings.Contains(string(raw), `"provider_failure"`) {
		t.Fatalf("log %s %v", raw, readErr)
	}
	s, p = noProgSession(t, true, "a", "a")
	if _, err = s.Round(context.Background(), executor.Input{}); err != nil || p.count() != 3 {
		t.Fatalf("terminal counted: %v %d", err, p.count())
	}
}
func TestKNoProgBuilderChanging(t *testing.T) {
	s, p := noProgSession(t, true, "a", "a", "b", "c", "d")
	if _, err := s.Round(context.Background(), executor.Input{}); err != nil || p.count() != 6 {
		t.Fatalf("%v %d", err, p.count())
	}
	// A new loop.Run after verification starts a fresh streak, even in the same session.
	s, p = noProgSession(t, true, "a", "a")
	if _, err := s.Round(context.Background(), executor.Input{}); err != nil {
		t.Fatal(err)
	}
	p.then(p.calls("read_file", map[string]any{"path": "a"}), p.calls("read_file", map[string]any{"path": "a"}), p.calls("finish", map[string]any{"summary": "done"}))
	if _, err := s.Round(context.Background(), executor.Input{Feedback: "retry"}); err != nil || p.count() != 6 {
		t.Fatalf("streak leaked: %v %d", err, p.count())
	}
	s, p = noProgSession(t, true, "a", "a", "b", "b", "b")
	_, err := s.Round(context.Background(), executor.Input{})
	var np *loop.NoProgressError
	if !errors.As(err, &np) || p.count() != 5 || np.Rounds[0] != 3 {
		t.Fatalf("%v %d", err, p.count())
	}
}
func TestKNoProgDefault(t *testing.T) {
	raw, _ := json.Marshal(project.Role{})
	if strings.Contains(string(raw), "NoProgress") {
		t.Fatal(string(raw))
	}
	raw, _ = json.Marshal(project.Role{NoProgress: true})
	if !strings.Contains(string(raw), `"NoProgress":true`) {
		t.Fatal(string(raw))
	}
	s, p := noProgSession(t, false, "a", "a", "a", "a")
	if _, err := s.Round(context.Background(), executor.Input{}); err != nil || p.count() != 5 {
		t.Fatalf("%v %d", err, p.count())
	}
	data, err := os.ReadFile(filepath.Join(s.b.Run.Dir, "checkpoint.json"))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(data), "NoProgress") {
		t.Fatal("false option retained")
	}
	enabled, _ := noProgSession(t, true, "a", "a")
	if _, err := enabled.Round(context.Background(), executor.Input{}); err != nil {
		t.Fatal(err)
	}
	data, err = os.ReadFile(filepath.Join(enabled.b.Run.Dir, "checkpoint.json"))
	if err != nil || !strings.Contains(string(data), `"NoProgress":true`) {
		t.Fatalf("enabled custody: %s %v", data, err)
	}
}

func TestKNoProgIndependentReview(t *testing.T) {
	for _, enabled := range []bool{false, true} {
		t.Run(fmt.Sprint(enabled), func(t *testing.T) {
			root := conformance.NewCheckout(t)
			home := physical(t, t.TempDir())
			seedLogin(t, home)
			p := newFakeProvider(t)
			for i := 0; i < 4; i++ {
				p.then(p.calls("read_file", map[string]any{"path": "protected"}))
			}
			p.then(submit(p, "approve"))
			b := newConformanceAttempt(t, root, home, p, true)
			role := b.Config.Models["review"]
			role.NoProgress = enabled
			buildRole := b.Config.Models["build"]
			buildRole.NoProgress = true
			b.Config.Models["build"] = buildRole
			nt := b.reviewNativeTools()
			r := &reviewRun{b: b, tools: reviewTools(nt), nativeTools: nt, sess: reviewSession{Role: role, Input: []any{map[string]any{"role": "user", "content": "review"}}, Usage: zeroTokens()}}
			verdict, err := r.converse(context.Background())
			if err != nil || verdict.Verdict != "approve" || p.count() != 5 {
				t.Fatalf("verdict=%+v err=%v requests=%d", verdict, err, p.count())
			}
			data, err := os.ReadFile(b.Run.LogPath)
			if err != nil || strings.Contains(string(data), "native_no_progress") {
				t.Fatalf("log %s err %v", data, err)
			}
		})
	}
}
