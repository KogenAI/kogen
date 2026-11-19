package main

import (
	"context"
	"encoding/json"
	"fmt"
	"github.com/KogenAI/kogen-coordinator/git"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
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
	lock := git.NewLock(path)
	if _, e := lock.Acquire(); e != nil {
		t.Fatal(e)
	}
	defer lock.Release()
	owner := object{"pid": strconv.Itoa(pid), "birth": strings.TrimSpace(string(birth)), "token": lock.Token()}
	if !alive(root, owner) {
		t.Fatal("matching owner was not live")
	}
	other := object{"pid": strconv.Itoa(pid), "birth": owner["birth"], "token": "another-owner"}
	if alive(root, other) {
		t.Fatal("a token that is not the lock's advertised")
	}
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

func captureStdout(t *testing.T, f func()) string {
	t.Helper()
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	stdout := os.Stdout
	os.Stdout = w
	defer func() { os.Stdout = stdout }()
	f()
	w.Close()
	b, _ := io.ReadAll(r)
	return string(b)
}

func TestInspectUnknownRunNamesNextCommand(t *testing.T) {
	c := factProject(t)
	for id, detail := range map[string]string{
		"run-1":    "not a run id: a run id is 8 lowercase hexadecimal characters, for example 0a1b2c3d",
		"0A1B2C3D": "not a run id: a run id is 8 lowercase hexadecimal characters, for example 0a1b2c3d",
		"0a1b2c3d": "no run with this id in this checkout",
	} {
		out := captureStdout(t, func() {
			if handled, code := localRead([]string{"intent", "inspect", "--project", c["root"].(string), id}); !handled || code != 1 {
				t.Fatal(id, handled, code)
			}
		})
		var got struct {
			Error map[string]any `json:"error"`
		}
		if e := json.Unmarshal([]byte(out), &got); e != nil {
			t.Fatal(id, e, out)
		}
		want := map[string]any{"class": "intent", "reason": "run_not_found", "detail": detail, "paths": []any{}, "next": "kogen intent list"}
		if !reflect.DeepEqual(got.Error, want) {
			t.Fatal(id, got.Error)
		}
	}
	out := captureStdout(t, func() { localRead([]string{"intent", "inspect", "--project", c["root"].(string)}) })
	var got struct {
		Error map[string]any `json:"error"`
	}
	if e := json.Unmarshal([]byte(out), &got); e != nil || got.Error["next"] != nil || len(got.Error) != 4 {
		t.Fatal(e, out)
	}
}

func projectAnswerDetail(t *testing.T, args ...string) (string, object) {
	t.Helper()
	var code int
	out := captureStdout(t, func() { _, code = localRead(args) })
	if code != 3 {
		t.Fatalf("exit %d: %s", code, out)
	}
	var got struct {
		Error object `json:"error"`
	}
	if e := json.Unmarshal([]byte(out), &got); e != nil {
		t.Fatal(out, e)
	}
	return fmt.Sprint(got.Error["detail"]), got.Error
}

const notProjectTail = " is not a Kogen project: no Git checkout with .kogen/project.yaml here; run kogen init in the project folder, or pass --project with its path"

func TestProjectAnswersNameTheFolderThatIsNotAGitCheckout(t *testing.T) {
	dir := t.TempDir()
	for _, args := range [][]string{{"intent", "list", "--project", dir}, {"intent", "usage", "--project", dir}} {
		detail, er := projectAnswerDetail(t, args...)
		if detail != dir+notProjectTail || er["reason"] != "not_project" || er["class"] != "environment" || len(er) != 4 {
			t.Fatal(detail, er)
		}
	}
}

func TestProjectAnswersNameAGitCheckoutWithoutProjectConfig(t *testing.T) {
	dir := t.TempDir()
	if b, e := exec.Command("git", "init", "-q", dir).CombinedOutput(); e != nil {
		t.Fatalf("%s: %v", b, e)
	}
	detail, er := projectAnswerDetail(t, "intent", "inspect", "0a1b2c3d", "--project", dir)
	if detail != dir+notProjectTail || er["reason"] != "not_project" {
		t.Fatal(detail, er)
	}
}

func TestProjectAnswersNameAMissingProjectFolder(t *testing.T) {
	gone := filepath.Join(t.TempDir(), "gone")
	want := " is not a readable directory; pass --project with the path of the project folder"
	for _, args := range [][]string{{"intent", "list", "--project", gone}, {"context", "--project", gone}} {
		detail, er := projectAnswerDetail(t, args...)
		if detail != gone+want || er["reason"] != "project_unavailable" {
			t.Fatal(detail, er)
		}
	}
	abs, _ := filepath.Abs("gone-relative")
	if detail, _ := projectAnswerDetail(t, "intent", "list", "--project", "gone-relative"); detail != abs+want {
		t.Fatal(detail)
	}
}

func TestProjectAnswersDocumentIsCurrent(t *testing.T) {
	b, e := os.ReadFile("../docs/troubleshooting.md")
	if e != nil {
		t.Fatal(e)
	}
	doc := string(b)
	for _, want := range []string{"intent/not_found: Intent does not exist: is-even (looked in .kogen/intents/is-even)", "kogen intent list shows existing Intents;"} {
		if !strings.Contains(doc, want) {
			t.Fatal("missing", want)
		}
	}
	for _, bad := range []string{"names no next command", "prints raw"} {
		if strings.Contains(doc, bad) {
			t.Fatal("stale", bad)
		}
	}
}

// refusedDetail runs a read command that must be refused with exit 2 and returns error.detail.
func refusedDetail(t *testing.T, args ...string) string {
	t.Helper()
	var code int
	out := captureStdout(t, func() { _, code = localRead(args) })
	var got struct {
		Error object `json:"error"`
	}
	if e := json.Unmarshal([]byte(out), &got); e != nil || code != 2 {
		t.Fatalf("%v: exit %d: %s", args, code, out)
	}
	if got.Error["class"] != "intent" || got.Error["reason"] != "invalid_argument" || len(got.Error) != 4 {
		t.Fatalf("%v: %v", args, got.Error)
	}
	d, _ := got.Error["detail"].(string)
	return d
}

func checkRefusedDetails(t *testing.T, cases [][]string) {
	t.Helper()
	for _, c := range cases {
		if got := refusedDetail(t, c[1:]...); got != c[0] {
			t.Errorf("%v: detail %q, want %q", c[1:], got, c[0])
		}
	}
}

func TestReadCommandsNameOptionsAndPositionals(t *testing.T) {
	checkRefusedDetails(t, [][]string{
		{"kogen intent inspect: unknown option '--bogus'", "intent", "inspect", "--bogus=1", "0a1b2c3d"},
		{"kogen intent inspect: unknown option '--limit'", "intent", "inspect", "--limit", "5", "0a1b2c3d"},
		{"kogen intent preflight: unknown option '--json'", "intent", "preflight", "--json=1", "abc"},
		{"kogen intent list: unknown option '--bogus'", "intent", "list", "--bogus"},
		{"kogen intent list: --project needs a value", "intent", "list", "--project"},
		{"kogen intent list: --cursor needs a value", "intent", "list", "--cursor"},
		{"kogen context: unknown option '--cursor'", "context", "--cursor=x"},
		{"kogen context: unexpected argument 'extra'", "context", "extra"},
		{"kogen intent list: unexpected argument 'extra'", "intent", "list", "extra"},
		{"kogen intent list: unexpected argument 'extra'", "intent", "list", "--", "extra"},
		{"kogen intent list: unknown option '--bogus'", "intent", "list", "extra", "--bogus"},
	})
}

func TestInspectAndPreflightNameMissingAndInvalid(t *testing.T) {
	root := factProject(t)["root"].(string)
	checkRefusedDetails(t, [][]string{
		{"kogen intent inspect: unexpected argument '1a1b2c3d'", "intent", "inspect", "--project", root, "0a1b2c3d", "1a1b2c3d"},
		{"kogen intent inspect: missing the run id", "intent", "inspect", "--project", root},
		{"kogen intent preflight: missing the slug", "intent", "preflight", "--project", root},
		{"kogen intent preflight: the slug must be 3 to 48 characters and use lowercase letters, digits and dashes", "intent", "preflight", "--project", root, "Is_Even"},
		{"kogen intent preflight: unexpected argument 'two'", "intent", "preflight", "--project", root, "one", "two"},
	})
}

func TestListAndUsageNameLimitAndCursor(t *testing.T) {
	root := factProject(t)["root"].(string)
	checkRefusedDetails(t, [][]string{
		{"kogen intent list: --limit must be a whole number from 1 to 100", "intent", "list", "--limit", "0"},
		{"kogen intent list: --limit must be a whole number from 1 to 100", "intent", "list", "--limit=x"},
		{"kogen intent usage: --limit must be a whole number from 1 to 100", "intent", "usage", "--limit", "101"},
		{"kogen intent list: --cursor is not a cursor of the current list", "intent", "list", "--project", root, "--cursor=x"},
	})
}

func TestUsageNamesTheRefusedFilter(t *testing.T) {
	checkRefusedDetails(t, [][]string{
		{"kogen intent usage: --lineage needs a run id", "intent", "usage", "--lineage"},
		{"kogen intent usage: --group-by field 'bogus' is unknown (fields: project, slug, lineage, phase, role, model, effective-model, effort, effective-effort, outcome, pass, repair)", "intent", "usage", "--group-by", "phase,bogus"},
		{"kogen intent usage: --since must be a UTC time such as 2026-11-16T00:00:00Z", "intent", "usage", "--since", "2026-11-16"},
		{"kogen intent usage: --until must be a UTC time such as 2026-11-16T00:00:00Z", "intent", "usage", "--until=2026-11-16T00:00:00+01:00"},
		{"kogen intent usage: unknown option '--bogus'", "intent", "usage", "extra", "--bogus"},
		{"kogen intent usage: unexpected argument 'extra'", "intent", "usage", "extra"},
		{"kogen intent usage: --slug needs a value", "intent", "usage", "--slug"},
		{"kogen intent usage: unknown option '--lineage'", "intent", "usage", "--lineage=1"},
	})
}
