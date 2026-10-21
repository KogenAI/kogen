package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func coverageSummary(n any, parent, root string) object {
	m := object{"summary_available": true, "unknown_requests": n}
	if parent != "" {
		m["resumed_from"] = parent
	}
	if root != "" {
		m["root_build"] = root
	}
	return m
}
func coverageRow(op, outcome, run string) object {
	r := usageFixture(op+outcome, 100, 20)
	r["operation_id"], r["outcome"], r["run_id"] = op, outcome, run
	return normalizeUsage(object{"event": "provider_attempt", "provider": r}, object{})
}
func TestUsageCoverageArithmeticAndAttribution(t *testing.T) {
	const a, b, d = "11111111", "22222222", "33333333"
	for _, test := range []struct {
		name             string
		meta             map[string]object
		rows             []object
		filters          object
		summary, missing any
		completed        any
		limitation       string
	}{
		{"empty", nil, nil, nil, nil, nil, 0, "summary_coverage_unavailable"},
		{"missing", map[string]object{a: {}}, []object{coverageRow("done", "completed", a)}, nil, nil, nil, 1, "summary_coverage_unavailable"},
		{"invalid", map[string]object{a: coverageSummary(nil, "", "")}, nil, nil, nil, nil, 0, "summary_coverage_unavailable"},
		{"summary only", map[string]object{a: coverageSummary(int64(1), "", "")}, nil, nil, int64(1), int64(1), 0, "summary_usage_unrepresented"},
		{"retained unresolved", map[string]object{a: coverageSummary(int64(1), "", "")}, []object{coverageRow("fail", "failed", a)}, nil, int64(1), int64(0), 0, ""},
		{"cancelled", map[string]object{a: coverageSummary(int64(1), "", "")}, []object{coverageRow("cancel", "cancelled", a)}, nil, int64(1), int64(0), 0, ""},
		{"fallback", map[string]object{a: coverageSummary(int64(0), "", "")}, []object{coverageRow("retry", "failed", a), coverageRow("retry", "completed", a)}, nil, int64(0), int64(0), 1, ""},
		{"legacy completion", map[string]object{a: coverageSummary(int64(1), "", "")}, []object{coverageRow("", "completed", a)}, nil, int64(1), int64(1), nil, "summary_usage_unrepresented"},
		{"unidentified failure", map[string]object{a: coverageSummary(int64(1), "", "")}, []object{coverageRow("", "failed", a)}, nil, int64(1), nil, nil, "summary_evidence_inconsistent"},
		{"contradiction", map[string]object{a: coverageSummary(int64(0), "", "")}, []object{coverageRow("fail", "failed", a)}, nil, int64(0), nil, 0, "summary_evidence_inconsistent"},
		{"linear", map[string]object{a: coverageSummary(int64(1), "", ""), b: coverageSummary(int64(1), a, a)}, []object{coverageRow("fail", "failed", a), coverageRow("fail", "completed", b)}, nil, int64(1), int64(1), 1, "summary_usage_unrepresented"},
		{"child alone", map[string]object{b: coverageSummary(int64(1), a, a)}, nil, nil, nil, nil, 0, "summary_scope_unattributed"},
		{"branch", map[string]object{a: coverageSummary(int64(1), "", ""), b: coverageSummary(int64(1), a, a), d: coverageSummary(int64(1), a, a)}, nil, nil, nil, nil, 0, "summary_scope_unattributed"},
		{"conflicting root", map[string]object{a: coverageSummary(int64(1), "", ""), b: coverageSummary(int64(1), a, d)}, nil, nil, nil, nil, 0, "summary_scope_unattributed"},
		{"cycle", map[string]object{a: coverageSummary(int64(1), b, b), b: coverageSummary(int64(1), a, a)}, nil, nil, nil, nil, 0, "summary_scope_unattributed"},
		{"decreasing", map[string]object{a: coverageSummary(int64(2), "", ""), b: coverageSummary(int64(1), a, a)}, nil, nil, nil, nil, 0, "summary_evidence_inconsistent"},
		{"independent", map[string]object{a: coverageSummary(int64(1), "", ""), b: coverageSummary(int64(2), "", "")}, nil, nil, int64(3), int64(3), 0, "summary_usage_unrepresented"},
		{"filtered", map[string]object{a: coverageSummary(int64(1), "", "")}, nil, object{"outcome": "completed"}, nil, nil, 0, "summary_scope_unattributed"},
	} {
		t.Run(test.name, func(t *testing.T) {
			s := usageScan{metadata: test.meta, selected: map[string]bool{}, limitations: map[string]bool{}}
			for id := range test.meta {
				s.selected[id] = true
			}
			totals := aggregateUsage(test.rows)
			c := s.coverage(test.rows, totals, test.filters, 1)
			if c["summary_unknown_requests"] != test.summary || c["unrepresented_unknown_requests"] != test.missing || c["completed_operations"] != test.completed {
				t.Fatal(c, s.limitations)
			}
			if c["retained_attempts"] != len(test.rows) || c["retained_unknown_attempts"] != totals["unknown_usage"] {
				t.Fatal(c)
			}
			if test.limitation != "" && !s.limitations[test.limitation] {
				t.Fatal(s.limitations)
			}
			want := "uncertain"
			if test.missing == int64(0) {
				want = "reconciled"
			}
			if c["status"] != want {
				t.Fatal(c)
			}
		})
	}
}

