package project

import (
	"strings"
)

// Template is the configuration `kogen init` writes before it keeps any detected command (SET-8):
// every list empty, acceptance null, the default model per role.
func Template() string {
	var b strings.Builder
	b.WriteString(templateHead)
	d := DefaultModels()
	for _, role := range ModelRoles {
		b.WriteString("  " + role + ":\n    model: " + d[role].Model + "\n    effort: " + d[role].Effort + "\n")
	}
	return b.String()
}

const templateHead = `version: 1
commands:
  setup: []          # run before readiness dry runs and before each Build
  fix: []            # deterministic fixers, run once after each builder round
  checks: []         # project checks, e.g. {name: test, run: "mix test"}
  acceptance:
    run: null        # the acceptance command (VER-3)
    steps_dir: null  # where shaping writes step-definition files
protect: []          # check configuration the Build must not change, e.g. .credo.exs
models:
`

// templateLine is the template's own line for key: the empty value with its comment.
func templateLine(key string) string {
	for _, l := range strings.Split(templateHead, "\n") {
		if strings.HasPrefix(l, key) {
			return l
		}
	}
	return ""
}

// RenderConfig is the template with the commands `init` kept (SET-2): the setup, fix, checks,
// protect and acceptance fields of c are written; models keep their defaults.
func RenderConfig(c *Config) string {
	lines := []string{"version: 1", "commands:"}
	list := func(key string, items []string) {
		if len(items) == 0 {
			lines = append(lines, templateLine(key))
			return
		}
		lines = append(lines, strings.TrimRight(key, " "))
		for _, it := range items {
			lines = append(lines, "    - "+it)
		}
	}
	quoted := func(ss []string) []string {
		out := make([]string, len(ss))
		for i, s := range ss {
			out[i] = yamlQuote(s)
		}
		return out
	}
	list("  setup:", quoted(c.Setup))
	list("  fix:", quoted(c.Fix))
	checks := make([]string, len(c.Checks))
	for i, ch := range c.Checks {
		checks[i] = "name: " + ch.Name + "\n      run: " + yamlQuote(ch.Run)
	}
	list("  checks:", checks)
	lines = append(lines, "  acceptance:")
	if a := c.Acceptance; a != nil {
		lines = append(lines, "    run: "+yamlQuote(a.Run), "    steps_dir: "+yamlQuote(a.StepsDir))
	} else {
		lines = append(lines, templateLine("    run:"), templateLine("    steps_dir:"))
	}
	if len(c.Protect) == 0 {
		lines = append(lines, templateLine("protect:"))
	} else {
		lines = append(lines, "protect:\n"+strings.Join(prefixed("  - ", quoted(c.Protect)), "\n"))
	}
	lines = append(lines, "models:")
	_, models, _ := strings.Cut(Template(), "models:\n")
	return strings.Join(lines, "\n") + "\n" + models
}

func prefixed(prefix string, ss []string) []string {
	out := make([]string, len(ss))
	for i, s := range ss {
		out[i] = prefix + s
	}
	return out
}

// yamlQuote is a YAML single-quoted scalar: the only escape is ” for '.
func yamlQuote(s string) string { return "'" + strings.ReplaceAll(s, "'", "''") + "'" }
