package provider

import (
	"bytes"
	"context"
	"io"
	"sort"
	"strings"
)

// The Chat Completions route reads a server-sent event stream: each data chunk is a
// chat.completion.chunk whose deltas are folded into the one assistant message a plain JSON
// answer would carry, and that message goes through adaptChat like any other answer. A host that
// ignores the stream request and answers one JSON object is read whole.

// chatCall is one tool call assembled from the delta fragments that share an index.
type chatCall struct {
	id, typ, name string
	args          strings.Builder
}

// chatStream folds the events of one Chat Completions stream.
type chatStream struct {
	line    []byte // the unfinished line
	data    []byte // the data lines of the current event, joined by LF
	hasData bool

	text, reasoning, refusal strings.Builder
	hasText, hasRefusal      bool
	details                  []any
	calls                    map[int64]*chatCall
	lastCall                 int64
	finish                   any
	usage                    any
	meta                     map[string]any

	done    bool // the [DONE] marker arrived
	delta   bool // a delta with visible or reasoning content arrived
	invalid bool // a chunk was malformed or reported an error
}

func newChatStream() *chatStream {
	return &chatStream{calls: map[int64]*chatCall{}, meta: map[string]any{}, lastCall: -1}
}

// feed consumes one body read; it reports whether the stream ended (the done marker or an
// invalid chunk).
func (s *chatStream) feed(p []byte) bool {
	for len(p) > 0 && !s.done && !s.invalid {
		i := bytes.IndexByte(p, '\n')
		if i < 0 {
			s.line = append(s.line, p...)
			return false
		}
		s.line = append(s.line, p[:i]...)
		p = p[i+1:]
		s.endLine()
	}
	return s.done || s.invalid
}

// flush handles the unfinished last line and event at EOF; a malformed one is a cut, not invalid.
func (s *chatStream) flush() {
	if s.done || s.invalid {
		return
	}
	if len(s.line) > 0 {
		s.endLine()
	}
	if s.hasData && !s.done && !s.invalid {
		s.dispatch(true)
	}
}

func (s *chatStream) endLine() {
	line := bytes.TrimSuffix(s.line, []byte("\r"))
	defer func() { s.line = s.line[:0] }()
	if len(line) == 0 {
		if s.hasData {
			s.dispatch(false)
		}
		return
	}
	if line[0] == ':' {
		return
	}
	name, value, _ := bytes.Cut(line, []byte(":"))
	if string(name) != "data" {
		return
	}
	value = bytes.TrimPrefix(value, []byte(" "))
	if s.hasData {
		s.data = append(s.data, '\n')
	}
	s.hasData = true
	s.data = append(s.data, value...)
}

// dispatch applies the finished event. lenient ignores a data block that is not a JSON object.
func (s *chatStream) dispatch(lenient bool) {
	data := bytes.TrimSpace(s.data)
	s.data, s.hasData = s.data[:0], false
	if string(data) == "[DONE]" {
		s.done = true
		return
	}
	v, err := decodeJSON(data)
	chunk, ok := asMap(v)
	if err != nil || !ok {
		if !lenient {
			s.invalid = true
		}
		return
	}
	s.apply(chunk)
}

func (s *chatStream) apply(chunk map[string]any) {
	if chunk["error"] != nil {
		s.invalid = true
		return
	}
	for _, k := range []string{"id", "model"} {
		if v, ok := chunk[k].(string); ok && v != "" {
			if _, has := s.meta[k]; !has {
				s.meta[k] = v
			}
		}
	}
	if u := chunk["usage"]; u != nil {
		s.usage = u
	}
	choices, _ := asList(chunk["choices"])
	for _, c := range choices {
		choice, ok := asMap(c)
		if !ok {
			s.invalid = true
			return
		}
		if n, has := asInt(choice["index"]); has && n != 0 {
			continue
		}
		if f := choice["finish_reason"]; f != nil {
			s.finish = f
		}
		delta, _ := asMap(choice["delta"])
		s.applyDelta(delta)
	}
}

func (s *chatStream) applyDelta(d map[string]any) {
	if c, ok := d["content"].(string); ok && c != "" {
		s.text.WriteString(c)
		s.hasText, s.delta = true, true
	}
	for _, k := range []string{"reasoning_content", "reasoning"} {
		if r, ok := d[k].(string); ok && r != "" {
			s.reasoning.WriteString(r)
			s.delta = true
		}
	}
	if list, ok := asList(d["reasoning_details"]); ok && len(list) > 0 {
		s.details = append(s.details, list...)
		s.delta = true
	}
	if r, ok := d["refusal"].(string); ok && r != "" {
		s.refusal.WriteString(r)
		s.hasRefusal, s.delta = true, true
	}
	calls, _ := asList(d["tool_calls"])
	for _, c := range calls {
		frag, ok := asMap(c)
		if !ok {
			s.invalid = true
			return
		}
		fn, _ := asMap(frag["function"])
		id, _ := frag["id"].(string)
		idx, hasIdx := asInt(frag["index"])
		if !hasIdx {
			// A host without indexes: an id starts a new call, anything else continues the last.
			idx = s.lastCall
			if _, known := s.calls[idx]; id != "" && (!known || s.calls[idx].id != "" && s.calls[idx].id != id) {
				idx = s.lastCall + 1
			}
			if idx < 0 {
				idx = 0
			}
		}
		call := s.calls[idx]
		if call == nil {
			call = &chatCall{}
			s.calls[idx] = call
		}
		s.lastCall = idx
		if call.id == "" {
			call.id = id
		}
		if t, ok := frag["type"].(string); ok && call.typ == "" {
			call.typ = t
		}
		if name, ok := fn["name"].(string); ok && call.name == "" {
			call.name = name
		}
		if a, ok := fn["arguments"].(string); ok {
			call.args.WriteString(a)
		}
		s.delta = true
	}
}

