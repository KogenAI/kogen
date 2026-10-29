package agent

import (
	"fmt"
	"strings"
	"time"

	"kogen-loop/provider"
	"kogen-loop/sys"
)

// BuildReviewBudget is the fixed provider response budget of native Build and independent
// Review: one logical Respond call, absolute, shared by refresh, lock waits, retries and backoff.
// Shape, Refine, init and the workers leave the client's budget zero: the loop's 30 minutes.
const BuildReviewBudget = 10 * time.Minute

// ApplyBuildReview gives the client Build and Review use their fixed response budget.
func ApplyBuildReview(c *provider.Client) *provider.Client {
	if c != nil {
		c.ResponseBudget = BuildReviewBudget
	}
	return c
}

// BudgetEvent is the run-log record of the effective response budget of c, which a run
// records once when it starts, not per request.
func BudgetEvent(c *provider.Client) map[string]any {
	d := provider.ResponseBudget
	if c != nil && c.ResponseBudget != 0 {
		d = c.ResponseBudget
	}
	return map[string]any{"event": "response_budget", "budget_ms": d.Milliseconds(), "budget": describeBudget(d)}
}

// describeBudget is how Kogen names a response budget: whole minutes as "10 minutes" or
// "30 minutes", and any other duration as Go renders it.
func describeBudget(d time.Duration) string {
	if d == 10*time.Minute || d == 30*time.Minute {
		return fmt.Sprintf("%d minutes", d/time.Minute)
	}
	return d.String()
}

// NameBudgetExpiry renames the expiry of Build and Review's explicit budget in a provider
// failure. The pinned library renders an explicit budget as a Go duration ("10m0s") and its own
// default as "30 minutes"; classification, exit code and every other message and duration are
// unchanged.
func NameBudgetExpiry(err error, budget time.Duration) error {
	e, ok := err.(*sys.Error)
	if !ok || budget != BuildReviewBudget || e.Class != "provider" || e.Reason != "unavailable" {
		return err
	}
	if rest, found := strings.CutSuffix(e.Detail, " response wait exceeded "+budget.String()); found {
		renamed := *e
		renamed.Detail = rest + " response wait exceeded " + describeBudget(budget)
		return &renamed
	}
	return err
}
