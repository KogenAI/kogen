package provider

import (
	"bytes"
	"context"
	"io"
	"net/http"
	"regexp"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"kogen-loop/sys"
)

// Request is one logical model request: the role, the policy text, the whole conversation
// and the tool definitions.
type Request struct {
	Role         Role
	Instructions string
	Input, Tools []any
	// ToolChoice, when nonempty, names the one tool the provider must call for this request
	// (an API-level requirement): Responses {"type":"function","name":N}, Chat Completions
	// {"type":"function","function":{"name":N}}. It applies only when Tools is nonempty. A
	// route that cannot force a tool (see SupportsToolChoice) refuses the request with
	// provider/unsupported_capability before any transport, never ignoring it. Empty sends
	// today's exact bytes.
	ToolChoice string
	// Single makes ChatGPT attempts single-shot: no retry of transient or unreadable
	// answers and no refresh after a 401 (the other providers keep their retries).
	Single bool
	// CacheID is the conversation's cache identity (at most 64 characters): create it once
	// with NewCacheID or Cache.Identity when the conversation starts, keep it with the
	// conversation's checkpoint and pass it on every request of it. Empty derives it from
	// Scope and Cache.
	CacheID string
	// Scope names the independent conversation when CacheID is empty: a Build's
	// [root run, role, review number], a shaping evidence directory, a batch job ID. With
	// the role's provider and model it selects the identity the Cache keeps.
	Scope any
	// Cache holds the conversation identities; nil uses the Client's.
	Cache *Cache
	// Context is merged into every attempt record (phase, role, slug, run_id, lineage,
	// pass, repair).
	Context map[string]any
}

// Response is a completed, validated answer.
type Response struct {
	Items      []map[string]any
	Usage      Usage      // compatible totals; zero when the usage was inconsistent
	Known      KnownUsage // validated analytical usage
	UsageState string
	ID         string // the provider's response ID ("" if none)
	Model      string // effective model reported by the provider
	Effort     string // effective reasoning effort reported by the provider
	// CacheStatus is the prompt-cache status of the answering attempt: applied,
	// unsupported or unknown.
	CacheStatus string
	// OperationID links every attempt record of this logical call.
	OperationID string
	// Metadata is the response object's id, model, service_tier, reasoning and
	// prompt_cache_diagnostics as received.
	Metadata map[string]any
}

// Observer receives one record per transport attempt, completed or not, in order: the
// `provider` object of the run log's provider_attempt event (and of shaping evidence).
// The map holds plain JSON data.
type Observer interface{ Attempt(record map[string]any) }

var seamPattern = regexp.MustCompile(`^http://(127\.0\.0\.1|localhost):[0-9]+$`)

// ErrMissingSession is the validation error of a request made without a Session: it is
// refused before any credential is read or any request is sent.
func ErrMissingSession() *sys.Error {
	return sys.Fail("validation", "missing_session", "Session is required", 2)
}

// CheckSeams refuses a KOGEN_PROVIDER_URL or KOGEN_AUTH_URL that is not a loopback
// http origin (GPT-11): environment/invalid_test_seam, exit 3.
func CheckSeams(s *sys.Session) error {
	if s == nil {
		return ErrMissingSession()
	}
	for _, name := range []string{"KOGEN_PROVIDER_URL", "KOGEN_AUTH_URL"} {
		if v, ok := s.LookupEnv(name); ok && !seamPattern.MatchString(v) {
			return sys.Fail("environment", "invalid_test_seam", name+" must be http://127.0.0.1:<port> or http://localhost:<port>", 3)
		}
	}
	return nil
}

// InputBudgetBytes is the inclusive ceiling of one complete next request.
const InputBudgetBytes = 524288

// OutputReserveTokens is conservative accounting, not a wire allowance.
const OutputReserveTokens = 131072

// run is the state of one logical Respond.
type run struct {
	k       *call
	req     Request
	obs     Observer
	cache   *Cache
	key     string // the conversation's key in cache
	state   CacheState
	rend    rendered
	encoded []byte
	hasKey  bool // the body carries SuperGrok's prompt_cache_key
	ev      evidence
	op      operation
	model   string

	requestID   string
	cacheStatus string
	respMeta    map[string]any
	so          *streamObs // the current attempt's stream observations
	watch       *idleWatch // the current attempt's first-byte and idle timer
}

type operation struct {
	id, timestamp, model, effort string
}

func (c *Client) cacheFor(req Request) *Cache {
	if req.Cache != nil {
		return req.Cache
	}
	if c.Cache != nil {
		return c.Cache
	}
	return NewCache(nil)
}

