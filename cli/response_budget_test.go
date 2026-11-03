package main

import (
	"testing"
	"time"

	"github.com/KogenAI/kogen-executor/agent"
	"kogen-loop/provider"
)

// TestShapeBudgetRoleContract observes the fixed response budgets.
func TestShapeBudgetRoleContract(t *testing.T) {
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

}
