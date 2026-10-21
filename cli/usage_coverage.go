package main

import (
	"math"
	"regexp"
	"sort"
)

var analyticalID = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$`)

func analyticalIdentifier(v any) any {
	if s, ok := v.(string); ok && analyticalID.MatchString(s) {
		return s
	}
	return nil
}
func coverageCount(v any) any {
	if v == nil {
		return "unknown"
	}
	return v
}

// coverage compares native logical uncertainty with retained physical evidence.
// It deliberately never contributes to the retained usage aggregates.
func (s *usageScan) coverage(rows []object, totals, filters object, limit int) object {
	c := object{"retained_attempts": totals["requests"], "retained_unknown_attempts": totals["unknown_usage"], "completed_operations": nil, "summary_unknown_requests": nil, "unrepresented_unknown_requests": nil, "status": "uncertain", "summaries": []object{}, "omitted_summaries": 0}
	completed := map[string]bool{}
	identities := true
	for _, r := range rows {
		op := stringValue(r["operation_id"])
		if op == "" || r["coverage_conflict"] == true {
			identities = false
		}
		if op != "" && r["outcome"] == "completed" {
			completed[op] = true
		}
	}
	if identities {
		c["completed_operations"] = len(completed)
	}
	ids := []string{}
	attributable, available := true, true
	for k := range filters {
		if k != "slug" {
			attributable = false
		}
	}
	for id := range s.selected {
		m := s.metadata[id]
		if slug, ok := filters["slug"]; ok {
			if m["slug"] != nil && m["slug"] != slug {
				continue
			}
			if m["slug"] == nil {
				attributable = false
			}
		}
		ids = append(ids, id)
	}
	sort.Strings(ids)
	scope := map[string]bool{}
	for _, id := range ids {
		scope[id] = true
		m := s.metadata[id]
		if m["coverage_incomplete"] == true {
			available = false
		}
		if m["row_scope_conflict"] == true {
			attributable = false
		}
		if m["identity_conflict"] == true {
			s.limitations["summary_identity_conflict"] = true
			available = false
			continue
		}
		if m["summary_available"] != true {
			available = false
			continue
		}
		c["summaries"] = append(c["summaries"].([]object), object{"run_id": id, "source": ".kogen/local/runs/" + id + "/result.json", "unknown_requests": m["unknown_requests"], "outcome": m["outcome"], "provider_failure_code": m["provider_failure_code"]})
		if m["unknown_requests"] == nil {
			available = false
		}
		if m["ancestry_conflict"] == true {
			attributable = false
		}
	}
	summaries := c["summaries"].([]object)
	if len(summaries) > limit {
		c["omitted_summaries"] = len(summaries) - limit
		c["summaries"] = summaries[:limit]
	}
	if len(ids) == 0 {
		available = false
	}
	// Deduplication must not erase evidence of overlapping scopes. Copies in
	// one chain still represent one operation, but copies across independent
	// roots cannot establish that their cumulative counters are disjoint.
	rowsByRun := map[string][]object{}
	for _, r := range rows {
		runs := map[string]bool{stringValue(r["run_id"]): true}
		if provenance, ok := r["provenance"].([]object); ok {
			for _, p := range provenance {
				runs[stringValue(p["run_id"])] = true
			}
		}
		for id := range runs {
			// Shape/refinement observations have no native Build counter.
			if !scope[id] {
				attributable = false
			}
			rowsByRun[id] = append(rowsByRun[id], r)
		}
	}
	if s.coverageIncomplete || s.limitations["directory_cap"] || s.limitations["byte_cap"] || s.limitations["row_cap"] {
		available = false
	}

	// Establish disjoint linear chains from explicit ancestry, never from sort order.
	children := map[string][]string{}
	roots := []string{}
	for _, id := range ids {
		m := s.metadata[id]
		parent := stringValue(m["resumed_from"])
		root := stringValue(m["root_build"])
		if parent == "" {
			if root != "" && root != id {
				attributable = false
			}
			roots = append(roots, id)
		} else {
			if !scope[parent] {
				attributable = false
			}
			children[parent] = append(children[parent], id)
		}
	}
	visited := map[string]bool{}
	chains := [][]string{}
	for _, root := range roots {
		chain := []string{}
		id := root
		for id != "" && !visited[id] {
			visited[id] = true
			chain = append(chain, id)
			m := s.metadata[id]
			declared := stringValue(m["root_build"])
			if declared != "" && declared != root {
				attributable = false
			}
			next := children[id]
			if len(next) > 1 {
				attributable = false
				break
			}
			id = ""
			if len(next) == 1 {
				id = next[0]
			}
		}
		chains = append(chains, chain)
	}
	if len(visited) != len(ids) {
		attributable = false
	}
	if !attributable {
		s.limitations["summary_scope_unattributed"] = true
	}
	if !available || !attributable {
		s.limitations["summary_coverage_unavailable"] = true
		return c
	}

	var summary, residual int64
	exact, counterExact := true, true
	operationChain := map[string]string{}
	for _, chain := range chains {
		chainRows := []object{}
		var previous int64
		for _, id := range chain {
			chainRows = append(chainRows, rowsByRun[id]...)
			n := s.metadata[id]["unknown_requests"].(int64)
			if n < previous {
				counterExact = false
			}
			previous = n
		}
		if previous > math.MaxInt64-summary {
			counterExact = false
		} else {
			summary += previous
		}
		done, unresolved := map[string]bool{}, map[string]bool{}
		for _, r := range chainRows {
			op := stringValue(r["operation_id"])
			if op != "" {
				if previous, ok := operationChain[op]; ok && previous != chain[0] {
					counterExact = false
					s.limitations["summary_scope_unattributed"] = true
				}
				operationChain[op] = chain[0]
			}
			if r["coverage_conflict"] == true {
				exact = false
			}
			switch r["outcome"] {
			case "completed":
				if op != "" {
					done[op] = true
				}
			case "failed", "cancelled":
				if op == "" {
					exact = false
				} else {
					unresolved[op] = true
				}
			default:
				exact = false
			}
			if r["usage_state"] == "inconsistent" {
				exact = false
			}
		}
		var represented int64
		for op := range unresolved {
			if !done[op] {
				represented++
			}
		}
		if represented > previous {
			exact = false
			continue
		}
		n := previous - represented
		if n > math.MaxInt64-residual {
			exact = false
		} else {
			residual += n
		}
	}
	if counterExact {
		c["summary_unknown_requests"] = summary
	}
	if !exact || !counterExact {
		s.limitations["summary_evidence_inconsistent"] = true
		s.limitations["summary_coverage_unavailable"] = true
		return c
	}
	c["summary_unknown_requests"], c["unrepresented_unknown_requests"] = summary, residual
	if residual > 0 {
		s.limitations["summary_usage_unrepresented"] = true
	} else {
		c["status"] = "reconciled"
	}
	return c
}