// resolve finds the conversation a request belongs to: the caller's CacheID, or the identity
// the Cache keeps for the request's provider, model and Scope (created on first use).
func (c *Cache) resolve(req Request) (key string, st CacheState) {
	if req.CacheID != "" {
		c.mu.Lock()
		defer c.mu.Unlock()
		key = "id:" + req.CacheID
		st = c.states[key]
		st.ID = req.CacheID
		if Name(req.Role) == "chatgpt" && st.Control != "prompt_cache_key" {
			st.Control = "prompt_cache_key"
			st.Unsupported = false
		}
		c.states[key] = st
		return key, st
	}
	key = conversationKey(req.Role, req.Scope)
	st, _ = c.conversation(key)
	if Name(req.Role) == "chatgpt" && st.Control != "prompt_cache_key" {
		st.Control = "prompt_cache_key"
		st.Unsupported = false
		c.put(key, st)
	}
	return key, st
}

// Render is the request body Respond would send, written for the role's provider with the
// conversation's cache identity in place, without sending anything. A request the provider
// cannot take (typed images on OpenCode Go or Anthropic) is refused here, before inference.
func (c *Client) Render(req Request) (map[string]any, error) {
	info, ok := Lookup(req.Role.Provider)
	if !ok {
		return nil, sys.Fail("provider", "refused", "unknown provider "+req.Role.Provider, 4)
	}
	_, st := c.cacheFor(req).resolve(req)
	r, err := render(info, req, wireID(st.ID), st.Unsupported && (info.supergrok() || info.chatgpt()))
	return r.body, err
}

// Body is Render without the refusal: the body Respond would send, for measuring the
// complete next request. A refused request still returns its body.
func (c *Client) Body(req Request) map[string]any {
	info, _ := Lookup(req.Role.Provider)
	_, st := c.cacheFor(req).resolve(req)
	r, _ := render(info, req, wireID(st.ID), st.Unsupported && (info.supergrok() || info.chatgpt()))
	return r.body
}

// Respond sends one request and returns the validated answer. Provider failures are
// *sys.Error (class provider, exit 4, reason context_too_long when the conversation no
// longer fits); an interrupt is *sys.Interrupted. One logical call has a 30-minute
// budget (lowerable by Client.ResponseBudget) shared by credentials, refresh, retries and backoff (GPT-8).
func (c *Client) Respond(ctx context.Context, s *sys.Session, req Request, obs Observer) (*Response, error) {
	if s == nil {
		return nil, ErrMissingSession()
	}
	info, ok := Lookup(req.Role.Provider)
	if !ok {
		return nil, sys.Fail("provider", "refused", "unknown provider "+req.Role.Provider, 4)
	}
	if err := CheckSeams(s); err != nil {
		return nil, err
	}
	budget := ResponseBudget
	if c.ResponseBudget != 0 {
		if c.ResponseBudget < time.Second || c.ResponseBudget > ResponseBudget {
			return nil, sys.Fail("provider", "refused", "response budget must be zero or between 1s and 30m0s", 4)
		}
		budget = c.ResponseBudget
	}
	if info.compatible() && req.Role.BaseURL == "" {
		return nil, sys.Fail("provider", "refused", "openai-compatible needs base_url in .kogen/project.yaml", 4)
	}
	k := c.newCall(ctx, s, info, budget)
	defer k.cancel()
	if c.ResponseBudget != 0 {
		k.expiry = budget.String()
	}
	k.baseURL = strings.TrimRight(req.Role.BaseURL, "/")
	cache := c.cacheFor(req)
	key, st := cache.resolve(req)
	unsupported := st.Unsupported && (info.supergrok() || info.chatgpt())
	id := wireID(st.ID)
	rend, err := render(info, req, id, unsupported)
	if err != nil {
		return nil, err
	}
	encoded, err := encodeBody(info, rend.body)
	if err != nil {
		return nil, err
	}
	limits := Limits{}
	if p := ResolveProfile(req.Role); p != nil {
		limits = p.Limits
	}
	limit := UsableInputBytes(limits)
	if !FitsInputBytes(len(encoded), limits) {
		return nil, sys.Fail("candidate", "context_budget_exceeded", "Complete next request "+itoa(int64(len(encoded)))+
			" bytes exceeds "+itoa(int64(limit))+"; reserve 131072 tokens. Retain private source/replay; use external image preparation or ordinary Refine and new approval.", 1)
	}
	_, hasKey := rend.body["prompt_cache_key"]
	ev := newEvidence(id, rend.mode, rend.boundaries, unsupported, req.Instructions, req.Input, req.Tools)
	r := &run{k: k, req: req, obs: obs, cache: cache, key: key, state: st, rend: rend, encoded: encoded,
		hasKey: hasKey && (info.supergrok() || info.chatgpt()), model: req.Role.Model,
		ev: ev,
		op: operation{id: newID("operation"), timestamp: timestamp(c.now()), model: req.Role.Model, effort: req.Role.Effort}}
	var resp *Response
	if req.Single && info.chatgpt() {
		resp, err = r.single()
	} else {
		resp, err = r.attempts()
	}
	err = modelHint(err, info, req.Role)
	if e, ok := err.(*sys.Error); ok && e.Class == "provider" && (e.Reason == "refused" || e.Reason == "model_unavailable" || e.Reason == "context_too_long") {
		classification := Classify(req, s)
		copy := *e
		selector := ".kogen/project.yaml (role selection)"
		role := classification.Role
		if role == "shape" || role == "build" || role == "review" {
			selector = ".kogen/project.yaml models." + role + ".model / models." + role + ".effort"
		} else if role == "read" || role == "probe" || role == "draft" {
			selector = ".kogen/project.yaml shape_workers." + role + ".model / shape_workers." + role + ".effort"
		} else if role == "" {
			role = "unknown"
		}
		copy.Lines = append(append([]string(nil), e.Lines...), "selection "+classification.Status+": role "+role+", provider "+classification.Provider+", configured model "+classification.Model+", effort "+classification.Effort+"; edit "+selector)
		err = &copy
	}
	return resp, err
}

