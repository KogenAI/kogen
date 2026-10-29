package main

import (
	"bytes"
	"context"
	"os"
	"os/exec"
	"reflect"
	"strings"
	"testing"
	"time"

	"kogen-loop/provider"
	"kogen-loop/sys"
	"kogen-loop/tools"
	"kogen/agent"
	"kogen/internal/research"
)

// responseBudgetSupport are the package-local tests that observe the real clients of every
// provider-backed entry under the production settings, and the subtests each must pass.
// TestResponseBudgetDefaultContract runs them and requires each named PASS, so a missing,
// renamed or skipped test cannot pass silently.
var responseBudgetSupport = []struct {
	pkg   string
	tests []string
}{
	{"./shape", []string{
		"TestResponseBudgetDefaultShape",
		"TestResponseBudgetDefaultShape/shape sends every request under ten minutes and records it once",
		"TestResponseBudgetDefaultShape/a stalled shape expires unavailable naming ten minutes, is not retried and records once",
		"TestResponseBudgetDefaultShape/refine sends every request under ten minutes and records it once",
		"TestResponseBudgetDefaultShape/a stalled refine expires unavailable naming ten minutes and records once",
		"TestResponseBudgetDefaultShape/shape workers send under the same ten minutes within the one record",
		"TestResponseBudgetDefaultShape/the setup conversation of init sends under ten minutes",
	}},
	{"./build", []string{
		"TestResponseBudgetDefaultBuild",
		"TestResponseBudgetDefaultBuild/the builder and the independent reviewer send under ten minutes and the run records it once",
		"TestResponseBudgetDefaultBuild/a stalled builder expires unavailable naming ten minutes and its resume lands under a new budget",
		"TestResponseBudgetDefaultBuild/a stalled review expires unavailable naming ten minutes and its resume answers it",
	}},
	{"./internal/research", []string{
		"TestProductionResponseBudgetDefault",
		"TestApplyClientKeepsALowerBudget",
		"TestRespondNamesTheTenMinuteExpiry",
		"TestRespondExpiryEndsUnavailableNamingTenMinutes",
	}},
}

// responseBudgetStartEnv is the environment the test process started with: other tests in this
// package leave variables of their own (the tool locations of a deleted install) in the live
// environment, and the supporting tests need the one the suite was started in.
var responseBudgetStartEnv = os.Environ()

