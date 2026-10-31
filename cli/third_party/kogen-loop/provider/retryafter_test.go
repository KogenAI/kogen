package provider

import (
	"context"
	"net/http"
	"reflect"
	"strings"
	"testing"
	"time"
)

// raRoute is one HTTP route's test world: it runs a script of answers and reports the
// requests made, the error and the label.
type raRoute struct {
	name, label string
	run         func(t *testing.T, mod func(*env), h ...handler) (e *env, requests func() int, resp *Response, err error)
}

func raRoutes() []raRoute {
	return []raRoute{
		{"chatgpt", "ChatGPT", func(t *testing.T, mod func(*env), h ...handler) (*env, func() int, *Response, error) {
			e, f := chatEnv(t, h...)
			mod(e)
			resp, err := e.respond(Request{Input: user("x")})
			return e, func() int { return len(f.requests()) }, resp, err
		}},
		{"opencode-go", "OpenCode Go", func(t *testing.T, mod func(*env), h ...handler) (*env, func() int, *Response, error) {
			e, f := keyEnv(t, "opencode-go", h...)
			mod(e)
			resp, err := e.c.Respond(context.Background(), e.s, Request{Role: goRole, Instructions: "p", Input: user("x")}, nil)
			return e, func() int { return len(f.requests()) }, resp, err
		}},
		{"anthropic", "Anthropic", func(t *testing.T, mod func(*env), h ...handler) (*env, func() int, *Response, error) {
			e, f := keyEnv(t, "anthropic", h...)
			mod(e)
			resp, err := e.c.Respond(context.Background(), e.s, Request{Role: claudeRole, Instructions: "p", Input: user("x")}, nil)
			return e, func() int { return len(f.requests()) }, resp, err
		}},
	}
}

func (r raRoute) ok() handler {
	switch r.name {
	case "opencode-go":
		return textHandlerGo("done")
	case "anthropic":
		return claudeText("done")
	}
	return textAnswer("done")
}

// limited is a rate-limited answer; retryAfter "-" sends no header.
func limited(status int, retryAfter ...string) handler {
	return func(w http.ResponseWriter, r *http.Request) {
		for _, v := range retryAfter {
			w.Header().Add("Retry-After", v)
		}
		jsonAnswer(status, map[string]any{"error": map[string]any{"message": "rate limited"}})(w, r)
	}
}

func noMod(*env) {}

func secs(n ...int) []time.Duration {
	var out []time.Duration
	for _, v := range n {
		out = append(out, time.Duration(v)*time.Second)
	}
	return out
}

func TestRetryAfterWaits(t *testing.T) {
	for _, rt := range raRoutes() {
		for _, status := range []int{429, 503} {
			for _, tc := range []struct {
				header string
				want   []time.Duration
			}{{"3", secs(3)}, {"003", secs(3)}, {"0", secs(0)}, {"1", secs(1)}, {" \t3 ", secs(3)}} {
				t.Run(rt.name+"/"+tc.header, func(t *testing.T) {
					e, n, resp, err := rt.run(t, noMod, limited(status, tc.header), rt.ok())
					if err != nil || resp == nil || n() != 2 || !reflect.DeepEqual(e.clk.slept(), tc.want) {
						t.Fatalf("%v, %d requests, slept %v", err, n(), e.clk.slept())
					}
				})
			}
			t.Run(rt.name+"/then header-less", func(t *testing.T) {
				e, n, resp, err := rt.run(t, noMod, limited(status, "3"), limited(status), rt.ok())
				if err != nil || resp == nil || n() != 3 || !reflect.DeepEqual(e.clk.slept(), secs(3, 8)) {
					t.Fatalf("%v, %d requests, slept %v", err, n(), e.clk.slept())
				}
			})
		}
		// No usable header keeps 2 s / 8 s.
		for name, h := range map[string]handler{
			"absent": limited(429), "empty": limited(429, ""), "negative": limited(429, "-1"), "fractional": limited(429, "1.5"),
			"text": limited(429, "soon"), "bad date": limited(429, "Sun, 99 Nov 1994 08:49:37 GMT"), "plus": limited(429, "+3"),
			"500": limited(500, "3"), "502": limited(502, "3"), "504": limited(504, "99999"),
		} {
			t.Run(rt.name+"/none/"+name, func(t *testing.T) {
				e, n, _, err := rt.run(t, noMod, h, h, h)
				se := mustErr(t, err)
				if n() != 3 || !reflect.DeepEqual(e.clk.slept(), secs(2, 8)) || se.Reason != "unavailable" || !strings.HasPrefix(se.Detail, rt.label+" did not answer after 3 attempts: ") {
					t.Fatalf("%v, %d requests, slept %v", se, n(), e.clk.slept())
				}
			})
		}
	}
}