// modelHint adds the fix to a provider's refusal of the model or the request (KOGEN-057):
// Kogen sends any configured model and effort unchanged, so a refusal may mean the provider
// does not offer them. The first line stays the provider's error; nothing is retried.
func modelHint(err error, info Info, role Role) error {
	e, ok := err.(*sys.Error)
	if !ok || e.Class != "provider" {
		return err
	}
	status, _ := asInt(e.ProviderFailure["http_status"])
	if e.Reason != "model_unavailable" && !(e.Reason == "refused" && (status == 400 || status == 404 || status == 422)) {
		return err
	}
	c := *e
	c.Lines = append(append([]string(nil), e.Lines...), "model "+role.Model+" with effort "+role.Effort+
		" was sent to "+info.Label+" unchanged and not retried; if "+info.Label+" does not offer them, set another model or effort for this role in .kogen/project.yaml")
	return &c
}

func timestamp(t time.Time) string { return t.UTC().Format("2006-01-02T15:04:05.000000Z") }

func (r *run) response(res result) *Response {
	id := identifier(res.meta["id"])
	resp := &Response{
		Items: res.items, Usage: res.usage, Known: res.known, UsageState: res.state,
		ID: id, Model: identifier(res.meta["model"]), Effort: returnedEffort(res.meta["reasoning"]),
		CacheStatus: r.cacheStatus, OperationID: r.op.id, Metadata: res.meta,
	}
	return resp
}

func returnedEffort(v any) string {
	if m, ok := asMap(v); ok {
		return identifier(m["effort"])
	}
	return ""
}

func (r *run) label() string { return r.k.info.Label }

func (r *run) unavailable(detail string, diag map[string]any) error {
	return withDiagnostics(providerFail("unavailable", detail), diag)
}

// refusedError is a key provider's definite refusal: the reason chosen from its status, the
// safe diagnostics and the sanitised upstream message, when one was kept.
func (r *run) refusedError(res result) error {
	status, _ := asInt(res.fail.status)
	err := withDiagnostics(providerFail(res.reason, r.label()+" refused HTTP "+itoa(status)+"; no route or model fallback"), res.fail.diagnostics())
	if e, ok := err.(*sys.Error); ok && res.fail.message != "" {
		e.Lines = append(e.Lines, r.label()+" said: "+res.fail.message)
	}
	return err
}

// hostMessage is an OpenAI-compatible host's error text made safe to print: one line of at most
// 300 bytes without control characters, the saved key redacted; "" when nothing printable is left.
func hostMessage(msg, key string) string {
	if key != "" {
		msg = strings.ReplaceAll(msg, key, "[redacted]")
	}
	msg = strings.Join(strings.FieldsFunc(msg, func(r rune) bool { return unicode.IsSpace(r) || unicode.IsControl(r) }), " ")
	if !utf8.ValidString(msg) {
		return ""
	}
	if len(msg) > 300 {
		cut := 300
		for cut > 0 && !utf8.RuneStart(msg[cut]) {
			cut--
		}
		msg = msg[:cut] + "…"
	}
	return msg
}

