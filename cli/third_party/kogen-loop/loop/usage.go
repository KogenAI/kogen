package loop

import (
	"kogen-loop/api"
	"kogen-loop/provider"
)

// UsageOf is the usage a response reported, as api.Usage. A category the provider did not
// report (or reported inconsistently) is nil; nothing is estimated. The state is complete when
// all four categories are known, unknown when none is, partial otherwise.
func UsageOf(resp *provider.Response) api.Usage {
	if resp == nil || resp.UsageState == provider.UsageInconsistent {
		return usageFrom(nil, nil, nil, nil)
	}
	k := resp.Known
	return usageFrom(k.Input, k.Cached, k.Output, k.Reasoning)
}

// SumUsage adds usages. A category is nil as soon as one usage lacks it: a total that hides
// a missing value would be an estimate. Summing nothing is unknown.
func SumUsage(us ...api.Usage) api.Usage {
	if len(us) == 0 {
		return usageFrom(nil, nil, nil, nil)
	}
	add := func(pick func(api.Usage) *int) *int {
		sum := 0
		for _, u := range us {
			p := pick(u)
			if p == nil {
				return nil
			}
			sum += *p
		}
		return &sum
	}
	return usageFrom(
		add(func(u api.Usage) *int { return u.Input }),
		add(func(u api.Usage) *int { return u.Cached }),
		add(func(u api.Usage) *int { return u.Output }),
		add(func(u api.Usage) *int { return u.Reasoning }),
	)
}

func usageFrom(input, cached, output, reasoning *int) api.Usage {
	u := api.Usage{Input: copyInt(input), Cached: copyInt(cached), Output: copyInt(output), Reasoning: copyInt(reasoning), Source: "provider"}
	known := 0
	for _, p := range []*int{u.Input, u.Cached, u.Output, u.Reasoning} {
		if p != nil {
			known++
		}
	}
	switch known {
	case 0:
		u.State = api.UsageUnknown
	case 4:
		u.State = api.UsageComplete
	default:
		u.State = api.UsagePartial
	}
	return u
}

func copyInt(p *int) *int {
	if p == nil {
		return nil
	}
	v := *p
	return &v
}
