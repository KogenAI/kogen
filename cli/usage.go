package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"
)

var usageTokens = []string{"input", "cached", "write", "write_30m", "write_12h", "output", "reasoning"}
var usageKeys = []string{"project", "slug", "lineage", "phase", "role", "model", "effective-model", "effort", "effective-effort", "outcome", "pass", "repair"}
var usageFields = map[string]string{"model": "configured_model", "effective-model": "effective_model", "effort": "configured_effort", "effective-effort": "effective_effort"}

func usageField(r object, k string) any {
	if f, ok := usageFields[k]; ok {
		return r[f]
	}
	return r[k]
}
func usageCommand(args []string) int {
	project, id := "", ""
	limit := 20
	lineage, jsonMode := false, false
	filters := object{}
	group := []string{"phase", "role"}
	bad := false
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch a {
		case "--json":
			jsonMode = true
			continue
		case "--lineage":
			lineage = true
			continue
		case "--help", "-h":
			fmt.Println("Usage: kogen intent usage [RUN-ID] [--lineage] [--project DIR] [--json] [--limit 1..100]\nFilters: --slug --phase --role --model --effective-model --effort --effective-effort --outcome --pass --repair --since --until\n--group-by project,slug,lineage,phase,role,model,effective-model,effort,effective-effort,outcome,pass,repair")
			return 0
		}
		if strings.HasPrefix(a, "--") {
			k, v, has := strings.Cut(strings.TrimPrefix(a, "--"), "=")
			if !has {
				i++
				if i >= len(args) {
					bad = true
					break
				}
				v = args[i]
			}
			switch k {
			case "project":
				project = v
			case "limit":
				n, e := strconv.Atoi(v)
				if e != nil || n < 1 || n > 100 {
					bad = true
				} else {
					limit = n
				}
			case "group-by":
				group = strings.Split(v, ",")
				for _, g := range group {
					if !contains(usageKeys, g) {
						bad = true
					}
				}
			case "since", "until":
				t, e := time.Parse(time.RFC3339, v)
				if e != nil || !strings.HasSuffix(v, "Z") {
					bad = true
				} else {
					filters[k] = t.Format(time.RFC3339Nano)
				}
			default:
				if contains(usageKeys, k) && k != "project" && k != "lineage" {
					filters[k] = v
				} else {
					bad = true
				}
			}
		} else if id == "" && runID.MatchString(a) {
			id = a
		} else {
			bad = true
		}
	}
	if lineage && id == "" {
		bad = true
	}
	if bad {
		return response("usage", nil, nil, "invalid_argument", 2)
	}
	c, reason := discover(project)
	if reason != "" {
		return response("usage", nil, nil, reason, 3)
	}
	s := usageScan{root: c["root"].(string), limitations: map[string]bool{}, metadata: map[string]object{}, selected: map[string]bool{}}
	rows := s.scan(id, lineage)
	if id != "" && !s.selected[id] {
		return response("usage", c, nil, "unknown_run", 1)
	}
	selected := []object{}
	for _, r := range rows {
		for _, k := range usageKeys {
			if usageField(r, k) == nil {
				s.limitations["unknown_"+strings.ReplaceAll(k, "-", "_")] = true
			}
		}
		match := matchesUsage(r, filters)
		if match {
			selected = append(selected, r)
		}
	}
	selected, dups := deduplicateUsage(selected)
	totals := aggregateUsage(selected)
	if totals["unknown_usage"].(int) > 0 {
		s.limitations["unknown_usage"] = true
	}
	if totals["inconsistent"].(int) > 0 {
		s.limitations["inconsistent_usage"] = true
	}
	if totals["legacy_without_ids"].(int) > 0 {
		s.limitations["legacy_without_ids"] = true
	}
	if len(filters) == 0 || (len(filters) == 1 && filters["phase"] != nil) {
		var wall int64
		known := false
		for _, d := range s.durations {
			if filters["phase"] == nil || filters["phase"] == d["phase"] {
				wall += d["wall_ms"].(int64)
				known = true
			}
		}
		if known {
			totals["phase_wall_ms"] = wall
		} else {
			s.limitations["phase_wall_unavailable"] = true
		}
	} else {
		s.limitations["phase_wall_unavailable_for_filters"] = true
	}
	totals["duplicate_responses"] = dups
	groupsMap := map[string][]object{}
	keys := map[string]object{}
	for _, r := range selected {
		key := object{}
		for _, g := range group {
			key[g] = usageField(r, g)
		}
		b, _ := json.Marshal(key)
		k := string(b)
		keys[k] = key
		groupsMap[k] = append(groupsMap[k], r)
	}
	names := []string{}
	for k := range groupsMap {
		names = append(names, k)
	}
	sort.Strings(names)
	groups := []object{}
	for _, k := range names {
		g := aggregateUsage(groupsMap[k])
		if len(filters) == 0 {
			var wall int64
			known := false
			eligible := true
			for _, key := range group {
				if !contains([]string{"phase", "project", "slug", "lineage"}, key) {
					eligible = false
				}
			}
			if eligible {
				for _, d := range s.durations {
					match := true
					for _, key := range group {
						v := d[key]
						if key == "project" {
							v = s.root
						}
						if v != keys[k][key] {
							match = false
						}
					}
					if match {
						wall += d["wall_ms"].(int64)
						known = true
					}
				}
				if known {
					g["phase_wall_ms"] = wall
				}
			}
		}
		g["key"] = keys[k]
		groups = append(groups, g)
	}
	sort.Slice(selected, func(i, j int) bool {
		a, b := stringValue(selected[i]["timestamp"]), stringValue(selected[j]["timestamp"])
		ta, ea := time.Parse(time.RFC3339Nano, a)
		tb, eb := time.Parse(time.RFC3339Nano, b)
		if ea == nil && eb != nil {
			return true
		}
		if ea != nil && eb == nil {
			return false
		}
		if ea == nil && eb == nil && !ta.Equal(tb) {
			return ta.After(tb)
		}
		a, b = stringValue(selected[i]["source"]), stringValue(selected[j]["source"])
		if a != b {
			return a < b
		}
		return selected[i]["source_line"].(int) < selected[j]["source_line"].(int)
	})
	coverage := s.coverage(selected, totals, filters, limit)
	omitted := 0
	if len(selected) > limit {
		omitted = len(selected) - limit
		selected = selected[:limit]
	}
	limitations := []string{}
	for k := range s.limitations {
		limitations = append(limitations, k)
	}
	sort.Strings(limitations)
	data := object{"scope": object{"project_root": s.root, "run_id": nil, "lineage": lineage, "filters": filters}, "totals": totals, "coverage": coverage, "groups": groups, "requests": selected, "limitations": limitations, "truncated": s.truncated, "omitted_rows": omitted}
	if id != "" {
		data["scope"].(object)["run_id"] = id
	}
	if jsonMode {
		return response("usage", c, data, "", 0)
	}
	fmt.Printf("Local retained evidence in %s (not account or weekly usage)\n", s.root)
	fmt.Printf("Requests: %v; completed %v; failed %v; cancelled %v; unknown usage %v; inconsistent %v\n", totals["requests"], totals["completed"], totals["failed"], totals["cancelled"], totals["unknown_usage"], totals["inconsistent"])
	fmt.Printf("Known input %v; cached %v; weighted cached/input %v%% (paired input %v, rows %v)\n", totals["known_input"], totals["known_cached"], totals["cached_input_percent"], totals["paired_input"], totals["paired_requests"])
	fmt.Printf("Known writes %v (30m %v; 12h %v); output %v; reasoning %v\nUnknown fields: %v\nResponse wall ms: %v; phase wall ms: %v\nMiss reasons: %v\n", totals["known_write"], totals["known_write_30m"], totals["known_write_12h"], totals["known_output"], totals["known_reasoning"], totals["unknown_fields"], totals["response_wall_ms"], totals["phase_wall_ms"], totals["miss_reasons"])
	fmt.Printf("Retained attempts: %v; unknown usage attempts: %v; completed logical operations: %v\n", coverage["retained_attempts"], coverage["retained_unknown_attempts"], coverageCount(coverage["completed_operations"]))
	fmt.Printf("Summary unknown requests: %v; unrepresented unknown requests: %v; reconciliation: %v\n", coverageCount(coverage["summary_unknown_requests"]), coverageCount(coverage["unrepresented_unknown_requests"]), coverage["status"])
	for _, summary := range coverage["summaries"].([]object) {
		b, _ := json.Marshal(summary)
		fmt.Printf("Coverage summary: %s\n", b)
	}
	fmt.Printf("Omitted summaries: %v\n", coverage["omitted_summaries"])
	b, _ := json.Marshal(data["scope"])
	fmt.Printf("Scope: %s\n", b)
	for _, g := range groups {
		b, _ = json.Marshal(g)
		fmt.Printf("Group: %s\n", b)
	}
	for _, r := range selected {
		b, _ = json.Marshal(r)
		fmt.Printf("Request: %s\n", b)
	}
	fmt.Printf("Limitations: %v; truncated %v; omitted rows %d\n", limitations, s.truncated, omitted)
	return 0
}
func matchesUsage(r object, filters object) bool {
	for k, v := range filters {
		if k == "since" || k == "until" {
			t, e := time.Parse(time.RFC3339Nano, stringValue(r["timestamp"]))
			bound, _ := time.Parse(time.RFC3339Nano, v.(string))
			if e != nil || (k == "since" && t.Before(bound)) || (k == "until" && !t.Before(bound)) {
				return false
			}
			continue
		}
		x := usageField(r, k)
		if x == nil || fmt.Sprint(x) != fmt.Sprint(v) {
			return false
		}
	}
	return true
}
func stringValue(v any) string { s, _ := v.(string); return s }

