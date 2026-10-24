package project

import (
	"encoding/json"
	"slices"
	"strings"
)

// Detected is what Detect found: the commands `init` starts from (SET-10).
type Detected struct {
	Setup, Fix []string
	Checks     []Check
	Protect    []string
	// Runner is the steps folder of an existing Cucumber runner, or "".
	Runner string
}

const (
	npmCI          = "npm ci --no-audit --no-fund"
	npmPlaceholder = `echo "Error: no test specified" && exit 1`
)

var npmScripts = []string{"test", "lint", "typecheck", "check"}

// Detect finds the project's commands deterministically from its committed root files (SET-10).
// files maps root file names to their committed text (absent when the file is); tracked lists
// every tracked path.
func Detect(files map[string]string, tracked []string) Detected {
	var d Detected
	if mix, ok := files["mix.exs"]; ok {
		detectMix(&d, mix, tracked)
	}
	if pkg := packageJSON(files); pkg != nil {
		detectNpm(&d, pkg, tracked)
	}
	detectGo(&d, files, tracked)
	return d
}

func detectMix(d *Detected, mix string, tracked []string) {
	formatter := slices.Contains(tracked, ".formatter.exs")
	credo := strings.Contains(mix, ":credo")
	d.Setup = append(d.Setup, "mix deps.get")
	if formatter {
		d.Fix = append(d.Fix, "mix format")
		d.Checks = append(d.Checks, Check{"format", "mix format --check-formatted"})
	}
	d.Checks = append(d.Checks, Check{"compile", "mix compile --warnings-as-errors"}, Check{"test", "mix test"})
	if credo {
		d.Checks = append(d.Checks, Check{"credo", "mix credo --strict"})
	}
	if formatter {
		d.Protect = append(d.Protect, ".formatter.exs")
	}
	if credo && slices.Contains(tracked, ".credo.exs") {
		d.Protect = append(d.Protect, ".credo.exs")
	}
}

func packageJSON(files map[string]string) map[string]any {
	text, ok := files["package.json"]
	if !ok {
		return nil
	}
	var m map[string]any
	if json.Unmarshal([]byte(text), &m) != nil {
		return nil
	}
	return m
}

func objectAt(m map[string]any, key string) map[string]any {
	o, _ := m[key].(map[string]any)
	return o
}

func detectNpm(d *Detected, pkg map[string]any, tracked []string) {
	scripts := objectAt(pkg, "scripts")
	for _, script := range npmScripts {
		body, ok := scripts[script].(string)
		if !ok || strings.TrimSpace(body) == npmPlaceholder {
			continue
		}
		name := script
		if slices.ContainsFunc(d.Checks, func(c Check) bool { return c.Name == script }) {
			name = "npm-" + script
		}
		d.Checks = append(d.Checks, Check{name, "npm run " + script})
	}
	_, prod := objectAt(pkg, "dependencies")["@cucumber/cucumber"]
	_, dev := objectAt(pkg, "devDependencies")["@cucumber/cucumber"]
	d.Runner = ""
	if prod || dev {
		d.Runner = "features/steps"
		for _, dir := range []string{"features/steps", "features/step_definitions"} {
			if slices.ContainsFunc(tracked, func(p string) bool { return strings.HasPrefix(p, dir+"/") }) {
				d.Runner = dir
				break
			}
		}
	}
	if slices.Contains(tracked, "package-lock.json") {
		d.Setup = append(d.Setup, npmCI)
	}
}

// detectGo handles the two supported layouts, `go.mod` and `cli/go.mod`, not arbitrary nested-module
// discovery.
func detectGo(d *Detected, files map[string]string, tracked []string) {
	var modules []string
	for _, m := range []string{"go.mod", "cli/go.mod"} {
		if _, ok := files[m]; ok && slices.Contains(tracked, m) {
			modules = append(modules, m)
		}
	}
	for _, manifest := range modules {
		nested := manifest == "cli/go.mod"
		command := func(run string) string {
			if nested {
				return "(cd cli && " + run + ")"
			}
			return run
		}
		prefix := "go"
		if len(modules) > 1 {
			prefix = "go-root"
			if nested {
				prefix = "go-cli"
			}
		}
		d.Setup = append(d.Setup, command("go mod download"))
		d.Checks = append(d.Checks,
			Check{prefix + "-format", command(`test -z "$(gofmt -l .)"`)},
			Check{prefix + "-test", command("go test ./...")},
			Check{prefix + "-vet", command("go vet ./...")},
			Check{prefix + "-build", command("go build -o /dev/null ./...")},
		)
	}
}

// Runner says which Cucumber the acceptance command runs.
type Runner int

const (
	// ProjectRunner is the project's own Cucumber in node_modules.
	ProjectRunner Runner = iota
	// KogenRunner is the Cucumber Kogen ships (the acceptance bridge, SET-13).
	KogenRunner
)

// AcceptanceCommand is the acceptance command (SET-10, SET-13): the project's own Cucumber when it
// has one, else the one Kogen ships, whose node_modules also resolves the step files'
// `require('@cucumber/cucumber')`; both on Kogen's own Node.
func AcceptanceCommand(stepsDir string, runner Runner) string {
	args := `--strict --require '` + stepsDir + `/*.js' --format "message:$KOGEN_ACCEPTANCE_REPORT" "$KOGEN_ACCEPTANCE_FEATURES"`
	if runner == ProjectRunner {
		return `"$KOGEN_NODE" node_modules/@cucumber/cucumber/bin/cucumber.js ` + args
	}
	return `NODE_PATH="$KOGEN_CUCUMBER" "$KOGEN_NODE" "$KOGEN_CUCUMBER/@cucumber/cucumber/bin/cucumber.js" ` + args
}