// malformed is an unreadable answer of a key provider: never retried.
func (r *run) malformed() error {
	return providerFail("invalid_response", "malformed "+r.label()+" completion")
}

// single is the single-attempt mode of a ChatGPT request (shaping workers and probes).
func (r *run) single() (*Response, error) {
	token, err := r.k.accessToken()
	if err != nil {
		return nil, err
	}
	res, err := r.transport(token)
	if err != nil {
		return nil, err
	}
	if res.kind == resError && r.refused(res.fail) {
		// A definite nonexecuting cache-key refusal is compatibility, not a
		// transient retry. Keep the same call deadline and token; strip once.
		r.stripKey()
		res, err = r.transport(token)
		if err != nil {
			return nil, err
		}
	}
	switch res.kind {
	case resOK:
		return r.response(res), nil
	case resError:
		return nil, res.fail.classify(r.k.info, r.model)
	case resUnauthorized:
		return nil, r.k.rejected(res.fail.diagnostics())
	case resTransient:
		return nil, r.unavailable(res.detail, res.diag)
	}
	return nil, providerFail("invalid_response", res.detail)
}

// attempts is the retrying mode: up to 3 transport attempts with 2 s then 8 s waits, one
// retry of an unreadable answer, one refresh and retry after a 401 (never for an API key,
// never for a key provider's unreadable answer).
func (r *run) attempts() (*Response, error) {
	n, refreshed, retriedInvalid := 1, false, false
	keyed := r.k.info.key
	token := ""
	for {
		var err error
		if token == "" {
			if token, err = r.k.accessToken(); err != nil {
				return nil, err
			}
		}
		used := token
		token = ""
		res, err := r.transport(used)
		if err != nil {
			return nil, err
		}
		switch res.kind {
		case resOK:
			return r.response(res), nil
		case resUnauthorized:
			if keyed || refreshed {
				return nil, r.k.rejected(res.fail.diagnostics())
			}
			fresh, rerr := r.k.refreshed(used, refreshAfter401)
			if rerr != nil {
				return nil, withDiagnostics(rerr, res.fail.diagnostics())
			}
			refreshed = true
			// A short-lived SuperGrok grant still gets exactly one retry after its 401 refresh.
			if r.k.info.supergrok() {
				token = fresh
			}
		case resTransient:
			if n >= 3 {
				return nil, r.unavailable(r.label()+" did not answer after 3 attempts: "+res.detail, res.diag)
			}
			wait := 2 * time.Second
			if n > 1 {
				wait = 8 * time.Second
			}
			if err := r.k.pause(wait); err != nil {
				return nil, err
			}
			n++
		case resInvalid:
			if keyed {
				return nil, withDiagnostics(r.malformed(), res.diag)
			}
			if retriedInvalid {
				return nil, providerFail("invalid_response", r.label()+" sent a response Kogen cannot read: "+res.detail)
			}
			retriedInvalid = true
		case resRefused:
			return nil, r.refusedError(res)
		case resError:
			if r.refused(res.fail) {
				r.markUnsupported()
				r.stripKey()
				continue
			}
			return nil, res.fail.classify(r.k.info, r.model)
		}
	}
}

// Only a definite nonexecuting400 naming the exact routing key permits one retry.
func (r *run) refused(f failure) bool {
	if !r.hasKey {
		return false
	}
	if st, ok := asInt(f.status); !ok || st != 400 {
		return false
	}
	return f.param == "prompt_cache_key" && (f.code == "unknown_parameter" || f.code == "unsupported_parameter" || (r.k.info.chatgpt() && f.code == "invalid_parameter" && f.message == "prompt_cache_key is not supported on this model"))
}

// markUnsupported remembers the refusal in the conversation (and so its checkpoint).
func (r *run) markUnsupported() {
	r.state.Unsupported = true
	r.cache.put(r.key, r.state)
	r.ev.cache["status"] = "unsupported"
	r.ev.cache["configured_mode"] = nil
}

// stripKey removes only prompt_cache_key; the caller's items are not modified.
func (r *run) stripKey() {
	body := make(map[string]any, len(r.rend.body))
	for k, v := range r.rend.body {
		if k != "prompt_cache_key" {
			body[k] = v
		}
	}
	r.rend.body = body
	r.encoded, _ = encodeBody(r.k.info, body)
	r.hasKey = false
}