func TestRetryAfterBound(t *testing.T) {
	for _, rt := range raRoutes() {
		for _, status := range []int{429, 503} {
			t.Run(rt.name+"/60", func(t *testing.T) {
				e, n, resp, err := rt.run(t, noMod, limited(status, "60"), rt.ok())
				if err != nil || resp == nil || n() != 2 || !reflect.DeepEqual(e.clk.slept(), secs(60)) {
					t.Fatalf("%v, %d requests, slept %v", err, n(), e.clk.slept())
				}
			})
			for _, v := range []string{"61", "0061", "99999999999999999999"} {
				t.Run(rt.name+"/"+v, func(t *testing.T) {
					e, n, _, err := rt.run(t, noMod, limited(status, v), rt.ok())
					se := mustErr(t, err)
					digits := strings.TrimLeft(v, "0")
					if n() != 1 || len(e.clk.slept()) != 0 || se.Class != "provider" || se.Reason != "unavailable" || se.Exit != 4 ||
						!strings.HasPrefix(se.Detail, rt.label+" asked to wait "+digits+" s before retrying, more than the 60 s limit: ") ||
						strings.Contains(se.Detail, "did not answer") {
						t.Fatalf("%v, %d requests, slept %v", se, n(), e.clk.slept())
					}
					if !strings.Contains(strings.Join(se.Lines, "|"), "provider failure: ") {
						t.Fatalf("no diagnostics: %v", se.Lines)
					}
				})
			}
		}
	}
	t.Run("exact detail", func(t *testing.T) {
		_, _, _, err := raRoutes()[0].run(t, noMod, limited(429, "61"))
		if se := mustErr(t, err); se.Detail != "ChatGPT asked to wait 61 s before retrying, more than the 60 s limit: HTTP 429 rate limited" {
			t.Fatal(se.Detail)
		}
	})
	t.Run("three attempts", func(t *testing.T) {
		for _, rt := range raRoutes() {
			e, n, _, err := rt.run(t, noMod, limited(429, "1"), limited(429, "1"), limited(429, "1"))
			se := mustErr(t, err)
			if n() != 3 || !reflect.DeepEqual(e.clk.slept(), secs(1, 1)) || !strings.HasPrefix(se.Detail, rt.label+" did not answer after 3 attempts: ") {
				t.Fatalf("%s: %v, %d requests, slept %v", rt.name, se, n(), e.clk.slept())
			}
			// the third attempt's header is never a wait or a bound
			e, n, _, err = rt.run(t, noMod, limited(429, "1"), limited(429, "1"), limited(429, "120"))
			se = mustErr(t, err)
			if n() != 3 || !reflect.DeepEqual(e.clk.slept(), secs(1, 1)) || !strings.HasPrefix(se.Detail, rt.label+" did not answer after 3 attempts: ") {
				t.Fatalf("%s: %v, %d requests, slept %v", rt.name, se, n(), e.clk.slept())
			}
		}
	})
	t.Run("budget", func(t *testing.T) {
		for _, rt := range raRoutes() {
			e, n, _, err := rt.run(t, func(e *env) { e.c.ResponseBudget = 10 * time.Second }, limited(429, "30"), rt.ok())
			se := mustErr(t, err)
			var total time.Duration
			for _, d := range e.clk.slept() {
				total += d
			}
			if n() != 1 || total > 10*time.Second || total == 0 || se.Reason != "unavailable" || strings.Contains(se.Detail, "did not answer") || strings.Contains(se.Detail, "asked to wait") {
				t.Fatalf("%s: %v, %d requests, slept %v", rt.name, se, n(), e.clk.slept())
			}
		}
	})
	t.Run("single", func(t *testing.T) {
		e, f := chatEnv(t, limited(429, "3"), textAnswer("never"))
		_, err := single(e)
		se := mustErr(t, err)
		if len(f.requests()) != 1 || len(e.clk.slept()) != 0 || se.Reason != "unavailable" || se.Detail != "HTTP 429 rate limited" {
			t.Fatalf("%v, %d requests", se, len(f.requests()))
		}
	})
}

