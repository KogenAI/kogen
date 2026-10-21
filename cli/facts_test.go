package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

func factProject(t *testing.T) object {
	t.Helper()
	root := t.TempDir()
	if b, e := exec.Command("git", "init", "-q", root).CombinedOutput(); e != nil {
		t.Fatalf("%s: %v", b, e)
	}
	if e := os.MkdirAll(filepath.Join(root, ".kogen/local"), 0700); e != nil {
		t.Fatal(e)
	}
	if e := os.WriteFile(filepath.Join(root, ".kogen/project.yaml"), []byte("fixture"), 0600); e != nil {
		t.Fatal(e)
	}
	c, reason := discover(root)
	if reason != "" {
		t.Fatal(reason)
	}
	return c
}
func putFact(t *testing.T, c object, m object) {
	t.Helper()
	b, e := json.Marshal(m)
	if e != nil {
		t.Fatal(e)
	}
	if e = os.WriteFile(filepath.Join(c["root"].(string), ".kogen/local/context.json"), b, 0600); e != nil {
		t.Fatal(e)
	}
}
func TestContextValidation(t *testing.T) {
	c := factProject(t)
	if got := contextData(c); got["integration_state"] != "missing" || got["last_built"] != nil {
		t.Fatal(got)
	}
	last := object{"slug": "fixture", "run_id": "1234abcd"}
	active := object{"slug": "fixture", "run_id": "1234abcd", "phase": "building", "verification_pass": nil}
	m := object{"schema_version": 1, "checkout": c, "active": active, "last_built": last, "owner": object{"pid": "99999999", "birth": "not alive", "token": "old"}}
	putFact(t, c, m)
	if got := contextData(c); got["integration_state"] != "ok" || got["active"] != nil || got["last_built"] == nil {
		t.Fatal(got)
	}
	for _, mutate := range []func(){
		func() { m["schema_version"] = 2 },
		func() { m["checkout"] = object{"id": "foreign"} },
		func() { active["run_id"] = "ffffffff" },
		func() { active["phase"] = "verifying"; active["verification_pass"] = 0 },
	} {
		m["schema_version"] = 1
		m["checkout"] = c
		active["run_id"] = "1234abcd"
		active["phase"] = "building"
		active["verification_pass"] = nil
		mutate()
		putFact(t, c, m)
		if got := contextData(c); got["integration_state"] != "invalid" || got["active"] != nil || got["last_built"] != nil {
			t.Fatal(got)
		}
	}
}
func TestContextNeverOpensHistory(t *testing.T) {
	c := factProject(t)
	root := c["root"].(string)
	// A file in place of the history directory denies traversal, independently of providers.
	if e := os.WriteFile(filepath.Join(root, ".kogen/local/runs"), []byte("inaccessible history"), 0000); e != nil {
		t.Fatal(e)
	}
	if got := contextData(c); got["integration_state"] != "missing" {
		t.Fatal(got)
	}
}
func TestOwnerRequiresMatchingLockAndBirth(t *testing.T) {
	c := factProject(t)
	root := c["root"].(string)
	pid := os.Getpid()
	birth, e := exec.Command("ps", "-p", strconv.Itoa(pid), "-o", "lstart=").Output()
	if e != nil {
		t.Fatal(e)
	}
	path := filepath.Join(root, ".kogen/local/build.lock")
	os.Mkdir(path, 0700)
	owner := object{"pid": strconv.Itoa(pid), "birth": strings.TrimSpace(string(birth)), "token": "original"}
	os.WriteFile(filepath.Join(path, "original"), []byte(strconv.Itoa(pid)), 0600)
	if !alive(root, owner) {
		t.Fatal("matching owner was not live")
	}
	os.WriteFile(filepath.Join(path, "another-owner"), []byte(strconv.Itoa(pid)), 0600)
	if alive(root, owner) {
		t.Fatal("ambiguous lock owners advertised")
	}
	os.Remove(filepath.Join(path, "another-owner"))
	owner["birth"] = "previous process"
	if alive(root, owner) {
		t.Fatal("PID reuse advertised")
	}
	owner["birth"] = strings.TrimSpace(string(birth))
	owner["token"] = "replacement"
	if alive(root, owner) {
		t.Fatal("lock mismatch advertised")
	}
}

