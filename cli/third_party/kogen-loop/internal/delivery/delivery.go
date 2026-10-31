// Package delivery is the context-scoped bridge that carries completed streamed items from a
// provider attempt to the engine, so the engine can start a tool call before the whole
// response has arrived. It is internal: it adds no option, field or exported surface to the
// library.
package delivery

import "context"

// Sink receives the items of one provider attempt as they complete. The provider calls it
// from the goroutine that reads the stream, so calls never overlap.
type Sink interface {
	// Attempt starts a transport attempt. Anything delivered by an earlier attempt is
	// discarded, with its work cancelled and joined, before Attempt returns.
	Attempt()
	// Done reports that the output item at stream position pos is complete. call is the
	// item of a valid, complete function call, nil for any other settled item. A position
	// that never settles keeps every later call from starting.
	Done(pos int, call map[string]any)
	// Abort ends a failed attempt: its work is cancelled and joined, its results discarded.
	Abort()
}

type key struct{}

// With returns ctx carrying s.
func With(ctx context.Context, s Sink) context.Context { return context.WithValue(ctx, key{}, s) }

// From is the Sink ctx carries, nil when there is none.
func From(ctx context.Context) Sink {
	if ctx == nil {
		return nil
	}
	s, _ := ctx.Value(key{}).(Sink)
	return s
}
