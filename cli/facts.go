package main

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"syscall"
)

type object = map[string]any

func localJSON(path string, target any) error {
	f, e := os.OpenFile(path, os.O_RDONLY|syscall.O_NONBLOCK, 0)
	if e != nil {
		return e
	}
	defer f.Close()
	st, e := f.Stat()
	if e != nil {
		return e
	}
	if !st.Mode().IsRegular() {
		return fmt.Errorf("not a regular metadata file")
	}
	var reader io.Reader = f
	if filepath.Base(path) == "context.json" || filepath.Base(path) == "completion.json" {
		reader = io.LimitReader(f, (1<<20)+1)
	}
	b, e := io.ReadAll(reader)
	if (filepath.Base(path) == "context.json" || filepath.Base(path) == "completion.json") && len(b) > 1<<20 {
		return fmt.Errorf("oversized integration metadata")
	}
	if e != nil {
		return e
	}
	return json.Unmarshal(b, target)
}
func discover(project string) (object, string) {
	if project == "" {
		project = "."
	}
	st, e := os.Stat(project)
	if e != nil || !st.IsDir() {
		return nil, "project_unavailable"
	}
	out, e := exec.Command("git", "-C", project, "rev-parse", "--show-toplevel", "--absolute-git-dir").Output()
	if e != nil {
		return nil, "not_project"
	}
	lines := strings.Split(strings.TrimSpace(string(out)), "\n")
	if len(lines) != 2 {
		return nil, "not_project"
	}
	root, e := filepath.EvalSymlinks(lines[0])
	if e != nil {
		return nil, "project_unavailable"
	}
	gd, e := filepath.EvalSymlinks(lines[1])
	if e != nil {
		return nil, "project_unavailable"
	}
	if _, e = os.Stat(filepath.Join(root, ".kogen/project.yaml")); e != nil {
		return nil, "not_project"
	}
	return object{"root": root, "git_dir": gd, "id": fmt.Sprintf("%x", sha256.Sum256([]byte(gd)))}, ""
}
func alive(root string, owner object) bool {
	pid, ok := owner["pid"].(string)
	if !ok {
		return false
	}
	n, e := strconv.Atoi(pid)
	if e != nil || n <= 0 || syscall.Kill(n, 0) != nil {
		return false
	}
	token, ok := owner["token"].(string)
	if !ok || token == "" || strings.ContainsAny(token, "/\\") {
		return false
	}
	entries, e := os.ReadDir(filepath.Join(root, ".kogen/local/build.lock"))
	if e != nil || len(entries) != 1 || entries[0].Name() != token {
		return false
	}
	f, e := os.OpenFile(filepath.Join(root, ".kogen/local/build.lock", token), os.O_RDONLY|syscall.O_NONBLOCK, 0)
	if e != nil {
		return false
	}
	defer f.Close()
	st, e := f.Stat()
	if e != nil || !st.Mode().IsRegular() {
		return false
	}
	b, e := io.ReadAll(io.LimitReader(f, 64))
	if e != nil || strings.TrimSpace(string(b)) != pid {
		return false
	}
	birth, ok := owner["birth"].(string)
	if !ok || birth == "" {
		return false
	}
	out, e := exec.Command("ps", "-p", pid, "-o", "lstart=").Output()
	return e == nil && strings.TrimSpace(string(out)) == birth
}
func contextData(c object) object {
	d := object{"project": c != nil, "active": nil, "last_built": nil, "integration_state": "missing"}
	if c == nil {
		return d
	}
	root := c["root"].(string)
	var m object
	e := localJSON(filepath.Join(root, ".kogen/local/context.json"), &m)
	if os.IsNotExist(e) {
		return d
	}
	d["integration_state"] = "invalid"
	if e != nil {
		return d
	}
	cc, ok := m["checkout"].(map[string]any)
	if !ok || cc["id"] != c["id"] || cc["root"] != c["root"] || cc["git_dir"] != c["git_dir"] || m["schema_version"] != float64(1) {
		return d
	}
	last, ok := m["last_built"].(map[string]any)
	if !ok || !validFact(last) {
		return d
	}
	a, present := m["active"]
	if !present {
		return d
	}
	if a != nil {
		am, ok := a.(map[string]any)
		if !ok || !validFact(am) || am["run_id"] != last["run_id"] || am["slug"] != last["slug"] {
			return d
		}
		phase, _ := am["phase"].(string)
		if !contains([]string{"startup", "building", "verifying", "reviewing", "committing"}, phase) {
			return d
		}
		p := am["verification_pass"]
		if phase == "verifying" {
			v, ok := p.(float64)
			if !ok || v < 1 || v != float64(int(v)) {
				return d
			}
		} else if p != nil {
			return d
		}
		owner, _ := m["owner"].(map[string]any)
		if alive(root, owner) {
			d["active"] = am
		}
	}
	d["integration_state"] = "ok"
	d["last_built"] = last
	return d
}
func validFact(m object) bool {
	s, ok := m["slug"].(string)
	id, ok2 := m["run_id"].(string)
	return ok && ok2 && slugRe.MatchString(s) && runID.MatchString(id)
}

