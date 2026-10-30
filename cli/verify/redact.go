package verify

import (
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
)

// Redacted replaces every secret the Redactor recognizes.
const Redacted = "[REDACTED]"

// Redactor masks secrets in diagnostic text before it is excerpted, bounded, shown or kept.
//
// It recognizes exactly these, and nothing else:
//   - the values of the caller's nonempty environment variables whose names contain TOKEN,
//     KEY, PASSWORD or SECRET (in any letter case) ;
//   - the string values of Kogen's own saved logins in ~/.kogen/credentials/*.json whose field
//     names contain token, key, secret, password, auth, bearer or credential;
//   - the value of an Authorization header or assignment, and any `Bearer <value>`;
//   - the value of an assignment (`name=value`, `name: value`, `"name": "value"`) or a long
//     option (`--name value`) whose name contains token, key, secret, password or passwd.
//
// A secret that is none of these (an unlabeled value Kogen was never given) cannot be
// detected. Masking is applied to the complete text, so it precedes every excerpt and byte
// bound and a secret cannot be split by one. The one cut outside Kogen's reach is the
// command runner's own 512 KiB head and tail capture of a single command's output: a secret
// straddling that cut loses its middle, which is dropped, but the surviving ends are not
// masked.
type Redactor struct {
	known    []string
	replacer *strings.Replacer
}

var secretName = `[A-Za-z0-9_.-]*(?:token|key|secret|password|passwd)[A-Za-z0-9_.-]*`

var redactPatterns = []struct {
	re   *regexp.Regexp
	with string
}{
	{regexp.MustCompile(`(?i)\b(authorization["']?\s*[:=]\s*["']?)(?:(bearer|basic|token)\s+)?[^\s"',;]+`), "${1}${2} " + Redacted},
	{regexp.MustCompile(`(?i)\b(bearer)\s+[A-Za-z0-9._~+/=-]{6,}`), "${1} " + Redacted},
	{regexp.MustCompile(`(?i)(--` + secretName + `)(\s+)("[^"]*"|'[^']*'|[^\s"'-][^\s"']*)`), "${1}${2}" + Redacted},
	{regexp.MustCompile(`(?i)\b(` + secretName + `["']?\s*[:=]\s*)("[^"]*"|'[^']*'|[^\s"',;&]+)`), "${1}" + Redacted},
}

var envSecretName = regexp.MustCompile(`(?i)TOKEN|KEY|PASSWORD|SECRET`)

var credentialField = regexp.MustCompile(`(?i)token|key|secret|password|auth|bearer|credential`)

// NewRedactor builds the Redactor for a caller environment (KEY=value entries) and home
// directory; home may be empty.
func NewRedactor(env []string, home string) *Redactor {
	seen := map[string]bool{}
	var known []string
	add := func(v string) {
		if len(v) > 0 && !seen[v] {
			seen[v] = true
			known = append(known, v)
		}
	}
	for _, kv := range env {
		if name, value, ok := strings.Cut(kv, "="); ok && envSecretName.MatchString(name) {
			add(value)
		}
	}
	if home != "" {
		files, _ := filepath.Glob(filepath.Join(home, ".kogen", "credentials", "*.json"))
		for _, f := range files {
			b, err := os.ReadFile(f)
			if err != nil {
				continue
			}
			var doc any
			if json.Unmarshal(b, &doc) == nil {
				collectCredentials(doc, "", add)
			}
		}
	}
	// Longest first, so a secret that contains another one is masked whole.
	slices.SortStableFunc(known, func(a, b string) int { return len(b) - len(a) })
	pairs := make([]string, 0, 2*len(known))
	for _, k := range known {
		pairs = append(pairs, k, Redacted)
	}
	return &Redactor{known: known, replacer: strings.NewReplacer(pairs...)}
}

func collectCredentials(v any, field string, add func(string)) {
	switch x := v.(type) {
	case map[string]any:
		for k, e := range x {
			collectCredentials(e, k, add)
		}
	case []any:
		for _, e := range x {
			collectCredentials(e, field, add)
		}
	case string:
		if credentialField.MatchString(field) {
			add(x)
		}
	}
}

// Redact masks the known secret values and the labeled secrets in text. A nil Redactor
// masks only the labeled ones. Bytes that are not valid UTF-8 become U+FFFD.
func (r *Redactor) Redact(text string) string {
	// Bytes that are not UTF-8 would make the text unrecordable and its byte bounds unsafe.
	text = strings.ToValidUTF8(text, "\uFFFD")
	for _, p := range redactPatterns {
		text = p.re.ReplaceAllString(text, p.with)
	}
	if r != nil && r.replacer != nil && len(r.known) > 0 {
		text = r.replacer.Replace(text)
	}
	return text
}