// transport makes one HTTP attempt and records it.
func (r *run) transport(token string) (result, error) {
	start := r.k.c.now()
	ts := timestamp(start)
	r.requestID = ""
	r.so = newStreamObs(start)
	r.watch = nil
	res, err := r.exchange(token)
	r.watch = nil
	if err == nil && res.kind == resError && r.refused(res.fail) {
		// The refusal is evidence of the route, whatever happens next.
		r.markUnsupported()
	}
	r.record(res, err, start, ts)
	return res, err
}

// origin is the inference origin: the loopback test seam or the provider's own.
func (k *call) origin() string {
	if k.info.compatible() {
		return k.baseURL
	}
	if v := k.env("KOGEN_PROVIDER_URL"); v != "" {
		return v
	}
	return k.info.APIBase
}

// do sends a provider request without following redirects: a redirect must never carry
// the authorization somewhere else, and answers as the refusal it is. Requests name their
// connection (keep-alive) like Kogen's HTTP client always did; the installed suites pin the
// header-name set.
func (k *call) do(req *http.Request) (*http.Response, error) {
	req.Header.Set("Connection", "keep-alive")
	client := *k.c.http()
	client.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	return client.Do(req)
}

// post sends the encoded body to the provider's endpoint with the headers.
func (r *run) post(ctx context.Context, url string, header map[string]string) (*http.Response, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(r.encoded))
	if err != nil {
		return nil, err
	}
	for k, v := range header {
		req.Header.Set(k, v)
	}
	for k, v := range r.rend.headers {
		req.Header.Set(k, v)
	}
	return r.k.do(req)
}

func (r *run) exchange(token string) (result, error) {
	switch r.k.info.wire {
	case wireChat:
		return r.exchangeChat(token)
	case wireMessages:
		return r.exchangeMessages(token)
	}
	return r.exchangeResponses(token)
}

func (r *run) exchangeResponses(token string) (result, error) {
	k := r.k
	r.so.endTracked = true
	ctx, cancel, err := k.requestContext()
	if err != nil {
		r.so.finishCheck(k)
		return result{}, err
	}
	defer cancel()
	w := r.newWatch(cancel)
	defer w.stop()
	header := map[string]string{"Authorization": "Bearer " + token, "Accept": "text/event-stream", "Content-Type": "application/json"}
	if k.info.supergrok() {
		header["User-Agent"] = k.c.userAgent()
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, k.origin()+"/v1/responses", bytes.NewReader(r.encoded))
	if err != nil {
		return result{}, err
	}
	for name, v := range header {
		req.Header.Set(name, v)
	}
	for name, v := range r.rend.headers {
		req.Header.Set(name, v)
	}
	if !k.info.supergrok() {
		req.Header["User-Agent"] = []string{""}
	}
	resp, err := k.do(req)
	if err != nil {
		return r.transportFailure(ctx, err)
	}
	defer resp.Body.Close()
	w.attach(resp.Body)
	hat := k.c.now()
	r.so.gotHeaders(hat)
	r.requestID = identifier(resp.Header.Get("X-Request-Id"))
	if w.expired() {
		return r.idleStop(ctx, w)
	}
	if resp.StatusCode != 200 && resp.StatusCode != 206 {
		r.so.endTracked = false
		// A body read whole: the headers are the first byte and start the idle clock.
		if w.observe(hat, true) {
			return r.idleStop(ctx, w)
		}
		r.so.progress(hat)
		body, rerr := io.ReadAll(io.LimitReader(r.whole(resp.Body), 4<<20))
		if rerr != nil {
			return r.transportFailure(ctx, rerr)
		}
		if err := k.check(); err != nil {
			return result{}, err
		}
		return httpFailure(resp.StatusCode, body, k.info.supergrok(), token), nil
	}
	r.so.beginStream()
	scan := &sseProgress{}
	acc := newAccumulator()
	buf := make([]byte, 32<<10)
	total := 0
	for {
		if err := k.check(); err != nil {
			r.so.finishCheck(k)
			return result{}, err
		}
		n, rerr := resp.Body.Read(buf)
		at := k.c.now()
		r.so.read(at, n)
		progress := n > 0 && scan.feed(buf[:n])
		if w.observe(at, progress) {
			return r.idleStop(ctx, w)
		}
		if progress {
			r.so.progress(at)
		}
		if total += n; total > streamLimit {
			return r.overflow(), nil
		}
		if n > 0 {
			detail := acc.feed(string(buf[:n]))
			if acc.delta {
				r.so.firstDelta(at)
			}
			if detail != "" {
				r.so.finish("complete")
				return result{kind: resInvalid, detail: detail}, nil
			}
			if err := k.check(); err != nil {
				r.so.finishCheck(k)
				return result{}, err
			}
			if acc.done || acc.failure != nil {
				r.so.finish("complete")
				return acc.finish(k.info.supergrok()), nil
			}
		}
		if rerr == io.EOF || rerr == io.ErrUnexpectedEOF {
			if err := k.check(); err != nil {
				r.so.finishCheck(k)
				return result{}, err
			}
			// The parser takes EOF as the end; the telemetry calls a stream that never
			// completed a broken one.
			if rerr == io.EOF && (acc.done || acc.failure != nil) {
				r.so.finish("complete")
			} else {
				r.so.finish("transport")
			}
			return acc.finish(k.info.supergrok()), nil
		}
		if rerr != nil {
			return r.transportFailure(ctx, rerr)
		}
	}
}

