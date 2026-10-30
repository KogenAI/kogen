package provider

import (
	"sort"
	"strings"
	"unicode"
)

// resultKind is how one transport attempt ended.
type resultKind int

const (
	resOK resultKind = iota
	resTransient
	resError
	resUnauthorized
	resInvalid
	// resRefused is a definite refusal of a key provider (OpenCode Go, Anthropic): reason is
	// the error's reason, fail its safe diagnostics.
	resRefused
)

// result is one transport attempt's outcome.
type result struct {
	kind resultKind
	// resOK
	items []map[string]any
	usage Usage
	known KnownUsage
	state string
	meta  map[string]any // id, model, service_tier, reasoning, prompt_cache_diagnostics
	// resTransient and resInvalid
	detail string
	reason string         // resRefused
	diag   map[string]any // transient: allowlisted failure fields
	// resError, resUnauthorized and resRefused
	fail failure
}

// streamFailure is a failure reported inside the stream.
type streamFailure struct {
	body any
	kind string
	// response is the terminal envelope of a response.failed or response.incomplete event
	// (nil for other failures); only its identity and usage are read.
	response map[string]any
	// incomplete is the allowlisted incomplete_details.reason ("" when none was reported).
	incomplete string
}

// accumulator folds SSE events into validated output items (GPT-7).
type accumulator struct {
	meta                                                     map[string]any
	buf                                                      []byte
	scan                                                     int // bytes of buf, from its start, already searched for an event break
	items                                                    map[int]any
	pending                                                  map[int]bool
	usage                                                    any
	done                                                     bool
	failure                                                  *streamFailure
	reasons                                                  map[string]bool
	terminalResponse, terminalOutput, terminalOutputReplaced bool
	observed                                                 int
	delta                                                    bool // a parsed *.delta event was seen
}

func newAccumulator() *accumulator {
	return &accumulator{meta: map[string]any{}, items: map[int]any{}, pending: map[int]bool{}, reasons: map[string]bool{}}
}

// eventBreak finds the first `\r?\n\r?\n` of b at or after from: its start and end, or -1.
func eventBreak(b []byte, from int) (start, end int) {
	for i := from; i < len(b); i++ {
		if b[i] != '\n' {
			continue
		}
		next := i + 1
		if next < len(b) && b[next] == '\r' {
			next++
		}
		if next < len(b) && b[next] == '\n' {
			start = i
			if i > 0 && b[i-1] == '\r' {
				start--
			}
			return start, next + 1
		}
	}
	return -1, -1
}

// feed adds a chunk of the stream. A non-empty detail means an event was not JSON (the
// response is unreadable).
func (a *accumulator) feed(chunk string) (invalid string) {
	a.buf = append(a.buf, chunk...)
	start := 0
	for {
		from, to := eventBreak(a.buf, start+a.scan)
		if from < 0 {
			// A break needs four bytes; only its last three can still be incomplete.
			a.scan = max(0, len(a.buf)-start-3)
			a.drop(start)
			return ""
		}
		event := string(a.buf[start:from])
		start, a.scan = to, 0
		if d := a.event(event); d != "" {
			a.drop(start)
			return d
		}
	}
}

// drop discards the first n bytes of the buffer, which hold events already handled.
func (a *accumulator) drop(n int) {
	if n > 0 {
		a.buf = a.buf[:copy(a.buf, a.buf[n:])]
	}
}

func (a *accumulator) event(text string) string {
	var data []string
	for more := true; more; {
		var line string
		line, text, more = strings.Cut(text, "\n")
		if more {
			line = strings.TrimSuffix(line, "\r")
		}
		if rest, ok := strings.CutPrefix(line, "data:"); ok {
			data = append(data, strings.TrimLeftFunc(rest, unicode.IsSpace))
		}
	}
	joined := strings.Join(data, "\n")
	if joined == "" || joined == "[DONE]" {
		return ""
	}
	v, err := decodeJSON([]byte(joined))
	ev, ok := asMap(v)
	if err != nil || !ok {
		return "an event is not JSON"
	}
	if _, has := ev["type"]; !has {
		return "an event is not JSON"
	}
	a.apply(ev)
	return ""
}

func (a *accumulator) reason(r string) { a.reasons[r] = true }

func index(v any) (int, bool) {
	n, ok := asInt(v)
	if !ok || n < 0 || n > 1<<31 {
		return 0, false
	}
	return int(n), true
}

func (a *accumulator) observedCount() int {
	seen := map[int]bool{}
	for i := range a.items {
		seen[i] = true
	}
	for i := range a.pending {
		seen[i] = true
	}
	return len(seen)
}

