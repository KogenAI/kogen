package project

import (
	"encoding/json"
	"slices"
	"strings"
	"testing"
)

func checkNames(d Detected) []string {
	var out []string
	for _, c := range d.Checks {
		out = append(out, c.Name)
	}
	return out
}

func TestDetectGoModules(t *testing.T) {
	// ExUnit: SET-10: root and cli Go modules get real Go checks without protecting manifests
	for _, path := range []string{"go.mod", "cli/go.mod"} {
		d := Detect(map[string]string{path: "module example.invalid/app\n\ngo 1.27\n"}, []string{path})
		if !slices.Equal(checkNames(d), []string{"go-format", "go-test", "go-vet", "go-build"}) {
			t.Errorf("%s checks %v", path, checkNames(d))
		}
		if !slices.ContainsFunc(d.Setup, func(s string) bool { return strings.Contains(s, "go mod download") }) {
			t.Errorf("%s setup %v", path, d.Setup)
		}
		if !slices.ContainsFunc(d.Checks, func(c Check) bool { return strings.Contains(c.Run, "go test ./...") }) {
			t.Errorf("%s has no go test check", path)
		}
		if len(d.Protect) != 0 {
			t.Errorf("%s protects %v", path, d.Protect)
		}
		for _, c := range d.Checks {
			if strings.Contains(c.Run, "cd cli") && path != "cli/go.mod" {
				t.Errorf("%s: %q changes into cli", path, c.Run)
			}
			if path == "cli/go.mod" && !strings.HasPrefix(c.Run, "(cd cli && ") {
				t.Errorf("%s: %q does not run in cli", path, c.Run)
			}
		}
	}
	both := Detect(map[string]string{"go.mod": "module root", "cli/go.mod": "module cli"}, []string{"go.mod", "cli/go.mod"})
	names := checkNames(both)
	if len(names) != 8 || len(slices.Compact(slices.Sorted(slices.Values(names)))) != 8 {
		t.Errorf("both modules: %v", names)
	}
	if names[0] != "go-root-format" || names[4] != "go-cli-format" {
		t.Errorf("both modules order: %v", names)
	}
	if !slices.Equal(both.Setup, []string{"go mod download", "(cd cli && go mod download)"}) {
		t.Errorf("both modules setup: %v", both.Setup)
	}
	want := []Check{
		{"go-format", `test -z "$(gofmt -l .)"`},
		{"go-test", "go test ./..."},
		{"go-vet", "go vet ./..."},
		{"go-build", "go build -o /dev/null ./..."},
	}
	if got := Detect(map[string]string{"go.mod": "m"}, []string{"go.mod"}).Checks; !slices.Equal(got, want) {
		t.Errorf("root checks %v", got)
	}
}

func TestDetectGoNeedsTrackedManifest(t *testing.T) {
	if d := Detect(map[string]string{"go.mod": "module x"}, nil); len(d.Checks) != 0 || len(d.Setup) != 0 {
		t.Errorf("an untracked go.mod was detected: %+v", d)
	}
	if d := Detect(nil, []string{"go.mod"}); len(d.Checks) != 0 {
		t.Errorf("a go.mod without text was detected: %+v", d)
	}
	d := Detect(map[string]string{"cli/go.mod": "m", "go.mod": "m"}, []string{"go.mod"})
	if !slices.Equal(checkNames(d), []string{"go-format", "go-test", "go-vet", "go-build"}) {
		t.Errorf("only the tracked module counts: %v", checkNames(d))
	}
}

func TestDetectMixWithFormatterAndCredo(t *testing.T) {
	// ExUnit: SET-10: a Mix project with a formatter and credo gets setup, fixer, checks and protect
	mix := `defp deps, do: [{:credo, "~> 1.7", only: :test}]`
	d := Detect(map[string]string{"mix.exs": mix}, []string{"mix.exs", ".formatter.exs", ".credo.exs", "lib/a.ex"})
	if !slices.Equal(d.Setup, []string{"mix deps.get"}) || !slices.Equal(d.Fix, []string{"mix format"}) {
		t.Errorf("setup/fix %v %v", d.Setup, d.Fix)
	}
	if !slices.Equal(checkNames(d), []string{"format", "compile", "test", "credo"}) {
		t.Errorf("checks %v", checkNames(d))
	}
	if !slices.Equal(d.Protect, []string{".formatter.exs", ".credo.exs"}) || d.Runner != "" {
		t.Errorf("protect/runner %v %q", d.Protect, d.Runner)
	}
	if d.Checks[0].Run != "mix format --check-formatted" || d.Checks[3].Run != "mix credo --strict" {
		t.Errorf("commands %v", d.Checks)
	}
	// credo without .credo.exs protects only the formatter settings; no formatter, no fixer.
	d = Detect(map[string]string{"mix.exs": mix}, []string{"mix.exs"})
	if len(d.Protect) != 0 || len(d.Fix) != 0 || !slices.Equal(checkNames(d), []string{"compile", "test", "credo"}) {
		t.Errorf("credo only: %+v", d)
	}
}

func TestDetectMixWithoutFormatterOrCredo(t *testing.T) {
	// ExUnit: SET-10: a Mix project without .formatter.exs or credo gets compile and test only
	d := Detect(map[string]string{"mix.exs": "defmodule A.MixProject do end"}, []string{"mix.exs"})
	if len(d.Fix) != 0 {
		t.Errorf("fix %v", d.Fix)
	}
	want := []Check{{"compile", "mix compile --warnings-as-errors"}, {"test", "mix test"}}
	if !slices.Equal(d.Checks, want) || len(d.Protect) != 0 {
		t.Errorf("got %+v", d)
	}
}

