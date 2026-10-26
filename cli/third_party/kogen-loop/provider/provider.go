// Package provider is Kogen's connection to model providers: the catalog (ChatGPT,
// SuperGrok, OpenCode Go, Anthropic, any OpenAI-compatible host), sign-in and key storage, Kogen's own credential files
// and locks, token refresh and the model request with retries, budget, error classification,
// prompt-cache routing and the per-attempt usage record (spec chapter 08).
//
// A Client is safe for concurrent use. Nothing here keeps package-level state: the clock,
// the sleep, the HTTP client, the lock owner, the secret input and the prompt-cache states
// are fields the caller (or a test) controls.
package provider

// Role is a model role as the provider needs it: the provider ("" means a legacy ChatGPT
// role), model and reasoning effort, sent unchanged, and for openai-compatible the base URL.
type Role struct{ Provider, Model, Effort, BaseURL string }

// wire is the request/response protocol a provider speaks.
type wire int

const (
	wireResponses wire = iota // streamed Responses API (ChatGPT, SuperGrok)
	wireChat                  // non-streaming Chat Completions (OpenCode Go, OpenAI-compatible)
	wireMessages              // streamed Messages API (Anthropic)
)

// Info describes one supported provider.
type Info struct {
	Name  string // "chatgpt", "supergrok", "opencode-go", "anthropic", "openai-compatible"
	Label string // "ChatGPT", "SuperGrok", "OpenCode Go", "Anthropic", "OpenAI-compatible"
	// AuthBase and APIBase are the default authorization and inference origins; the
	// loopback test seams KOGEN_AUTH_URL and KOGEN_PROVIDER_URL replace them. Key
	// providers have no authorization origin.
	AuthBase, APIBase string
	// Models and Efforts are the known models and efforts: recommended defaults and
	// documentation hints only. Any model and effort is sent unchanged (KOGEN-057).
	Models, Efforts []string

	wire wire
	// key marks a provider whose credential is an API key the user saves from stdin
	// ({"provider": name, "api_key": key}); there is no OAuth sign-in and no refresh.
	key bool
	// optionalKey marks a key provider that also works without a key (local hosts): no
	// Authorization header is sent then.
	optionalKey bool
}

// Catalog lists the supported providers in `kogen provider list` order.
func Catalog() []Info {
	return []Info{
		{Name: "chatgpt", Label: "ChatGPT", AuthBase: "https://auth.openai.com", APIBase: "https://api.openai.com"},
		{Name: "supergrok", Label: "SuperGrok", AuthBase: "https://auth.x.ai", APIBase: "https://api.x.ai",
			Models: []string{"grok-4.7"}, Efforts: []string{"low", "medium", "high", "xhigh"}},
		{Name: "opencode-go", Label: "OpenCode Go", APIBase: "https://opencode.ai",
			Models: []string{"kimi-k3"}, Efforts: []string{"default", "high"}, wire: wireChat, key: true},
		{Name: "anthropic", Label: "Anthropic", APIBase: "https://api.anthropic.com",
			Models: []string{"claude-opus-5-5", "claude-sonnet-5-5"}, Efforts: []string{"low", "medium", "high", "max"},
			wire: wireMessages, key: true},
		// The role's base_url names the host (Ollama, LM Studio, vLLM, ...): there is no default.
		{Name: "openai-compatible", Label: "OpenAI-compatible", wire: wireChat, key: true, optionalKey: true},
	}
}

// Lookup finds a provider by name; "" is ChatGPT.
func Lookup(name string) (Info, bool) {
	if name == "" {
		name = "chatgpt"
	}
	for _, p := range Catalog() {
		if p.Name == name {
			return p, true
		}
	}
	return Info{}, false
}

// Name is the provider a role routes to ("chatgpt" when the role omits it).
func Name(r Role) string {
	if r.Provider == "" {
		return "chatgpt"
	}
	return r.Provider
}

func (p Info) supergrok() bool  { return p.Name == "supergrok" }
func (p Info) compatible() bool { return p.Name == "openai-compatible" }
func (p Info) chatgpt() bool    { return p.Name == "chatgpt" }