// streamLimit is the most body bytes one streaming attempt may receive: framing, comments and
// unfinished frames count, and exactly the limit is allowed. It is fixed, not an option.
const streamLimit = 64 << 20

// overflow ends an attempt whose stream passed streamLimit. The caller has not appended or parsed
// the overflowing read; the deferred body close ends the transfer. The answer is unreadable, not
// an end of stream, and no partial output is kept.
func (r *run) overflow() result {
	r.so.finish("transport")
	return result{kind: resInvalid, detail: "stream exceeded " + itoa(streamLimit) + " bytes"}
}

// exchangeChat is one OpenCode Go request: a JSON POST answered by one JSON body.
func (r *run) exchangeChat(key string) (result, error) {
	k := r.k
	ctx, cancel, err := k.requestContext()
	if err != nil {
		return result{}, err
	}
	defer cancel()
	w := r.newWatch(cancel)
	defer w.stop()
	header := map[string]string{"Accept": "application/json", "Content-Type": "application/json", "User-Agent": k.c.userAgent()}
	if key != "" {
		header["Authorization"] = "Bearer " + key
	}
	path := chatPath
	if k.info.compatible() {
		path = "/chat/completions"
	}
	resp, err := r.post(ctx, k.origin()+path, header)
	if err != nil {
		return r.transportFailure(ctx, err)
	}
	defer resp.Body.Close()
	w.attach(resp.Body)
	at := k.c.now()
	r.so.gotHeaders(at)
	r.requestID = identifier(resp.Header.Get("X-Request-Id"))
	// A body read whole has no stream: its headers are the first byte and idle starts there.
	if w.observe(at, true) {
		return r.idleStop(ctx, w)
	}
	r.so.progress(at)
	body, rerr := io.ReadAll(io.LimitReader(r.whole(resp.Body), 64<<20))
	if rerr != nil {
		return r.transportFailure(ctx, rerr)
	}
	if err := k.check(); err != nil {
		return result{}, err
	}
	response := map[string]any{}
	if v, derr := decodeJSON(body); derr == nil {
		if m, ok := asMap(v); ok {
			response = m
		}
	}
	errObj, _ := asMap(response["error"])
	f := failure{status: int64(resp.StatusCode), code: safeCode(errObj["code"]), typ: safeCode(errObj["type"])}
	if k.info.compatible() {
		// A self-hosted server's own refusal text (Ollama: "model 'x' not found, try pulling it
		// first") is the fix the user needs; OpenCode Go's body is never shown.
		msg, _ := errObj["message"].(string)
		if s, ok := response["error"].(string); ok {
			msg = s
		}
		f.message = hostMessage(msg, key)
	}
	status := resp.StatusCode
	switch {
	case status == 200:
		return adaptChat(k.info, response), nil
	case status == 429 || status >= 500:
		return result{kind: resTransient, detail: k.info.Label + " temporary HTTP " + itoa(int64(status)), diag: f.diagnostics()}, nil
	case status == 401:
		return result{kind: resUnauthorized, fail: f}, nil
	}
	reason := "refused"
	if f.code == "model_not_found" {
		reason = "model_unavailable"
	}
	return result{kind: resRefused, reason: reason, fail: f}, nil
}

