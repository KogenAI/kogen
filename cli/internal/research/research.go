// Package research holds Kogen's internal research settings for the pinned loop: the one
// struct and the one zero-valued source (Current) that every production construction path
// reads. There is no command-line flag, project.yaml key or environment variable; to try a
// setting, change its line in Current. Zero means the loop's own default for a field. Every
// field is zero; the requests, tool definitions, results, transcripts and checkpoints are
// exactly what the pinned loop produces without these options.
//
// The provider response budget is not a research setting: native Build and independent Review
// construct their client with the fixed BuildReviewBudget (ApplyBuildReview), and Shape,
// Refine and init leave it zero, so the pinned loop's 30-minute default applies per logical
// Respond call.
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

// Settings are all the research settings. InputBudgetBytes is loop.FailOverBudget's and
// AuthorityBoundary is provider.Request's (nil: disabled).
type Settings struct {
	Tools             ToolSettings
	Documentation     DocumentationSettings
	InputBudgetBytes  int
	AuthorityBoundary *int
}

// Current is the source of the settings: one line per setting, all zero.
var Current = Settings{
	Tools: ToolSettings{
		ResultBound: 0,
		ResultHead:  0,
	},
	Documentation: DocumentationSettings{
		ResultBound: 0,
		BodyBound:   0,
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

// BuildReviewBudget is the fixed provider response budget of native Build and independent
// Review: one logical Respond call, absolute, shared by refresh, lock waits, retries and backoff.
const BuildReviewBudget = 10 * time.Minute

// ApplyBuildReview gives the client Build and Review use their fixed response budget. Shape,
// Refine and init never call it: their clients keep the zero budget, the loop's 30 minutes.
func ApplyBuildReview(c *provider.Client) *provider.Client {
	if c != nil {
		c.ResponseBudget = BuildReviewBudget
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

// EffectiveBudget is the response budget c gives one logical Respond call: its own explicit
// budget, or the loop's default when it is zero (or c is nil).
func EffectiveBudget(c *provider.Client) time.Duration {
	if c == nil || c.ResponseBudget == 0 {
		return provider.ResponseBudget
	}
	return c.ResponseBudget
}

// BudgetEvent is the run-log record of the effective response budget of c, which a run
// records once when it starts, not per request.
func BudgetEvent(c *provider.Client) map[string]any {
	d := EffectiveBudget(c)
	return map[string]any{"event": "response_budget", "budget_ms": d.Milliseconds(), "budget": DescribeBudget(d)}
}

// DescribeBudget is how Kogen names a response budget: whole minutes as "10 minutes" or
// "30 minutes", and any other duration as Go renders it.
func DescribeBudget(d time.Duration) string {
	if d == 10*time.Minute || d == 30*time.Minute {
		return fmt.Sprintf("%d minutes", d/time.Minute)
	}
	return d.String()
}

// diagnostic renames the expiry of the client's explicit budget in a provider failure. The
// pinned library renders an explicit budget as a Go duration ("10m0s") and its own default as
// "30 minutes"; classification, exit code and every other message and duration are unchanged.
func diagnostic(err error, budget time.Duration) error {
	e, ok := err.(*sys.Error)
	if !ok || budget != BuildReviewBudget || e.Class != "provider" || e.Reason != "unavailable" {
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
// loop.FailOverBudget's input budget. An
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
	return nil
}
