package provider

import (
	"fmt"
)

// Usage is the compatible token total of a request or a run (GPT-9): reasoning is a
// subset of output, cached a subset of input.
type Usage struct{ Input, Cached, Output, Reasoning int }

// Add returns the sum of u and o.
func (u Usage) Add(o Usage) Usage {
	return Usage{u.Input + o.Input, u.Cached + o.Cached, u.Output + o.Output, u.Reasoning + o.Reasoning}
}

// Line is the progress text `input=… cached=… output=… reasoning=…`.
func (u Usage) Line() string {
	return fmt.Sprintf("input=%d cached=%d output=%d reasoning=%d", u.Input, u.Cached, u.Output, u.Reasoning)
}

// Total is input plus output.
func (u Usage) Total() int { return u.Input + u.Output }

// Usage states of one measured response.
const (
	UsageKnown        = "known"
	UsagePartial      = "partial"
	UsageUnknown      = "unknown"
	UsageInconsistent = "inconsistent"
)

// KnownUsage is the validated analytical usage of one response: every category is nil
// unless the provider reported a nonnegative integer for it.
type KnownUsage struct {
	Input     *int `json:"input"`
	Cached    *int `json:"cached"`
	Write     *int `json:"write"`
	Write30m  *int `json:"write_30m"`
	Write12h  *int `json:"write_12h"`
	Output    *int `json:"output"`
	Reasoning *int `json:"reasoning"`
}

// Map is the record form: category name to int or nil.
func (k KnownUsage) Map() map[string]any {
	m := map[string]any{}
	for name, p := range map[string]*int{"input": k.Input, "cached": k.Cached, "write": k.Write, "write_30m": k.Write30m, "write_12h": k.Write12h, "output": k.Output, "reasoning": k.Reasoning} {
		if p == nil {
			m[name] = nil
		} else {
			m[name] = *p
		}
	}
	return m
}

// rawUsage holds the reported values as received (anything), to judge them before
// they are narrowed to KnownUsage.
type rawUsage struct{ input, cached, write, write30m, write12h, output, reasoning any }

func (r rawUsage) values() []any {
	return []any{r.input, r.cached, r.write, r.write30m, r.write12h, r.output, r.reasoning}
}

// known narrows to the nonnegative integers.
func (r rawUsage) known() KnownUsage {
	return KnownUsage{nonneg(r.input), nonneg(r.cached), nonneg(r.write), nonneg(r.write30m), nonneg(r.write12h), nonneg(r.output), nonneg(r.reasoning)}
}

func nonneg(v any) *int {
	if n, ok := asInt(v); ok && n >= 0 {
		i := int(n)
		return &i
	}
	return nil
}

// state is Kogen.Usage.state: inconsistent values are labelled, never clamped.
func (r rawUsage) state() string {
	for _, v := range r.values() {
		if v == nil {
			continue
		}
		if n, ok := asInt(v); !ok || n < 0 {
			return UsageInconsistent
		}
	}
	k := r.known()
	le := func(a, b *int) bool { return a == nil || b == nil || *a <= *b }
	disjoint := k.Cached == nil || k.Write == nil || k.Input == nil || *k.Cached+*k.Write <= *k.Input
	lifetimes := k.Write == nil || k.Write30m == nil || k.Write12h == nil || *k.Write30m+*k.Write12h == *k.Write
	if !le(k.Cached, k.Input) || !le(k.Write, k.Input) || !le(k.Write30m, k.Write) || !le(k.Write12h, k.Write) || !le(k.Reasoning, k.Output) || !disjoint || !lifetimes {
		return UsageInconsistent
	}
	nils := 0
	for _, v := range r.values() {
		if v == nil {
			nils++
		}
	}
	switch nils {
	case 7:
		return UsageUnknown
	case 0:
		return UsageKnown
	}
	return UsagePartial
}

// State is the usage state of k (the nil categories are unknown, never inconsistent).
func (k KnownUsage) State() string {
	v := func(p *int) any {
		if p == nil {
			return nil
		}
		return int64(*p)
	}
	return rawUsage{v(k.Input), v(k.Cached), v(k.Write), v(k.Write30m), v(k.Write12h), v(k.Output), v(k.Reasoning)}.state()
}

// rawFrom reads the response `usage` object (nil when absent).
func rawFrom(u map[string]any) rawUsage {
	if u == nil {
		return rawUsage{}
	}
	dig := func(path ...string) any {
		var cur any = u
		for _, k := range path {
			m, ok := cur.(map[string]any)
			if !ok {
				return nil
			}
			cur = m[k]
		}
		return cur
	}
	return rawUsage{
		write:     dig("input_tokens_details", "cache_write_tokens"),
		write30m:  dig("input_tokens_details", "cache_write_tokens_details", "ttl_30m_tokens"),
		write12h:  dig("input_tokens_details", "cache_write_tokens_details", "ttl_12h_tokens"),
		input:     dig("input_tokens"),
		cached:    dig("input_tokens_details", "cached_tokens"),
		output:    dig("output_tokens"),
		reasoning: dig("output_tokens_details", "reasoning_tokens"),
	}
}

// compatible is the legacy total of a validated usage object: missing counts are zero.
func compatible(u map[string]any) Usage {
	num := func(path ...string) int {
		var cur any = u
		for _, k := range path {
			m, ok := cur.(map[string]any)
			if !ok {
				return 0
			}
			cur = m[k]
		}
		n, _ := asInt(cur)
		return int(n)
	}
	return Usage{
		Input:     num("input_tokens"),
		Cached:    num("input_tokens_details", "cached_tokens"),
		Output:    num("output_tokens"),
		Reasoning: num("output_tokens_details", "reasoning_tokens"),
	}
}
