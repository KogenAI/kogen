package provider

import (
	"net/http"
	"strings"
	"time"
)

// maxRetryAfter is the longest advertised Retry-After that is waited, inclusive. It is fixed,
// not an option: a longer one ends the call at once.
const maxRetryAfter = 60 * time.Second

// retryAfter is a usable Retry-After of a 429 or 503 answer.
type retryAfter struct {
	wait time.Duration
	// secs is the advertised wait as text for the error detail: the header's digits without
	// leading zeros (never parsed into an integer), or an HTTP-date's wait in whole seconds.
	secs string
}

// usableRetryAfter reads the Retry-After of an HTTP answer: only 429 and 503 count, and only
// RFC 9110 delay-seconds or an HTTP-date; anything else is nil.
func usableRetryAfter(status int, h http.Header, now time.Time) *retryAfter {
	if status != 429 && status != 503 {
		return nil
	}
	v := strings.Trim(h.Get("Retry-After"), " \t")
	if v == "" {
		return nil
	}
	if digitsOnly(v) {
		d := strings.TrimLeft(v, "0")
		if d == "" {
			d = "0"
		}
		wait := maxRetryAfter + time.Second
		if len(d) <= 2 {
			n := 0
			for _, c := range d {
				n = n*10 + int(c-'0')
			}
			wait = time.Duration(n) * time.Second
		}
		return &retryAfter{wait: wait, secs: d}
	}
	t, err := http.ParseTime(v)
	if err != nil {
		return nil
	}
	wait := t.Sub(now)
	if wait < 0 {
		wait = 0
	}
	return &retryAfter{wait: wait, secs: itoa(int64((wait + time.Second - 1) / time.Second))}
}

func digitsOnly(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return s != ""
}

// withRetryAfter attaches the answer's usable Retry-After to a transient result.
func (k *call) withRetryAfter(res result, resp *http.Response) result {
	if res.kind == resTransient {
		res.after = usableRetryAfter(resp.StatusCode, resp.Header, k.c.now())
	}
	return res
}
