package main

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/KogenAI/kogen-coordinator/project"
	"github.com/KogenAI/kogen-loop/provider"
	"github.com/KogenAI/kogen-loop/sys"
)

const guidedModels = "models:\n  shape:\n    provider: chatgpt\n    model: gpt-6.1-sol\n    effort: low\n  build:\n    provider: chatgpt\n    model: gpt-6.1-terra\n    effort: high\n  review:\n    provider: chatgpt\n    model: gpt-6.1-terra\n    effort: medium\n"

const tokenURL = "https://token-plan.maas.qwencloudapi.com/compatible-mode/v1"

// guidedRun runs the guided login in a temp project and home with the typed lines as input.
func guidedRun(t *testing.T, models string, typed string) (project, home, out string, err error) {
	t.Helper()
	project, home = t.TempDir(), t.TempDir()
	t.Setenv("HOME", home)
	if models != "" {
		if err := os.MkdirAll(filepath.Join(project, ".kogen"), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(project, ".kogen", "models.yaml"), []byte(models), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	old, werr := os.Getwd()
	if werr != nil {
		t.Fatal(werr)
	}
	if werr := os.Chdir(project); werr != nil {
		t.Fatal(werr)
	}
	t.Cleanup(func() { os.Chdir(old) })
	var buf strings.Builder
	s := sys.New()
	s.Stdout = &buf
	err = loginGuided(s, provider.NewClient("kogen test"), provider.Input{Reader: strings.NewReader(typed)})
	return project, home, buf.String(), err
}

func TestGuidedQwenCloudSavesTheBuildRoleOnlyAfterY(t *testing.T) {
	project, home, out, err := guidedRun(t, guidedModels, "6\n1\nsk-fake-guided-key\ny\n")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(out, "sk-fake-guided-key") {
		t.Fatalf("key printed: %s", out)
	}
	if strings.Index(out, "qwen4-max") > strings.Index(out, "[y/N]") || !strings.Contains(out, tokenURL) {
		t.Fatalf("preview must name the model and URL before the confirmation: %s", out)
	}
	cred, err := os.ReadFile(filepath.Join(home, ".kogen", "credentials", "openai-compatible.json"))
	if err != nil || !strings.Contains(string(cred), "https://token-plan.maas.qwencloudapi.com") {
		t.Fatalf("credential not bound to the origin: %s %v", cred, err)
	}
	got, _ := os.ReadFile(filepath.Join(project, ".kogen", "models.yaml"))
	want := strings.Replace(guidedModels, "  build:\n    provider: chatgpt\n    model: gpt-6.1-terra\n    effort: high\n",
		"  build:\n    provider: openai-compatible\n    model: qwen4-max\n    effort: high\n    base_url: "+tokenURL+"\n", 1)
	if string(got) != want {
		t.Fatalf("models.yaml:\n%s\nwant:\n%s", got, want)
	}
}

func TestGuidedQwenCloudAnyOtherAnswerSavesNothing(t *testing.T) {
	for _, answer := range []string{"n", "", "yes", "Y"} {
		project, home, _, err := guidedRun(t, guidedModels, "QwenCloud\nPay-as-you-go (Singapore)\nsk-fake-guided-key\n"+answer+"\n")
		if err != nil {
			t.Fatal(err)
		}
		if _, err := os.Stat(filepath.Join(home, ".kogen", "credentials")); !os.IsNotExist(err) {
			t.Fatalf("answer %q: credential store touched: %v", answer, err)
		}
		if got, _ := os.ReadFile(filepath.Join(project, ".kogen", "models.yaml")); string(got) != guidedModels {
			t.Fatalf("answer %q: models.yaml changed: %s", answer, got)
		}
	}
}

func TestGuidedQwenCloudWarnsOnlyForTokenPlan(t *testing.T) {
	_, _, token, _ := guidedRun(t, guidedModels, "6\n1\nk\nn\n")
	_, _, payg, _ := guidedRun(t, guidedModels, "6\n2\nk\nn\n")
	if n := strings.Count(token, "terms restrict automation"); n != 1 {
		t.Fatalf("Token Plan warning printed %d times: %s", n, token)
	}
	if strings.Contains(payg, "restrict automation") || !strings.Contains(payg, "https://ap-southeast-1.maas.qwencloudapi.com/compatible-mode/v1") {
		t.Fatalf("pay-as-you-go output: %s", payg)
	}
}

func TestGuidedRefusesAnUnknownChoice(t *testing.T) {
	_, home, out, err := guidedRun(t, guidedModels, "8\n")
	if err == nil || !strings.Contains(err.Error(), "not one of the choices") && !strings.Contains(sysText(err), "not one of the choices") {
		t.Fatalf("err = %v, out %s", err, out)
	}
	if _, err := os.Stat(filepath.Join(home, ".kogen")); !os.IsNotExist(err) {
		t.Fatalf("home touched: %v", err)
	}
}

func sysText(err error) string {
	if e, ok := sys.AsError(err); ok {
		return e.Render()
	}
	return ""
}

func TestGuidedAdvancedOffersOnlyChatCompletions(t *testing.T) {
	_, home, out, err := guidedRun(t, guidedModels, "7\n1\nhttps://example.com/v1\nsk-fake-guided-key\n")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(out, "Messages") || !strings.Contains(out, "1) Chat Completions (openai-compatible)") {
		t.Fatalf("endpoint choices: %s", out)
	}
	cred, _ := os.ReadFile(filepath.Join(home, ".kogen", "credentials", "openai-compatible.json"))
	if !strings.Contains(string(cred), "https://example.com") {
		t.Fatalf("credential: %s", cred)
	}
}

func TestWithBuildRoleKeepsTheOtherRoles(t *testing.T) {
	flow := "# lineup\nmodels:\n  shape: {provider: chatgpt, model: a, effort: low}\n  build: {provider: chatgpt, model: b, effort: high}\n  review: {provider: chatgpt, model: c, effort: medium}\nother: 1\n"
	got, err := withBuildRole(flow, tokenURL)
	if err != nil {
		t.Fatal(err)
	}
	want := "# lineup\nmodels:\n  shape: {provider: chatgpt, model: a, effort: low}\n  build:\n    provider: openai-compatible\n    model: qwen4-max\n    effort: high\n    base_url: " + tokenURL + "\n  review: {provider: chatgpt, model: c, effort: medium}\nother: 1\n"
	if got != want {
		t.Fatalf("got:\n%s\nwant:\n%s", got, want)
	}
	added, err := withBuildRole("models:\n  shape: {provider: chatgpt, model: a, effort: low}\n", tokenURL)
	if err != nil || !strings.HasPrefix(added, "models:\n  shape: {provider: chatgpt, model: a, effort: low}\n  build:\n    provider: openai-compatible\n") {
		t.Fatalf("added: %q %v", added, err)
	}
	fresh, err := withBuildRole("", tokenURL)
	if err != nil || !strings.HasPrefix(fresh, "models:\n  build:\n") {
		t.Fatalf("fresh: %q %v", fresh, err)
	}
	if _, err := withBuildRole("models: {shape: {model: a}}\n", tokenURL); err == nil {
		t.Fatal("an inline models mapping was rewritten")
	}
}

func TestLoginWithoutProviderIsRefusedOffATerminal(t *testing.T) {
	old := interactiveLogin
	t.Cleanup(func() { interactiveLogin = old })
	interactiveLogin = func() bool { return false }
	if code := run([]string{"provider", "login"}, func() (string, error) { t.Fatal("runtime lookup"); return "", nil }); code != 2 {
		t.Fatalf("exit %d, want 2", code)
	}
}

// fakeTester replaces the connection test with a recorder that also records a success, so the
// guided login never reaches a public host.
func fakeTester(t *testing.T) *int {
	t.Helper()
	calls := 0
	old := connectionTester
	connectionTester = func(ctx context.Context, home string, role project.Role) (connectionResult, error) {
		calls++
		res := connectionResult{At: time.Date(2026, 11, 28, 10, 0, 0, 0, time.UTC), OK: true, Status: 200}
		origin, _ := normalizeOrigin(role.BaseURL)
		return res, writeConnectionRecord(home, testableProvider, connectionRecord{Time: formatTime(res.At), Result: "ok", Status: 200, Origin: origin})
	}
	t.Cleanup(func() { connectionTester = old })
	return &calls
}

func TestGuidedQwenCloudOffersTheConnectionTestAndRunsItOnlyAfterY(t *testing.T) {
	calls := fakeTester(t)
	_, _, out, err := guidedRun(t, guidedModels, "6\n1\nsk-fake-guided-key\ny\ny\n")
	if err != nil {
		t.Fatal(err)
	}
	if *calls != 1 {
		t.Fatalf("test ran %d times", *calls)
	}
	if strings.Index(out, "Saved the build role") > strings.Index(out, "Run a connection test now? [y/N]") {
		t.Fatalf("the offer comes before the save: %s", out)
	}
	for _, want := range []string{
		"openai-compatible: connection tested 2026-11-28T10:00:00Z (HTTP 200)",
		"states role build (openai-compatible, qwen4-max): key saved; connection tested 2026-11-28T10:00:00Z",
	} {
		if !strings.Contains(out, want) {
			t.Fatalf("missing %q in: %s", want, out)
		}
	}
	if strings.Contains(out, "sk-fake-guided-key") || strings.Contains(out, "role verified") {
		t.Fatalf("output: %s", out)
	}
}

func TestGuidedQwenCloudAnyOtherAnswerRunsNoTest(t *testing.T) {
	for _, typed := range []string{"n\n", "\n", "yes\n", "Y\n", ""} {
		calls := fakeTester(t)
		_, _, out, err := guidedRun(t, guidedModels, "6\n1\nsk-fake-guided-key\ny\n"+typed)
		if err != nil {
			t.Fatal(err)
		}
		if *calls != 0 {
			t.Fatalf("answer %q ran the test", typed)
		}
		if !strings.Contains(out, "states role build (openai-compatible, qwen4-max): key saved\n") {
			t.Fatalf("answer %q: summary missing in: %s", typed, out)
		}
	}
}

func TestGuidedQwenCloudDeclinedSaveOffersNoTest(t *testing.T) {
	calls := fakeTester(t)
	_, _, out, err := guidedRun(t, guidedModels, "6\n1\nsk-fake-guided-key\nn\ny\n")
	if err != nil || *calls != 0 || strings.Contains(out, "connection test") {
		t.Fatalf("calls %d err %v out %s", *calls, err, out)
	}
}
