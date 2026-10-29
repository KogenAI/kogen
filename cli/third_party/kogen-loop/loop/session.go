package loop

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"time"

	"kogen-loop/api"
	"kogen-loop/provider"
	"kogen-loop/sys"
	"kogen-loop/tools"
)

// DefaultInstructions is the model instruction text of a Session that names none.
const DefaultInstructions = "You are a coding agent. Work in the working directory with the tools you are given. " +
	"Read what you need, make the changes the task asks for and check your work with the available tools. " +
	"When you are done, call the finish tool with a summary of what you did. " +
	"Your finish is a claim: the caller verifies the work independently, so say plainly what you did not check or could not do."

// FinishTool is the generic terminal tool name.
const FinishTool = "finish"

// DefaultTools are the generic tools a Session enables when none are named.
var DefaultTools = []string{tools.ReadFileTool, tools.WriteFileTool, tools.ListFilesTool, tools.SearchTextTool, tools.ShellTool}

// TerminalDefinition is the standalone definition of a terminal tool: one required string
// argument, "summary". Kogen supplies its own finish definition and does not use this one.
func TerminalDefinition(name string) map[string]any {
	return map[string]any{
		"type": "function",
		"name": name,
		"description": "End the round. Call it when you are done, with a summary of what you did. " +
			"The summary is your claim; the caller verifies the work independently.",
		"parameters": map[string]any{
			"type":                 "object",
			"properties":           map[string]any{"summary": map[string]any{"type": "string"}},
			"required":             []any{"summary"},
			"additionalProperties": false,
		},
		"strict": false,
	}
}

// SessionConfig configures a standalone multi-round conversation.
type SessionConfig struct {
	Root         string
	Role         provider.Role
	Instructions string   // "": DefaultInstructions
	Enabled      []string // generic tools; default read_file, write_file, list_files, search_text, shell
	Protected    []string // write_file refuses these paths (prevention only; not detection)
	Excluded     []string
	Terminal     []string // default ["finish"]
	// TerminalReminders is Round.TerminalReminders (Go only; no task or CLI setting).
	TerminalReminders int
	Dir               string // transcript directory ("" = in memory)
	Client            *provider.Client
	Session           *sys.Session
	Emit              func(api.Event) // event sink (nil: discard)
}

// Session is a standalone multi-round conversation with optional transcript persistence. It
// numbers the events it emits from 1; a host that adds events of its own renumbers them.
type Session struct {
	cfg          SessionConfig
	id           string
	instructions string
	defs         []any
	terminal     []string
	tools        *tools.Tools
	direct       *Direct

	mu       sync.Mutex
	input    []any
	pending  *terminalRef // the terminal call of the last round, if it ended with one
	seq      int
	requests int // requests started in the current round (read by Attempt)
}

// terminalRef names the terminal call a completed round ended with.
type terminalRef struct {
	CallID any    `json:"call_id"`
	Name   string `json:"name"`
}

// transcript is session.json.
type transcript struct {
	Protocol           string       `json:"protocol"`
	SessionID          string       `json:"session_id"`
	Role               api.Role     `json:"role"`
	InstructionsSHA256 string       `json:"instructions_sha256"`
	DefinitionsSHA256  string       `json:"definitions_sha256"`
	Terminal           *terminalRef `json:"terminal"`
	Input              []any        `json:"input"`
}

const transcriptName = "session.json"

func invalid(detail string) error {
	return sys.Fail(api.ErrClassLoop, api.ErrInvalidTask, detail, api.ExitInvalid)
}

func mismatch(detail string) error {
	return sys.Fail(api.ErrClassLoop, api.ErrSessionMismatch, detail, api.ExitInvalid)
}

// NewSession starts a conversation. With cfg.Dir the transcript is written after every
// completed round; NewSession does not read an existing one (see ResumeSession).
func NewSession(cfg SessionConfig) (*Session, error) {
	s, err := build(cfg)
	if err != nil {
		return nil, err
	}
	b := make([]byte, 8)
	if _, err := rand.Read(b); err != nil {
		return nil, err
	}
	s.id = "session-" + hex.EncodeToString(b)
	s.direct.CacheID = s.id
	return s, nil
}

