// Package project reads and writes what Kogen keeps about a project: `.kogen/project.yaml`
// (commands, protected paths, models), Gherkin features, Intent packages with their baseline
// hash and approvals, and the command detection `kogen init` starts from. It holds data and
// files only; the one Git it runs is `git check-ignore` and `git ls-files`.
package project

import (
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"strconv"
	"strings"

	"kogen-loop/sys"
)

// ConfigPath is the project configuration, relative to the repository root.
const ConfigPath = ".kogen/project.yaml"

// Role is one model selection. Provider "" means the role names no provider (legacy ChatGPT).
// BaseURL is set only for the openai-compatible provider (the host's /v1 base); it is
// omitted from JSON when empty so existing checkpoints keep their bytes.
//
// Executor and MaxRounds may be set on each of the shape, build and review roles
// (docs/executor-contract.md): Executor is "" for the native role (also when the file says
// `executor: native`) or "claude-code"; MaxRounds is claude-code's round cap for that role,
// 0 when the file sets none (the default, DefaultExternalRounds, applies). Both are omitted from JSON
// when empty for the same reason.
type Role struct {
	Provider, Model, Effort string
	BaseURL                 string `json:",omitempty"`
	Executor                string `json:",omitempty"`
	MaxRounds               int    `json:",omitempty"`
}

// DefaultExternalRounds is the round cap of an external role that sets no max_rounds.
const DefaultExternalRounds = 6

// Executor names a role may select (the native one is the empty Executor).
const (
	ExecutorNative     = "native"
	ExecutorClaudeCode = "claude-code"
)

// External reports whether the role is served by an external executor instead of Kogen's own
// provider-backed builder.
func (r Role) External() bool { return r.Executor != "" && r.Executor != ExecutorNative }

// Check is a project check: a unique lowercase name and its command.
type Check struct{ Name, Run string }

// Acceptance is the acceptance command and the folder shaping writes step files to
// (`commands.acceptance`). Either may be empty while it is not configured.
type Acceptance struct{ Run, StepsDir string }

// Workers is `shape_workers`: whether the shaper may use workers and their roles
// ("read", "probe", "draft").
type Workers struct {
	Enabled bool
	Roles   map[string]Role
}

// Config is a validated `.kogen/project.yaml` (SET-8).
type Config struct {
	Setup, Fix   []string
	Checks       []Check
	Acceptance   *Acceptance // nil when neither run nor steps_dir is set
	Protect      []string
	Models       map[string]Role // "shape", "build", "review"; defaults where the file says nothing
	ShapeWorkers Workers
}

// ModelRoles lists the model roles in the order the template writes them.
var ModelRoles = [...]string{"shape", "build", "review"}

// DefaultModels returns the per-role defaults (SET-8); the template is derived from it.
func DefaultModels() map[string]Role {
	return map[string]Role{
		"shape":  {Model: "gpt-6.1-sol", Effort: "high"},
		"build":  {Model: "gpt-6.1-sol", Effort: "medium"},
		"review": {Model: "gpt-6.1-sol", Effort: "high"},
	}
}

// AcceptanceConfigured reports whether both the acceptance command and the steps folder are set.
func (c *Config) AcceptanceConfigured() bool {
	return c.Acceptance != nil && c.Acceptance.Run != "" && c.Acceptance.StepsDir != ""
}

// NamedCommand is a configured command with the name Kogen reports it under.
type NamedCommand struct{ Name, Run string }

// NamedCommands lists every configured command in the order Kogen runs them (SET-8).
func (c *Config) NamedCommands() []NamedCommand {
	var out []NamedCommand
	for i, cmd := range c.Setup {
		out = append(out, NamedCommand{fmt.Sprintf("setup-%d", i+1), cmd})
	}
	for i, cmd := range c.Fix {
		out = append(out, NamedCommand{fmt.Sprintf("fix-%d", i+1), cmd})
	}
	for _, ch := range c.Checks {
		out = append(out, NamedCommand{ch.Name, ch.Run})
	}
	if c.Acceptance != nil && c.Acceptance.Run != "" {
		out = append(out, NamedCommand{"acceptance", c.Acceptance.Run})
	}
	return out
}

