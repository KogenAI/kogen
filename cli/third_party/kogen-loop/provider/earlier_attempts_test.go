package provider

import (
	"reflect"
	"strings"
	"testing"
)

func earlierLines(lines []string) (earlier []string) {
	for _, l := range lines {
		if strings.HasPrefix(l, "earlier attempts:") {
			earlier = append(earlier, l)
		}
	}
	return earlier
}

func TestEarlierAttemptsNamesBothEarlierFailures(t *testing.T) {
	t.Parallel()
	e, f := chatEnv(t, limited(429), jsonAnswer(503, map[string]any{"error": map[string]any{"message": "overloaded"}}), limited(502))
	_, err := e.respond(Request{Input: user("x")})
	se := mustErr(t, err)
	if se.Class != "provider" || se.Reason != "unavailable" || se.Exit != 4 ||
		se.Detail != "ChatGPT did not answer after 3 attempts: HTTP 502 rate limited" {
		t.Fatalf("error %v", se)
	}
	if len(f.requests()) != 3 || !reflect.DeepEqual(e.clk.slept(), secs(2, 8)) {
		t.Fatalf("%d requests, slept %v", len(f.requests()), e.clk.slept())
	}
	want := []string{`provider failure: {"http_status":502}`, "earlier attempts: 1 HTTP 429 rate limited; 2 HTTP 503 overloaded"}
	if !reflect.DeepEqual(se.Lines, want) {
		t.Fatalf("lines %q, want %q", se.Lines, want)
	}
}

func TestEarlierAttemptsIdenticalFailuresAddNoLine(t *testing.T) {
	t.Parallel()
	e, f := chatEnv(t, limited(429), limited(429), limited(429))
	_, err := e.respond(Request{Input: user("x")})
	se := mustErr(t, err)
	if se.Detail != "ChatGPT did not answer after 3 attempts: HTTP 429 rate limited" || len(f.requests()) != 3 || !reflect.DeepEqual(e.clk.slept(), secs(2, 8)) {
		t.Fatalf("%v, %d requests, slept %v", se, len(f.requests()), e.clk.slept())
	}
	if want := []string{`provider failure: {"http_status":429}`}; !reflect.DeepEqual(se.Lines, want) {
		t.Fatalf("lines %q, want %q", se.Lines, want)
	}
}

func TestEarlierAttemptsAfterRetryAfterBound(t *testing.T) {
	t.Parallel()
	e, f := chatEnv(t, limited(429), limited(503, "90"), textAnswer("done"))
	_, err := e.respond(Request{Input: user("x")})
	se := mustErr(t, err)
	if se.Class != "provider" || se.Reason != "unavailable" || se.Exit != 4 ||
		se.Detail != "ChatGPT asked to wait 90 s before retrying, more than the 60 s limit: HTTP 503 rate limited" {
		t.Fatalf("error %v", se)
	}
	if len(f.requests()) != 2 || !reflect.DeepEqual(e.clk.slept(), secs(2)) {
		t.Fatalf("%d requests, slept %v", len(f.requests()), e.clk.slept())
	}
	want := []string{`provider failure: {"http_status":503}`, "earlier attempts: 1 HTTP 429 rate limited"}
	if !reflect.DeepEqual(se.Lines, want) {
		t.Fatalf("lines %q, want %q", se.Lines, want)
	}
	if got := earlierLines(se.Lines); len(got) != 1 {
		t.Fatalf("earlier lines %q", got)
	}
}
