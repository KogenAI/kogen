// Package api is kogen-loop's public caller protocol v1 (docs/contract/loop-v1.md): the task
// a process caller sends, the JSON Lines events it receives, usage, errors and capabilities.
// The contract owner changes these types deliberately; see the versioning rule in the
// contract. Callers must ignore unknown fields and event types within a major version.
package api

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
)

const (
	// Protocol is the process protocol id carried by every task and event.
	Protocol = "kogen-loop/v1"
	// Library is the Go library API id (package loop).
	Library = "loop/v1"
)

// Role selects the provider, model, effort and (for openai-compatible) base URL.
type Role struct {
	Provider string `json:"provider"`
	Model    string `json:"model"`
	Effort   string `json:"effort"`
	BaseURL  string `json:"base_url"`
}

// SessionSpec asks for transcript persistence and, with Resume, continuation.
type SessionSpec struct {
	Dir    string `json:"dir"`
	Resume bool   `json:"resume"`
}

// Task is one round requested by a process caller.
type Task struct {
	Protocol        string      `json:"protocol"`
	Root            string      `json:"root"`
	Role            Role        `json:"role"`
	Instructions    string      `json:"instructions"`
	Prompt          string      `json:"prompt"`
	Tools           []string    `json:"tools"`
	Protected       []string    `json:"protected"`
	Excluded        []string    `json:"excluded"`
	Terminal        []string    `json:"terminal"`
	DeadlineSeconds int         `json:"deadline_seconds"`
	Session         SessionSpec `json:"session"`
	Requires        []string    `json:"requires"`
}

// DecodeTask reads one task strictly: unknown fields and trailing data are refused.
func DecodeTask(r io.Reader) (Task, error) {
	data, err := io.ReadAll(r)
	if err != nil {
		return Task{}, err
	}
	data = bytes.TrimSpace(data)
	if len(data) == 0 || data[0] != '{' {
		return Task{}, fmt.Errorf("invalid task: expected one JSON object")
	}
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	var t Task
	if err := dec.Decode(&t); err != nil {
		return Task{}, fmt.Errorf("invalid task: %w", err)
	}
	var trailing any
	if err := dec.Decode(&trailing); err != io.EOF {
		return Task{}, fmt.Errorf("invalid task: trailing data after the task object")
	}
	return t, nil
}

// Usage is provider-reported usage. Nil means not reported; nothing is estimated.
type Usage struct {
	Input     *int   `json:"input"`
	Cached    *int   `json:"cached"`
	Output    *int   `json:"output"`
	Reasoning *int   `json:"reasoning"`
	State     string `json:"state"`  // complete | partial | unknown
	Source    string `json:"source"` // provider
}

// Usage states.
const (
	UsageComplete = "complete"
	UsagePartial  = "partial"
	UsageUnknown  = "unknown"
)

// Event types (v1).
const (
	EventSessionStarted = "session.started"
	EventRequestStarted = "request.started"
	EventRequestAttempt = "request.attempt"
	EventResponse       = "response"
	EventToolCall       = "tool.call"
	EventToolResult     = "tool.result"
	EventRoundEnded     = "round.ended"
	EventError          = "error"
	EventSessionEnded   = "session.ended"
)

// Endings of a round (round.ended "ending"): model claims, not completion.
const (
	EndingTerminal = "terminal"
	EndingNoCall   = "no_call"
)

// Session end statuses (session.ended "status").
const (
	StatusEnded       = "ended"
	StatusFailed      = "failed"
	StatusInterrupted = "interrupted"
)

// Event is one JSON Lines record. Protocol, Seq, Time and Type are always present; Fields
// carries the type's own fields (flattened into the same object when encoded).
type Event struct {
	Protocol string
	Seq      int
	Time     string
	Type     string
	Fields   map[string]any
}

// MarshalJSON flattens Fields beside the envelope keys. A field named like an envelope key
// is an encoding error rather than a silent overwrite.
func (e Event) MarshalJSON() ([]byte, error) {
	m := make(map[string]any, len(e.Fields)+4)
	for k, v := range e.Fields {
		switch k {
		case "protocol", "seq", "time", "type":
			return nil, fmt.Errorf("event field %q collides with the envelope", k)
		}
		m[k] = v
	}
	m["protocol"], m["seq"], m["time"], m["type"] = e.Protocol, e.Seq, e.Time, e.Type
	return json.Marshal(m)
}

// Capabilities is what `kogen-loop capabilities --json` prints. False or absent means the
// capability is not provided.
type Capabilities struct {
	Protocol        string   `json:"protocol"`
	Library         string   `json:"library"`
	Version         string   `json:"version"`
	Providers       []string `json:"providers"`
	Tools           []string `json:"tools"`
	TerminalDefault []string `json:"terminal_default"`
	SessionResume   string   `json:"session_resume"` // "transcript" or ""
	ContextPolicies []string `json:"context_policies"`
	Usage           string   `json:"usage"` // "provider"
	Images          bool     `json:"images"`
	Subagents       bool     `json:"subagents"`
	Compaction      bool     `json:"compaction"`
}

// Capability names a task may list in Requires.
const (
	CapSessionResume = "session_resume"
	CapImages        = "images"
	CapSubagents     = "subagents"
	CapCompaction    = "compaction"
)

// Error classes added by kogen-loop (provider classes are unchanged from Kogen).
const (
	ErrContextBudget         = "context_budget_exceeded"
	ErrDeadline              = "deadline"
	ErrUnsupportedCapability = "unsupported_capability"
	ErrSessionMismatch       = "session_mismatch"
	ErrInvalidTask           = "invalid_task"
	ErrUnsupportedProtocol   = "unsupported_protocol"
	ErrClassLoop             = "loop"
)

// Exit codes of `kogen-loop run`.
const (
	ExitEnded       = 0
	ExitFailed      = 1
	ExitInvalid     = 2
	ExitInterrupted = 130 // SIGINT; SIGTERM is 143
)