func pkgJSON(t *testing.T, v any) string {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func TestDetectNpmScripts(t *testing.T) {
	// ExUnit: SET-10: npm scripts become checks, npm's placeholder test does not, a taken name is prefixed
	pkg := pkgJSON(t, map[string]any{"scripts": map[string]any{
		"test":  `echo "Error: no test specified" && exit 1`,
		"lint":  "eslint .",
		"build": "vite build",
	}})
	d := Detect(map[string]string{"package.json": pkg}, []string{"package.json", "package-lock.json"})
	if !slices.Equal(d.Setup, []string{"npm ci --no-audit --no-fund"}) {
		t.Errorf("setup %v", d.Setup)
	}
	if !slices.Equal(d.Checks, []Check{{"lint", "npm run lint"}}) {
		t.Errorf("checks %v", d.Checks)
	}
	both := Detect(map[string]string{
		"mix.exs":      "",
		"package.json": pkgJSON(t, map[string]any{"scripts": map[string]any{"test": "jest"}}),
	}, []string{"mix.exs", "package.json"})
	if !slices.Equal(checkNames(both), []string{"compile", "test", "npm-test"}) || !slices.Equal(both.Setup, []string{"mix deps.get"}) {
		t.Errorf("mix and npm: %+v", both)
	}
}

func TestDetectNpmEdgeCases(t *testing.T) {
	cases := []struct {
		name, pkg string
		want      []string
	}{
		{"all four scripts in order", pkgJSON(t, map[string]any{"scripts": map[string]any{"check": "c", "typecheck": "t", "lint": "l", "test": "x"}}), []string{"test", "lint", "typecheck", "check"}},
		{"placeholder with spaces", pkgJSON(t, map[string]any{"scripts": map[string]any{"test": `  echo "Error: no test specified" && exit 1  `}}), nil},
		{"scripts not an object", `{"scripts": "nope"}`, nil},
		{"script not a string", `{"scripts": {"test": 1, "lint": null}}`, nil},
		{"not json", "not json", nil},
		{"json array", "[1,2]", nil},
		{"empty file", "", nil},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			d := Detect(map[string]string{"package.json": c.pkg}, []string{"package.json"})
			if !slices.Equal(checkNames(d), c.want) {
				t.Errorf("checks %v, want %v", checkNames(d), c.want)
			}
		})
	}
}

func TestDetectCucumberRunner(t *testing.T) {
	// ExUnit: SET-10: an existing Cucumber runner and its steps folder are found
	pkg := pkgJSON(t, map[string]any{"devDependencies": map[string]any{"@cucumber/cucumber": "13.3.0"}})
	cases := []struct {
		name    string
		pkg     string
		tracked []string
		want    string
	}{
		{"step_definitions exists", pkg, []string{"package.json", "features/step_definitions/a.js"}, "features/step_definitions"},
		{"none exists", pkg, []string{"package.json"}, "features/steps"},
		{"steps wins when both exist", pkg, []string{"features/step_definitions/a.js", "features/steps/b.js"}, "features/steps"},
		{"a file is not a folder", pkg, []string{"features/steps.js"}, "features/steps"},
		{"dependencies count", pkgJSON(t, map[string]any{"dependencies": map[string]any{"@cucumber/cucumber": "1"}}), []string{"features/step_definitions/x.js"}, "features/step_definitions"},
		{"no cucumber", pkgJSON(t, map[string]any{"devDependencies": map[string]any{"jest": "1"}}), []string{"features/steps/x.js"}, ""},
		{"dependencies not objects", pkgJSON(t, map[string]any{"dependencies": "x", "devDependencies": []any{}}), nil, ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := Detect(map[string]string{"package.json": c.pkg}, c.tracked).Runner; got != c.want {
				t.Errorf("runner %q, want %q", got, c.want)
			}
		})
	}
}

func TestDetectNothing(t *testing.T) {
	d := Detect(nil, nil)
	if len(d.Setup)+len(d.Fix)+len(d.Checks)+len(d.Protect) != 0 || d.Runner != "" {
		t.Errorf("got %+v", d)
	}
}

func TestAcceptanceCommand(t *testing.T) {
	project := `"$KOGEN_NODE" node_modules/@cucumber/cucumber/bin/cucumber.js --strict --require 'features/steps/*.js' --format "message:$KOGEN_ACCEPTANCE_REPORT" "$KOGEN_ACCEPTANCE_FEATURES"`
	if got := AcceptanceCommand("features/steps", ProjectRunner); got != project {
		t.Errorf("project: %s", got)
	}
	bridge := `NODE_PATH="$KOGEN_CUCUMBER" "$KOGEN_NODE" "$KOGEN_CUCUMBER/@cucumber/cucumber/bin/cucumber.js" --strict --require 'features/steps/*.js' --format "message:$KOGEN_ACCEPTANCE_REPORT" "$KOGEN_ACCEPTANCE_FEATURES"`
	if got := AcceptanceCommand("features/steps", KogenRunner); got != bridge {
		t.Errorf("bridge: %s", got)
	}
}