var runID = regexp.MustCompile(`^[a-f0-9]{8}$`)

func catalog(c object) ([]object, error) {
	var m map[string]object
	e := localJSON(filepath.Join(c["root"].(string), ".kogen/local/catalog.json"), &m)
	if os.IsNotExist(e) {
		return []object{}, nil
	}
	if e != nil {
		return nil, e
	}
	if m == nil {
		return nil, fmt.Errorf("invalid catalog")
	}
	rows := []object{}
	for _, r := range m {
		if !validRun(r) || r["checkout_id"] != c["id"] {
			return nil, fmt.Errorf("invalid run record")
		}
		r["type"] = "build"
		rows = append(rows, r)
	}
	return rows, nil
}
func validRun(r object) bool {
	if !validFact(r) {
		return false
	}
	for _, k := range []string{"state", "phase", "resume_status"} {
		if _, ok := r[k].(string); !ok {
			return false
		}
	}
	return contains([]string{"requires_validation", "unsupported", "potentially_available"}, r["resume_status"].(string)) &&
		contains([]string{"startup", "building", "verifying", "reviewing", "committing"}, r["phase"].(string))
}
func observe(c object, r object) object {
	if r["resume_status"] == "potentially_available" {
		path := filepath.Join(c["root"].(string), ".kogen/local/runs", r["run_id"].(string), "checkpoint.json")
		if st, e := os.Stat(path); e != nil || !st.Mode().IsRegular() {
			r["resume_status"] = "unsupported"
			r["blockers"] = []object{{"class": "candidate", "reason": "checkpoint_unavailable", "detail": "checkpoint is missing; inspect and correct the checkout or obtain fresh exact approval for a new Build", "paths": []string{path}}}
		}
	}
	if r["state"] == "active" {
		owner, _ := r["owner"].(map[string]any)
		if !alive(c["root"].(string), owner) {
			r["state"] = "interrupted"
			r["reason"] = "owner stopped without a finalized outcome"
			if r["resume_status"] != "unsupported" {
				r["resume_status"] = "requires_validation"
			}
		}
	}
	r["next_command"] = nil
	if r["resume_status"] == "potentially_available" {
		r["next_command"] = "kogen intent resume " + r["run_id"].(string) + " --project " + shellQuote(c["root"].(string))
	}
	r["observations"] = object{"activity_checked_now": true, "resume_authorized": false}
	delete(r, "owner")
	return r
}
func shellQuote(s string) string { return "'" + strings.ReplaceAll(s, "'", "'\\''") + "'" }
func response(kind string, c object, data any, reason string, code int) int {
	var er any
	if reason != "" {
		class := "environment"
		if code == 1 || code == 2 {
			class = "intent"
		}
		er = object{"class": class, "reason": reason, "detail": reason, "paths": []string{}}
	}
	json.NewEncoder(os.Stdout).Encode(object{"schema_version": 1, "kind": kind, "checkout": c, "data": data, "error": er})
	return code
}

