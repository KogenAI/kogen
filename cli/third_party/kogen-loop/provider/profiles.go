package provider

import (
	_ "embed"
	"encoding/json"
	"fmt"
	"strings"

	"kogen-loop/sys"
)

//go:embed profiles.json
var profileJSON []byte

// Limits are documented family limits, not measured tokenization. Nil is unknown.
type Limits struct {
	Context *int `json:"context_tokens"`
	Input   *int `json:"max_input_tokens"`
	Output  int  `json:"max_output_tokens"`
	Bytes   int  `json:"input_bytes"`
	Reserve int  `json:"reserve_tokens"`
}

type Settings struct {
	Wire      string `json:"wire"`
	Stream    bool   `json:"stream"`
	Effort    string `json:"effort"`
	Reasoning string `json:"reasoning"`
	Output    string `json:"output"`
	Tools     string `json:"tools"`
	Schema    string `json:"schema"`
	Replay    string `json:"replay"`
	Cache     string `json:"cache"`
	Images    string `json:"images"`
}

type Qualification struct {
	Role        string   `json:"role"`
	Effort      string   `json:"effort"`
	EvidenceIDs []string `json:"evidence_ids"`
}

type Profile struct {
	ID                string           `json:"id"`
	Provider          string           `json:"provider"`
	Model             string           `json:"model"`
	Route             string           `json:"route"`
	Limits            Limits           `json:"limits"`
	Settings          Settings         `json:"settings"`
	DocumentedEfforts []string         `json:"documented_efforts"`
	Qualifications    []Qualification  `json:"qualifications"`
	Evidence          []map[string]any `json:"evidence"`
}

type ProfileCatalog struct {
	SchemaVersion int       `json:"schema_version"`
	Profiles      []Profile `json:"profiles"`
}

// Profiles returns the offline catalog, with independently scoped evidence per row.
func Profiles() ProfileCatalog {
	var c ProfileCatalog
	if err := json.Unmarshal(profileJSON, &c); err != nil {
		panic(err)
	}
	return c
}

// ResolveProfile matches only the exact provider and configured model. A compatible
// host or a response-reported model cannot inherit a vendor route's qualification.
func ResolveProfile(r Role) *Profile {
	for _, p := range Profiles().Profiles {
		if p.Provider == Name(r) && p.Model == r.Model {
			return &p
		}
	}
	return nil
}

// UsableInputBytes bounds the conservative byte-as-token proxy by every known
// input/context bound. The output reserve is accounting, not an extra wire allowance.
func UsableInputBytes(l Limits) int {
	n := InputBudgetBytes
	if l.Input != nil && *l.Input < n {
		n = *l.Input
	}
	if l.Context != nil && *l.Context-OutputReserveTokens < n {
		n = *l.Context - OutputReserveTokens
	}
	return n
}

// FitsInputBytes applies the inclusive bound without clipping the complete request.
func FitsInputBytes(size int, limits Limits) bool { return size <= UsableInputBytes(limits) }

func RequestInputBytes(r Role) int {
	if p := ResolveProfile(r); p != nil {
		return UsableInputBytes(p.Limits)
	}
	return InputBudgetBytes
}

// Compatibility describes qualification of a selection, not call success or access.
type Compatibility struct {
	Status   string  `json:"status"`
	Profile  *string `json:"profile"`
	Role     string  `json:"role"`
	Provider string  `json:"provider"`
	Model    string  `json:"model"`
	Effort   string  `json:"effort"`
}

// Map is plain JSON data for attempt observers, including a null unknown profile.
func (c Compatibility) Map() map[string]any {
	var profile any
	if c.Profile != nil {
		profile = *c.Profile
	}
	return map[string]any{"status": c.Status, "profile": profile, "role": c.Role, "provider": c.Provider, "model": c.Model, "effort": c.Effort}
}

func Classify(req Request, s *sys.Session) Compatibility {
	role, _ := req.Context["role"].(string)
	c := Compatibility{Status: "experimental", Role: role, Provider: Name(req.Role), Model: req.Role.Model, Effort: req.Role.Effort}
	p := ResolveProfile(req.Role)
	if p == nil {
		return c
	}
	c.Profile = &p.ID
	if hasImage(req.Input) {
		return c
	}
	for _, name := range []string{"KOGEN_PROVIDER_URL", "KOGEN_AUTH_URL"} {
		if s == nil {
			break
		}
		if _, ok := s.LookupEnv(name); ok {
			return c
		}
	}
	for _, q := range p.Qualifications {
		if q.Role == role && q.Effort == req.Role.Effort {
			c.Status = "supported"
			break
		}
	}
	return c
}

func OfficialText() string {
	var b strings.Builder
	b.WriteString("Official compatibility (text/tool input, normal routes only):\n")
	for _, p := range Profiles().Profiles {
		fmt.Fprintf(&b, "%s: %s/%s — %s\n", p.ID, p.Provider, p.Model, p.Route)
		for _, q := range p.Qualifications {
			fmt.Fprintf(&b, "  %s/%s [%s]\n", q.Role, q.Effort, strings.Join(q.EvidenceIDs, ", "))
		}
	}
	b.WriteString("Recommended ChatGPT defaults: Shape gpt-6.1-sol/high, Build gpt-6.1-sol/medium, Review gpt-6.1-terra/medium (omitted roles keep these defaults).\n")
	b.WriteString("Other model/effort/role strings and custom routes are experimental, may fail, and are not blocked. Recommended defaults are not qualification. Login status is local only; no credentials refreshed or account checked.\n")
	return b.String()
}