// ResumeSession loads cfg.Dir/session.json and continues that conversation. It refuses a
// transcript that does not match the configuration (protocol, role, instructions digest or
// definitions digest) with loop/session_mismatch, before any request.
func ResumeSession(cfg SessionConfig) (*Session, error) {
	if cfg.Dir == "" {
		return nil, invalid("resume needs a session directory")
	}
	s, err := build(cfg)
	if err != nil {
		return nil, err
	}
	path := filepath.Join(cfg.Dir, transcriptName)
	data, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return nil, mismatch("no session transcript at " + path)
		}
		return nil, mismatch("cannot read the session transcript: " + err.Error())
	}
	var t transcript
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.UseNumber()
	if err := dec.Decode(&t); err != nil {
		return nil, mismatch("the session transcript is not valid: " + err.Error())
	}
	role := api.Role{Provider: cfg.Role.Provider, Model: cfg.Role.Model, Effort: cfg.Role.Effort, BaseURL: cfg.Role.BaseURL}
	switch {
	case t.Protocol != api.Protocol:
		return nil, mismatch(fmt.Sprintf("the transcript has protocol %q, not %q", t.Protocol, api.Protocol))
	case t.SessionID == "" || len(t.Input) == 0:
		return nil, mismatch("the session transcript has no conversation")
	case t.Role != role:
		return nil, mismatch("the transcript was written for another role")
	case t.InstructionsSHA256 != digest(s.instructions):
		return nil, mismatch("the transcript was written with other instructions")
	case t.DefinitionsSHA256 != definitionsDigest(s.defs):
		return nil, mismatch("the transcript was written with other tool definitions")
	}
	s.id, s.input, s.pending = t.SessionID, t.Input, t.Terminal
	s.direct.CacheID = s.id
	return s, nil
}

func build(cfg SessionConfig) (*Session, error) {
	if cfg.Root == "" {
		return nil, invalid("root is required")
	}
	if _, ok := provider.Lookup(cfg.Role.Provider); !ok {
		return nil, invalid("unknown provider " + cfg.Role.Provider)
	}
	enabled := cfg.Enabled
	if len(enabled) == 0 {
		enabled = DefaultTools
	}
	terminal := cfg.Terminal
	if len(terminal) == 0 {
		terminal = DefaultTerminal
	}
	var defs []any
	seen := map[string]bool{}
	for _, name := range enabled {
		d, ok := tools.Definition(name)
		if !ok {
			return nil, invalid("unknown tool " + name)
		}
		if seen[name] {
			return nil, invalid("duplicate tool " + name)
		}
		seen[name] = true
		defs = append(defs, d)
	}
	for _, name := range terminal {
		if name == "" || seen[name] {
			return nil, invalid("terminal tool names must be non-empty and unique, and differ from the enabled tools")
		}
		seen[name] = true
		defs = append(defs, TerminalDefinition(name))
	}
	instructions := cfg.Instructions
	if instructions == "" {
		instructions = DefaultInstructions
	}
	session := cfg.Session
	if session == nil {
		session = sys.New()
	}
	client := cfg.Client
	if client == nil {
		client = provider.NewClient("kogen-loop dev")
	}
	cache := client.Cache
	if cache == nil {
		cache = provider.NewCache(nil)
	}
	s := &Session{
		cfg: cfg, instructions: instructions, defs: defs, terminal: slices.Clone(terminal),
		tools: &tools.Tools{Root: cfg.Root, Session: session, Enabled: slices.Clone(enabled), Protected: cfg.Protected, Excluded: cfg.Excluded},
	}
	s.direct = &Direct{Client: client, Session: session, Observer: attempts{s}, Cache: cache}
	return s, nil
}

// ID is the session id carried by the transcript.
func (s *Session) ID() string { return s.id }

// Definitions are the tool definitions the session sends to the model.
func (s *Session) Definitions() []any { return slices.Clone(s.defs) }

