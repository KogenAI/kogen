// Package research holds Kogen's internal research settings for the pinned loop: the one
// struct and the one zero-valued source (Current) that every production construction path
// reads. There is no command-line flag, project.yaml key or environment variable; to try a
// setting, change its line in Current. Zero means the loop's own default for a field. Every
// field is zero except the provider response budget, which is ten minutes for every
// provider-backed entry; with all fields zero the requests, tool definitions, results,
// transcripts and checkpoints are exactly what the pinned loop produces without these options.
//
// The loop validates the settings, not this package: Validate calls the loop's own checks
// and returns their original errors.
package research

import (
	"context"
	"fmt"
	"strings"
	"time"

	"kogen-loop/loop"
	"kogen-loop/provider"
	"kogen-loop/sys"
	"kogen-loop/tools"
)

// ToolSettings are tools.Tools.ResultBound and ResultHead.
type ToolSettings struct {
	ResultBound int
	ResultHead  int
}

// DocumentationSettings are tools.Documentation.ResultBound and BodyBound.
type DocumentationSettings struct {
	ResultBound int
	BodyBound   int
}

// ClientSettings are provider.Client.ResponseBudget.
type ClientSettings struct {
	ResponseBudget time.Duration
}

// Settings are all the research settings. InputBudgetBytes is loop.FailOverBudget's and
// AuthorityBoundary is provider.Request's (nil: disabled).
type Settings struct {
	Tools             ToolSettings
	Documentation     DocumentationSettings
	Client            ClientSettings
	InputBudgetBytes  int
	AuthorityBoundary *int
}

// Current is the source of the settings: one line per setting, all zero but the response budget.
var Current = Settings{
	Tools: ToolSettings{
		ResultBound: 0,
		ResultHead:  0,
	},
	Documentation: DocumentationSettings{
		ResultBound: 0,
		BodyBound:   0,
	},
	Client: ClientSettings{
		ResponseBudget: 10 * time.Minute,
	},
	InputBudgetBytes:  0,
	AuthorityBoundary: nil,
}

// toolOptions are the tools.Tools options of the settings.
func toolOptions(s Settings) tools.Tools {
	return tools.Tools{
		ResultBound:   s.Tools.ResultBound,
		ResultHead:    s.Tools.ResultHead,
		Documentation: tools.Documentation{ResultBound: s.Documentation.ResultBound, BodyBound: s.Documentation.BodyBound},
	}
}

// ApplyTools sets the four tool bounds on t and leaves its other fields alone.
func ApplyTools(t *tools.Tools) *tools.Tools {
	o := toolOptions(Current)
	t.ResultBound, t.ResultHead = o.ResultBound, o.ResultHead
	t.Documentation.ResultBound, t.Documentation.BodyBound = o.Documentation.ResultBound, o.Documentation.BodyBound
	return t
}

// Cut is the delivered form of a model-facing tool result under the configured bounds; typed
// parts pass unchanged. With zero settings it is exactly tools.Output.Cut.
func Cut(out tools.Output) tools.Output {
	return ApplyTools(&tools.Tools{}).Cut(out)
}

// CutText is Cut of a text.
func CutText(text string) string {
	return Cut(tools.Output{Text: text}).Text
}

// ApplyClient lowers the client's response budget to the configured one; a zero setting, or
// a budget the caller already built that is lower, leaves the client as it was.
func ApplyClient(c *provider.Client) *provider.Client {
	if b := Current.Client.ResponseBudget; c != nil && b != 0 && (c.ResponseBudget == 0 || b < c.ResponseBudget) {
		c.ResponseBudget = b
	}
	return c
}

// Request gives a model request the configured authority boundary. The same request is
// measured and sent.
func Request(req provider.Request) provider.Request {
	if b := Current.AuthorityBoundary; b != nil {
		v := *b
		req.AuthorityBoundary = &v
	}
	return req
}

// InputBudget is the input ceiling the settings give: the loop's default, or the lower
// configured one.
func InputBudget() int {
	if b := Current.InputBudgetBytes; b != 0 && b < tools.InputBudgetBytes {
		return b
	}
	return tools.InputBudgetBytes
}