// LoadConfig reads and validates the configuration of an initialized project: errors are
// environment/not_initialized, environment/old_kogen_config and environment/project_config_invalid.
func LoadConfig(root string) (*Config, error) {
	file := filepath.Join(root, ConfigPath)
	b, err := os.ReadFile(file)
	if err != nil {
		return nil, sys.Fail("environment", "not_initialized", root+" has no .kogen/project.yaml; run kogen init", 3)
	}
	return ParseConfig(string(b), file)
}

// ParseConfig validates configuration text; file names it in errors.
func ParseConfig(text, file string) (*Config, error) {
	var cfg *Config
	var problems []problem
	node, probs := parseYAML(text)
	switch {
	case probs != nil:
		problems = probs
	case node.kind == kindMap:
		hasVersion := false
		for _, p := range node.pairs {
			hasVersion = hasVersion || p.key == "version"
		}
		if !hasVersion {
			return nil, sys.Fail("environment", "old_kogen_config", ".kogen/ is from an earlier Kogen; move it aside (git mv .kogen .kogen-old), commit, and run kogen init", 3)
		}
		cfg, problems = validateConfig(node)
	default:
		cfg, problems = validateConfig(node)
	}
	if len(problems) > 0 {
		sort.SliceStable(problems, func(i, j int) bool {
			if problems[i].line != problems[j].line {
				return problems[i].line < problems[j].line
			}
			return problems[i].msg < problems[j].msg
		})
		e := sys.Fail("environment", "project_config_invalid", file, 3)
		for _, p := range problems {
			e.Lines = append(e.Lines, fmt.Sprintf("line %d: %s", p.line, p.msg))
		}
		return nil, e
	}
	return cfg, nil
}

type validator struct{ problems []problem }

func (v *validator) add(line int, msg string) { v.problems = append(v.problems, problem{line, msg}) }

var (
	checkNameRe = regexp.MustCompile(`^[a-z0-9]+(-[a-z0-9]+)*$`)
	notStringRe = regexp.MustCompile(`^(true|false|True|False|TRUE|FALSE|[-+]?[0-9][0-9._]*(e[-+]?[0-9]+)?)$`)
)

func validateConfig(node *yamlNode) (*Config, []problem) {
	if node.kind != kindMap {
		return nil, []problem{{node.line, "the file must be a mapping"}}
	}
	v := &validator{}
	c := &Config{Models: DefaultModels(), ShapeWorkers: Workers{Roles: map[string]Role{}}}
	for _, p := range node.pairs {
		switch p.key {
		case "version":
			if !(p.node.kind == kindScalar && !p.node.null && !p.node.quoted && p.node.text == "1") {
				v.add(p.line, "version must be 1")
			}
		case "commands":
			v.commands(p.node, c)
		case "protect":
			c.Protect = v.strings(p.node, "protect")
		case "shape_workers":
			c.ShapeWorkers = v.workers(p.node)
		case "models":
			c.Models = v.models(p.node)
		default:
			v.add(p.line, "unknown key "+p.key)
		}
	}
	return c, v.problems
}

func (v *validator) commands(node *yamlNode, c *Config) {
	if node.kind != kindMap {
		v.add(node.line, "commands must be a mapping")
		return
	}
	for _, p := range node.pairs {
		switch p.key {
		case "setup":
			c.Setup = v.strings(p.node, "commands.setup")
		case "fix":
			c.Fix = v.strings(p.node, "commands.fix")
		case "checks":
			c.Checks = v.checks(p.node)
		case "acceptance":
			v.acceptance(p.node, c)
		default:
			v.add(p.line, "unknown key "+p.key)
		}
	}
}