func TestOrderingAndOpaquePagination(t *testing.T) {
	rows := []object{
		{"type": "build", "slug": "bbb", "run_id": "ffffffff", "started_at": "2026-01-02"},
		{"type": "build", "slug": "aaa", "run_id": "bbbbbbbb", "started_at": "2026-01-02"},
		{"type": "intent", "slug": "aaa"},
		{"type": "build", "slug": "aaa", "run_id": "aaaaaaaa", "started_at": "2026-01-02"},
		{"type": "build", "slug": "aaa", "run_id": "cccccccc", "started_at": "2026-01-01"},
	}
	var visited []object
	cursor := ""
	for {
		items, next, e := pageRows(rows, 1, cursor)
		if e != nil {
			t.Fatal(e)
		}
		visited = append(visited, items...)
		if next == nil {
			break
		}
		cursor = next.(string)
	}
	want := []string{"<nil>", "aaaaaaaa", "bbbbbbbb", "cccccccc", "ffffffff"}
	for i, r := range visited {
		if fmt.Sprint(r["run_id"]) != want[i] {
			t.Fatal(visited)
		}
	}
	for _, limit := range []int{0, 101} {
		if _, _, e := pageRows(rows, limit, ""); e == nil {
			t.Fatal("invalid limit accepted")
		}
	}
	for _, limit := range []int{1, 100} {
		if _, _, e := pageRows(rows, limit, ""); e != nil {
			t.Fatal(e)
		}
	}
	if _, _, e := pageRows(rows, 20, "not-a-cursor"); e == nil {
		t.Fatal("invalid cursor accepted")
	}
	_, next, _ := pageRows(rows, 1, "")
	rows[0]["slug"] = "changed"
	if _, _, e := pageRows(rows, 1, next.(string)); e == nil {
		t.Fatal("stale cursor accepted")
	}
}

func TestRunCompletionDoesNotOpenPackages(t *testing.T) {
	c := factProject(t)
	root := c["root"].(string)
	// A retained package baseline FIFO would hang a reader that needlessly hashes packages.
	os.MkdirAll(filepath.Join(root, ".kogen/intents/fixture"), 0700)
	os.MkdirAll(filepath.Join(root, ".kogen/local/packages"), 0700)
	os.WriteFile(filepath.Join(root, ".kogen/intents/fixture/intent.md"), []byte("fixture"), 0600)
	summary, _ := json.Marshal(object{"checkout_id": c["id"], "paths": []string{"blocked-body"}})
	os.WriteFile(filepath.Join(root, ".kogen/local/packages/fixture.json"), summary, 0600)
	if e := syscall.Mkfifo(filepath.Join(root, "blocked-body"), 0600); e != nil {
		t.Fatal(e)
	}
	b, _ := json.Marshal(map[string][]object{"resume": {{"slug": "fixture", "run_id": "1234abcd", "checkout_id": c["id"], "state": "interrupted", "phase": "building", "resume_status": "requires_validation"}}})
	os.WriteFile(filepath.Join(root, ".kogen/local/completion.json"), b, 0600)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestLocalReadProcess$")
	cmd.Env = append(os.Environ(), "KOGEN_LOCAL_ARGS="+`["__complete","resume","--project",`+strconv.Quote(root)+`]`)
	out, e := cmd.CombinedOutput()
	if e != nil || string(out) != "1234abcd\tfixture interrupted\n" {
		t.Fatalf("%s: %v", out, e)
	}
}

func TestLocalReadProcess(t *testing.T) {
	if raw := os.Getenv("KOGEN_LOCAL_ARGS"); raw != "" {
		var args []string
		json.Unmarshal([]byte(raw), &args)
		_, code := localRead(args)
		os.Exit(code)
	}
}

func TestMalformedCatalogAndMissingSnapshotFields(t *testing.T) {
	c := factProject(t)
	root := c["root"].(string)
	for _, value := range []string{`null`, `{"x":{"slug":"fixture","run_id":"1234abcd","phase":[],"state":"active"}}`} {
		os.WriteFile(filepath.Join(root, ".kogen/local/catalog.json"), []byte(value), 0600)
		if _, e := catalog(c); e == nil {
			t.Fatalf("accepted %s", value)
		}
	}
	putFact(t, c, object{"schema_version": 1, "checkout": c, "last_built": object{"slug": "fixture", "run_id": "1234abcd"}})
	if got := contextData(c); got["integration_state"] != "invalid" {
		t.Fatal(got)
	}
}
