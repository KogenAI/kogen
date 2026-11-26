package loop

import (
	"math"
	"reflect"
	"testing"

	"github.com/KogenAI/kogen-loop/api"
)

func TestSumUsageOverflow(t *testing.T) {
	n := func(v int) *int { return &v }
	usage := func(a, b, c, d int) api.Usage {
		return api.Usage{Input: n(a), Cached: n(b), Output: n(c), Reasoning: n(d), State: api.UsageUnknown}
	}
	tests := []struct {
		name   string
		values []api.Usage
		want   api.Usage
	}{
		{"one overflow", []api.Usage{usage(math.MaxInt, 2, 5, 1), usage(1, 1, 6, 2)}, api.Usage{Cached: n(3), Output: n(11), Reasoning: n(3), State: api.UsagePartial, Source: "provider"}},
		{"maximum", []api.Usage{usage(math.MaxInt-1, 2, 5, 1), usage(1, 1, 6, 2)}, api.Usage{Input: n(math.MaxInt), Cached: n(3), Output: n(11), Reasoning: n(3), State: api.UsageComplete, Source: "provider"}},
		{"below maximum", []api.Usage{usage(math.MaxInt-2, 2, 5, 1), usage(1, 1, 6, 2)}, api.Usage{Input: n(math.MaxInt - 1), Cached: n(3), Output: n(11), Reasoning: n(3), State: api.UsageComplete, Source: "provider"}},
		{"all overflow", []api.Usage{usage(math.MaxInt, math.MaxInt, math.MaxInt, math.MaxInt), usage(1, 1, 1, 1)}, api.Usage{State: api.UsageUnknown, Source: "provider"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := SumUsage(tt.values...); !reflect.DeepEqual(got, tt.want) {
				t.Errorf("SumUsage() = %+v, want %+v", got, tt.want)
			}
		})
	}
}
