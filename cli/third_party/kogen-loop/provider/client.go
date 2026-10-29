package provider

import (
	"context"
	"errors"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"kogen-loop/sys"
)

// ResponseBudget is the fixed absolute budget of one logical Respond call (GPT-8).
const ResponseBudget = 30 * time.Minute

// Client talks to the providers. The zero value works; NewClient also keeps prompt-cache
// state across requests.
type Client struct {
	// HTTP sends every request; nil uses a client with a 30 s connect ceiling, verified TLS,
	// no proxy and no transparent compression.
	HTTP *http.Client
	// Now is the clock for budgets, token expiry, device-code lifetimes and timestamps.
	Now func() time.Time
	// Sleep pauses for backoff, lock waits and device-code pacing; it returns early with
	// the context's error.
	Sleep func(ctx context.Context, d time.Duration) error
	// Cache holds the conversations' cache identities shared by requests that do not bring their own.
	Cache *Cache
	// Locker takes the credential locks.
	Locker Locker
	// Input is where key logins read their secret; nil is the process's standard input.
	Input *Input
	// Version is Kogen's version line (`kogen dev+12345678 (test)`); its second word names
	// Kogen in SuperGrok's user-agent.
	Version string
	// ResponseBudget lowers the absolute budget of one logical Respond call. Zero keeps
	// the package ResponseBudget (30 minutes); a nonzero value must be in [1s, 30m].
	ResponseBudget time.Duration

	httpOnce sync.Once
	defHTTP  *http.Client
}

// NewClient returns a Client with the default transport and no conversation cache identities yet.
func NewClient(version string) *Client {
	return &Client{Cache: NewCache(nil), Version: version}
}

func (c *Client) now() time.Time {
	if c.Now != nil {
		return c.Now()
	}
	return time.Now()
}