func TestUsageSummaryReadsIdentityCountersAndBounds(t *testing.T) {
	for _, test := range []struct {
		body     string
		count    any
		conflict bool
	}{
		{`{"build":"11111111","unknown_requests":0,"outcome":"completed","provider_failure":{"code":"context_length_exceeded","message":"private prose"}}`, int64(0), false},
		{`{"build":"22222222","unknown_requests":1}`, int64(1), true},
		{`{"unknown_requests":-1}`, nil, false}, {`{"unknown_requests":1.5}`, nil, false},
		{`{"unknown_requests":"1"}`, nil, false}, {`{}`, nil, false},
		{`{"unknown_requests":9007199254740993}`, int64(9007199254740993), false},
		{`{"unknown_requests":9223372036854775807}`, int64(9223372036854775807), false},
		{`{"unknown_requests":9223372036854775808}`, nil, false},
		{`{"unknown_requests":0.99999999999999999}`, nil, false},
		{`{"UNKNOWN_REQUESTS":0}`, nil, false},
	} {
		root := t.TempDir()
		dir := filepath.Join(root, ".kogen/local/runs/11111111")
		os.MkdirAll(dir, 0700)
		file := filepath.Join(dir, "result.json")
		os.WriteFile(file, []byte(test.body), 0600)
		s := usageScan{root: root, limitations: map[string]bool{}}
		m := s.readMeta(file)
		if m["unknown_requests"] != test.count || (m["identity_conflict"] == true) != test.conflict {
			t.Fatal(m)
		}
		s.metadata = map[string]object{"11111111": m}
		s.selected = map[string]bool{"11111111": true}
		c := s.coverage(nil, aggregateUsage(nil), nil, 20)
		if test.conflict && (len(c["summaries"].([]object)) != 0 || c["summary_unknown_requests"] != nil || !s.limitations["summary_identity_conflict"]) {
			t.Fatal(c, s.limitations)
		}
		encoded, _ := json.Marshal(c)
		if strings.Contains(string(encoded), "private prose") {
			t.Fatal(string(encoded))
		}
		after, _ := os.ReadFile(file)
		if string(after) != test.body {
			t.Fatal("mutated evidence")
		}
		s.bytes = (256 << 20) - 1
		s.readMeta(file)
		if !s.truncated || !s.limitations["byte_cap"] {
			t.Fatal(s)
		}
	}
	root := t.TempDir()
	file := filepath.Join(root, "result.json")
	target := filepath.Join(root, "other")
	os.WriteFile(target, []byte(`{"unknown_requests":0}`), 0600)
	os.Symlink(target, file)
	s := usageScan{root: root, limitations: map[string]bool{}}
	if s.readMeta(file)["summary_available"] == true || s.bytes != 0 {
		t.Fatal(s)
	}
}