type usageScan struct {
	root               string
	bytes              int64
	count              int
	truncated          bool
	limitations        map[string]bool
	metadata           map[string]object
	selected           map[string]bool
	durations          []object
	coverageIncomplete bool
}

func (s *usageScan) incompleteCoverage(base object) {
	if m, ok := s.metadata[stringValue(base["run_id"])]; ok {
		m["coverage_incomplete"] = true
	} else {
		s.coverageIncomplete = true
	}
}

func (s *usageScan) cap(reason string) { s.truncated = true; s.limitations[reason] = true }
func (s *usageScan) directories(root string) []os.DirEntry {
	st, err := os.Lstat(root)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil || !st.IsDir() || st.Mode()&os.ModeSymlink != 0 {
		s.limitations["nonregular_source"] = true
		s.coverageIncomplete = true
		return nil
	}
	f, e := os.Open(root)
	if os.IsNotExist(e) {
		return nil
	}
	if e != nil {
		s.limitations["unreadable_source"] = true
		s.coverageIncomplete = true
		return nil
	}
	defer f.Close()
	es, e := f.ReadDir(10001)
	if e != nil && e != io.EOF {
		s.limitations["unreadable_source"] = true
		s.coverageIncomplete = true
	}
	sort.Slice(es, func(i, j int) bool { return es[i].Name() < es[j].Name() })
	if len(es) > 10000 {
		es = es[:10000]
		s.cap("directory_cap")
	}
	return es
}
func (s *usageScan) readMeta(path string) object {
	if s.bytes >= 256<<20 {
		s.cap("byte_cap")
		return object{}
	}
	st, err := os.Lstat(path)
	if err != nil || !st.Mode().IsRegular() {
		s.limitations["missing_record"] = true
		return object{}
	}
	f, e := os.Open(path)
	if e != nil {
		s.limitations["missing_record"] = true
		return object{}
	}
	defer f.Close()
	if st.Size() > 4<<20 {
		s.cap("oversized_record")
		return object{}
	}
	remaining := (256 << 20) - s.bytes
	b, e := io.ReadAll(io.LimitReader(f, min(int64(4<<20), remaining)))
	s.bytes += int64(len(b))
	if st.Size() > int64(len(b)) {
		s.cap("byte_cap")
		return object{}
	}
	var m object
	if e != nil || json.Unmarshal(b, &m) != nil {
		s.limitations["malformed_record"] = true
		return object{}
	}
	safe := object{"summary_available": true, "unknown_requests": nil, "outcome": analyticalIdentifier(m["outcome"]), "provider_failure_code": nil}
	// Decode the native integer separately: float64 rounding could otherwise
	// turn a fractional/overflowing counter into an apparently exact count.
	var fields map[string]json.RawMessage
	var counter *int64
	if json.Unmarshal(b, &fields) == nil && json.Unmarshal(fields["unknown_requests"], &counter) == nil && counter != nil && *counter >= 0 {
		safe["unknown_requests"] = *counter
	}
	if failure, ok := m["provider_failure"].(map[string]any); ok {
		safe["provider_failure_code"] = analyticalIdentifier(failure["code"])
	}
	if m["build"] != nil && m["build"] != filepath.Base(filepath.Dir(path)) {
		safe["identity_conflict"] = true
	}
	for _, k := range []string{"resumed_from", "root_build"} {
		if m[k] != nil && (!runID.MatchString(stringValue(m[k]))) {
			safe["ancestry_conflict"] = true
		}
	}
	for _, k := range []string{"slug", "resumed_from", "root_build"} {
		v := stringValue(m[k])
		if v != "" && len(v) <= 256 {
			if k == "slug" {
				if slugRe.MatchString(v) {
					safe[k] = v
				}
			} else if runID.MatchString(v) {
				safe[k] = v
			}
		}
	}
	return safe
}
func (s *usageScan) scan(id string, lineage bool) []object {
	runsRoot := filepath.Join(s.root, ".kogen/local/runs")
	entries := s.directories(runsRoot)
	for _, e := range entries {
		if !e.IsDir() || e.Type()&os.ModeSymlink != 0 || !runID.MatchString(e.Name()) {
			continue
		}
		s.metadata[e.Name()] = s.readMeta(filepath.Join(runsRoot, e.Name(), "result.json"))
	}
	if id != "" {
		if _, ok := s.metadata[id]; ok {
			s.selected[id] = true
		}
		if lineage && s.selected[id] {
			root := id
			seen := map[string]bool{}
			for !seen[root] {
				seen[root] = true
				p := stringValue(s.metadata[root]["resumed_from"])
				if p != "" {
					if _, ok := s.metadata[p]; !ok {
						s.limitations["missing_lineage_record"] = true
						break
					}
				}
				if p == "" {
					break
				}
				root = p
			}
			s.selected[root] = true
			changed := true
			for changed {
				changed = false
				for run, m := range s.metadata {
					if !s.selected[run] && (s.selected[stringValue(m["resumed_from"])] || stringValue(m["root_build"]) == root) {
						s.selected[run] = true
						changed = true
					}
				}
			}
		}
	} else {
		for run := range s.metadata {
			s.selected[run] = true
		}
	}
	rows := []object{}
	ids := []string{}
	for run := range s.selected {
		ids = append(ids, run)
	}
	sort.Strings(ids)
	for _, run := range ids {
		m := s.metadata[run]
		base := object{"run_id": run, "slug": m["slug"], "lineage": m["root_build"]}
		if base["lineage"] == nil {
			base["lineage"] = run
		}
		s.readRows(filepath.Join(runsRoot, run, "log.jsonl"), base, &rows)
	}
	if id == "" {
		for _, root := range []string{"shaping", "refinements"} {
			p := filepath.Join(s.root, ".kogen/local", root)
			for _, e := range s.directories(p) {
				name := e.Name()
				valid := slugRe.MatchString(name)
				if root == "refinements" {
					valid = len(name) == 16 && hashRe.MatchString(name)
				}
				if valid && e.IsDir() && e.Type()&os.ModeSymlink == 0 {
					var slug any = e.Name()
					if root == "refinements" {
						slug = s.readMeta(filepath.Join(p, e.Name(), "result.json"))["slug"]
					}
					s.readRows(filepath.Join(p, e.Name(), "events.ndjson"), object{"slug": slug, "run_id": nil, "lineage": nil}, &rows)
				}
			}
		}
	}
	return rows
}
func (s *usageScan) readRows(path string, base object, rows *[]object) {
	if s.bytes >= 256<<20 {
		s.cap("byte_cap")
		return
	}
	if s.count >= 100000 {
		s.cap("row_cap")
		return
	}
	st, e := os.Lstat(path)
	if e != nil {
		s.limitations["missing_record"] = true
		s.incompleteCoverage(base)
		return
	}
	if !st.Mode().IsRegular() {
		s.limitations["nonregular_source"] = true
		s.incompleteCoverage(base)
		return
	}
	f, e := os.Open(path)
	if e != nil {
		s.limitations["unreadable_source"] = true
		s.incompleteCoverage(base)
		return
	}
	defer f.Close()
	reader := bufio.NewReaderSize(io.LimitReader(f, (256<<20)-s.bytes), 64<<10)
	line := 0
	found := false
	for {
		if s.bytes >= 256<<20 {
			s.cap("byte_cap")
			break
		}
		if s.count >= 100000 {
			s.cap("row_cap")
			break
		}
		line++
		b, e := reader.ReadSlice('\n')
		buffer := append([]byte{}, b...)
		oversize := false
		for e == bufio.ErrBufferFull {
			s.bytes += int64(len(b))
			if s.bytes >= 256<<20 {
				s.cap("byte_cap")
				return
			}
			b, e = reader.ReadSlice('\n')
			if !oversize && len(buffer)+len(b) <= 4<<20 {
				buffer = append(buffer, b...)
			} else {
				oversize = true
				buffer = nil
			}
		}
		s.bytes += int64(len(b))
		if len(buffer) == 0 && e == io.EOF {
			break
		}
		if oversize {
			s.cap("oversized_line")
			s.incompleteCoverage(base)
			if e == io.EOF {
				break
			}
			continue
		}
		if len(buffer) > 0 && buffer[len(buffer)-1] != '\n' {
			s.limitations["truncated_record"] = true
			s.incompleteCoverage(base)
		}
		var ev object
		if json.Unmarshal(buffer, &ev) != nil {
			s.limitations["malformed_record"] = true
			s.incompleteCoverage(base)
		} else {
			event := stringValue(ev["event"])
			if event == "phase_duration" {
				if n, ok := tokenNumber(ev["wall_ms"]); ok && ev["timestamp"] != nil && len(stringValue(ev["phase"])) <= 256 {
					d := object{"phase": stringValue(ev["phase"]), "wall_ms": n, "timestamp": ev["timestamp"], "source": path}
					for k, v := range base {
						d[k] = v
					}
					if len(s.durations) < 100000 {
						s.durations = append(s.durations, d)
					} else {
						s.cap("row_cap")
					}
				}
			}

			if event == "provider_attempt" || event == "request" || event == "provider_call" {
				if event == "request" && ev["operation_id"] != nil {
					s.limitations["logical_summaries_excluded"] = true
				} else {
					r := normalizeUsage(ev, base)
					if r == nil {
						s.limitations["malformed_record"] = true
						s.incompleteCoverage(base)
					}
					if r != nil {
						if base["run_id"] != nil && (r["run_id"] != base["run_id"] || (base["slug"] != nil && r["slug"] != base["slug"])) {
							r["coverage_conflict"] = true
							if m := s.metadata[stringValue(base["run_id"])]; m != nil {
								// Keep scope conflicts even when a row filter hides the row.
								m["row_scope_conflict"] = true
							}
						}
						r["source"], _ = filepath.Rel(s.root, path)
						r["source_line"] = line
						r["project"] = s.root
						for _, k := range []string{"timestamp", "configured_model", "configured_effort", "phase", "role"} {
							if r[k] == nil {
								s.limitations["unknown_"+k] = true
							}
						}
						*rows = append(*rows, r)
						s.count++
						found = true
					}
				}
			}
		}
		if e == io.EOF {
			if s.bytes >= 256<<20 {
				s.cap("byte_cap")
			}
			break
		}
		if e != nil {
			s.limitations["unreadable_source"] = true
			s.incompleteCoverage(base)
			break
		}
	}
	if !found {
		s.limitations["summary_only_or_no_request_detail"] = true
	}
}

