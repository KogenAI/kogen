package main

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func usageFixture(id string, input, cached any) object {
	return normalizeUsage(object{"event": "provider_attempt", "provider": object{"provider_response_id": id, "operation_id": "op" + id, "attempt_id": "attempt" + id, "timestamp": "2026-10-21T10:00:00Z", "outcome": "completed", "phase": "build", "usage": object{"input": input, "cached": cached, "output": float64(10), "reasoning": float64(2)}}}, object{})
}
func TestUsageWeightedCountOnceAndConflicts(t *testing.T) {
	a := usageFixture("a", float64(100), float64(0))
	b := usageFixture("b", float64(900), float64(600))
	rows, duplicates := deduplicateUsage([]object{a, b, usageFixture("b", float64(900), float64(600))})
	totals := aggregateUsage(rows)
	if duplicates != 1 || totals["known_input"] != int64(1000) || totals["cached_input_percent"] != float64(60) || totals["zero_hit_requests"] != 1 {
		t.Fatal(totals, duplicates)
	}
	rows, duplicates = deduplicateUsage([]object{usageFixture("a", float64(100), float64(20)), usageFixture("a", float64(101), float64(20))})
	totals = aggregateUsage(rows)
	if duplicates != 1 || totals["inconsistent"] != 1 || totals["known_input"] != int64(0) || len(rows[0]["provenance"].([]object)) != 2 {
		t.Fatal(totals, rows)
	}
}
func TestUsageValidationBoundariesAndUnknowns(t *testing.T) {
	for _, test := range []struct {
		u   object
		bad bool
	}{
		{object{"input": 10, "cached": 10, "write": 0, "write_30m": 0, "write_12h": 0, "output": 2, "reasoning": 2}, false},
		{object{"input": 10, "cached": 9, "write": 1, "write_30m": 1, "write_12h": 0}, false},
		{object{"input": 10, "cached": 10, "write": 1}, true},
		{object{"input": 10, "cached": 11}, true},
		{object{"output": 2, "reasoning": 3}, true},
		{object{"write": 10, "write_30m": 5, "write_12h": 4}, true},
		{object{"write": 10, "write_30m": 5, "write_12h": 5}, false},
		{object{"write": 10, "write_30m": 5, "write_12h": 6}, true},
	} {
		if invalidUsage(test.u) != test.bad {
			t.Fatal(test)
		}
	}
	for _, v := range []any{float64(-1), float64(1.5), "2", float64(1 << 63)} {
		if _, ok := tokenNumber(v); ok {
			t.Fatal(v)
		}
	}
	rows := []object{usageFixture("bad", float64(10), float64(11)), usageFixture("zero", float64(0), float64(0))}
	totals := aggregateUsage(rows)
	if totals["cached_input_percent"] != nil || totals["inconsistent"] != 1 || totals["unknown_fields"].(object)["write"] != 2 {
		t.Fatal(totals)
	}
	legacy := normalizeUsage(object{"event": "request", "usage": object{"input": float64(10), "cached": float64(0)}}, object{})
	rows, duplicates := deduplicateUsage([]object{legacy, legacy})
	if len(rows) != 2 || duplicates != 0 {
		t.Fatal(rows)
	}
	if aggregateUsage(rows)["legacy_without_ids"] != 2 {
		t.Fatal(rows)
	}
}
func TestUsageScanDamageSymlinksAndCaps(t *testing.T) {
	root := t.TempDir()
	dir := filepath.Join(root, ".kogen/local/runs/11111111")
	if e := os.MkdirAll(dir, 0700); e != nil {
		t.Fatal(e)
	}
	os.WriteFile(filepath.Join(dir, "result.json"), []byte(`{"slug":"fixture"}`), 0600)
	row := object{"event": "request", "usage": object{"input": 100, "cached": 20, "output": 10, "reasoning": 2}, "at": "2026-10-21T00:00:00Z", "role": "build"}
	b, _ := json.Marshal(row)
	os.WriteFile(filepath.Join(dir, "log.jsonl"), append(append([]byte("broken\n"), b...), []byte("\n{\"event\":")...), 0600)
	os.Mkdir(filepath.Join(dir, "checkpoint.json"), 0700)
	os.Symlink(dir, filepath.Join(root, ".kogen/local/runs/22222222"))
	s := usageScan{root: root, limitations: map[string]bool{}, metadata: map[string]object{}, selected: map[string]bool{}}
	rows := s.scan("", false)
	if len(rows) != 1 || !s.limitations["malformed_record"] || !s.limitations["truncated_record"] {
		t.Fatal(rows, s.limitations)
	}
	for _, cap := range []struct {
		bytes  int64
		count  int
		reason string
	}{{256 << 20, 0, "byte_cap"}, {0, 100000, "row_cap"}} {
		s.bytes = cap.bytes
		s.count = cap.count
		s.truncated = false
		s.readRows(filepath.Join(dir, "log.jsonl"), object{}, &rows)
		if !s.truncated || !s.limitations[cap.reason] {
			t.Fatal(s)
		}
	}
}

func TestUsageExactFiltersDatesAndUnknowns(t *testing.T) {
	r := usageFixture("a", float64(100), float64(20))
	for _, k := range usageKeys {
		field := k
		if f, ok := usageFields[k]; ok {
			field = f
		}
		r[field] = "exact"
	}
	r["timestamp"] = "2026-10-21T00:00:00Z"
	for _, k := range usageKeys {
		if !matchesUsage(r, object{k: "exact"}) || matchesUsage(r, object{k: "Exact"}) {
			t.Fatal(k)
		}
	}
	if !matchesUsage(r, object{"since": "2026-10-21T00:00:00Z", "until": "2026-10-21T00:00:01Z"}) {
		t.Fatal(r)
	}
	if matchesUsage(r, object{"until": "2026-10-21T00:00:00Z"}) || matchesUsage(r, object{"since": "2026-10-21T00:00:01Z"}) {
		t.Fatal(r)
	}
	r["timestamp"] = nil
	r["effective_model"] = nil
	if matchesUsage(r, object{"since": "2026-10-21T00:00:00Z"}) || matchesUsage(r, object{"effective-model": "exact"}) {
		t.Fatal(r)
	}
}

