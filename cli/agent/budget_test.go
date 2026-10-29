package agent

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"kogen-loop/provider"
	"kogen-loop/sys"
)

// TestBudgetRoleConstants holds the response budget of each role: Build and Review get the
// fixed ten minutes; a client nothing configured keeps zero and so the loop's thirty minutes.
// The run record names the effective budget.
func TestBudgetRoleConstants(t *testing.T) {
	if BuildReviewBudget != 10*time.Minute {
		t.Fatalf("Build/Review budget %s", BuildReviewBudget)
	}
	if got := ApplyBuildReview(provider.NewClient("")).ResponseBudget; got != 10*time.Minute {
		t.Fatalf("Build/Review client %s", got)
	}
	if ApplyBuildReview(nil) != nil {
		t.Fatal("nil client became a client")
	}
	if provider.NewClient("").ResponseBudget != 0 {
		t.Fatal("a new client has a budget")
	}
	for _, c := range []struct {
		client *provider.Client
		ms     int64
		text   string
	}{
		{nil, 1800000, "30 minutes"},
		{provider.NewClient(""), 1800000, "30 minutes"},
		{ApplyBuildReview(provider.NewClient("")), 600000, "10 minutes"},
	} {
		if e := BudgetEvent(c.client); e["event"] != "response_budget" || e["budget"] != c.text || e["budget_ms"] != c.ms || len(e) != 3 {
			t.Errorf("event %v, want %d %s", e, c.ms, c.text)
		}
	}
}

// TestNameBudgetExpiryNamesTheTenMinuteExpiry holds that only the ten-minute expiry is renamed:
// other durations, classes and reasons pass unchanged.
func TestNameBudgetExpiryNamesTheTenMinuteExpiry(t *testing.T) {
	got := NameBudgetExpiry(sys.Fail("provider", "unavailable", "SuperGrok response wait exceeded 10m0s", 4), 10*time.Minute).(*sys.Error)
	if got.Class != "provider" || got.Reason != "unavailable" || got.Exit != 4 || got.Detail != "SuperGrok response wait exceeded 10 minutes" {
		t.Fatalf("%+v", got)
	}
	for _, c := range []struct {
		budget time.Duration
		err    *sys.Error
	}{
		{10 * time.Minute, sys.Fail("provider", "unavailable", "ChatGPT response wait exceeded 2s", 4)},
		{10 * time.Minute, sys.Fail("provider", "unavailable", "ChatGPT response wait exceeded 30 minutes", 4)},
		{10 * time.Minute, sys.Fail("provider", "refused", "ChatGPT response wait exceeded 10m0s", 4)},
		{10 * time.Minute, sys.Fail("provider", "unavailable", "the response wait exceeded 10m0s of patience", 4)},
		{time.Second, sys.Fail("provider", "unavailable", "ChatGPT response wait exceeded 1s", 4)},
		{5 * time.Minute, sys.Fail("provider", "unavailable", "ChatGPT response wait exceeded 5m0s", 4)},
	} {
		if err := NameBudgetExpiry(c.err, c.budget); err != error(c.err) {
			t.Errorf("%q was changed: %v", c.err.Detail, err)
		}
	}
	if NameBudgetExpiry(nil, 10*time.Minute) != nil {
		t.Error("nil became an error")
	}
}

// TestNameBudgetExpiryEndsUnavailableNamingTenMinutes runs a real client whose clock passes ten
// minutes while the provider stalls.
func TestNameBudgetExpiryEndsUnavailableNamingTenMinutes(t *testing.T) {
	var mu sync.Mutex
	now := time.Now()
	clock := func() time.Time { mu.Lock(); defer mu.Unlock(); return now }
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		w.WriteHeader(http.StatusOK)
		w.(http.Flusher).Flush()
		mu.Lock()
		now = now.Add(10*time.Minute + time.Second)
		mu.Unlock()
		panic(http.ErrAbortHandler)
	}))
	defer srv.Close()
	home := t.TempDir()
	dir := filepath.Join(home, ".kogen", "credentials")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	key, _ := json.Marshal(map[string]any{"provider": "anthropic", "api_key": "sk-ant-FIXTURE-KEY"})
	if err := os.WriteFile(filepath.Join(dir, "anthropic.json"), key, 0o600); err != nil {
		t.Fatal(err)
	}
	s := sys.NewWith([]string{"PATH=" + os.Getenv("PATH"), "HOME=" + home, "KOGEN_PROVIDER_URL=" + srv.URL, "KOGEN_AUTH_URL=" + srv.URL}, t.TempDir())
	c := ApplyBuildReview(provider.NewClient("kogen dev+12345678 (test)"))
	c.Sleep = func(context.Context, time.Duration) error { return nil }
	c.Now = clock
	req := provider.Request{
		Role: provider.Role{Provider: "anthropic", Model: "claude-sonnet-5-5", Effort: "high"}, Instructions: "policy", CacheID: "budget-test",
		Input: []any{map[string]any{"role": "user", "content": strings.Repeat("a", 10)}},
	}
	_, err := c.Respond(context.Background(), s, req, nil)
	err = NameBudgetExpiry(err, c.ResponseBudget)
	e, ok := sys.AsError(err)
	if !ok || e.Class != "provider" || e.Reason != "unavailable" || e.Exit != 4 || !strings.HasSuffix(e.Detail, "response wait exceeded 10 minutes") {
		t.Fatalf("err %v", err)
	}
}