func (v *validator) acceptance(node *yamlNode, c *Config) {
	if node.kind != kindMap {
		v.add(node.line, "commands.acceptance must be a mapping")
		return
	}
	for _, p := range node.pairs {
		if p.key != "run" && p.key != "steps_dir" {
			v.add(p.line, "unknown key "+p.key)
			continue
		}
		n := p.node
		if n.kind != kindScalar || (!n.null && !isString(n)) {
			v.add(p.line, "commands.acceptance."+p.key+" must be a string or null")
			continue
		}
		if n.null {
			continue
		}
		if c.Acceptance == nil {
			c.Acceptance = &Acceptance{}
		}
		if p.key == "run" {
			c.Acceptance.Run = n.text
		} else {
			c.Acceptance.StepsDir = strings.TrimRight(n.text, "/")
		}
	}
}

func (v *validator) checks(node *yamlNode) []Check {
	if node.kind != kindSeq {
		v.add(node.line, "commands.checks must be a list")
		return nil
	}
	var list []Check
	for _, item := range node.items {
		if item.kind != kindMap {
			v.add(item.line, "a check must be {name, run}")
			continue
		}
		unknown := false
		for _, p := range item.pairs {
			if p.key != "name" && p.key != "run" {
				v.add(p.line, "unknown key "+p.key)
				unknown = true
			}
		}
		if unknown {
			continue
		}
		name, okName := stringAt(item.pairs, "name")
		run, okRun := stringAt(item.pairs, "run")
		switch {
		case !okName || !okRun:
			v.add(item.line, "a check needs a name and a run string")
		case name == "acceptance" || name == "model":
			v.add(item.line, "check name "+name+" is reserved")
		case !checkNameRe.MatchString(name):
			v.add(item.line, "check name "+name+" must be lowercase")
		case hasCheck(list, name):
			v.add(item.line, "check name "+name+" is used twice")
		default:
			list = append(list, Check{name, run})
		}
	}
	return list
}

func hasCheck(list []Check, name string) bool {
	for _, c := range list {
		if c.Name == name {
			return true
		}
	}
	return false
}

func (v *validator) models(node *yamlNode) map[string]Role {
	roles := DefaultModels()
	if node.kind != kindMap {
		v.add(node.line, "models must be a mapping")
		return roles
	}
	for _, p := range node.pairs {
		// Older project files may retain a planner model. It is ignored: building starts
		// directly and never issues a separate planning request.
		if p.key == "plan" {
			continue
		}
		if _, known := roles[p.key]; !known {
			v.add(p.line, "unknown key "+p.key)
			continue
		}
		rest, exec, rounds, ok := v.executorKeys(p)
		if !ok {
			continue
		}
		if exec == ExecutorClaudeCode {
			if r, ok := v.externalRole(rest, "models."+p.key, p.line); ok {
				r.Executor, r.MaxRounds = exec, rounds
				roles[p.key] = r
			}
			continue
		}
		m, e, ok := modelEffort(rest, false)
		if !ok {
			v.add(p.line, "models."+p.key+" must be {model, effort}")
			continue
		}
		if r, ok := v.roleConfig(rest.pairs, "models."+p.key, p.line, m, e); ok {
			roles[p.key] = r
		}
	}
	return roles
}

// maxRoundsRe is a positive decimal integer as the configuration spells it.
var maxRoundsRe = regexp.MustCompile(`^[1-9][0-9]{0,8}$`)

// executorKeys separates the `executor` and `max_rounds` keys of a models role from the rest
// of its mapping (docs/executor-contract.md section 5). They are valid for the shape, build
// and review roles independently; max_rounds only with executor claude-code. ok is false when the role must be skipped
// (a problem was reported). rest is the mapping without the two keys.
func (v *validator) executorKeys(p yamlPair) (rest *yamlNode, exec string, rounds int, ok bool) {
	rest = p.node
	if p.node.kind != kindMap {
		return rest, "", 0, true
	}
	var execPair, roundsPair *yamlPair
	var kept []yamlPair
	for i := range p.node.pairs {
		switch p.node.pairs[i].key {
		case "executor":
			execPair = &p.node.pairs[i]
		case "max_rounds":
			roundsPair = &p.node.pairs[i]
		default:
			kept = append(kept, p.node.pairs[i])
		}
	}
	if execPair == nil && roundsPair == nil {
		return rest, "", 0, true
	}
	path := "models." + p.key
	copied := *p.node
	copied.pairs = kept
	rest = &copied
	ok = true
	if execPair != nil {
		n := execPair.node
		if n.kind == kindScalar && !n.null && isString(n) && (n.text == ExecutorNative || n.text == ExecutorClaudeCode) {
			if n.text == ExecutorClaudeCode {
				exec = ExecutorClaudeCode
			}
		} else {
			v.add(execPair.line, path+".executor must be native or claude-code")
			ok = false
		}
	}
	if roundsPair != nil {
		n := roundsPair.node
		switch {
		case !(n.kind == kindScalar && !n.null && !n.quoted && maxRoundsRe.MatchString(n.text)):
			v.add(roundsPair.line, path+".max_rounds must be a positive integer")
			ok = false
		case exec != ExecutorClaudeCode:
			v.add(roundsPair.line, path+".max_rounds is only for executor claude-code")
			ok = false
		default:
			rounds, _ = strconv.Atoi(n.text)
		}
	}
	return rest, exec, rounds, ok
}