// exchangeMessages is one Anthropic request: a streamed answer assembled once complete.
func (r *run) exchangeMessages(key string) (result, error) {
	k := r.k
	r.so.endTracked = true
	ctx, cancel, err := k.requestContext()
	if err != nil {
		r.so.finishCheck(k)
		return result{}, err
	}
	defer cancel()
	w := r.newWatch(cancel)
	defer w.stop()
	resp, err := r.post(ctx, k.origin()+messagesPath, map[string]string{
		"x-api-key": key, "anthropic-version": anthropicVersion, "Accept": "text/event-stream",
		"Content-Type": "application/json", "User-Agent": k.c.userAgent(),
	})
	if err != nil {
		return r.transportFailure(ctx, err)
	}
	defer resp.Body.Close()
	w.attach(resp.Body)
	hat := k.c.now()
	r.so.gotHeaders(hat)
	for _, name := range []string{"Request-Id", "X-Request-Id"} {
		if id := safeIdentifier(resp.Header.Get(name), key); id != nil {
			r.requestID = id.(string)
			break
		}
	}
	if w.expired() {
		return r.idleStop(ctx, w)
	}
	if resp.StatusCode != 200 && resp.StatusCode != 206 {
		r.so.endTracked = false
		// A body read whole: the headers are the first byte and start the idle clock.
		if w.observe(hat, true) {
			return r.idleStop(ctx, w)
		}
		r.so.progress(hat)
		body, rerr := io.ReadAll(io.LimitReader(r.whole(resp.Body), 4<<20))
		if rerr != nil {
			return r.transportFailure(ctx, rerr)
		}
		if err := k.check(); err != nil {
			return result{}, err
		}
		return messagesFailure(resp.StatusCode, body, key), nil
	}
	r.so.beginStream()
	scan := &sseProgress{messages: true}
	var all strings.Builder
	tail := ""
	buf := make([]byte, 32<<10)
	total := 0
	for {
		if err := k.check(); err != nil {
			r.so.finishCheck(k)
			return result{}, err
		}
		n, rerr := resp.Body.Read(buf)
		at := k.c.now()
		r.so.read(at, n)
		progress := n > 0 && scan.feed(buf[:n])
		if w.observe(at, progress) {
			return r.idleStop(ctx, w)
		}
		if progress {
			r.so.progress(at)
		}
		if total += n; total > streamLimit {
			return r.overflow(), nil
		}
		if n > 0 {
			chunk := string(buf[:n])
			all.WriteString(chunk)
			pieces := strings.Split(strings.ReplaceAll(tail+chunk, "\r\n", "\n"), "\n\n")
			tail = pieces[len(pieces)-1]
			for _, p := range pieces[:len(pieces)-1] {
				f := decodeFrame(p)
				if f.event == nil {
					continue
				}
				if f.event["type"] == "content_block_delta" || f.event["type"] == "message_delta" {
					r.so.firstDelta(at)
				}
				if f.event["type"] == "message_stop" || f.event["type"] == "error" {
					return r.completeMessages(all.String(), key, "complete")
				}
			}
			if err := k.check(); err != nil {
				r.so.finishCheck(k)
				return result{}, err
			}
		}
		if rerr == io.EOF || rerr == io.ErrUnexpectedEOF {
			// An unfinished frame is not a parsed terminal event.
			return r.completeMessages(all.String(), key, "transport")
		}
		if rerr != nil {
			return r.transportFailure(ctx, rerr)
		}
	}
}

func (r *run) completeMessages(stream, key, end string) (result, error) {
	if err := r.k.check(); err != nil {
		r.so.finishCheck(r.k)
		return result{}, err
	}
	r.so.finish(end)
	res := parseMessages(stream)
	if res.kind == resOK {
		meta := map[string]any{
			"id":                          safeIdentifier(res.meta["id"], key),
			"model":                       safeIdentifier(res.meta["model"], key),
			"anthropic_stop_reason":       res.meta["anthropic_stop_reason"],
			"anthropic_end_turn_tool_use": res.meta["anthropic_end_turn_tool_use"],
		}
		res.meta = meta
	}
	return res, nil
}

// messagesFailure classifies a non-200 Messages answer by status; only the status, a known
// error type and, for a 4xx refusal other than 401 and 429, the sanitised error message are kept.
func messagesFailure(status int, body []byte, key string) result {
	f := failure{status: int64(status)}
	if v, err := decodeJSON(body); err == nil {
		if m, ok := asMap(v); ok {
			if e, ok := asMap(m["error"]); ok {
				if msg, ok := e["message"].(string); ok && status >= 400 && status < 500 && status != 401 && status != 429 {
					f.message = hostMessage(msg, key)
				}
				if t, ok := e["type"].(string); ok && errorTypes[t] {
					if id := safeIdentifier(t, key); id != nil {
						f.typ = id
					}
				}
			}
		}
	}
	switch {
	case status == 429 || status >= 500:
		return result{kind: resTransient, detail: "Anthropic temporary HTTP " + itoa(int64(status)), diag: f.diagnostics()}
	case status == 401:
		return result{kind: resUnauthorized, fail: f}
	}
	reason := "refused"
	switch status {
	case 404:
		reason = "model_unavailable"
	case 413:
		reason = "context_too_long"
	}
	return result{kind: resRefused, reason: reason, fail: f}
}

