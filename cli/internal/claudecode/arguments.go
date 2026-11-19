package claudecode

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"regexp"
	"sort"
	"strings"
)

const (
	argStringBytes = 4096
	argHeadBytes   = 256
	argWholeBytes  = 65536
	argMinEnvBytes = 8
)

// secretWords are the words that make a NAME secret-named. TOKENS is separate: it only counts
// when its value is not a count.
var secretWords = map[string]bool{
	"TOKEN": true, "SECRET": true, "PASSWORD": true, "PASSWD": true, "PASSPHRASE": true, "APIKEY": true, "CREDENTIAL": true,
	"SECRETS": true, "PASSWORDS": true, "PASSWDS": true, "PASSPHRASES": true, "APIKEYS": true, "CREDENTIALS": true,
	"COOKIE": true, "BEARER": true, "AUTHORIZATION": true,
	"AUTHTOKEN": true, "ACCESSTOKEN": true, "REFRESHTOKEN": true, "CLIENTSECRET": true, "PRIVATEKEY": true,
}

// secretPairs are the adjacent word pairs that make a NAME secret-named.
var secretPairs = map[string]bool{
	"API KEY": true, "ACCESS KEY": true, "PRIVATE KEY": true, "ENCRYPTION KEY": true,
	"SIGNING KEY": true, "MASTER KEY": true, "SESSION KEY": true, "DECRYPTION KEY": true,
}

// nonsecretLast are the last words that exempt a NAME.
var nonsecretLast = map[string]bool{
	"FILE": true, "PATH": true, "STDIN": true, "LIMIT": true, "COUNT": true, "LENGTH": true,
	"SIZE": true, "NAME": true, "HELPER": true, "TTL": true, "MAX": true, "MIN": true,
}

func isNameSeparator(r rune) bool { return r == '_' || r == '-' || r == '.' }

func isUpperByte(c byte) bool { return c >= 'A' && c <= 'Z' }
func isLowerByte(c byte) bool { return c >= 'a' && c <= 'z' }
func isDigitByte(c byte) bool { return c >= '0' && c <= '9' }

// splitCamel splits w before an uppercase letter that follows a lowercase letter or a digit, and
// before an uppercase letter that is followed by a lowercase letter and preceded by an uppercase one.
func splitCamel(w string) []string {
	var out []string
	start := 0
	for i := 1; i < len(w); i++ {
		if !isUpperByte(w[i]) {
			continue
		}
		prev := w[i-1]
		if isLowerByte(prev) || isDigitByte(prev) || (isUpperByte(prev) && i+1 < len(w) && isLowerByte(w[i+1])) {
			out = append(out, w[start:i])
			start = i
		}
	}
	return append(out, w[start:])
}

// nameWords returns the words of a NAME: list A splits on separators, list B also at camelCase
// boundaries. Words are upper-case.
func nameWords(name string) (a, b []string) {
	for _, piece := range strings.FieldsFunc(strings.TrimLeft(name, "-"), isNameSeparator) {
		a = append(a, strings.ToUpper(piece))
		for _, w := range splitCamel(piece) {
			b = append(b, strings.ToUpper(w))
		}
	}
	return a, b
}

// isCount reports whether value is one or more ASCII digits once one pair of surrounding quotes is removed.
func isCount(value string) bool {
	if len(value) >= 2 && (value[0] == '"' || value[0] == '\'') && value[len(value)-1] == value[0] {
		value = value[1 : len(value)-1]
	}
	if value == "" {
		return false
	}
	for i := 0; i < len(value); i++ {
		if !isDigitByte(value[i]) {
			return false
		}
	}
	return true
}

