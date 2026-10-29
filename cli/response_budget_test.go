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
	"kogen/agent"
)

// responseBudgetSupport are the package-local tests that observe the real clients of every
// provider-backed entry under the production settings, and the subtests each must pass.
// TestShapeBudgetRoleContract runs them and requires each named PASS, so a missing,
// renamed or skipped test cannot pass silently.
var responseBudgetSupport = []struct {
	pkg   string
	tests []string
}{
	{"./shape", []string{
		"TestShapeBudgetRolesShape",
		"TestShapeBudgetRolesShape/shape sends every request under thirty minutes and records it once",
		"TestShapeBudgetRolesShape/a stalled shape expires unavailable naming thirty minutes, is not retried and records once",
		"TestShapeBudgetRolesShape/refine sends every request under thirty minutes and records it once",
		"TestShapeBudgetRolesShape/a stalled refine expires unavailable naming thirty minutes and records once",
		"TestShapeBudgetRolesShape/shape workers send under the same thirty minutes within the one record",
		"TestShapeBudgetRolesShape/the setup conversation of init sends under thirty minutes",
	}},
	{"./build", []string{
		"TestShapeBudgetRolesBuild",
		"TestShapeBudgetRolesBuild/the builder and the independent reviewer send under ten minutes and the run records it once",
		"TestShapeBudgetRolesBuild/a stalled builder expires unavailable naming ten minutes and its resume lands under a new budget",
		"TestShapeBudgetRolesBuild/a stalled review expires unavailable naming ten minutes and its resume answers it",
	}},
	{"./agent", []string{
		"TestBudgetRoleConstants",
		"TestNameBudgetExpiryNamesTheTenMinuteExpiry",
		"TestNameBudgetExpiryEndsUnavailableNamingTenMinutes",
	}},
}

// responseBudgetStartEnv is the environment the test process started with: other tests in this
// package leave variables of their own (the tool locations of a deleted install) in the live
// environment, and the supporting tests need the one the suite was started in.
var responseBudgetStartEnv = os.Environ()

// TestResponseBudgetDefaultContract is the contract of what the response budget does to the
// wire: nothing. A Build/Review client and an unconfigured one render and send the same bytes.
// Which role gets which budget is TestShapeBudgetRoleContract's.
func TestResponseBudgetDefaultContract(t *testing.T) {
	t.Run("serialized requests equal the unconfigured client's", func(t *testing.T) {
		render := func(client *provider.Client) any {
			return knobNormalize(knobFixtureRequests(func(r provider.Request) map[string]any { return client.Body(r) }))
		}
		build := agent.ApplyBuildReview(provider.NewClient("kogen dev+12345678 (test)"))
		if unconfigured := render(provider.NewClient("kogen dev+12345678 (test)")); !reflect.DeepEqual(render(build), unconfigured) {
			t.Fatal("the fixed requests differ between a Build/Review client and an unconfigured one")
		}
	})

	t.Run("the request sent equals the unconfigured client's byte for byte", func(t *testing.T) {
		role := provider.Role{Provider: "anthropic", Model: "claude-sonnet-5-5", Effort: "high"}
		send := func(configure func(*provider.Client) *provider.Client) []byte {
			k := newKnobServer(t)
			sess := knobSession(t, k)
			client := configure(provider.NewClient("kogen dev+12345678 (test)"))
			client.Sleep = func(context.Context, time.Duration) error { return nil }
			req := provider.Request{Role: role, Instructions: "policy", Input: knobFixtureInput(),
				Tools: agent.AsAny(agent.Defs(knobFixtureEveryTool...)), CacheID: "knob-fixture-cache"}
			client.Respond(context.Background(), sess, req, nil)
			if len(k.bodies) == 0 {
				t.Fatal("nothing was sent")
			}
			return k.bodies[0]
		}
		buildReview := send(agent.ApplyBuildReview)
		if plain := send(func(c *provider.Client) *provider.Client { return c }); !bytes.Equal(buildReview, plain) {
			t.Fatalf("sent %d bytes under the Build/Review budget, %d under the library's", len(buildReview), len(plain))
		}
	})
}

// TestShapeBudgetRoleContract is the contract of the response budget per role: Shape, Refine,
// the shape workers and init leave the client's budget zero and send under the pinned loop's 30
// minutes; native Build (fresh and resumed) and independent Review use the fixed 10 minutes. The
// run log records the effective budget once, a stalled Build or Review wait expires unavailable
// naming ten minutes and the existing resume answers it. The real entries are observed by the
// package-local tests below, each required by exact name to run and pass.
func TestShapeBudgetRoleContract(t *testing.T) {
	t.Run("wire identity and other settings", TestResponseBudgetDefaultContract)
	t.Run("the role constants are Build and Review's ten minutes and the loop's thirty for the rest", func(t *testing.T) {
		if agent.BuildReviewBudget != 10*time.Minute {
			t.Fatalf("Build/Review budget %s", agent.BuildReviewBudget)
		}
		if provider.ResponseBudget != 30*time.Minute || provider.NewClient("").ResponseBudget != 0 {
			t.Fatalf("library default %s / client %s", provider.ResponseBudget, provider.NewClient("").ResponseBudget)
		}
		if got := agent.ApplyBuildReview(provider.NewClient("")).ResponseBudget; got != 10*time.Minute {
			t.Fatalf("Build/Review client %s", got)
		}
		for _, c := range []struct {
			client *provider.Client
			ms     int64
			text   string
		}{
			{provider.NewClient(""), 1800000, "30 minutes"},
			{agent.ApplyBuildReview(provider.NewClient("")), 600000, "10 minutes"},
		} {
			if e := agent.BudgetEvent(c.client); e["budget_ms"] != c.ms || e["budget"] != c.text || e["event"] != "response_budget" || len(e) != 3 {
				t.Errorf("event %v, want %d %s", e, c.ms, c.text)
			}
		}
	})

	t.Run("every role is observed under its budget with exact execution checks", func(t *testing.T) {
		if testing.Short() {
			t.Fatal("the role contract requires its package-local observations; do not use -short")
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
					t.Errorf("required test %s: go test -race %s: not executed with PASS", n, p.pkg)
				}
			}
		}
		if strings.Contains(text, "--- SKIP") || strings.Contains(text, "--- FAIL") {
			t.Errorf("a required test skipped or failed:\n%s", text)
		}
	})
}