// transportFailure is a failed exchange: the caller's interrupt or the spent budget end
// the call; anything else is a transient network error.
func (r *run) transportFailure(ctx context.Context, err error) (result, error) {
	if _, ok := r.k.stopped(); !ok && r.watch.expired() {
		return r.idleStop(ctx, r.watch)
	}
	r.so.finishFailure(r.k, ctx.Err())
	if stop, ok := r.k.stopped(); ok {
		return result{}, stop
	}
	if ctx.Err() != nil {
		return result{}, r.k.expired()
	}
	if r.k.info.key {
		return result{kind: resTransient, detail: r.k.info.Label + " network failure"}, nil
	}
	return result{kind: resTransient, detail: "network error: " + networkText(err)}, nil
}

// record sends the attempt's usage record to the Observer.
func (r *run) record(res result, err error, start time.Time, ts string) {
	completed := err == nil && res.kind == resOK
	outcome := "failed"
	switch {
	case completed:
		outcome = "completed"
	case err != nil:
		if _, ok := err.(*sys.Interrupted); ok {
			outcome = "cancelled"
		}
	}
	var meta map[string]any
	known := KnownUsage{}
	state := UsageUnknown
	if completed || (err == nil && res.state != "") {
		// A failed or incomplete terminal envelope's own accounting and identity count the same way.
		meta, known, state = res.meta, res.known, res.state
	}
	if meta == nil {
		meta = map[string]any{}
	}
	cache := make(map[string]any, len(r.ev.cache))
	for k, v := range r.ev.cache {
		cache[k] = v
	}
	if completed && cache["status"] == "requested" {
		cache["status"] = "applied"
		cache["applied_mode"] = nil
	}
	if completed {
		cache["diagnostics"] = cacheDiagnostics(meta["prompt_cache_diagnostics"])
	}
	if !r.hasKey && r.k.info.supergrok() {
		cache["boundaries"] = []any{}
	}
	rec := make(map[string]any, len(r.ev.meta)+32)
	for k, v := range r.ev.meta {
		rec[k] = v
	}
	for k, v := range r.req.Context {
		rec[k] = v
	}
	var reqID any
	if r.requestID != "" {
		reqID = r.requestID
	}
	var errField any
	if !completed {
		errField = "provider_failure"
	}
	effort := returnedEffort(meta["reasoning"])
	var effEffort any
	if effort != "" {
		effEffort = effort
	}
	for k, v := range map[string]any{
		"provider":                    r.k.info.Name,
		"compatibility":               Classify(r.req, r.k.s).Map(),
		"operation_id":                r.op.id,
		"attempt_id":                  newID("attempt"),
		"timestamp":                   ts,
		"provider_response_id":        identifierOrNil(meta["id"]),
		"provider_request_id":         reqID,
		"configured_model":            r.op.model,
		"configured_effort":           r.op.effort,
		"effective_model":             identifierOrNil(meta["model"]),
		"effective_effort":            effEffort,
		"requested_service_tier":      nil,
		"effective_service_tier":      identifierOrNil(meta["service_tier"]),
		"requested_reasoning_context": nil,
		"effective_reasoning_context": nil,
		"cache":                       cache,
		"usage":                       known.Map(),
		"usage_state":                 state,
		"wall_ms":                     r.k.c.now().Sub(start).Milliseconds(),
		"outcome":                     outcome,
		"error":                       errField,
	} {
		rec[k] = v
	}
	for k, v := range r.so.fields() {
		rec[k] = v
	}
	switch {
	case err != nil:
	case res.kind == resRefused:
		rec["provider_failure"] = res.fail.diagnostics()
	case res.kind == resError:
		rec["provider_failure"] = res.fail.attemptDiagnostics()
	case (res.kind == resTransient || res.kind == resInvalid) && res.diag != nil:
		rec["provider_failure"] = res.diag
	case res.kind == resUnauthorized && r.k.info.key:
		rec["provider_failure"] = res.fail.diagnostics()
	}
	if r.k.info.Name == "anthropic" {
		rec["anthropic_stop_reason"] = meta["anthropic_stop_reason"]
		marker, _ := meta["anthropic_end_turn_tool_use"].(bool)
		rec["anthropic_end_turn_tool_use"] = marker
	}
	if completed {
		r.cacheStatus, _ = cache["status"].(string)
		r.respMeta = meta
	}
	if r.obs != nil {
		r.obs.Attempt(rec)
	}
}