// secretNamed reports whether an environment, assignment or option NAME with the given VALUE looks
// like it holds a secret.
func secretNamed(name, value string) bool {
	a, b := nameWords(name)
	for _, words := range [][]string{a, b} {
		if len(words) == 0 {
			continue
		}
		if words[0] == "NO" || nonsecretLast[words[len(words)-1]] {
			return false
		}
	}
	tokens := false
	for _, words := range [][]string{a, b} {
		for i, w := range words {
			if secretWords[w] || (i+1 < len(words) && secretPairs[w+" "+words[i+1]]) {
				return true
			}
			if w == "TOKENS" {
				tokens = true
			}
		}
	}
	return tokens && !isCount(value)
}

const argValue = `\$'(?:\\.|[^'\\])*'|\\"(?:\\.|[^"\\])*\\"|\\'(?:\\.|[^'\\])*\\'|'[^']*'|"[^"]*"|[^\s'"` + "`" + `;&|()<>]+`

var (
	reHeader     = regexp.MustCompile(`(?i)(?:^|\s)(?:-H|--header)\s+(?:"[A-Za-z0-9_-]+:[^"\r\n]*"|'[A-Za-z0-9_-]+:[^'\r\n]*')`)
	rePair       = regexp.MustCompile(`(?i)(["']?[A-Za-z0-9_-]+["']?)(\s*:\s*)("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|\[redacted\][^\s,;}\]"']*|[^\s,;}\]"']+)`)
	reBasicAuth  = regexp.MustCompile(`(^|\s)(?:-u|--user)\s+(?:"[^"\s:]+:(?:\\.|[^"\\])*"|'[^'\s:]+:[^']*'|[^\s:'"]+:[^\s'";&|()<>]+)`)
	rePrivateKey = regexp.MustCompile(`(?s)-----BEGIN[A-Z0-9 ]*PRIVATE KEY-----.*?(?:-----END[A-Z0-9 ]*PRIVATE KEY-----|\z)`)
	reURLAuth    = regexp.MustCompile(`([A-Za-z][A-Za-z0-9+.\-]*://[^\s:/@]*:)[^\s/@]+(@)`)
	reAuthHeader = regexp.MustCompile(`(?i)(Authorization:\s*[A-Za-z]+\s+)[^\s'"]+`)
	reTokens     = regexp.MustCompile(`\bgh[pousr]_[A-Za-z0-9]+|\bgithub_pat_[A-Za-z0-9_]+|\bsk-[A-Za-z0-9_-]{20,}|\b(?:AKIA|ASIA)[A-Z0-9]{16}\b|\bxox[abprs]-[A-Za-z0-9-]+` +
		`|\b(?:sk_live_|rk_live_|sk_test_)[A-Za-z0-9]{24,}|\bglpat-[A-Za-z0-9_-]{20,}|\bnpm_[A-Za-z0-9]{36,}|\bAIza[A-Za-z0-9_-]{35,}|\bxapp-[A-Za-z0-9-]+` +
		`|\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+`)
	reCookie      = regexp.MustCompile(`(?i)(^|[\s"'])((?:Set-)?Cookie:[ \t]*)`)
	reAssignValue = regexp.MustCompile(`^(?:` + argValue + `)`)
	reOption      = regexp.MustCompile(`(^|\s)(--?[A-Za-z0-9_][A-Za-z0-9_-]*)(\s+)(?:` + argValue + `)`)
)

// secretEnvValues are the values of the secret-named NAME=VALUE entries of env that are long
// enough to redact, longest first.
func secretEnvValues(env []string) []string {
	seen := map[string]bool{}
	var out []string
	for _, kv := range env {
		name, val, ok := strings.Cut(kv, "=")
		if !ok || len(val) < argMinEnvBytes || !secretNamed(name, val) || seen[val] {
			continue
		}
		seen[val] = true
		out = append(out, val)
	}
	sort.SliceStable(out, func(i, j int) bool { return len(out[i]) > len(out[j]) })
	return out
}