func (a *accumulator) apply(ev map[string]any) {
	typ, _ := ev["type"].(string)
	if strings.HasSuffix(typ, ".delta") {
		a.delta = true
	}
	switch typ {
	case "response.output_item.added":
		if i, ok := index(ev["output_index"]); ok {
			a.pending[i] = true
			return
		}
		a.reason("item_event_shape")
	case "response.output_item.done":
		i, ok := index(ev["output_index"])
		item, has := ev["item"]
		if ok && has {
			a.items[i] = item
			delete(a.pending, i)
			return
		}
		a.reason("item_event_shape")
	case "response.completed":
		a.completed(ev)
	case "response.incomplete":
		response, _ := asMap(ev["response"])
		a.failure = &streamFailure{
			body:       map[string]any{"code": "incomplete", "message": inspectTerm(dig(ev, "response", "incomplete_details"))},
			kind:       "response.incomplete",
			response:   response,
			incomplete: incompleteReason(dig(ev, "response", "incomplete_details", "reason")),
		}
	case "response.failed":
		var body any = map[string]any{}
		if e := dig(ev, "response", "error"); truthy(e) {
			body = e
		}
		response, _ := asMap(ev["response"])
		a.failure = &streamFailure{body: body, kind: "response.failed", response: response}
	case "error":
		var body any
		if e := ev["error"]; truthy(e) {
			body = e
		} else {
			rest := map[string]any{}
			for k, v := range ev {
				if k != "type" {
					rest[k] = v
				}
			}
			body = rest
		}
		a.failure = &streamFailure{body: body, kind: "error"}
	}
}

// incompleteReason is the reported reason of an incomplete response as a fixed category:
// a known reason as received, any other string "other", a non-string "unknown", none "".
func incompleteReason(v any) string {
	if v == nil {
		return ""
	}
	return category(v, "max_output_tokens", "content_filter")
}

func truthy(v any) bool {
	if v == nil {
		return false
	}
	if b, ok := v.(bool); ok {
		return b
	}
	return true
}

func dig(v any, path ...string) any {
	for _, k := range path {
		m, ok := v.(map[string]any)
		if !ok {
			return nil
		}
		v = m[k]
	}
	return v
}

func (a *accumulator) completed(ev map[string]any) {
	response, ok := asMap(ev["response"])
	if !ok {
		a.done = true
		a.observed = a.observedCount()
		a.reason("terminal_envelope")
		return
	}
	observed := map[int]bool{}
	for i := range a.items {
		observed[i] = true
	}
	for i := range a.pending {
		observed[i] = true
	}
	if s, has := response["status"]; has && s != nil && s != "completed" {
		a.reason("response_status")
	}
	if response["error"] != nil {
		a.reason("response_error")
	}
	if !validUsage(response["usage"]) {
		a.reason("usage_shape")
	}
	a.meta = map[string]any{}
	for _, k := range []string{"id", "model", "service_tier", "reasoning", "prompt_cache_diagnostics"} {
		if v, has := response[k]; has {
			a.meta[k] = v
		}
	}
	a.done = true
	a.usage = response["usage"]
	_, a.terminalOutput = response["output"]
	a.terminalResponse = true
	a.observed = len(observed)
	out, has := response["output"]
	if !has {
		return
	}
	list, isList := out.([]any)
	if !isList {
		a.reason("terminal_output_shape")
		return
	}
	if len(list) == 0 {
		return
	}
	items := make(map[int]any, len(list))
	for i, item := range list {
		items[i] = item
	}
	a.items, a.pending, a.terminalOutputReplaced = items, map[int]bool{}, true
	for i := range observed {
		if _, ok := items[i]; !ok {
			a.reason("terminal_index_coverage")
			break
		}
	}
}

func validUsage(v any) bool {
	if v == nil {
		return true
	}
	u, ok := asMap(v)
	if !ok {
		return false
	}
	for _, k := range []string{"input_tokens", "output_tokens"} {
		if x := u[k]; x != nil {
			if _, ok := asInt(x); !ok {
				return false
			}
		}
	}
	for _, d := range [][2]string{{"input_tokens_details", "cached_tokens"}, {"output_tokens_details", "reasoning_tokens"}} {
		switch details := u[d[0]].(type) {
		case nil:
		case map[string]any:
			if x := details[d[1]]; x != nil {
				if _, ok := asInt(x); !ok {
					return false
				}
			}
		default:
			return false
		}
	}
	return true
}

