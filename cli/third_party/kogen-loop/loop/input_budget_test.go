package loop

import (
	"context"
	"reflect"
	"strings"
	"testing"

	"kogen-loop/provider"
	"kogen-loop/sys"
	"kogen-loop/tools"
)

func budgetReq(n int) Request {
	return Request{Role: provider.Role{Provider: "chatgpt", Model: "gpt-6.1-sol", Effort: "high"}, Instructions: strings.Repeat("a", n), Input: []any{}}
}

func TestInputBudgetBytes(t *testing.T) {
	for _, tc := range []struct {
		budget, instr int
		want          string
	}{
		{0, 1000, ""}, {262144, 300 * 1024, "context_budget_exceeded"}, {262144, 200 * 1024, ""},
		{65535, 10, "invalid_task"}, {-1, 10, "invalid_task"}, {524289, 10, "invalid_task"},
		{65536, 10, ""}, {524288, 10, ""}, {65536, 70000, "context_budget_exceeded"},
	} {
		_, err := FailOverBudget{InputBudgetBytes: tc.budget}.Prepare(context.Background(), budgetReq(tc.instr))
		got := ""
		if err != nil {
			e, _ := sys.AsError(err)
			got = e.Reason
			if tc.want == "invalid_task" && (!strings.Contains(err.Error(), "InputBudgetBytes") || e.Exit != 2) {
				t.Errorf("budget %d: bad error %v", tc.budget, err)
			}
		}
		if got != tc.want {
			t.Errorf("budget %d instr %d: got %q want %q", tc.budget, tc.instr, got, tc.want)
		}
	}
}

func TestDirectBudgetWiring(t *testing.T) {
	d := &Direct{InputBudgetBytes: 1}
	if _, _, err := d.Request(context.Background(), budgetReq(10)); err == nil || !strings.Contains(err.Error(), "InputBudgetBytes") {
		t.Fatalf("default route must validate: %v", err)
	}
	d = &Direct{InputBudgetBytes: 65536}
	if _, _, err := d.Request(context.Background(), budgetReq(70000)); err == nil || !strings.Contains(err.Error(), "exceeds 65536") {
		t.Fatalf("default route must apply budget: %v", err)
	}
}

func TestDirectBudgetTransport(t *testing.T) {
	srv := newParallelServer(t, []string{"finish"}, []string{"finish"}, []string{"finish"})
	client, session := parallelClient(t, srv.srv.URL)
	r := Request{Role: parallelRole, Instructions: "instructions", Input: []any{map[string]any{"role": "user", "content": "hello"}}, Tools: parallelDefs(), DisableParallelToolCalls: true}
	for _, budget := range []int{0, 524288, 65536} {
		d := Direct{Client: client, Session: session, InputBudgetBytes: budget}
		_, sent, err := d.Request(context.Background(), r)
		if err != nil || !reflect.DeepEqual(sent, r.Input) {
			t.Fatalf("budget %d: sent=%v err=%v", budget, sent, err)
		}
	}
	bodies := srv.requests()
	if len(bodies) != 3 || !reflect.DeepEqual(bodies[0], bodies[1]) || !reflect.DeepEqual(bodies[0], bodies[2]) {
		t.Fatalf("accepted bodies differ: %v", bodies)
	}
	r.Instructions = strings.Repeat("a", 70000)
	d := Direct{Client: client, Session: session, InputBudgetBytes: 65536}
	if _, _, err := d.Request(context.Background(), r); err == nil {
		t.Fatal("over-budget request passed")
	}
	if len(srv.requests()) != 3 {
		t.Fatal("refusal reached transport")
	}
}

func TestBudgetRenderedBoundaryAndDefaultRefusal(t *testing.T) {
	client := provider.NewClient("")
	r := Request{Role: parallelRole, Input: []any{map[string]any{"role": "user", "content": "hello"}}, Tools: parallelDefs(), DisableParallelToolCalls: true}
	body := func() map[string]any {
		return client.Body(provider.Request{Role: r.Role, Instructions: r.Instructions, Input: r.Input, Tools: r.Tools, CacheID: "cache-id", DisableParallelToolCalls: r.DisableParallelToolCalls})
	}
	m, err := tools.Measure(body(), r.Role)
	if err != nil {
		t.Fatal(err)
	}
	r.Instructions = strings.Repeat("a", 65536-m.RenderedBytes)
	p := FailOverBudget{Client: client, CacheID: "cache-id", InputBudgetBytes: 65536}
	m, err = tools.Measure(body(), r.Role)
	if err != nil || m.RenderedBytes != 65536 {
		t.Fatalf("measurement: %+v %v", m, err)
	}
	sent, err := p.Prepare(context.Background(), r)
	if err != nil || !reflect.DeepEqual(sent, r.Input) {
		t.Fatalf("boundary: %v %v", sent, err)
	}
	r.Instructions += "a"
	_, err = p.Prepare(context.Background(), r)
	e, ok := sys.AsError(err)
	if !ok || e.Class != "loop" || e.Reason != "context_budget_exceeded" || e.Exit != 1 || !strings.Contains(e.Detail, "exceeds 65536; reserve 131072 tokens") {
		t.Fatalf("refusal: %v", err)
	}
	r.Instructions = strings.Repeat("a", 524289)
	_, err0 := (FailOverBudget{Client: client, CacheID: "cache-id"}).Prepare(context.Background(), r)
	_, errMax := (FailOverBudget{Client: client, CacheID: "cache-id", InputBudgetBytes: 524288}).Prepare(context.Background(), r)
	if err0 == nil || errMax == nil || err0.Error() != errMax.Error() {
		t.Fatalf("default refusals: %v / %v", err0, errMax)
	}
}