var providerSafe = strings.Fields("operation_id attempt_id conversation_id timestamp phase role run_id slug lineage pass repair provider_response_id provider_request_id configured_model effective_model configured_effort effective_effort requested_service_tier effective_service_tier requested_reasoning_context effective_reasoning_context cache fingerprints usage usage_state wall_ms ttft_ms outcome error")

func normalizeUsage(ev, base object) object {
	r := object{}
	p, modern := ev["provider"].(map[string]any)
	if modern {
		for _, k := range providerSafe {
			r[k] = p[k]
		}
	} else {
		if ev["event"] == "provider_attempt" {
			return nil
		}
		for _, k := range providerSafe {
			r[k] = nil
		}
		r["legacy"] = true
		r["role"] = ev["role"]
		r["phase"] = ev["phase"]
		if r["phase"] == nil {
			r["phase"] = ev["role"]
		}
		r["configured_model"] = ev["model"]
		if r["configured_model"] == nil {
			r["configured_model"] = ev["configured_model"]
		}
		r["configured_effort"] = ev["effort"]
		if r["configured_effort"] == nil {
			r["configured_effort"] = ev["configured_effort"]
		}
		r["timestamp"] = ev["at"]
		r["wall_ms"] = ev["wall_ms"]
		r["usage"] = ev["usage"]
		r["outcome"] = ev["status"]
		if r["outcome"] == nil {
			r["outcome"] = "completed"
		}
	}
	for k, v := range base {
		if r[k] == nil {
			r[k] = v
		}
	}
	// Analytical fields are selected, never arbitrary event content or provider prose.
	for _, k := range providerSafe {
		if contains([]string{"cache", "fingerprints", "usage"}, k) {
			continue
		}
		switch v := r[k].(type) {
		case nil:
		case string:
			if len(v) > 256 {
				r[k] = nil
			}
		case float64:
			if k != "wall_ms" && k != "ttft_ms" && k != "pass" && k != "repair" {
				r[k] = nil
			}
		default:
			r[k] = nil
		}
	}
	if _, e := time.Parse(time.RFC3339Nano, stringValue(r["timestamp"])); e != nil {
		r["timestamp"] = nil
	}

	for _, k := range []string{"operation_id", "attempt_id", "conversation_id", "provider_response_id", "provider_request_id", "configured_model", "effective_model", "configured_effort", "effective_effort", "phase", "role"} {
		if v, ok := r[k].(string); ok && len(v) > 256 {
			r[k] = nil
		}
	}
	if !contains([]string{"completed", "failed", "cancelled"}, stringValue(r["outcome"])) {
		r["outcome"] = nil
	}
	r["error"] = nil
	if r["outcome"] != "completed" {
		r["error"] = "provider_failure"
		r["usage"] = object{}
	}
	cache, _ := r["cache"].(map[string]any)
	r["cache"] = nil
	if cache != nil {
		safe := object{}
		for _, k := range strings.Fields("configured_mode applied_mode configured_ttl applied_ttl status comparison_response_id") {
			v := cache[k]
			if str, ok := v.(string); ok && len(str) <= 256 {
				safe[k] = str
			} else {
				safe[k] = nil
			}
		}
		for _, k := range []string{"configured_mode", "applied_mode"} {
			if safe[k] != nil && !contains([]string{"implicit", "explicit"}, stringValue(safe[k])) {
				safe[k] = nil
			}
		}
		for _, k := range []string{"configured_ttl", "applied_ttl"} {
			if safe[k] != nil && !contains([]string{"30m", "12h"}, stringValue(safe[k])) {
				safe[k] = nil
			}
		}
		if !contains([]string{"requested", "applied", "unsupported", "unknown"}, stringValue(safe["status"])) {
			safe["status"] = "unknown"
		}
		safe["boundaries"] = []any{}
		if bs, ok := cache["boundaries"].([]any); ok {
			for _, b := range bs {
				if str, ok := b.(string); ok && len(str) <= 256 && len(safe["boundaries"].([]any)) < 4 {
					safe["boundaries"] = append(safe["boundaries"].([]any), str)
				}
			}
		}
		safe["diagnostics"] = safeCacheDiagnostics(cache["diagnostics"])
		r["cache"] = safe
	}
	fps, _ := r["fingerprints"].(map[string]any)
	r["fingerprints"] = nil
	if fps != nil {
		safe := object{}
		for _, k := range []string{"policy", "tools", "schema", "contract", "prefix"} {
			safe[k] = nil
			if f, ok := fps[k].(map[string]any); ok {
				hash := stringValue(f["sha256"])
				if len(hash) == 64 {
					if n, ok := tokenNumber(f["bytes"]); ok {
						safe[k] = object{"sha256": hash, "bytes": n}
					}
				}
			}
		}
		r["fingerprints"] = safe
	}
	u, _ := r["usage"].(map[string]any)
	safe := object{}
	invalid := r["usage_state"] == "inconsistent"
	for _, k := range usageTokens {
		v, ok := tokenNumber(u[k])
		safe[k] = nil
		if ok {
			safe[k] = v
		} else if u[k] != nil {
			invalid = true
		}
	}
	r["usage"] = safe
	invalid = invalid || invalidUsage(safe)
	r["usage_state"] = "known"
	for _, k := range usageTokens {
		if safe[k] == nil {
			r["usage_state"] = "partial"
		}
	}
	if r["outcome"] != "completed" {
		r["usage_state"] = "unknown"
	}
	allMissing := true
	for _, k := range usageTokens {
		if safe[k] != nil {
			allMissing = false
		}
	}
	if allMissing {
		r["usage_state"] = "unknown"
	}
	if invalid {
		r["usage_state"] = "inconsistent"
	}
	return r
}
func safeCacheDiagnostics(v any) any {
	m, ok := v.(map[string]any)
	if !ok {
		return nil
	}
	b, _ := json.Marshal(m)
	if len(b) > 2048 {
		return nil
	}
	r := object{}
	for _, k := range []string{"type", "reason"} {
		s := stringValue(m[k])
		allowed := []string{"cache_hit", "cache_miss", "comparison_response_not_found", "unavailable", "tools_changed", "policy_changed", "prefix_changed", "schema_changed", "contract_changed", "expired"}
		if contains(allowed, s) {
			r[k] = s
		} else {
			r[k] = "other"
		}
	}
	for _, k := range []string{"comparison_reusable_tokens", "cache_missed_tokens", "cache_hit_tokens"} {
		if n, ok := tokenNumber(m[k]); ok {
			r[k] = n
		}
	}
	return r
}
func tokenNumber(v any) (int64, bool) {
	switch n := v.(type) {
	case float64:
		if n >= 0 && n < 1<<63 && n == float64(int64(n)) {
			return int64(n), true
		}
	case int64:
		if n >= 0 {
			return n, true
		}
	case int:
		if n >= 0 {
			return int64(n), true
		}
	}
	return 0, false
}
func invalidUsage(u object) bool {
	in, i := tokenNumber(u["input"])
	c, cc := tokenNumber(u["cached"])
	w, ww := tokenNumber(u["write"])
	o, oo := tokenNumber(u["output"])
	r, rr := tokenNumber(u["reasoning"])
	a, aa := tokenNumber(u["write_30m"])
	b, bb := tokenNumber(u["write_12h"])
	return (i && cc && c > in) || (i && ww && w > in) || (i && cc && ww && w > in-c) || (oo && rr && r > o) || (ww && aa && a > w) || (ww && bb && b > w) || (ww && aa && bb && (a > w-b)) || (ww && aa && bb && a+b != w)
}
func deduplicateUsage(rows []object) ([]object, int) {
	out := []object{}
	seen := map[string]int{}
	duplicates := 0
	for _, r := range rows {
		key := stringValue(r["provider_response_id"])
		if key != "" {
			key = "response:" + key
		} else if r["legacy"] != true && r["operation_id"] != nil && r["attempt_id"] != nil {
			key = fmt.Sprint(r["operation_id"], "/", r["attempt_id"])
		}
		prov := object{"source": r["source"], "source_line": r["source_line"], "operation_id": r["operation_id"], "attempt_id": r["attempt_id"], "run_id": r["run_id"], "usage": r["usage"], "usage_state": r["usage_state"]}
		if n, ok := seen[key]; ok && key != "" {
			duplicates++
			old := out[n]
			if old["operation_id"] != r["operation_id"] || old["outcome"] != r["outcome"] || r["coverage_conflict"] == true {
				old["coverage_conflict"] = true
			}
			old["provenance"] = append(old["provenance"].([]object), prov)
			a, _ := json.Marshal(old["usage"])
			b, _ := json.Marshal(r["usage"])
			if string(a) != string(b) || r["usage_state"] == "inconsistent" {
				old["usage_state"] = "inconsistent"
			}
			continue
		}
		r["provenance"] = []object{prov}
		if key != "" {
			seen[key] = len(out)
		}
		out = append(out, r)
	}
	return out, duplicates
}
func aggregateUsage(rows []object) object {
	t := object{"requests": len(rows), "completed": 0, "failed": 0, "cancelled": 0, "unknown_usage": 0, "inconsistent": 0, "duplicate_responses": 0, "legacy_without_ids": 0, "cached_input_percent": nil, "zero_hit_requests": 0, "response_wall_ms": int64(0), "phase_wall_ms": nil, "paired_input": int64(0), "paired_cached": int64(0), "paired_requests": 0}
	unknown := object{}
	miss := object{}
	for _, k := range usageTokens {
		t["known_"+k] = int64(0)
		unknown[k] = 0
	}
	inc := func(k string) { t[k] = t[k].(int) + 1 }
	for _, r := range rows {
		if p, ok := r["provenance"].([]object); ok && len(p) > 1 {
			t["duplicate_responses"] = t["duplicate_responses"].(int) + len(p) - 1
		}
		switch r["outcome"] {
		case "completed":
			inc("completed")
		case "failed":
			inc("failed")
		case "cancelled":
			inc("cancelled")
		}
		if r["legacy"] == true {
			inc("legacy_without_ids")
		}
		u := r["usage"].(object)
		inconsistent := r["usage_state"] == "inconsistent"
		if inconsistent {
			inc("inconsistent")
		}
		missing := inconsistent
		for _, k := range []string{"input", "cached", "output", "reasoning"} {
			if u[k] == nil {
				missing = true
			}
		}
		if missing {
			inc("unknown_usage")
		}
		for _, k := range usageTokens {
			if n, ok := tokenNumber(u[k]); ok && !inconsistent {
				t["known_"+k] = t["known_"+k].(int64) + n
			} else {
				unknown[k] = unknown[k].(int) + 1
			}
		}
		if !inconsistent {
			i, ok := tokenNumber(u["input"])
			c, ck := tokenNumber(u["cached"])
			if ok && ck {
				t["paired_input"] = t["paired_input"].(int64) + i
				t["paired_cached"] = t["paired_cached"].(int64) + c
				inc("paired_requests")
				if i > 0 && c == 0 {
					inc("zero_hit_requests")
				}
			}
		}
		if n, ok := tokenNumber(r["wall_ms"]); ok {
			t["response_wall_ms"] = t["response_wall_ms"].(int64) + n
		}
		if c, ok := r["cache"].(object); ok {
			if d, ok := c["diagnostics"].(object); ok {
				k := stringValue(d["type"])
				if k == "cache_miss" {
					k += "/" + stringValue(d["reason"])
				}
				n, _ := miss[k].(int)
				miss[k] = n + 1
			}
		}
	}
	if t["paired_input"].(int64) > 0 {
		t["cached_input_percent"] = 100 * float64(t["paired_cached"].(int64)) / float64(t["paired_input"].(int64))
	}
	t["unknown_fields"] = unknown
	t["miss_reasons"] = miss
	return t
}