// message is the one assistant message the stream built.
func (s *chatStream) message() map[string]any {
	msg := map[string]any{"role": "assistant", "content": nil}
	if s.hasText {
		msg["content"] = s.text.String()
	}
	if s.reasoning.Len() > 0 {
		msg["reasoning_content"] = s.reasoning.String()
	}
	if len(s.details) > 0 {
		msg["reasoning_details"] = s.details
	}
	if s.hasRefusal {
		msg["refusal"] = s.refusal.String()
	}
	if len(s.calls) > 0 {
		indexes := make([]int64, 0, len(s.calls))
		for i := range s.calls {
			indexes = append(indexes, i)
		}
		sort.Slice(indexes, func(a, b int) bool { return indexes[a] < indexes[b] })
		list := make([]any, len(indexes))
		for n, i := range indexes {
			c := s.calls[i]
			typ := c.typ
			if typ == "" {
				typ = "function"
			}
			list[n] = map[string]any{"id": c.id, "type": typ, "function": map[string]any{"name": c.name, "arguments": c.args.String()}}
		}
		msg["tool_calls"] = list
	}
	return msg
}

// response is the stream as the JSON answer it stands for.
func (s *chatStream) response() map[string]any {
	choice := map[string]any{"message": s.message()}
	if s.finish != nil {
		choice["finish_reason"] = s.finish
	}
	resp := map[string]any{"choices": []any{choice}}
	for k, v := range s.meta {
		resp[k] = v
	}
	if s.usage != nil {
		resp["usage"] = s.usage
	}
	return resp
}

// result is the stream's outcome at its end: the done marker, or EOF (a cut unless a finish
// reason was received).
func (s *chatStream) result(info Info) result {
	if s.invalid {
		return result{kind: resInvalid, detail: "incomplete or malformed " + info.Label + " completion"}
	}
	if !s.done && s.finish == nil {
		return result{kind: resTransient, detail: "the response stream ended before it completed"}
	}
	return adaptChat(info, s.response())
}

// readChat reads a 200 Chat answer. A body whose first non-whitespace byte is `{` is a plain JSON
// answer, read whole and returned as plain; any other body is an event stream, returned as its
// result. Each read is observed by the watchdog: only a completed data event (or, for a plain
// body, a byte other than whitespace) is progress.
func (r *run) readChat(ctx context.Context, body io.Reader) (plain []byte, isPlain bool, res result, err error) {
	k, w := r.k, r.watch
	scan := &sseProgress{}
	var cs *chatStream
	var whole []byte
	mode := 0 // 0 undecided, 1 plain JSON, 2 event stream
	buf := make([]byte, 32<<10)
	total := 0
	for {
		if err := k.check(); err != nil {
			r.so.finishCheck(k)
			return nil, false, result{}, err
		}
		n, rerr := body.Read(buf)
		at := k.c.now()
		chunk := buf[:n]
		if mode == 0 && n > 0 {
			if j := bytes.IndexFunc(chunk, func(c rune) bool { return c != ' ' && c != '\t' && c != '\n' && c != '\r' }); j >= 0 {
				if chunk[j] == '{' {
					mode = 1
				} else {
					mode, cs = 2, newChatStream()
					r.so.beginStream()
					r.so.endTracked = true
				}
			}
		}
		r.so.read(at, n)
		progress := false
		switch mode {
		case 1:
			progress = n > 0 && hasContent(chunk)
		case 2:
			progress = n > 0 && scan.feed(chunk)
		}
		if w.observe(at, progress) {
			res, err = r.idleStop(ctx, w)
			return nil, false, res, err
		}
		if progress {
			r.so.progress(at)
		}
		if total += n; total > streamLimit {
			return nil, false, r.overflow(), nil
		}
		switch mode {
		case 1:
			whole = append(whole, chunk...)
		case 2:
			ended := cs.feed(chunk)
			if cs.delta {
				r.so.firstDelta(at)
			}
			if ended {
				if err := k.check(); err != nil {
					r.so.finishCheck(k)
					return nil, false, result{}, err
				}
				r.so.finish("complete")
				if cs.done && rerr == nil {
					// The answer ends at the done marker, not at the server's close. One more
					// read lets the transport see the end of the body when it follows at once;
					// it never delays the answer, and closing the body ends it.
					go body.Read(make([]byte, 1))
				}
				return nil, false, cs.result(k.info), nil
			}
		}
		if rerr == io.EOF || rerr == io.ErrUnexpectedEOF {
			if err := k.check(); err != nil {
				r.so.finishCheck(k)
				return nil, false, result{}, err
			}
			if mode != 2 {
				return whole, true, result{}, nil
			}
			cs.flush()
			if cs.delta {
				r.so.firstDelta(at)
			}
			if rerr == io.EOF && (cs.done || cs.invalid || cs.finish != nil) {
				r.so.finish("complete")
			} else {
				r.so.finish("transport")
			}
			return nil, false, cs.result(k.info), nil
		}
		if rerr != nil {
			res, err = r.transportFailure(ctx, rerr)
			return nil, false, res, err
		}
	}
}