func (c *Client) sleep(ctx context.Context, d time.Duration) error {
	if c.Sleep != nil {
		return c.Sleep(ctx, d)
	}
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-t.C:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (c *Client) http() *http.Client {
	if c.HTTP != nil {
		return c.HTTP
	}
	c.httpOnce.Do(func() {
		c.defHTTP = &http.Client{Transport: &http.Transport{
			DialContext:         (&net.Dialer{Timeout: 30 * time.Second}).DialContext,
			TLSHandshakeTimeout: 30 * time.Second,
			DisableCompression:  true,
			MaxIdleConnsPerHost: 4,
			IdleConnTimeout:     90 * time.Second,
		}}
	})
	return c.defHTTP
}

func (c *Client) userAgent() string {
	f := strings.Fields(c.Version)
	if len(f) > 1 {
		return "kogen/" + f[1]
	}
	return "kogen/"
}

// call is one logical operation: a session, its environment, the provider and the
// absolute budget that bytes, heartbeats and retries cannot renew.
type call struct {
	c        *Client
	s        *sys.Session
	ctx      context.Context
	cancel   context.CancelFunc
	info     Info
	home     string
	deadline time.Time // zero: no budget
	expiry   string    // the duration text of the expiry detail; empty: the default 30 minutes
	baseURL  string    // the role's base_url (openai-compatible only)
}

func (c *Client) newCall(ctx context.Context, s *sys.Session, info Info, budget time.Duration) *call {
	if ctx == nil {
		ctx = context.Background()
	}
	ctx, cancel := context.WithCancel(ctx)
	if s != nil {
		stop := context.AfterFunc(s.Context(), cancel)
		prev := cancel
		cancel = func() { stop(); prev() }
	}
	k := &call{c: c, s: s, ctx: ctx, cancel: cancel, info: info}
	if s != nil {
		k.home = s.Getenv("HOME")
	}
	if budget > 0 {
		k.deadline = c.now().Add(budget)
	}
	return k
}

func (k *call) env(name string) string {
	if k.s == nil {
		return ""
	}
	return k.s.Getenv(name)
}

func (k *call) authBase() string {
	if v := k.env("KOGEN_AUTH_URL"); v != "" {
		return v
	}
	return k.info.AuthBase
}

// apiBase is the origin's Responses root, ending in /v1.
func (k *call) apiBase() string {
	if v := k.env("KOGEN_PROVIDER_URL"); v != "" {
		return v + "/v1"
	}
	return k.info.APIBase + "/v1"
}

// interrupted is the caller's interrupt, if any.
func (k *call) interrupted() error {
	if k.s != nil {
		if err := k.s.Err(); err != nil {
			return err
		}
	}
	return nil
}

func (k *call) expired() error {
	text := k.expiry
	if text == "" {
		text = "30 minutes"
	}
	return providerFail("unavailable", k.info.Label+" response wait exceeded "+text)
}

// check is Kogen's `remaining` without the time: an interrupt or an expired budget stops the call.
func (k *call) check() error {
	_, err := k.remaining()
	return err
}

// remaining is the time left in the budget (a huge value without one); it fails for an
// interrupt or once the budget is spent.
func (k *call) remaining() (time.Duration, error) {
	if err := k.interrupted(); err != nil {
		return 0, err
	}
	if k.deadline.IsZero() {
		return time.Duration(1<<62 - 1), nil
	}
	d := k.deadline.Sub(k.c.now())
	if d <= 0 {
		return 0, k.expired()
	}
	return d, nil
}

// pause waits d, at most the remaining budget, then fails if the budget is spent.
func (k *call) pause(d time.Duration) error {
	rem, err := k.remaining()
	if err != nil {
		return err
	}
	if rem < d {
		d = rem
	}
	if err := k.c.sleep(k.ctx, d); err != nil {
		if ie := k.interrupted(); ie != nil {
			return ie
		}
		return err
	}
	return k.check()
}

// stopped converts a transport error caused by cancellation or expiry into the error
// the caller sees; ok is false when the failure was an ordinary network error.
func (k *call) stopped() (error, bool) {
	if err := k.interrupted(); err != nil {
		return err, true
	}
	if err := k.ctx.Err(); err != nil {
		return err, true
	}
	if !k.deadline.IsZero() && !k.c.now().Before(k.deadline) {
		return k.expired(), true
	}
	return nil, false
}

// requestContext limits one HTTP exchange to the remaining budget.
func (k *call) requestContext() (context.Context, context.CancelFunc, error) {
	rem, err := k.remaining()
	if err != nil {
		return nil, nil, err
	}
	if k.deadline.IsZero() {
		ctx, cancel := context.WithCancel(k.ctx)
		return ctx, cancel, nil
	}
	ctx, cancel := context.WithTimeout(k.ctx, rem)
	return ctx, cancel, nil
}

// networkText is a transport error without the request URL.
func networkText(err error) string {
	var ue *url.Error
	if errors.As(err, &ue) {
		err = ue.Err
	}
	return err.Error()
}

// postForm sends an application/x-www-form-urlencoded token request and returns the
// status (0 for a network failure) with the JSON object answered ({} when it was not one).
// limit, when set, is an extra absolute time (device code lifetime) after which the wait
// ends with errLimit.
func (k *call) postForm(endpoint string, form url.Values, userAgent string, limit time.Time) (int, map[string]any, error) {
	budgetCtx, cancel, err := k.requestContext()
	if err != nil {
		return 0, nil, err
	}
	defer cancel()
	ctx := budgetCtx
	if !limit.IsZero() {
		wait := limit.Sub(k.c.now())
		if wait < 0 {
			wait = 0
		}
		var cancelLimit context.CancelFunc
		ctx, cancelLimit = context.WithTimeout(budgetCtx, wait)
		defer cancelLimit()
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, strings.NewReader(form.Encode()))
	if err != nil {
		return 0, map[string]any{"error": err.Error()}, nil
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	if userAgent != "" {
		req.Header.Set("User-Agent", userAgent)
	} else {
		req.Header["User-Agent"] = []string{""}
	}
	resp, err := k.c.http().Do(req)
	var body []byte
	if err == nil {
		body, err = io.ReadAll(io.LimitReader(resp.Body, 4<<20))
		resp.Body.Close()
	}
	if err != nil {
		if stop, ok := k.stopped(); ok {
			return 0, nil, stop
		}
		if budgetCtx.Err() != nil {
			return 0, nil, k.expired()
		}
		if ctx.Err() != nil {
			return 0, nil, errLimit
		}
		if k.info.supergrok() {
			return 0, map[string]any{}, nil
		}
		return 0, map[string]any{"error": networkText(err)}, nil
	}
	if cerr := k.check(); cerr != nil {
		return 0, nil, cerr
	}
	out := map[string]any{}
	if v, derr := decodeJSON(body); derr == nil {
		if m, ok := asMap(v); ok {
			out = m
		}
	}
	return resp.StatusCode, out, nil
}

var errLimit = errors.New("device code lifetime reached")

// withLock runs fn holding the credentials lock, waiting 100 ms at a time while another
// live process holds it. The wait shares the call's budget.
func (k *call) withLock(fn func() (string, error)) (string, error) {
	path := lockPath(k.home, k.info)
	for {
		if err := k.check(); err != nil {
			return "", err
		}
		lock, err := k.c.Locker.Acquire(path)
		var held *HeldError
		switch {
		case errors.As(err, &held):
			if perr := k.pause(100 * time.Millisecond); perr != nil {
				return "", perr
			}
			continue
		case err != nil:
			return "", err
		}
		defer lock.Release()
		return fn()
	}
}
