package provider

import (
	"context"
	"encoding/json"
	"math"
	"runtime"
	"sync"
	"testing"
	"time"
)

// advanceOnce makes the client's clock jump by d on its second reading of a call, which is
// before the first attempt starts (the first reading starts the call).
func advanceOnce(e *env, d time.Duration) {
	var mu sync.Mutex
	reads := 0
	now := e.c.Now
	e.c.Now = func() time.Time {
		mu.Lock()
		reads++
		if reads == 2 {
			e.clk.advance(d)
		}
		mu.Unlock()
		return now()
	}
}

func offsetOf(t *testing.T, rec map[string]any) int64 {
	t.Helper()
	n, ok := rec["request_offset_ms"].(int64)
	if !ok {
		t.Fatalf("request_offset_ms = %#v, want an integer", rec["request_offset_ms"])
	}
	return n
}

func TestAttemptRequestOffset(t *testing.T) {
	t.Parallel()
	head, tail := wireStream("chatgpt")
	ok := obsAttempt{steps: []obsStep{{advance: ms1, data: head + tail}}}

	t.Run("retries count from the call start", func(t *testing.T) {
		t.Parallel()
		e, _, req := obsEnv(t, "chatgpt", obsAttempt{status: 503, headersAdvance: 12 * ms1, steps: []obsStep{{advance: 8 * ms1, data: "x"}}}, ok)
		advanceOnce(e, 250*ms1)
		obs := &observer{}
		if _, err := e.c.Respond(context.Background(), e.s, req, obs); err != nil {
			t.Fatal(err)
		}
		recs := attemptRecords(t, obs, 2)
		var waited time.Duration
		for _, d := range e.clk.slept() {
			waited += d
		}
		if waited == 0 {
			t.Fatal("the retry did not wait")
		}
		if got := offsetOf(t, recs[0]); got != 250 {
			t.Errorf("first offset = %d, want 250", got)
		}
		want := (250*ms1 + 20*ms1 + waited).Milliseconds()
		if got := offsetOf(t, recs[1]); got != want {
			t.Errorf("second offset = %d, want %d", got, want)
		}
	})

	t.Run("single attempt", func(t *testing.T) {
		t.Parallel()
		e, _, req := obsEnv(t, "chatgpt", ok)
		req.Single = true
		advanceOnce(e, 40*ms1)
		obs := &observer{}
		if _, err := e.c.Respond(context.Background(), e.s, req, obs); err != nil {
			t.Fatal(err)
		}
		if got := offsetOf(t, attemptRecords(t, obs, 1)[0]); got != 40 {
			t.Errorf("offset = %d, want 40", got)
		}
	})
}

func TestAttemptLoadAverage(t *testing.T) {
	t.Parallel()
	head, tail := wireStream("chatgpt")
	e, _, req := obsEnv(t, "chatgpt", obsAttempt{steps: []obsStep{{advance: ms1, data: head + tail}}})
	obs := &observer{}
	if _, err := e.c.Respond(context.Background(), e.s, req, obs); err != nil {
		t.Fatal(err)
	}
	rec := attemptRecords(t, obs, 1)[0]
	raw, err := json.Marshal(rec["load_average"])
	if err != nil {
		t.Fatal(err)
	}
	if runtime.GOOS != "darwin" && runtime.GOOS != "linux" {
		if string(raw) != "null" {
			t.Fatalf("load_average = %s, want null", raw)
		}
		return
	}
	var got []float64
	if err := json.Unmarshal(raw, &got); err != nil || len(got) != 3 {
		t.Fatalf("load_average = %s, want three numbers", raw)
	}
	for _, v := range got {
		if math.IsNaN(v) || math.IsInf(v, 0) || v < 0 || math.Abs(v*100-math.Round(v*100)) > 1e-9 {
			t.Errorf("load_average = %s, want finite non-negative two-decimal numbers", raw)
		}
	}
}