// Digests are the instructions and definitions digests recorded in the transcript.
func (s *Session) Digests() (instructions, definitions string) {
	return digest(s.instructions), definitionsDigest(s.defs)
}

type attempts struct{ s *Session }

// Attempt forwards one provider attempt record as a request.attempt event.
func (a attempts) Attempt(record map[string]any) {
	a.s.emit(api.EventRequestAttempt, map[string]any{"n": a.s.requests, "record": record})
}

func (s *Session) emit(typ string, fields map[string]any) {
	if s.cfg.Emit == nil {
		return
	}
	s.seq++
	s.cfg.Emit(api.Event{
		Protocol: api.Protocol, Seq: s.seq, Time: time.Now().UTC().Format(time.RFC3339), Type: typ, Fields: fields,
	})
}

// Round runs one round. The first round opens the conversation with text as the user
// message. Later rounds append text as feedback: the output of the terminal call the previous
// round ended with, or a user message when it ended without a tool call. After a completed
// round the transcript is written (when the session has a directory). A round that fails
// leaves the conversation as it was after the last completed round.
func (s *Session) Round(ctx context.Context, text string) (Result, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	input := s.next(text)

	var usages []api.Usage
	cutCalls := map[string]bool{}
	rules := map[string]string{}
	s.requests = 0
	rd := Round{
		Owner: "loop", Role: s.cfg.Role, Instructions: s.instructions, Definitions: s.defs,
		Tools: s.tools, Terminal: s.terminal, TerminalReminders: s.cfg.TerminalReminders,
	}
	hooks := Hooks{
		BeforeRequest: func(ctx context.Context, in []any) error {
			s.requests++
			s.emit(api.EventRequestStarted, map[string]any{
				"n": s.requests, "owner": rd.Owner, "model": s.cfg.Role.Model, "effort": s.cfg.Role.Effort,
			})
			return nil
		},
		AfterResponse: func(ctx context.Context, resp *provider.Response, sent []any) error {
			u := UsageOf(resp)
			usages = append(usages, u)
			var id any
			if resp.ID != "" {
				id = resp.ID
			}
			s.emit(api.EventResponse, map[string]any{"n": s.requests, "response_id": id, "usage": u})
			return nil
		},
		TerminalReminder: func(ctx context.Context, n int, names []string) error {
			s.emit(api.EventTerminalReminder, map[string]any{"reminder": n, "terminal_tools": slices.Clone(names)})
			return nil
		},
		BeforeCall: func(ctx context.Context, call tools.Call, in []any) error {
			s.emit(api.EventToolCall, map[string]any{
				"call_id": call.CallID(), "name": call.Name, "arguments_sha256": digest(call.Arguments),
			})
			return nil
		},
		// The engine cuts what it runs itself; the session runs the call here to learn
		// whether the cut applied, which the engine's order does not report.
		HandleCall: func(ctx context.Context, call tools.Call) (Handled, error) {
			out, err := s.tools.CallContext(ctx, call)
			if err != nil {
				return Handled{}, err
			}
			cut := out.Cut()
			cutCalls[fmt.Sprint(call.CallID())] = cut.Text != out.Text
			if out.Rule != "" {
				rules[fmt.Sprint(call.CallID())] = out.Rule
			}
			return Handled{Handled: true, Output: cut}, nil
		},
		AfterCall: func(ctx context.Context, call tools.Call, out tools.Output, terminal bool, in []any) error {
			if terminal {
				return nil
			}
			var sum any
			size := 0
			if d := provider.Fingerprint(out.Value()); d != nil {
				sum, size = d.SHA256, d.Bytes
			}
			fields := map[string]any{
				"call_id": call.CallID(), "name": call.Name, "result_sha256": sum, "bytes": size,
				"cut": cutCalls[fmt.Sprint(call.CallID())],
			}
			if rule := rules[fmt.Sprint(call.CallID())]; rule != "" {
				fields["rule"] = rule
			}
			s.emit(api.EventToolResult, fields)
			return nil
		},
	}
	res, err := Run(ctx, rd, input, s.direct, hooks)
	if err != nil {
		return Result{}, err
	}
	var pending *terminalRef
	var terminalTool any
	claim := finalText(res.Response)
	if res.Terminal != nil {
		pending = &terminalRef{CallID: res.Terminal.CallID(), Name: res.Terminal.Name}
		terminalTool = res.Terminal.Name
		claim = res.Terminal.Arguments
	}
	if err := s.persist(res.Input, pending); err != nil {
		return Result{}, err
	}
	s.input, s.pending = res.Input, pending
	s.emit(api.EventRoundEnded, map[string]any{
		"ending": string(res.Ending), "terminal_tool": terminalTool, "claim": tools.Cut(claim),
		"requests": res.Requests, "usage": SumUsage(usages...),
	})
	return res, nil
}