// localRead handles bounded native reads before any installed runtime is consulted.
func localRead(args []string) (bool, int) {
	if len(args) > 1 && args[0] == "intent" && args[1] == "usage" {
		return true, usageCommand(args[2:])
	}
	if len(args) == 0 {
		return false, 0
	}
	kind := ""
	rest := []string{}
	switch {
	case args[0] == "context":
		kind = "context"
		rest = args[1:]
	case args[0] == "__complete":
		kind = "complete"
		rest = args[1:]
	case args[0] == "completion":
		if len(args) == 2 && args[1] == "zsh" {
			fmt.Print(zshCompletion)
			return true, 0
		}
		return true, response("context", nil, nil, "invalid_argument", 2)
	case len(args) > 1 && args[0] == "intent" && contains([]string{"list", "inspect", "preflight"}, args[1]):
		kind = map[string]string{"list": "intents", "inspect": "run", "preflight": "preflight"}[args[1]]
		rest = args[2:]
	default:
		return false, 0
	}
	if len(rest) > 0 && isHelpFlag(rest[len(rest)-1]) {
		if kind == "context" {
			fmt.Println("Usage: kogen context [--json] [--project DIR]")
		} else {
			fmt.Print(intentPage)
		}
		return true, 0
	}
	project := ""
	limit := 20
	cursor := ""
	jsonMode := kind == "context"
	pos := []string{}
	bad := false
	endOpts := false
	for i := 0; i < len(rest); i++ {
		a := rest[i]
		if endOpts {
			pos = append(pos, a)
			continue
		}
		if a == "--" {
			endOpts = true
			continue
		}
		if a == "--json" {
			jsonMode = true
			continue
		}
		if strings.HasPrefix(a, "--") {
			key, val, has := strings.Cut(a, "=")
			if !has {
				if i+1 == len(rest) {
					bad = true
					break
				}
				i++
				val = rest[i]
			}
			switch key {
			case "--project":
				project = val
			case "--limit":
				if kind != "intents" {
					bad = true
				}
				n, e := strconv.Atoi(val)
				if e != nil || n < 1 || n > 100 {
					bad = true
				} else {
					limit = n
				}
			case "--cursor":
				if kind != "intents" {
					bad = true
				}
				cursor = val
			default:
				bad = true
			}
		} else {
			pos = append(pos, a)
		}
	}
	want := 0
	if kind == "run" || kind == "preflight" || kind == "complete" {
		want = 1
	}
	if len(pos) != want {
		bad = true
	}
	if bad {
		return true, response(kind, nil, nil, "invalid_argument", 2)
	}
	c, reason := discover(project)
	if reason != "" {
		if kind == "complete" {
			return true, 0
		}
		if kind == "context" && reason == "not_project" {
			return true, response(kind, nil, contextData(nil), "", 0)
		}
		return true, response(kind, nil, nil, reason, 3)
	}
	if kind == "context" {
		return true, response(kind, c, contextData(c), "", 0)
	}
	if kind == "preflight" {
		if !slugRe.MatchString(pos[0]) || len(pos[0]) < 3 || len(pos[0]) > 48 {
			return true, response(kind, c, nil, "invalid_argument", 2)
		}
		root := installRoot()
		if st, e := os.Stat(filepath.Join(root, "lib/release/bin/kogen")); e != nil || !st.Mode().IsRegular() {
			return true, response(kind, c, nil, "core_unavailable", 3)
		}
		cwd, _ := os.Getwd()
		return true, newSession(root).run(object{"type": "run", "command": "preflight", "project": c["root"], "slug": pos[0], "json": jsonMode, "cwd": cwd, "install_root": root, "env": environ(), "checkout": c})
	}
	if kind == "run" {
		if !runID.MatchString(pos[0]) {
			return true, response(kind, c, nil, "run_not_found", 1)
		}
		var r object
		e := localJSON(filepath.Join(c["root"].(string), ".kogen/local/facts", pos[0]+".json"), &r)
		if os.IsNotExist(e) {
			return true, response(kind, c, nil, "run_not_found", 1)
		}
		if e != nil || !validRun(r) || r["checkout_id"] != c["id"] || r["run_id"] != pos[0] {
			return true, response(kind, c, nil, "local_data_invalid", 3)
		}
		for _, key := range []string{"verification", "reviews", "blockers"} {
			if _, ok := r[key].([]any); !ok {
				return true, response(kind, c, nil, "local_data_invalid", 3)
			}
		}
		if _, ok := r["locations"].(map[string]any); !ok {
			return true, response(kind, c, nil, "local_data_invalid", 3)
		}
		for _, key := range []string{"resumed_from", "root_run", "verification_pass", "reason", "commit", "evidence_truncated"} {
			if _, ok := r[key]; !ok {
				return true, response(kind, c, nil, "local_data_invalid", 3)
			}
		}
		r = observe(c, r)
		if jsonMode {
			return true, response(kind, c, r, "", 0)
		}
		fmt.Printf("Build %s · %s · %s · %s\n", r["run_id"], r["slug"], r["state"], r["phase"])
		if r["reason"] != nil {
			fmt.Printf("  reason: %s\n", r["reason"])
		}
		if r["commit"] != nil {
			fmt.Printf("  commit: %s\n", r["commit"])
		}
		fmt.Printf("  resume: %s (not authorization)\n", r["resume_status"])
		if locations, ok := r["locations"].(map[string]any); ok {
			fmt.Printf("  candidate: %s; evidence: %s\n", locations["candidate"], locations["run_dir"])
		}
		if blockers, ok := r["blockers"].([]any); ok {
			for _, blocker := range blockers {
				fmt.Printf("  blocker: %v\n", blocker)
			}
		}
		if r["next_command"] != nil {
			fmt.Println(r["next_command"])
		}
		return true, 0
	}
	var runs []object
	if kind == "complete" {
		var m map[string][]object
		if localJSON(filepath.Join(c["root"].(string), ".kogen/local/completion.json"), &m) == nil {
			for _, r := range m[pos[0]] {
				if validRun(r) && r["checkout_id"] == c["id"] {
					runs = append(runs, r)
				}
				if len(runs) == 100 {
					break
				}
			}
		}
	} else {
		var e error
		runs, e = catalog(c)
		if e != nil {
			return true, response(kind, c, nil, "local_data_invalid", 3)
		}
	}
	packages := []object{}
	// Run operations use only the fixed-size candidate index, never package bodies.
	if kind != "complete" || (pos[0] != "resume" && pos[0] != "inspect" && pos[0] != "recover") {
		packages = packageRows(c)
	}
	if kind == "complete" {
		return true, completeCandidates(pos[0], packages, runs)
	}
	rows := append(packages, runs...)
	items, next, e := pageRows(rows, limit, cursor)
	if e != nil {
		return true, response(kind, c, nil, "invalid_argument", 2)
	}
	for _, r := range items {
		if r["type"] == "build" {
			observe(c, r)
		}
	}
	if jsonMode {
		return true, response(kind, c, object{"items": items, "next_cursor": next}, "", 0)
	}
	for _, r := range items {
		if r["type"] == "intent" {
			fmt.Printf("intent %s · package %s · approval %s\n", r["slug"], r["package_state"], r["approval_state"])
		} else {
			fmt.Printf("build %s %s · %s\n", r["slug"], r["run_id"], r["state"])
		}
	}
	return true, 0
}
func pageRows(rows []object, limit int, cursor string) ([]object, any, error) {
	if limit < 1 || limit > 100 {
		return nil, nil, fmt.Errorf("invalid limit")
	}
	sort.Slice(rows, func(i, j int) bool {
		a, b := rows[i], rows[j]
		if a["slug"] != b["slug"] {
			return fmt.Sprint(a["slug"]) < fmt.Sprint(b["slug"])
		}
		if a["type"] != b["type"] {
			return a["type"] == "intent"
		}
		if fmt.Sprint(a["started_at"]) != fmt.Sprint(b["started_at"]) {
			return fmt.Sprint(a["started_at"]) > fmt.Sprint(b["started_at"])
		}
		return fmt.Sprint(a["run_id"]) < fmt.Sprint(b["run_id"])
	})
	bytes, _ := json.Marshal(rows)
	digest := fmt.Sprintf("%x", sha256.Sum256(bytes))
	start := 0
	if cursor != "" {
		b, e := base64.RawURLEncoding.DecodeString(cursor)
		parts := strings.Split(string(b), ":")
		if e != nil || len(parts) != 2 || parts[0] != digest {
			return nil, nil, fmt.Errorf("invalid cursor")
		}
		start, e = strconv.Atoi(parts[1])
		if e != nil || start < 1 || start >= len(rows) {
			return nil, nil, fmt.Errorf("invalid cursor")
		}
	}
	end := start + limit
	if end > len(rows) {
		end = len(rows)
	}
	var next any
	if end < len(rows) {
		next = base64.RawURLEncoding.EncodeToString([]byte(fmt.Sprintf("%s:%d", digest, end)))
	}
	return rows[start:end], next, nil
}
func packageRows(c object) []object {
	rows := []object{}
	root := c["root"].(string)
	entries, _ := os.ReadDir(filepath.Join(root, ".kogen/intents"))
	for _, entry := range entries {
		if !entry.IsDir() || !slugRe.MatchString(entry.Name()) {
			continue
		}
		if _, e := os.Stat(filepath.Join(root, ".kogen/intents", entry.Name(), "intent.md")); e != nil {
			continue
		}
		approval := "absent"
		state := "unknown"
		var a, summary object
		current := ""
		if localJSON(filepath.Join(root, ".kogen/local/packages", entry.Name()+".json"), &summary) == nil {
			if paths, ok := summary["paths"].([]any); ok && summary["checkout_id"] == c["id"] {
				var text strings.Builder
				for _, p := range paths {
					path, ok := p.(string)
					if !ok || filepath.IsAbs(path) || path == ".." || strings.HasPrefix(filepath.Clean(path), "../") {
						text.Reset()
						break
					}
					bytes, e := os.ReadFile(filepath.Join(root, path))
					digest := "missing"
					if e == nil {
						digest = fmt.Sprintf("%x", sha256.Sum256(bytes))
					}
					fmt.Fprintf(&text, "%s%c%s\n", path, 0, digest)
				}
				current = fmt.Sprintf("%x", sha256.Sum256([]byte(text.String())))
				if current == summary["sha256"] {
					state, _ = summary["package_state"].(string)
					if state == "" {
						state = "unknown"
					}
				}
			}
		}
		if e := localJSON(filepath.Join(root, ".kogen/local/approvals", entry.Name()+".json"), &a); !os.IsNotExist(e) {
			approval = "unknown"
			if current != "" && a != nil {
				approval = "changed"
				if current == a["sha256"] {
					approval = "current"
				}
			}
		}
		rows = append(rows, object{"type": "intent", "slug": entry.Name(), "package_state": state, "approval_state": approval})
	}
	return rows
}
func completeCandidates(op string, packages, runs []object) int {
	candidates := []object{}
	if op == "resume" || op == "inspect" || op == "recover" {
		for _, r := range runs {
			if op == "recover" && r["state"] != "build_blocked" {
				continue
			}
			if op == "resume" && (r["resume_status"] == "unsupported" || r["state"] == "landed") {
				continue
			}
			candidates = append(candidates, object{"value": r["run_id"], "description": fmt.Sprint(r["slug"]) + " " + fmt.Sprint(r["state"])})
		}
	} else if contains([]string{"build", "approve", "refine", "preflight"}, op) {
		for _, p := range packages {
			if op == "refine" && p["package_state"] != "valid" {
				continue
			}
			candidates = append(candidates, object{"value": p["slug"], "description": p["approval_state"], "priority": candidatePriority(op, p)})
		}
	}
	sort.Slice(candidates, func(i, j int) bool {
		if candidates[i]["priority"] != candidates[j]["priority"] {
			return fmt.Sprint(candidates[i]["priority"]) < fmt.Sprint(candidates[j]["priority"])
		}
		return fmt.Sprint(candidates[i]["value"]) < fmt.Sprint(candidates[j]["value"])
	})
	if len(candidates) > 100 {
		candidates = candidates[:100]
	}
	for _, r := range candidates {
		fmt.Printf("%s\t%s\n", r["value"], r["description"])
	}
	return 0
}