// externalRole is a role served by an external executor: Kogen's provider keys do not apply
// (the executor uses its own sign-in), model and effort are required and passed through.
func (v *validator) externalRole(node *yamlNode, path string, line int) (Role, bool) {
	good := true
	for _, p := range node.pairs {
		if p.key == "provider" || p.key == "base_url" {
			v.add(p.line, path+"."+p.key+" is not allowed with executor claude-code")
			good = false
		}
	}
	if !good {
		return Role{}, false
	}
	m, e, ok := modelEffort(node, true)
	if !ok {
		v.add(line, path+" with executor claude-code must be {model, effort} non-blank strings")
		return Role{}, false
	}
	if !v.checkEffort(node.pairs, path, line, ExecutorClaudeCode, e) {
		return Role{}, false
	}
	return Role{Model: m, Effort: e}, true
}

// effortLists are the efforts known per route, exact and case-sensitive. Routes without an
// entry pass any effort through, except ultra, which no route lists.
var effortLists = map[string][]string{
	"anthropic":        {"low", "medium", "high", "xhigh", "max"},
	"supergrok":        {"low", "medium", "high", "xhigh"},
	ExecutorClaudeCode: {"low", "medium", "high", "xhigh", "max"},
}

// checkEffort rejects an effort the route does not accept, naming the line of the effort key.
func (v *validator) checkEffort(kv []yamlPair, path string, line int, route, effort string) bool {
	for _, p := range kv {
		if p.key == "effort" {
			line = p.line
		}
	}
	list, known := effortLists[route]
	if known && slices.Contains(list, effort) || !known && effort != "ultra" {
		return true
	}
	accepted := "any effort except ultra"
	if known {
		accepted = strings.Join(list, ", ")
	}
	v.add(line, fmt.Sprintf("%s.effort %q is not supported; accepted: %s", path, effort, accepted))
	return false
}

// modelEffort reads a role mapping: only model, effort, provider and base_url keys, model and
// effort strings (non-blank when nonBlank is set).
func modelEffort(node *yamlNode, nonBlank bool) (model, effort string, ok bool) {
	if node.kind != kindMap {
		return "", "", false
	}
	for _, p := range node.pairs {
		if p.key != "model" && p.key != "effort" && p.key != "provider" && p.key != "base_url" {
			return "", "", false
		}
	}
	m, okM := stringAt(node.pairs, "model")
	e, okE := stringAt(node.pairs, "effort")
	if !okM || !okE || (nonBlank && (strings.TrimSpace(m) == "" || strings.TrimSpace(e) == "")) {
		return "", "", false
	}
	return m, e, true
}