func validItem(item any) bool {
	m, ok := asMap(item)
	if !ok {
		return false
	}
	switch m["type"] {
	case "function_call":
		args, isStr := m["arguments"].(string)
		if !nonempty(m["call_id"]) || !nonempty(m["name"]) || !isStr {
			return false
		}
		return argumentsObject(args) == "yes"
	case "message":
		content, ok := asList(m["content"])
		if !ok {
			return false
		}
		for _, c := range content {
			b, ok := asMap(c)
			if !ok {
				return false
			}
			switch b["type"] {
			case "output_text":
				if _, ok := b["text"].(string); !ok {
					return false
				}
			case "refusal":
				if _, ok := b["refusal"].(string); !ok {
					return false
				}
			default:
				return false
			}
		}
		return true
	case "reasoning":
		return true
	}
	return false
}

// duplicateCallID reports a call_id shared by two function_call items of the effective output.
func duplicateCallID(items []any) bool {
	seen := map[string]bool{}
	for _, it := range items {
		if itemField(it, "type") != "function_call" {
			continue
		}
		id, ok := itemField(it, "call_id").(string)
		if !ok {
			continue
		}
		if seen[id] {
			return true
		}
		seen[id] = true
	}
	return false
}

func argumentsObject(args string) string {
	v, err := decodeJSON([]byte(args))
	if _, ok := asMap(v); err == nil && ok {
		return "yes"
	}
	return "no"
}

func itemField(item any, key string) any {
	if m, ok := asMap(item); ok {
		return m[key]
	}
	return nil
}

func category(v any, allowed ...string) string {
	s, ok := v.(string)
	if !ok {
		return "unknown"
	}
	for _, a := range allowed {
		if s == a {
			return s
		}
	}
	return "other"
}

func aggregate(items []any, f func(any) string) []any {
	seen := map[string]bool{}
	for _, it := range items {
		seen[f(it)] = true
	}
	out := make([]string, 0, len(seen))
	for s := range seen {
		out = append(out, s)
	}
	sort.Strings(out)
	list := make([]any, len(out))
	for i, s := range out {
		list[i] = s
	}
	return list
}

// finish judges the stream: a reported failure wins, a stream that ended before its
// completion event is transient, and a completed response needs complete, ordered,
// valid output items.
func (a *accumulator) finish(supergrok bool) result {
	if a.failure != nil {
		return streamFailureResult(*a.failure, supergrok)
	}
	if !a.done {
		return result{kind: resTransient, detail: "the response stream ended before it completed"}
	}
	indexes := make([]int, 0, len(a.items))
	for i := range a.items {
		indexes = append(indexes, i)
	}
	sort.Ints(indexes)
	items := make([]any, len(indexes))
	contiguous := true
	for n, i := range indexes {
		items[n] = a.items[i]
		if i != n {
			contiguous = false
		}
	}
	reasons := map[string]bool{}
	for r := range a.reasons {
		reasons[r] = true
	}
	flag := func(cond bool, r string) {
		if cond {
			reasons[r] = true
		}
	}
	flag(len(items) == 0, "empty_output")
	flag(!contiguous, "noncontiguous_indexes")
	flag(len(a.pending) != 0, "pending_items")
	badStatus, badShape := false, false
	for _, it := range items {
		if s := itemField(it, "status"); s != nil && s != "completed" {
			badStatus = true
		}
		if !validItem(it) {
			badShape = true
		}
	}
	flag(badStatus, "item_status")
	flag(badShape, "item_shape")
	flag(duplicateCallID(items), "duplicate_call_id")

	if len(reasons) == 0 {
		var u map[string]any
		if m, ok := asMap(a.usage); ok {
			u = m
		}
		raw := rawFrom(u)
		state := raw.state()
		res := result{kind: resOK, known: raw.known(), state: state, meta: a.meta}
		out := make([]map[string]any, len(items))
		for i, it := range items {
			out[i], _ = asMap(it)
		}
		res.items = out
		if state != UsageInconsistent {
			res.usage = compatible(u)
		}
		return res
	}
	names := make([]string, 0, len(reasons))
	for r := range reasons {
		names = append(names, r)
	}
	sort.Strings(names)
	reasonList := make([]any, len(names))
	for i, n := range names {
		reasonList[i] = n
	}
	counts := []int{len(items), len(a.pending), a.observed}
	capped := false
	for i, n := range counts {
		if n > 1024 {
			capped = true
			counts[i] = 1024
		}
	}
	var calls []any
	for _, it := range items {
		if itemField(it, "type") == "function_call" {
			calls = append(calls, it)
		}
	}
	facts := map[string]any{
		"event_kind":                "response.completed",
		"done":                      a.done,
		"terminal_response_present": a.terminalResponse,
		"terminal_output_present":   a.terminalOutput,
		"terminal_output_replaced":  a.terminalOutputReplaced,
		"item_count":                counts[0],
		"pending_count":             counts[1],
		"observed_index_count":      counts[2],
		"counts_capped":             capped,
		"indexes_contiguous":        contiguous,
		"item_types": aggregate(items, func(it any) string {
			return category(itemField(it, "type"), "function_call", "message", "reasoning")
		}),
		"item_statuses": aggregate(items, func(it any) string {
			return category(itemField(it, "status"), "completed", "in_progress", "incomplete", "failed")
		}),
		"arguments_object": aggregate(calls, func(it any) string {
			args, ok := itemField(it, "arguments").(string)
			if !ok {
				return "unknown"
			}
			return argumentsObject(args)
		}),
	}
	evidence := map[string]any{"reasons": reasonList, "facts": facts}
	detail := "the completed response has invalid or unfinished output; validation=" + string(mustEncode(evidence))
	return result{kind: resInvalid, detail: detail, diag: map[string]any{"validation": evidence}}
}