// next is the conversation that opens the round: the opening user message, the feedback
// that answers the previous terminal call(s), or a user message after a no-call ending.
func (s *Session) next(text string) []any {
	if len(s.input) == 0 {
		return []any{map[string]any{"role": "user", "content": text}}
	}
	input := slices.Clone(s.input)
	if s.pending != nil {
		ids := tools.Unanswered(input)
		if len(ids) == 0 {
			return append(input, tools.OutputItem(s.pending.CallID, tools.Cut(text)))
		}
		for _, id := range ids {
			input = append(input, tools.OutputItem(id, tools.Cut(text)))
		}
		return input
	}
	return append(input, map[string]any{"role": "user", "content": text})
}

// finalText is the assistant text of a response: its output_text parts, in order.
func finalText(resp *provider.Response) string {
	if resp == nil {
		return ""
	}
	var parts []string
	for _, it := range resp.Items {
		if it["type"] != "message" {
			continue
		}
		content, _ := it["content"].([]any)
		for _, c := range content {
			if part, ok := c.(map[string]any); ok && part["type"] == "output_text" {
				if t, ok := part["text"].(string); ok {
					parts = append(parts, t)
				}
			}
		}
	}
	return strings.Join(parts, "\n")
}

func (s *Session) persist(input []any, pending *terminalRef) error {
	if s.cfg.Dir == "" {
		return nil
	}
	role := api.Role{Provider: s.cfg.Role.Provider, Model: s.cfg.Role.Model, Effort: s.cfg.Role.Effort, BaseURL: s.cfg.Role.BaseURL}
	t := transcript{
		Protocol: api.Protocol, SessionID: s.id, Role: role,
		InstructionsSHA256: digest(s.instructions), DefinitionsSHA256: definitionsDigest(s.defs),
		Terminal: pending, Input: input,
	}
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(t); err != nil {
		return fmt.Errorf("session transcript: %w", err)
	}
	return writeAtomic(s.cfg.Dir, transcriptName, buf.Bytes())
}

// writeAtomic writes dir/name through a temporary file in dir and a rename. A directory
// that does not exist is created 0700; an existing one is left as it is. The file is 0600.
func writeAtomic(dir, name string, data []byte) error {
	if _, err := os.Stat(dir); errors.Is(err, fs.ErrNotExist) {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			return err
		}
	}
	f, err := os.CreateTemp(dir, ".session-*.tmp")
	if err != nil {
		return err
	}
	tmp := f.Name()
	ok := false
	defer func() {
		if !ok {
			os.Remove(tmp)
		}
	}()
	if err := f.Chmod(0o600); err != nil {
		f.Close()
		return err
	}
	if _, err := f.Write(data); err != nil {
		f.Close()
		return err
	}
	if err := f.Sync(); err != nil {
		f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmp, filepath.Join(dir, name)); err != nil {
		return err
	}
	ok = true
	if d, err := os.Open(dir); err == nil {
		d.Sync()
		d.Close()
	}
	return nil
}

func digest(text string) string {
	sum := sha256.Sum256([]byte(text))
	return hex.EncodeToString(sum[:])
}

func definitionsDigest(defs []any) string {
	data, _ := json.Marshal(defs)
	return digest(string(data))
}