func (v *validator) workers(node *yamlNode) Workers {
	w := Workers{Roles: map[string]Role{}}
	if node.kind != kindMap {
		v.add(node.line, "shape_workers must be a mapping")
		return w
	}
	for _, p := range node.pairs {
		switch p.key {
		case "enabled":
			n := p.node
			if n.kind == kindScalar && !n.null && !n.quoted && (n.text == "true" || n.text == "false") {
				w.Enabled = n.text == "true"
			} else {
				v.add(p.line, "shape_workers.enabled must be a Boolean")
			}
		case "read", "probe", "draft":
			m, e, ok := modelEffort(p.node, true)
			if !ok {
				v.add(p.line, "shape_workers."+p.key+" must be {model, effort} strings")
				continue
			}
			if r, ok := v.roleConfig(p.node.pairs, "shape_workers."+p.key, p.line, m, e); ok {
				w.Roles[p.key] = r
			}
		default:
			v.add(p.line, "unknown key "+p.key)
		}
	}
	if w.Enabled {
		for _, role := range []string{"read", "probe", "draft"} {
			if _, ok := w.Roles[role]; !ok {
				v.add(node.line, "shape_workers."+role+" requires explicit model and effort")
			}
		}
	}
	return w
}

// Providers lists the values a role's provider may name, in the order messages list them.
var Providers = []string{"chatgpt", "supergrok", "opencode-go", "anthropic", "openai-compatible"}

// roleConfig applies the provider rules to a role mapping (KOGEN-057): the provider, when
// given, is one Kogen knows; any model and effort are accepted and sent unchanged (a named
// provider needs both non-blank). openai-compatible needs base_url, an http(s) URL; no other
// provider takes one. Known models are defaults and documentation hints, never validation.
func (v *validator) roleConfig(kv []yamlPair, path string, line int, model, effort string) (Role, bool) {
	provider, _ := stringAt(kv, "provider")
	present, hasBase := false, false
	for _, p := range kv {
		present = present || p.key == "provider"
		hasBase = hasBase || p.key == "base_url"
	}
	base, baseOK := stringAt(kv, "base_url")
	switch {
	case present && !slices.Contains(Providers, provider):
		v.add(line, path+".provider must be chatgpt, supergrok, opencode-go, anthropic or openai-compatible")
		return Role{}, false
	case present && provider != "chatgpt" && (strings.TrimSpace(model) == "" || strings.TrimSpace(effort) == ""):
		v.add(line, path+" must be {model, effort}")
		return Role{}, false
	case hasBase && provider != "openai-compatible":
		v.add(line, path+".base_url is only for provider openai-compatible")
		return Role{}, false
	case provider == "openai-compatible" && !hasBase:
		v.add(line, path+": openai-compatible needs base_url, for example http://localhost:11434/v1")
		return Role{}, false
	case provider == "openai-compatible" && (!baseOK || !validBaseURL(base)):
		v.add(line, path+".base_url must be an http:// or https:// URL")
		return Role{}, false
	}
	if !v.checkEffort(kv, path, line, provider, effort) {
		return Role{}, false
	}
	r := Role{Model: model, Effort: effort}
	if present {
		r.Provider = provider
	}
	if provider == "openai-compatible" {
		r.BaseURL = strings.TrimRight(base, "/")
	}
	return r, true
}

// validBaseURL is an absolute http or https URL with a host and no query or fragment.
func validBaseURL(s string) bool {
	u, err := url.Parse(s)
	return err == nil && (u.Scheme == "http" || u.Scheme == "https") && u.Host != "" &&
		u.RawQuery == "" && u.Fragment == "" && u.User == nil && !strings.ContainsAny(s, " \t\r\n")
}

func (v *validator) strings(node *yamlNode, name string) []string {
	if node.kind != kindSeq {
		v.add(node.line, name+" must be a list")
		return nil
	}
	var list []string
	for _, item := range node.items {
		if item.kind == kindScalar && !item.null && isString(item) {
			list = append(list, item.text)
		} else {
			v.add(item.line, name+" entries must be strings")
		}
	}
	return list
}

// stringAt is the string value of key in pairs, when there is one: a plain true, false or number
// is not a string (quote it to use it as one).
func stringAt(pairs []yamlPair, key string) (string, bool) {
	for _, p := range pairs {
		if p.key == key {
			if p.node.kind == kindScalar && !p.node.null && isString(p.node) {
				return p.node.text, true
			}
			return "", false
		}
	}
	return "", false
}

func isString(n *yamlNode) bool { return n.quoted || !notStringRe.MatchString(n.text) }
