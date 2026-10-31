package shape

import (
	"testing"

	"kogen/executor"
)

func TestSumUsagePartialWhenStatesDiffer(t *testing.T) {
	parallel(t)
	a, b := 1.5, 2.0
	one := executor.Usage{CostUSD: &a, State: executor.UsageComplete}
	two := executor.Usage{CostUSD: &b, State: executor.UsageUnknown}
	got := sumUsage(one, two, false)
	if got.State != executor.UsagePartial {
		t.Fatalf("state %q, want partial", got.State)
	}
	if got.CostUSD == nil || *got.CostUSD != 3.5 {
		t.Fatalf("cost %v, want 3.5", got.CostUSD)
	}
}