func TestUsageCoverageSlugLimitAndSelectedScope(t *testing.T) {
	s := usageScan{metadata: map[string]object{}, selected: map[string]bool{}, limitations: map[string]bool{}}
	for _, id := range []string{"11111111", "22222222", "33333333"} {
		s.metadata[id] = coverageSummary(int64(1), "", "")
		s.metadata[id]["slug"] = "known"
	}
	s.selected["11111111"], s.selected["22222222"] = true, true
	c := s.coverage(nil, aggregateUsage(nil), object{"slug": "known"}, 1)
	if c["summary_unknown_requests"] != int64(2) || c["omitted_summaries"] != 1 || c["summaries"].([]object)[0]["run_id"] != "11111111" {
		t.Fatal(c)
	}
	s.metadata["22222222"]["slug"] = nil
	c = s.coverage(nil, aggregateUsage(nil), object{"slug": "known"}, 20)
	if c["summary_unknown_requests"] != nil || !s.limitations["summary_scope_unattributed"] {
		t.Fatal(c)
	}
}

func TestUsageSummarySizeBoundaryAndDamage(t *testing.T) {
	for _, size := range []int{(4 << 20) - 1, 4 << 20, (4 << 20) + 1} {
		root := t.TempDir()
		dir := filepath.Join(root, ".kogen/local/runs/11111111")
		os.MkdirAll(dir, 0700)
		prefix, suffix := `{"build":"11111111","unknown_requests":0,"ignored":"`, `"}`
		body := prefix + strings.Repeat("x", size-len(prefix)-len(suffix)) + suffix
		file := filepath.Join(dir, "result.json")
		os.WriteFile(file, []byte(body), 0600)
		os.WriteFile(filepath.Join(dir, "log.jsonl"), nil, 0600)
		s := usageScan{root: root, metadata: map[string]object{}, selected: map[string]bool{}, limitations: map[string]bool{}}
		rows := s.scan("11111111", false)
		c := s.coverage(rows, aggregateUsage(rows), nil, 20)
		if (c["status"] == "reconciled") != (size <= 4<<20) || s.truncated != (size > 4<<20) {
			t.Fatal(size, c, s.limitations)
		}
		after, _ := os.ReadFile(file)
		if string(after) != body {
			t.Fatal("changed summary")
		}
	}
	root := t.TempDir()
	dir := filepath.Join(root, ".kogen/local/runs/11111111")
	os.MkdirAll(dir, 0700)
	os.WriteFile(filepath.Join(dir, "result.json"), []byte(`{"unknown_requests":0}`), 0600)
	os.WriteFile(filepath.Join(dir, "log.jsonl"), []byte("broken\n"), 0600)
	s := usageScan{root: root, metadata: map[string]object{}, selected: map[string]bool{}, limitations: map[string]bool{}}
	rows := s.scan("11111111", false)
	c := s.coverage(rows, aggregateUsage(rows), nil, 20)
	if c["status"] != "uncertain" || c["unrepresented_unknown_requests"] != nil || !s.limitations["summary_coverage_unavailable"] {
		t.Fatal(c, s.limitations)
	}
}

func TestUsageCoverageConflictingDuplicateIdentities(t *testing.T) {
	a, b := coverageRow("a", "completed", "11111111"), coverageRow("b", "completed", "11111111")
	b["provider_response_id"] = a["provider_response_id"]
	rows, _ := deduplicateUsage([]object{a, b})
	s := usageScan{metadata: map[string]object{"11111111": coverageSummary(int64(0), "", "")}, selected: map[string]bool{"11111111": true}, limitations: map[string]bool{}}
	c := s.coverage(rows, aggregateUsage(rows), nil, 20)
	if c["completed_operations"] != nil || c["unrepresented_unknown_requests"] != nil || c["status"] != "uncertain" {
		t.Fatal(c)
	}
}

