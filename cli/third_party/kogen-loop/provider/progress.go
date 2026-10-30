package provider

import (
	"bytes"
	"encoding/json"
)

// Bounds of what the progress scanner keeps of one SSE block: it needs a field name, an event
// name and enough of the data to recognise a ping object, never the whole event.
const (
	progressLineCap = 4096
	progressDataCap = 256
)

// sseProgress tells which reads of a stream are response progress: a read that completes at
// least one SSE event (a block ending in a blank line, LF or CRLF) with a data field that is not a
// keep-alive. Comment lines and blank lines are keep-alives, and on Messages so are ping events.
// An unfinished event counts in the read that completes it. It holds one block's state, not the
// stream.
type sseProgress struct {
	messages bool // ping events are keep-alives

	line     []byte // the current line, up to progressLineCap bytes
	lineOver bool   // the current line is longer than progressLineCap

	hasData  bool
	event    string
	data     []byte
	dataOver bool
}

// feed consumes one body read and reports whether it completed a progress event.
func (s *sseProgress) feed(p []byte) bool {
	progress := false
	for len(p) > 0 {
		i := bytes.IndexByte(p, '\n')
		if i < 0 {
			s.addLine(p)
			break
		}
		s.addLine(p[:i])
		p = p[i+1:]
		if s.endLine() {
			progress = true
		}
	}
	return progress
}

func (s *sseProgress) addLine(p []byte) {
	room := progressLineCap - len(s.line)
	if len(p) > room {
		p, s.lineOver = p[:room], true
	}
	s.line = append(s.line, p...)
}

// endLine handles a finished line and reports whether it ended a progress event.
func (s *sseProgress) endLine() bool {
	line, over := bytes.TrimSuffix(s.line, []byte("\r")), s.lineOver
	s.line, s.lineOver = s.line[:0], false
	if len(line) == 0 && !over {
		progress := s.hasData && !(s.messages && s.ping())
		s.hasData, s.event, s.data, s.dataOver = false, "", s.data[:0], false
		return progress
	}
	if len(line) > 0 && line[0] == ':' {
		return false
	}
	name, value, _ := bytes.Cut(line, []byte(":"))
	value = bytes.TrimPrefix(value, []byte(" "))
	switch string(name) {
	case "data":
		if s.hasData && !s.dataOver {
			s.data = append(s.data, '\n')
		}
		s.hasData = true
		if over || len(s.data)+len(value) > progressDataCap {
			s.dataOver = true
		} else if !s.dataOver {
			s.data = append(s.data, value...)
		}
	case "event":
		if !over {
			s.event = string(value)
		}
	}
	return false
}

// ping reports whether the block is a Messages ping event.
func (s *sseProgress) ping() bool {
	if s.event == "ping" {
		return true
	}
	if s.dataOver {
		return false
	}
	var v struct {
		Type string `json:"type"`
	}
	return json.Unmarshal(s.data, &v) == nil && v.Type == "ping"
}

// hasContent reports whether a whole-body read has a byte other than JSON whitespace.
func hasContent(p []byte) bool {
	for _, c := range p {
		if c != ' ' && c != '\t' && c != '\n' && c != '\r' {
			return true
		}
	}
	return false
}