func TestUsageLineSizeBoundaryAndNeighbors(t *testing.T) {
	for _, size := range []int{(4 << 20) - 1, 4 << 20, (4 << 20) + 1} {
		root := t.TempDir()
		file := filepath.Join(root, "events.ndjson")
		prefix := `{"event":"unrelated","text":"`
		suffix := "\"}\n"
		line := prefix + strings.Repeat("x", size-len(prefix)-len(suffix)) + suffix
		next := `{"event":"request","usage":{"input":1,"cached":0,"output":1,"reasoning":0}}` + "\n"
		if e := os.WriteFile(file, []byte(line+next), 0600); e != nil {
			t.Fatal(e)
		}
		s := usageScan{root: root, limitations: map[string]bool{}}
		rows := []object{}
		s.readRows(file, object{}, &rows)
		if len(rows) != 1 || s.limitations["oversized_line"] != (size > 4<<20) || s.truncated != (size > 4<<20) {
			t.Fatal(size, len(rows), s.limitations)
		}
	}
}

func TestUsageNativeBoundaryArgumentsAndGroups(t *testing.T) {
	c := factProject(t)
	root := c["root"].(string)
	dir := filepath.Join(root, ".kogen/local/runs/11111111")
	os.MkdirAll(dir, 0700)
	os.WriteFile(filepath.Join(dir, "result.json"), []byte(`{"slug":"fixture"}`), 0600)
	os.WriteFile(filepath.Join(dir, "log.jsonl"), []byte(`{"event":"request","role":"review","model":"configured","effort":"high","at":"2026-10-21T00:00:00Z","usage":{"input":100,"cached":20,"output":10,"reasoning":2}}`+"\n"), 0600)
	for _, test := range []struct {
		args []string
		code int
	}{
		{[]string{"--json", "--phase", "review", "--effort", "high", "--group-by", "phase,effort", "--limit", "1"}, 0},
		{[]string{"--limit", "0"}, 2}, {[]string{"--limit", "101"}, 2}, {[]string{"--lineage"}, 2},
		{[]string{"--since", "2026-10-21"}, 2}, {[]string{"--group-by", "invalid"}, 2},
		{[]string{"22222222", "--json"}, 1},
	} {
		args := append([]string{"intent", "usage", "--project", root}, test.args...)
		raw, _ := json.Marshal(args)
		cmd := exec.Command(os.Args[0], "-test.run=^TestLocalReadProcess$")
		cmd.Env = append(os.Environ(), "KOGEN_LOCAL_ARGS="+string(raw))
		out, e := cmd.CombinedOutput()
		code := 0
		if e != nil {
			if x, ok := e.(*exec.ExitError); ok {
				code = x.ExitCode()
			} else {
				t.Fatal(e)
			}
		}
		if code != test.code {
			t.Fatalf("%v: %d %s", args, code, out)
		}
		var report object
		if json.Unmarshal(out, &report) != nil {
			t.Fatal(string(out))
		}
		if report["kind"] != "usage" {
			t.Fatal(report)
		}
		if code == 0 {
			data := report["data"].(map[string]any)
			groups := data["groups"].([]any)
			if len(groups) != 1 || groups[0].(map[string]any)["key"].(map[string]any)["effort"] != "high" {
				t.Fatal(data)
			}
		}
	}
}

func TestUsageDuplicateInconsistencyCannotBeLost(t *testing.T) {
	a := usageFixture("same", 100, 20)
	b := usageFixture("same", 100, 20)
	b["usage_state"] = "inconsistent"
	rows, _ := deduplicateUsage([]object{a, b})
	totals := aggregateUsage(rows)
	if totals["inconsistent"] != 1 || totals["known_input"] != int64(0) {
		t.Fatal(totals)
	}
}

func TestUsageRefinementSlugUsesRetainedIdentity(t *testing.T) {
	root := t.TempDir()
	dir := filepath.Join(root, ".kogen/local/refinements/0123456789abcdef")
	os.MkdirAll(dir, 0700)
	os.WriteFile(filepath.Join(dir, "result.json"), []byte(`{"slug":"actual-intent"}`), 0600)
	os.WriteFile(filepath.Join(dir, "events.ndjson"), []byte(`{"event":"provider_call","role":"shape","status":"completed","usage":{"input":1}}`+"\n"), 0600)
	s := usageScan{root: root, limitations: map[string]bool{}, metadata: map[string]object{}, selected: map[string]bool{}}
	rows := s.scan("", false)
	if len(rows) != 1 || !matchesUsage(rows[0], object{"slug": "actual-intent"}) {
		t.Fatal(rows)
	}
}

func TestUsageOversizedMetadataIsDisclosedAsCapped(t *testing.T) {
	root := t.TempDir()
	file := filepath.Join(root, "result.json")
	os.WriteFile(file, []byte(`{"slug":"fixture","summary":"`+strings.Repeat("x", 4<<20)+`"}`), 0600)
	s := usageScan{root: root, limitations: map[string]bool{}}
	s.readMeta(file)
	if !s.truncated || !s.limitations["oversized_record"] {
		t.Fatal(s)
	}
}