func TestUsageCoverageDuplicateRunProvenance(t *testing.T) {
	const a, b = "11111111", "22222222"
	for _, linear := range []bool{false, true} {
		t.Run(map[bool]string{false: "independent roots", true: "linear chain"}[linear], func(t *testing.T) {
			first := coverageRow("shared", "failed", a)
			copy := coverageRow("shared", "failed", b)
			rows, _ := deduplicateUsage([]object{first, copy})
			parent, root := "", ""
			if linear {
				parent, root = a, a
			}
			s := usageScan{metadata: map[string]object{a: coverageSummary(int64(1), "", ""), b: coverageSummary(int64(1), parent, root)}, selected: map[string]bool{a: true, b: true}, limitations: map[string]bool{}}
			totals := aggregateUsage(rows)
			c := s.coverage(rows, totals, nil, 20)
			if c["retained_attempts"] != 1 || c["retained_unknown_attempts"] != 1 || totals["known_input"] != int64(0) || len(rows[0]["provenance"].([]object)) != 2 {
				t.Fatal(c, rows)
			}
			if linear {
				if c["summary_unknown_requests"] != int64(1) || c["unrepresented_unknown_requests"] != int64(0) || c["status"] != "reconciled" {
					t.Fatal(c, s.limitations)
				}
			} else if c["summary_unknown_requests"] != nil || c["unrepresented_unknown_requests"] != nil || c["status"] != "uncertain" || !s.limitations["summary_evidence_inconsistent"] {
				t.Fatal(c, s.limitations)
			}
		})
	}
}

func TestUsageCoverageSlugScopeConflictsAndDamage(t *testing.T) {
	for _, test := range []struct {
		name, slug, log string
		wantReconciled  bool
	}{
		{"matching scope", "selected", "", true},
		{"conflict hidden by filter", "selected", `{"event":"provider_attempt","provider":{"run_id":"11111111","slug":"other","operation_id":"failed","attempt_id":"attempt","outcome":"failed"}}` + "\n", false},
		{"unrelated damaged log", "other", "broken\n", true},
		{"selected damaged log", "selected", "broken\n", false},
	} {
		t.Run(test.name, func(t *testing.T) {
			root := t.TempDir()
			for id, slug := range map[string]string{"11111111": test.slug, "22222222": "selected"} {
				dir := filepath.Join(root, ".kogen/local/runs", id)
				if err := os.MkdirAll(dir, 0700); err != nil {
					t.Fatal(err)
				}
				body, _ := json.Marshal(object{"build": id, "slug": slug, "unknown_requests": 0})
				if err := os.WriteFile(filepath.Join(dir, "result.json"), body, 0600); err != nil {
					t.Fatal(err)
				}
				log := ""
				if id == "11111111" {
					log = test.log
				}
				if err := os.WriteFile(filepath.Join(dir, "log.jsonl"), []byte(log), 0600); err != nil {
					t.Fatal(err)
				}
			}
			s := usageScan{root: root, metadata: map[string]object{}, selected: map[string]bool{}, limitations: map[string]bool{}}
			rows := s.scan("", false)
			filters := object{"slug": "selected"}
			selected := []object{}
			for _, r := range rows {
				if matchesUsage(r, filters) {
					selected = append(selected, r)
				}
			}
			c := s.coverage(selected, aggregateUsage(selected), filters, 20)
			if c["retained_attempts"] != 0 || (c["status"] == "reconciled") != test.wantReconciled {
				t.Fatal(c, s.limitations)
			}
			if !test.wantReconciled && (c["summary_unknown_requests"] != nil || c["unrepresented_unknown_requests"] != nil) {
				t.Fatal(c)
			}
		})
	}
}

func TestUsageCoverageDamagedHistoryDirectory(t *testing.T) {
	root := t.TempDir()
	dir := filepath.Join(root, ".kogen/local/runs/11111111")
	if err := os.MkdirAll(dir, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "result.json"), []byte(`{"unknown_requests":0}`), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "log.jsonl"), nil, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(dir, filepath.Join(root, ".kogen/local/shaping")); err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{"", "11111111"} {
		s := usageScan{root: root, metadata: map[string]object{}, selected: map[string]bool{}, limitations: map[string]bool{}}
		rows := s.scan(id, false)
		c := s.coverage(rows, aggregateUsage(rows), nil, 20)
		if (c["status"] == "reconciled") != (id != "") {
			t.Fatal(id, c, s.limitations)
		}
	}
}