// TestResponseBudgetDefaultContract is the contract of the ten-minute provider response default:
// every provider-backed entry (Shape, Refine, native Build, independent Review, associated
// workers and the setup conversation) sends under it, the run log records it once, a stalled wait
// expires unavailable naming ten minutes and the existing retry answers it, and requests and every
// other setting stay as they were. It never replaces the production default.
func TestResponseBudgetDefaultContract(t *testing.T) {
	t.Run("the production source sets only the ten-minute response budget", func(t *testing.T) {
		want := research.Settings{Client: research.ClientSettings{ResponseBudget: 10 * time.Minute}}
		if !reflect.DeepEqual(research.Current, want) {
			t.Fatalf("research.Current = %+v, want %+v", research.Current, want)
		}
		if research.Current.AuthorityBoundary != nil {
			t.Fatal("the authority boundary is not disabled")
		}
		if err := research.Validate(context.Background(), sys.New()); err != nil {
			t.Fatal(err)
		}
		if research.InputBudget() != tools.InputBudgetBytes {
			t.Fatalf("input budget %d", research.InputBudget())
		}
		if got := research.ApplyTools(&tools.Tools{}); !reflect.DeepEqual(got, &tools.Tools{}) {
			t.Fatalf("tool options changed: %+v", got)
		}
		for i, text := range knobFixtureRaw() {
			if got, want := research.CutText(text), tools.Cut(text); got != want {
				t.Errorf("cut %d: %d bytes, library %d", i, len(got), len(want))
			}
		}
		// The library's own default is independent of Kogen's: a client nobody configured keeps
		// its thirty minutes, and an explicit lower budget is not raised.
		if provider.ResponseBudget != 30*time.Minute || provider.NewClient("").ResponseBudget != 0 {
			t.Fatalf("library default %s / client %s", provider.ResponseBudget, provider.NewClient("").ResponseBudget)
		}
		low := provider.NewClient("")
		low.ResponseBudget = 42 * time.Second
		if research.ApplyClient(low).ResponseBudget != 42*time.Second || research.ApplyClient(provider.NewClient("")).ResponseBudget != 10*time.Minute {
			t.Fatal("ApplyClient did not give ten minutes to an unconfigured client and keep a lower one")
		}
	})

	t.Run("every provider-backed entry is observed under ten minutes with exact execution checks", func(t *testing.T) {
		if testing.Short() {
			t.Skip("runs the package-local observations")
		}
		var names []string
		var pkgs []string
		for _, p := range responseBudgetSupport {
			pkgs = append(pkgs, p.pkg)
			for _, n := range p.tests {
				if !strings.Contains(n, "/") {
					names = append(names, n)
				}
			}
		}
		args := append([]string{"test", "-race", "-count=1", "-v", "-run", "^(" + strings.Join(names, "|") + ")$"}, pkgs...)
		ctx, cancel := context.WithTimeout(context.Background(), 9*time.Minute)
		defer cancel()
		cmd := exec.CommandContext(ctx, "go", args...)
		cmd.Env = responseBudgetStartEnv
		var out bytes.Buffer
		cmd.Stdout, cmd.Stderr = &out, &out
		if err := cmd.Run(); err != nil {
			t.Fatalf("go %v: %v\n%s", args, err, out.String())
		}
		text := out.String()
		for _, p := range responseBudgetSupport {
			for _, n := range p.tests {
				name := strings.ReplaceAll(n, " ", "_")
				marker := "--- PASS: " + name + " ("
				if strings.Contains(n, "/") {
					marker = "    " + marker
				}
				if !strings.Contains(text, marker) {
					t.Errorf("%s: required test did not execute and pass: %s", p.pkg, n)
				}
			}
		}
		if strings.Contains(text, "--- SKIP") || strings.Contains(text, "--- FAIL") {
			t.Errorf("a required test skipped or failed:\n%s", text)
		}
	})

	t.Run("serialized requests and every other setting equal the zero configuration's", func(t *testing.T) {
		render := func() any {
			client := provider.NewClient("kogen dev+12345678 (test)")
			research.ApplyClient(client)
			return knobNormalize(knobFixtureRequests(research.CutText, research.Request, func(r provider.Request) map[string]any { return client.Body(r) }))
		}
		production := render()
		setKnobs(t, research.Settings{})
		if zero := render(); !reflect.DeepEqual(production, zero) {
			t.Fatal("the fixed requests differ between the ten-minute default and the zero configuration")
		}
		setKnobs(t, research.Settings{Client: research.ClientSettings{ResponseBudget: 10 * time.Minute}})
		if explicit := render(); !reflect.DeepEqual(production, explicit) {
			t.Fatal("the fixed requests differ under an explicit ten-minute configuration")
		}
	})

	t.Run("the request sent equals the zero configuration's byte for byte", func(t *testing.T) {
		role := provider.Role{Provider: "anthropic", Model: "claude-sonnet-5-5", Effort: "high"}
		send := func(s research.Settings) []byte {
			setKnobs(t, s)
			k := newKnobServer(t)
			sess := knobSession(t, k)
			client := research.ApplyClient(provider.NewClient("kogen dev+12345678 (test)"))
			client.Sleep = func(context.Context, time.Duration) error { return nil }
			req := research.Request(provider.Request{Role: role, Instructions: "policy", Input: knobFixtureInput(research.CutText),
				Tools: agent.AsAny(agent.Defs(knobFixtureEveryTool...)), CacheID: "knob-fixture-cache"})
			research.Respond(context.Background(), client, sess, req, nil)
			if len(k.bodies) == 0 {
				t.Fatal("nothing was sent")
			}
			return k.bodies[0]
		}
		production := send(research.Current)
		if zero := send(research.Settings{}); !bytes.Equal(production, zero) {
			t.Fatalf("sent %d bytes under the default, %d under zero", len(production), len(zero))
		}
	})
}
