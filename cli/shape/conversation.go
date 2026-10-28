package shape

import (
	"kogen-loop/provider"
	"kogen-loop/tools"
	"kogen/git"
	"kogen/internal/research"
	"kogen/project"
)

// A conversation's prompt-cache identity (provider.NewCacheID: at most 64 characters, no
// clock time, request id or counter) is created once when the conversation starts, recorded in
// the conversation's evidence as a `cache_identity` event, and passed on every request of that
// conversation: retries, transient-stream retries and working-window resets included. The
// shaper, each shape worker, a refinement and the setup conversation never share one. Shape
// and Refine have no resume of their own, so an identity lives as long as one invocation.
func newCacheID() string { return provider.NewCacheID() }

// startConversation creates a conversation's cache identity and saves it with the evidence.
func startConversation(ev *Evidence, owner string) string {
	id := newCacheID()
	if ev != nil {
		ev.Record(map[string]any{"event": "cache_identity", "owner": owner, "id": id})
	}
	return id
}

// conversationRequest completes a request of the conversation that holds cacheID: the one
// place where a conversation's requests get their identity.
func conversationRequest(req provider.Request, cacheID string) provider.Request {
	req.CacheID = cacheID
	return research.Request(req)
}

// toolOutput is the delivered result of one tool call (Shape.output): bounded text, or
// unchanged typed content. Text is cut once, here, and replayed as stored.
func toolOutput(c tools.Call, result any) map[string]any {
	switch v := result.(type) {
	case tools.Output:
		return c.Output(research.Cut(v))
	case string:
		return c.Output(research.CutText(v))
	}
	return c.Output(result)
}

// Navigation is the shaper's source navigation: where the checkout is, its revision and how to
// retrieve exact bytes. The text is `Context navigation: <JSON>\n`, two lines, small however
// large the tree; the exact contracts stay authoritative and complete in the message.
func Navigation(repo *git.Repo) (string, map[string]any, error) {
	revision, err := CurrentRevision(repo)
	if err != nil {
		return "", nil, err
	}
	descriptor := map[string]any{
		"root": repo.Dir, "revision": revision.Map(), "retrieval": contextRetrieval,
	}
	doc, err := project.EncodeJSON(descriptor)
	if err != nil {
		return "", nil, err
	}
	return "Context navigation: " + string(doc) + "\n", descriptor, nil
}