// redactSecrets applies the redaction steps after the stored token (rule 2 b to h) to s.
func redactSecrets(s string, envValues []string) string {
	for _, v := range envValues {
		s = strings.ReplaceAll(s, v, redactMark)
	}
	s = rePrivateKey.ReplaceAllLiteralString(s, redactMark)
	s = reURLAuth.ReplaceAllString(s, "${1}"+redactMark+"${2}")
	s = replaceMatches(reHeader, s, func(s string, m []int) string {
		match := s[m[0]:m[1]]
		colon := strings.IndexByte(match, ':')
		quote := strings.IndexAny(match, "\"'")
		rawName := match[quote+1 : colon]
		name := strings.ToUpper(rawName)
		start := colon + 1
		for start < len(match)-1 && (match[start] == ' ' || match[start] == '\t') {
			start++
		}
		if name != "COOKIE" && name != "SET-COOKIE" && !strings.Contains(name, "KEY") && !strings.Contains(name, "TOKEN") && !strings.Contains(name, "SECRET") && !strings.Contains(name, "AUTH") && !secretNamed(rawName, match[start:len(match)-1]) {
			return match
		}
		return match[:start] + redactMark + match[len(match)-1:]
	})
	s = redactCookies(s)
	s = reAuthHeader.ReplaceAllString(s, "${1}"+redactMark)
	s = replaceMatches(reBasicAuth, s, func(s string, m []int) string {
		match := s[m[0]:m[1]]
		colon := strings.IndexByte(match, ':')
		suffix := ""
		if match[len(match)-1] == '\'' || match[len(match)-1] == '"' {
			suffix = match[len(match)-1:]
		}
		return match[:colon+1] + redactMark + suffix
	})
	s = replaceMatches(rePair, s, func(s string, m []int) string {
		name := strings.Trim(s[m[2]:m[3]], "\"'")
		value := s[m[6]:m[7]]
		if !secretNamed(name, value) || value == redactMark {
			return s[m[0]:m[1]]
		}
		// "Authorization: <scheme> [redacted]" was already handled by the Authorization rule.
		if strings.EqualFold(name, "authorization") && isLetters(value) && authSchemeRedacted.MatchString(s[m[7]:]) {
			return s[m[0]:m[1]]
		}
		if len(value) >= 2 && (value[0] == '\'' || value[0] == '"') {
			return s[m[0]:m[6]+1] + redactMark + value[len(value)-1:]
		}
		return s[m[0]:m[6]] + redactMark
	})
	s = reTokens.ReplaceAllLiteralString(s, redactMark)
	s = redactAssignments(s)
	// A nonsecret option must not hide a subsequent secret option from the scan.
	var b strings.Builder
	for offset := 0; offset < len(s); {
		m := reOption.FindStringSubmatchIndex(s[offset:])
		if m == nil {
			b.WriteString(s[offset:])
			break
		}
		part := s[offset:]
		if secretNamed(part[m[4]:m[5]], part[m[7]:m[1]]) && !strings.HasPrefix(part[m[7]:m[1]], "-") {
			b.WriteString(part[:m[7]])
			b.WriteString(redactMark)
			offset += m[1]
		} else if strings.HasPrefix(part[m[7]:m[1]], "-") {
			b.WriteString(part[:m[5]])
			offset += m[5]
		} else {
			b.WriteString(part[:m[1]])
			offset += m[1]
		}
	}
	return b.String()
}

// redactAssignments replaces the VALUE of every secret-named NAME=VALUE in s. Each '=' is checked
// with the maximal NAME directly before it, so a non-secret value never hides a later secret
// assignment (--from-literal=password=x).
func redactAssignments(s string) string {
	var b strings.Builder
	last := 0
	for i := 0; i < len(s); i++ {
		if s[i] != '=' {
			continue
		}
		j := i
		for j > last && isNameByte(s[j-1]) {
			j--
		}
		if j == i {
			continue
		}
		m := reAssignValue.FindStringIndex(s[i+1:])
		if m == nil || !secretNamed(s[j:i], s[i+1:i+1+m[1]]) {
			continue
		}
		b.WriteString(s[last : i+1])
		b.WriteString(redactMark)
		last = i + 1 + m[1]
		i = last - 1
	}
	b.WriteString(s[last:])
	return b.String()
}