// Measure is tools.Measure against the lower of the role's ceiling and the configured one
// (as loop.FailOverBudget applies it).
func Measure(body map[string]any, role provider.Role) (tools.Measurement, error) {
	m, err := tools.Measure(body, role)
	if err != nil {
		return m, err
	}
	if b := Current.InputBudgetBytes; b != 0 && b < m.InputBudgetBytes {
		m.InputBudgetBytes = b
		m.Fits = m.RenderedBytes <= b
	}
	return m, nil
}

// BudgetEvent is the run-log record of the effective response budget, which a run records
// once when it starts, not per request. Nil without a configured budget: the library default
// then applies and nothing is recorded.
func BudgetEvent() map[string]any {
	d := Current.Client.ResponseBudget
	if d == 0 {
		return nil
	}
	return map[string]any{"event": "response_budget", "budget_ms": d.Milliseconds(), "budget": DescribeBudget(d)}
}

// DescribeBudget is how Kogen names a response budget: ten minutes as "10 minutes", the
// library's own wording for its thirty-minute default, and any other duration as Go renders it.
func DescribeBudget(d time.Duration) string {
	if d == 10*time.Minute {
		return "10 minutes"
	}
	return d.String()
}

// diagnostic renames the expiry of the client's configured budget in a provider failure. The
// pinned library renders an explicit budget as a Go duration ("10m0s") and its own default as
// "30 minutes"; classification, exit code and every other message and duration are unchanged.
func diagnostic(err error, budget time.Duration) error {
	e, ok := err.(*sys.Error)
	if !ok || budget != 10*time.Minute || e.Class != "provider" || e.Reason != "unavailable" {
		return err
	}
	if rest, found := strings.CutSuffix(e.Detail, " response wait exceeded "+budget.String()); found {
		renamed := *e
		renamed.Detail = rest + " response wait exceeded " + DescribeBudget(budget)
		return &renamed
	}
	return err
}

// Respond sends req with c.Respond after refusing, before any transport, a complete request
// over the configured input ceiling. With a zero InputBudgetBytes it is c.Respond. A response
// wait that expires names the budget as Kogen describes it.
func Respond(ctx context.Context, c *provider.Client, s *sys.Session, req provider.Request, obs provider.Observer) (*provider.Response, error) {
	if Current.InputBudgetBytes != 0 {
		m, err := Measure(c.Body(req), req.Role)
		if err != nil {
			return nil, err
		}
		if !m.Fits {
			return nil, sys.Fail("candidate", "context_budget_exceeded", fmt.Sprintf(
				"complete next request %d bytes exceeds %d; reserve %d tokens. Nothing was sent and nothing was clipped.",
				m.RenderedBytes, m.InputBudgetBytes, m.OutputReserveTokens), 1)
		}
	}
	resp, err := c.Respond(ctx, s, req, obs)
	return resp, diagnostic(err, c.ResponseBudget)
}

// Validate runs the loop's own checks of the settings without credentials, network or
// inference and returns the first original error: tools.New (Tools and Documentation),
// loop.FailOverBudget's input budget, and the provider client's response budget. An
// authority boundary is checked against the request it belongs to, when that request is sent.
func Validate(ctx context.Context, s *sys.Session) error {
	c := Current
	if _, err := tools.New(toolOptions(c)); err != nil {
		return err
	}
	if c.InputBudgetBytes != 0 {
		// An unknown provider has nothing to measure: Prepare validates the budget and returns.
		budget := loop.FailOverBudget{InputBudgetBytes: c.InputBudgetBytes}
		if _, err := budget.Prepare(ctx, loop.Request{Role: provider.Role{Provider: "research-preflight"}}); err != nil {
			return err
		}
	}
	if c.Client.ResponseBudget != 0 && s != nil {
		// Respond validates the budget before it needs a credential, a base_url or the network. A
		// role with no base_url ends there with the same refusal for any valid budget.
		probe := provider.Request{Role: provider.Role{Provider: "openai-compatible"}}
		_, valid := (&provider.Client{}).Respond(ctx, s, probe, nil)
		_, err := (&provider.Client{ResponseBudget: c.Client.ResponseBudget}).Respond(ctx, s, probe, nil)
		if err != nil && (valid == nil || err.Error() != valid.Error()) {
			return err
		}
	}
	return nil
}