func dateHeader(c *clock, ahead time.Duration) string {
	return c.Now().Add(ahead).UTC().Format(http.TimeFormat)
}

func TestRetryAfterDate(t *testing.T) {
	for _, rt := range raRoutes() {
		// the clock is created inside run, so the date is computed by the handler at request time
		dated := func(status int, ahead time.Duration, clk **clock) handler {
			return func(w http.ResponseWriter, r *http.Request) {
				limited(status, dateHeader(*clk, ahead))(w, r)
			}
		}
		var clk *clock
		mod := func(e *env) { clk = e.clk }
		t.Run(rt.name+"/ahead", func(t *testing.T) {
			// ParseTime truncates to seconds, so align the fake clock to a whole second
			e, n, resp, err := rt.run(t, func(e *env) { e.clk.t = e.clk.t.Truncate(time.Second); mod(e) }, dated(429, 5*time.Second, &clk), rt.ok())
			if err != nil || resp == nil || n() != 2 || !reflect.DeepEqual(e.clk.slept(), secs(5)) {
				t.Fatalf("%v, %d requests, slept %v", err, n(), e.clk.slept())
			}
		})
		t.Run(rt.name+"/past", func(t *testing.T) {
			e, n, resp, err := rt.run(t, func(e *env) { e.clk.t = e.clk.t.Truncate(time.Second); mod(e) }, dated(503, -30*time.Second, &clk), rt.ok())
			if err != nil || resp == nil || n() != 2 || !reflect.DeepEqual(e.clk.slept(), secs(0)) {
				t.Fatalf("%v, %d requests, slept %v", err, n(), e.clk.slept())
			}
		})
		t.Run(rt.name+"/over", func(t *testing.T) {
			e, n, _, err := rt.run(t, func(e *env) { e.clk.t = e.clk.t.Truncate(time.Second); mod(e) }, dated(429, 90*time.Second, &clk), rt.ok())
			se := mustErr(t, err)
			if n() != 1 || len(e.clk.slept()) != 0 || !strings.HasPrefix(se.Detail, rt.label+" asked to wait 90 s before retrying, more than the 60 s limit: ") {
				t.Fatalf("%v, %d requests", se, n())
			}
		})
	}
	t.Run("other formats", func(t *testing.T) {
		now := time.Date(1994, 11, 6, 8, 49, 0, 0, time.UTC)
		for _, v := range []string{"Sun, 06 Nov 1994 08:49:05 GMT", "Sunday, 06-Nov-94 08:49:05 GMT", "Sun Nov  6 08:49:05 1994"} {
			a := usableRetryAfter(429, http.Header{"Retry-After": {v}}, now)
			if a == nil || a.wait != 5*time.Second || a.secs != "5" {
				t.Fatalf("%q: %+v", v, a)
			}
		}
		// the date's wait is rounded up for the detail
		a := usableRetryAfter(503, http.Header{"Retry-After": {"Sun, 06 Nov 1994 08:50:30 GMT"}}, now.Add(500*time.Millisecond))
		if a == nil || a.secs != "90" {
			t.Fatalf("%+v", a)
		}
	})
}
