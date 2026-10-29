package provider

import (
	"context"
	"testing"
	"time"
)

// tcRoute is one offline route: a private credential, a local transport fixture that
// answers with a recorded response shape, and the role that reaches it.
type tcRoute struct {
	name string
	// wire is the effective wire after profile resolution: responses, chat or messages.
	wire  string
	setup func(t *testing.T) (e *env, role Role, requests func() []recorded)
}

var tcRoutes = []tcRoute{
	{"chatgpt", "responses", func(t *testing.T) (*env, Role, func() []recorded) {
		e, f := chatEnv(t, textAnswer("ok"))
		return e, Role{Model: "gpt-6.1-sol", Effort: "high"}, f.requests
	}},
	{"supergrok", "responses", func(t *testing.T) (*env, Role, func() []recorded) {
		e, f := chatEnv(t, textAnswer("ok"))
		e.saveCreds("supergrok", e.supergrokCreds())
		return e, grokRole, f.requests
	}},
	{"opencode-go", "chat", func(t *testing.T) (*env, Role, func() []recorded) {
		e, f := keyEnv(t, "opencode-go", jsonAnswer(200, goText("ok")))
		return e, goRole, f.requests
	}},
	{"openai-compatible", "chat", func(t *testing.T) (*env, Role, func() []recorded) {
		e, f, role := compatibleEnv(t, "", jsonAnswer(200, goText("ok")))
		return e, role, f.requests
	}},
	{"anthropic", "messages", func(t *testing.T) (*env, Role, func() []recorded) {
		e, f := keyEnv(t, "anthropic", claudeText("ok"))
		return e, claudeRole, f.requests
	}},
	{"anthropic-profile", "messages", func(t *testing.T) (*env, Role, func() []recorded) {
		e, f := keyEnv(t, "anthropic", claudeText("ok"))
		return e, Role{Provider: "anthropic", Model: "claude-sonnet-5-5", Effort: "high"}, f.requests
	}},
}

// tcRequest is the fixed request every case sends; only the role and the options vary.
func tcRequest(role Role, withTools bool) Request {
	req := Request{Role: role, Instructions: "policy", Input: user("hi"), CacheID: "fixed-cache-id"}
	if withTools {
		req.Tools = []any{goTool("read_file"), goTool("submit")}
	}
	return req
}

// tcRespond runs the real Client.Respond against the route's local fixture and returns the
// transport bodies it saw and the error.
func tcRespond(t *testing.T, route tcRoute, mutate func(*Request), withTools bool) ([]recorded, error) {
	t.Helper()
	e, role, requests := route.setup(t)
	req := tcRequest(role, withTools)
	if mutate != nil {
		mutate(&req)
	}
	_, err := tcRespondWith(t, e, req)
	return requests(), err
}

func tcRespondWith(t *testing.T, e *env, req Request) (*Response, error) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	return e.c.Respond(ctx, e.s, req, nil)
}