func candidatePriority(op string, p object) int {
	if op == "build" && p["approval_state"] == "current" {
		return 0
	}
	if op == "approve" && (p["approval_state"] == "absent" || p["approval_state"] == "changed") {
		return 0
	}
	return 1
}

const zshCompletion = `#compdef kogen
_kogen() {
  local -a candidates positionals options
  local project="" op="" word i skip=0 endopts=0
  if (( CURRENT == 2 )); then
    compadd init intent context completion provider uninstall version help
    return
  fi
  if [[ $words[2] == intent ]] && (( CURRENT == 3 )); then
    compadd shape refine approve build resume recover list inspect preflight usage
    return
  fi
  if [[ $words[CURRENT-1] == --project ]]; then _directories; return; fi
  if [[ $words[CURRENT-1] == --output ]]; then _directories; return; fi
  if [[ $words[CURRENT-1] == --context ]]; then _files; return; fi
  case $words[2] in
    context) options=(--project --json --help) ;;
    completion) compadd zsh; return ;;
    provider)
      if (( CURRENT == 3 )); then compadd login list
      elif [[ $words[3] == login ]]; then compadd chatgpt supergrok opencode-go anthropic; fi
      return ;;
    intent)
      op=$words[3]
      options=(--project --help)
      if [[ $op == usage ]]; then options+=(--json --lineage --limit --slug --phase --role --model --effective-model --effort --effective-effort --outcome --pass --repair --since --until --group-by); fi
      case $op in
        build) options+=(--context) ;;
        recover) options+=(--output) ;;
        approve) options+=(--by) ;;
        list) options+=(--json --limit --cursor) ;;
        inspect|preflight) options+=(--json) ;;
      esac ;;
    *) options=(--help) ;;
  esac
  if [[ $PREFIX == --* ]]; then compadd -- $options; return; fi
  [[ $words[2] == intent ]] || return
  for ((i=4;i<CURRENT;i++)); do
    word=$words[i]
    if (( skip )); then skip=0; continue; fi
    if (( endopts )); then positionals+=("$word"); continue; fi
    case $word in
      --project) project=$words[i+1]; skip=1 ;;
      --project=*) project=${word#--project=} ;;
      --output|--context|--by|--limit|--cursor) skip=1 ;;
      --) endopts=1 ;;
      --*) ;;
      *) positionals+=("$word") ;;
    esac
  done
  if (( $#positionals == 0 )) && [[ $op == (build|approve|refine|preflight|inspect|resume|recover) ]]; then
    if [[ -n $project ]]; then
      candidates=("${(@f)$(kogen __complete $op --project "$project")}")
    else
      candidates=("${(@f)$(kogen __complete $op)}")
    fi
    candidates=("${candidates[@]%%$'\t'*}")
    compadd -a candidates
  elif [[ $op == shape && $#positionals == 1 || $op == refine && $#positionals == 2 ]]; then
    _files
  fi
}
compdef _kogen kogen
`