// streamFailureResult classifies a failure event: the transient provider codes retry, and
// so does SuperGrok's codeless generation error (code and type absent, null or empty, the
// message exactly as observed, on an error or response.failed event); anything else is a
// refusal.
func streamFailureResult(sf streamFailure, supergrok bool) result {
	body, _ := asMap(sf.body)
	f := failure{
		status:     "stream",
		code:       body["code"],
		typ:        body["type"],
		eventKind:  sf.kind,
		param:      body["param"],
		message:    text(body["message"]),
		resetsAt:   body["resets_at"],
		incomplete: sf.incomplete,
	}
	res := terminalAccounting(sf.response)
	switch f.code {
	case "server_error", "server_is_overloaded", "rate_limit_exceeded", "subscription_sharing_usage_unavailable", "subscription_sharing_user_unavailable":
		res.kind, res.detail, res.diag = resTransient, f.code.(string)+": "+text(body["message"]), f.diagnostics()
		return res
	}
	absent := func(v any) bool { return v == nil || v == "" }
	if supergrok && absent(f.code) && absent(f.typ) && body["message"] == "Internal error during token generation" &&
		(sf.kind == "error" || sf.kind == "response.failed") {
		res.kind, res.detail, res.diag = resTransient, f.message, f.diagnostics()
		return res
	}
	res.kind, res.fail = resError, f
	return res
}

// terminalAccounting is the identity and usage a failed or incomplete terminal envelope
// reported, normalized like a completed response's whatever its output: a result carrying only
// meta, known and state. With no envelope (a stream cut short, an error event) it carries
// nothing and the attempt's usage stays unknown.
func terminalAccounting(response map[string]any) result {
	if response == nil {
		return result{}
	}
	meta := map[string]any{}
	for _, k := range []string{"id", "model", "service_tier", "reasoning"} {
		if v, has := response[k]; has {
			meta[k] = v
		}
	}
	u, _ := asMap(response["usage"])
	raw := rawFrom(u)
	return result{meta: meta, known: raw.known(), state: raw.state()}
}

// httpFailure classifies a non-streaming HTTP error answer.
func httpFailure(status int, body []byte, supergrok bool, key string) result {
	var errObj map[string]any
	var detail string
	v, derr := decodeJSON(body)
	m, isMap := asMap(v)
	switch {
	case derr == nil && isMap && isObject(m["error"]):
		errObj, _ = asMap(m["error"])
		msg := errObj["message"]
		if !truthy(msg) {
			msg = errObj["code"]
		}
		detail = text(msg)
	case derr == nil && isMap && has(m, "detail"):
		errObj = map[string]any{}
		detail = text(m["detail"])
	default:
		errObj = map[string]any{}
		detail = firstRunes(string(body), 200)
	}
	f := failure{status: int64(status), code: errObj["code"], typ: errObj["type"], param: errObj["param"], message: hostMessage(detail, key), resetsAt: errObj["resets_at"]}
	switch {
	case status == 401:
		return result{kind: resUnauthorized, fail: f}
	case !supergrok && f.code == "subscription_sharing_usage_limit_exceeded":
		return result{kind: resError, fail: f}
	case status == 429 || status >= 500:
		return result{kind: resTransient, detail: strings.TrimRightFunc("HTTP "+itoa(int64(status))+" "+detail, unicode.IsSpace), diag: f.diagnostics()}
	}
	return result{kind: resError, fail: f}
}

func isObject(v any) bool { _, ok := asMap(v); return ok }

func has(m map[string]any, k string) bool { _, ok := m[k]; return ok }

func firstRunes(s string, n int) string {
	r := []rune(s)
	if len(r) > n {
		r = r[:n]
	}
	return string(r)
}