var authSchemeRedacted = regexp.MustCompile(`^\s+\[redacted\]`)

func isLetters(s string) bool {
	for i := 0; i < len(s); i++ {
		if !isUpperByte(s[i]) && !isLowerByte(s[i]) {
			return false
		}
	}
	return s != ""
}

// redactCookies replaces the value of every Cookie: or Set-Cookie: in s. The value runs to the
// next quote when the name directly follows that quote, and otherwise to the end of the line.
func redactCookies(s string) string {
	var b strings.Builder
	last := 0
	for _, m := range reCookie.FindAllStringSubmatchIndex(s, -1) {
		if m[4] < last {
			continue
		}
		var end int
		if lead := s[m[2]:m[3]]; lead == "\"" || lead == "'" {
			end = strings.Index(s[m[1]:], lead)
		} else {
			end = strings.IndexAny(s[m[1]:], "\r\n")
		}
		if end < 0 {
			end = len(s)
		} else {
			end += m[1]
		}
		if end == m[1] {
			continue
		}
		b.WriteString(s[last:m[1]])
		b.WriteString(redactMark)
		last = end
	}
	b.WriteString(s[last:])
	return b.String()
}

func isNameByte(c byte) bool {
	return c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '_' || c == '-'
}

// replaceMatches replaces every match of re in s by fn(s, submatch indexes).
func replaceMatches(re *regexp.Regexp, s string, fn func(s string, m []int) string) string {
	var b strings.Builder
	last := 0
	for _, m := range re.FindAllStringSubmatchIndex(s, -1) {
		b.WriteString(s[last:m[0]])
		b.WriteString(fn(s, m))
		last = m[1]
	}
	b.WriteString(s[last:])
	return b.String()
}

func sha256Hex(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

// boundString keeps a string of at most 4096 bytes and replaces a longer one by its size, hash
// and a head cut back to a rune start.
func boundString(s string) any {
	if len(s) <= argStringBytes {
		return s
	}
	cut := argHeadBytes
	for cut > 0 && !isRuneStart(s[cut]) {
		cut--
	}
	return map[string]any{"truncated": true, "bytes": len(s), "sha256": sha256Hex([]byte(s)), "head": s[:cut]}
}

// jsonValueText is the text a JSON value stands for when deciding whether its key is a count: a
// number is a count, a string is itself and anything else is not.
func jsonValueText(v any) string {
	switch x := v.(type) {
	case string:
		return x
	case float64, json.Number, int, int64:
		return "0"
	}
	return ""
}

// processValue redacts and then bounds every string value of v at any depth.
func processValue(v any, envValues []string) any {
	switch x := v.(type) {
	case string:
		return boundString(redactSecrets(x, envValues))
	case map[string]any:
		out := make(map[string]any, len(x))
		for k, e := range x {
			if secretNamed(k, jsonValueText(e)) {
				out[k] = redactMark
			} else {
				out[k] = processValue(e, envValues)
			}
		}
		return out
	case []any:
		out := make([]any, len(x))
		for i, e := range x {
			out[i] = processValue(e, envValues)
		}
		return out
	}
	return v
}

// toolArguments is the logged form of a tool_use input: nil unless it is a JSON object, strings
// redacted and bounded, the whole replaced by its size and hash when its encoding is over 65536
// bytes. env is the adapter's base environment.
func toolArguments(input any, env []string) any {
	obj, ok := input.(map[string]any)
	if !ok {
		return nil
	}
	out := processValue(obj, secretEnvValues(env))
	enc, err := json.Marshal(out)
	if err != nil {
		return nil
	}
	if len(enc) > argWholeBytes {
		return map[string]any{"truncated": true, "bytes": len(enc), "sha256": sha256Hex(enc)}
	}
	return out
}

// toolArguments is the logged arguments of a tool_use input of this session.
func (s *session) toolArguments(input any) any {
	var env []string
	if s.a != nil {
		env = s.a.opts.Env
	}
	return toolArguments(input, env)
}
