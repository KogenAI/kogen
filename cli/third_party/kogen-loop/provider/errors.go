package provider

import (
	"strings"
	"time"
	"unicode"

	"kogen-loop/sys"
)

// failure is what a provider said went wrong: an HTTP error body or a failure event in the
// stream. Fields keep their received types so that only well-typed values are reported.
type failure struct {
	status    any // int for HTTP, "stream" for a failure event
	code      any
	typ       any
	param     any
	eventKind string
	message   string
	resetsAt  any
}

// diagnostics is the allowlisted provider_failure map: string code and type, the SSE event
// kind and the numeric HTTP status, each only when well typed. response.incomplete's code
// is a local marker, not a provider field.
func (f failure) diagnostics() map[string]any {
	d := map[string]any{}
	if f.eventKind != "response.incomplete" {
		if nonempty(f.code) {
			d["code"] = f.code
		}
	}
	if nonempty(f.typ) {
		d["type"] = f.typ
	}
	if f.eventKind != "" {
		d["event_kind"] = f.eventKind
	}
	if n, ok := asInt(f.status); ok {
		d["http_status"] = n
	}
	return d
}

// withDiagnostics attaches the diagnostics to a user-visible error and adds the
// `provider failure: <JSON>` line. Other errors and empty diagnostics pass unchanged.
func withDiagnostics(err error, diag map[string]any) error {
	e, ok := err.(*sys.Error)
	if !ok || len(diag) == 0 {
		return err
	}
	c := *e
	c.ProviderFailure = diag
	c.Lines = append(append([]string(nil), e.Lines...), "provider failure: "+string(mustEncode(diag)))
	return &c
}

func (f failure) suffix() string {
	if f.message == "" {
		return ""
	}
	return " " + f.message
}

// classify turns a request error that retrying cannot fix into the user-visible error.
func (f failure) classify(info Info, model string) error {
	return withDiagnostics(f.classified(info, model), f.diagnostics())
}

func (f failure) classified(info Info, model string) error {
	sg := info.supergrok()
	status, _ := asInt(f.status)
	switch {
	case sg && status == 402:
		return providerFail("refused", "SuperGrok reported a billing or credit limit (402"+f.suffix()+"); Kogen uses only the subscription sign-in and never falls back to paid API usage")
	case sg && status == 403:
		return providerFail("refused", "SuperGrok denied API access for this sign-in (403"+f.suffix()+"); Kogen never falls back to an API key or another provider")
	case !sg && f.code == "subscription_sharing_usage_limit_exceeded":
		return providerFail("usage_limit", "ChatGPT usage limit reached"+resetText(f.resetsAt))
	case f.code == "model_not_found" || (!sg && f.code == "subscription_sharing_unsupported_capability" && f.param == "model"):
		return providerFail("model_unavailable", model+" is not available to this "+info.Label+" account")
	case f.code == "context_length_exceeded":
		return providerFail("context_too_long", "the conversation no longer fits "+model+"'s context")
	}
	st := "stream"
	if n, ok := asInt(f.status); ok {
		st = itoa(n)
	}
	return providerFail("refused", strings.TrimRightFunc(info.Label+" refused the request: "+st+" "+f.message, unicode.IsSpace))
}

func resetText(v any) string {
	switch t := v.(type) {
	case int64:
		return "; it resets at " + time.Unix(t, 0).UTC().Format("2006-01-02T15:04:05Z")
	case string:
		return "; it resets at " + t
	}
	return ""
}
