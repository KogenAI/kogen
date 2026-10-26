package tools

import (
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"
)

// Documentation is the shaper's documentation tool: it discovers sources and retrieves
// current authoritative documentation, always as an honest result (retrieved, unreachable,
// unsupported or untrusted) and never as an error. Retrieved text is untrusted data. The
// zero value works: public search through Bing, fetches of any http(s) URL, 20 s per request.
type Documentation struct {
	// UserAgent is the user-agent of every request (`kogen/<version>`); empty is `kogen/`.
	UserAgent string
	// Timeout is the ceiling of one request; zero is 20 seconds.
	Timeout time.Duration
	// PublicSearch is the search URL prefix; empty is Bing's. The query is appended encoded.
	PublicSearch string
}

const (
	docMarker      = "UNTRUSTED-DIRECTIVE-7b9acb97"
	docOutputLimit = 16_384
	docBodyLimit   = 8 << 20
	docRedirects   = 5
	docUnsupported = "documentation source unsupported"
	docUnreachable = "documentation source unreachable"
	docUntrusted   = "documentation response untrusted"
)

type docSource struct{ URL, Title string }

type docResult struct {
	Operation, Status, Query, URL string
	Sources                       []docSource
	Body                          string
	Untrusted, Truncated          bool
	Error                         string
}

func (r docResult) value() map[string]any {
	sources := make([]any, len(r.Sources))
	for i, s := range r.Sources {
		sources[i] = map[string]any{"url": s.URL, "title": s.Title}
	}
	return map[string]any{
		"operation": r.Operation, "status": r.Status, "query": r.Query, "url": r.URL, "sources": sources,
		"body": r.Body, "untrusted": r.Untrusted, "truncated": r.Truncated, "error": r.Error,
	}
}

func docOf(operation, status, query, url string, sources []docSource, body string, untrusted bool, errText string) docResult {
	return docResult{Operation: operation, Status: status, Query: query, URL: url, Sources: sources, Body: body, Untrusted: untrusted, Error: errText}
}

func docUnsupportedResult(operation, query, url string) docResult {
	return docOf(operation, "unsupported", query, url, nil, "", false, docUnsupported)
}

func docString(args map[string]any, key string) string {
	s, _ := args[key].(string)
	return s
}

// Lookup is one call of the tool: the arguments are the decoded JSON object the model sent
// (nil: not an object). The text is the JSON result the model reads, at most 16384 bytes.
func (d Documentation) Lookup(args map[string]any) string {
	if args == nil {
		return d.encode(docUnsupportedResult("search", "", ""))
	}
	operation := "search"
	if op, ok := args["operation"].(string); ok {
		operation = op
	}
	query, u, base := docString(args, "query"), docString(args, "url"), docString(args, "base")
	return d.encode(d.dispatch(operation, query, u, base))
}

func (d Documentation) encode(r docResult) string {
	r = docFit(r)
	b, err := encodeJSON(r.value())
	if err != nil {
		return `{"error":"documentation source unsupported","status":"unsupported"}`
	}
	return string(b)
}

func (d Documentation) dispatch(operation, query, u, base string) docResult {
	if base == "" {
		switch operation {
		case "search":
			return d.publicSearch(query)
		case "fetch":
			return d.publicFetch(query, u)
		}
		return docUnsupportedResult(operation, query, u)
	}
	base = strings.TrimRight(base, "/")
	switch operation {
	case "search":
		return d.basedSearch(query, base)
	case "fetch":
		return d.basedFetch(query, u, base)
	}
	return docUnsupportedResult(operation, query, u)
}

func (d Documentation) publicSearch(query string) docResult {
	prefix := d.PublicSearch
	if prefix == "" {
		prefix = "https://www.bing.com/search?q="
	}
	status, body, err := d.get(prefix+docEscape(query)+"&setlang=en", "")
	switch {
	case err != nil:
		return docOf("search", "unreachable", query, "", nil, "", false, docUnreachable)
	case status != 200:
		return docUnsupportedResult("search", query, "")
	}
	sources := BingSources(string(body))
	if len(sources) == 0 {
		return docUnsupportedResult("search", query, "")
	}
	return docOf("search", "retrieved", query, "", sources, "", false, "")
}

func (d Documentation) publicFetch(query, u string) docResult {
	if !docHTTPURL(u) {
		return docUnsupportedResult("fetch", query, u)
	}
	status, body, err := d.get(u, "")
	return classifyFetch(query, u, status, body, err)
}

func (d Documentation) basedSearch(query, base string) docResult {
	status, body, err := d.get(base+"/search?q="+docEscape(query), base)
	switch {
	case err != nil:
		return docOf("search", "unreachable", query, "", nil, "", false, docUnreachable)
	case status != 200:
		return docUnsupportedResult("search", query, "")
	}
	return docOf("search", "retrieved", query, "", fixtureSources(body), "", false, "")
}

func (d Documentation) basedFetch(query, u, base string) docResult {
	if !strings.HasPrefix(u, base) || !docSameOrigin(u, base) {
		return docUnsupportedResult("fetch", query, u)
	}
	status, body, err := d.get(u, base)
	return classifyFetch(query, u, status, body, err)
}

func classifyFetch(query, u string, status int, raw []byte, err error) docResult {
	switch {
	case err != nil:
		return docOf("fetch", "unreachable", query, u, nil, "", false, docUnreachable)
	case status != 200:
		return docUnsupportedResult("fetch", query, u)
	}
	marked := strings.Contains(string(raw), docMarker)
	text := docUTF8(raw)
	if marked {
		if !strings.Contains(text, docMarker) {
			text = docMarker + text
		}
		r := docOf("fetch", "untrusted", query, u, nil, text, true, docUntrusted)
		return r
	}
	return docOf("fetch", "retrieved", query, u, nil, text, true, "")
}

// docEscape is URI.encode with only the unreserved characters kept: everything else
// percent-encoded, uppercase.
func docEscape(s string) string {
	const hex = "0123456789ABCDEF"
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '.' || c == '_' || c == '~' {
			b.WriteByte(c)
			continue
		}
		b.WriteByte('%')
		b.WriteByte(hex[c>>4])
		b.WriteByte(hex[c&15])
	}
	return b.String()
}

// get follows at most five redirects. With a base, no request leaves that origin: a URL
// outside it ends the walk with status 0.
func (d Documentation) get(raw, base string) (int, []byte, error) {
	current := docCanonical(raw)
	for left := docRedirects; ; left-- {
		if left < 1 || base != "" && !docAllowed(current, base) {
			return 0, nil, nil
		}
		status, header, body, err := d.once(current)
		if err != nil {
			return 0, nil, err
		}
		switch status {
		case 301, 302, 303, 307, 308:
		default:
			return status, body, nil
		}
		location := strings.TrimSpace(header.Get("Location"))
		if location == "" {
			return status, body, nil
		}
		next := docResolve(current, location)
		if !docHTTPURL(next) || base != "" && !docAllowed(next, base) {
			return status, body, nil
		}
		current = next
	}
}

func docResolve(current, location string) string {
	base, err := url.Parse(current)
	if err != nil {
		return location
	}
	ref, err := url.Parse(location)
	if err != nil {
		return location
	}
	return docCanonical(base.ResolveReference(ref).String())
}

func (d Documentation) once(u string) (int, http.Header, []byte, error) {
	timeout := d.Timeout
	if timeout <= 0 {
		timeout = 20 * time.Second
	}
	agent := d.UserAgent
	if agent == "" {
		agent = "kogen/"
	}
	client := &http.Client{
		Timeout: timeout,
		CheckRedirect: func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse
		},
		Transport: &http.Transport{
			Proxy:               nil,
			DisableKeepAlives:   true,
			DisableCompression:  true,
			TLSHandshakeTimeout: timeout,
		},
	}
	req, err := http.NewRequest(http.MethodGet, u, nil)
	if err != nil {
		return 0, nil, nil, err
	}
	req.Header.Set("User-Agent", agent)
	req.Header.Set("Accept", "text/html")
	req.Header.Set("Accept-Language", "en")
	resp, err := client.Do(req)
	if err != nil {
		return 0, nil, nil, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, docBodyLimit))
	if err != nil {
		return 0, nil, nil, err
	}
	return resp.StatusCode, resp.Header, body, nil
}

// docCanonical lowercases the host and drops any userinfo.
func docCanonical(raw string) string {
	u, err := url.Parse(raw)
	if err != nil {
		return raw
	}
	u.User = nil
	if u.Host != "" {
		host := strings.ToLower(u.Hostname())
		if strings.Contains(host, ":") {
			host = "[" + host + "]"
		}
		if port := u.Port(); port != "" {
			host += ":" + port
		}
		u.Host = host
	}
	return u.String()
}

func docAllowed(u, base string) bool { return strings.HasPrefix(u, base) && docSameOrigin(u, base) }

func docHTTPURL(raw string) bool {
	u, err := url.Parse(raw)
	if err != nil {
		return false
	}
	scheme := strings.ToLower(u.Scheme)
	return (scheme == "http" || scheme == "https") && u.Hostname() != ""
}

func docSameOrigin(a, b string) bool {
	ua, errA := url.Parse(a)
	ub, errB := url.Parse(b)
	if errA != nil || errB != nil {
		return false
	}
	scheme := strings.ToLower(ua.Scheme)
	return scheme == strings.ToLower(ub.Scheme) && (scheme == "http" || scheme == "https") &&
		strings.ToLower(ua.Hostname()) == strings.ToLower(ub.Hostname()) && ua.Hostname() != "" &&
		docPort(ua) == docPort(ub)
}

func docPort(u *url.URL) string {
	if p := u.Port(); p != "" {
		return p
	}
	if strings.EqualFold(u.Scheme, "https") {
		return "443"
	}
	return "80"
}

// fixtureSources are the `sources` of a pinned origin's JSON search answer.
func fixtureSources(body []byte) []docSource {
	var doc map[string]any
	if err := json.Unmarshal([]byte(docUTF8(body)), &doc); err != nil {
		return nil
	}
	list, _ := doc["sources"].([]any)
	var out []docSource
	for _, entry := range list {
		s, _ := entry.(map[string]any)
		u, uok := s["url"].(string)
		title, tok := s["title"].(string)
		if uok && tok {
			out = append(out, docSource{u, title})
		}
	}
	return out
}

var (
	bingOpen   = regexp.MustCompile(`(?i)<([a-zA-Z0-9]+)\b[^>]*class="[^"]*\bb_algo\b[^"]*"[^>]*>`)
	bingAnchor = regexp.MustCompile(`(?i)<h2\b[^>]*>\s*<a\b[^>]*href="([^"]*)"[^>]*>([\s\S]*?)</a>`)
	tagPattern = regexp.MustCompile(`<[^>]*>`)
	spaces     = regexp.MustCompile(`\s+`)
)

// BingSources are the results of a public search page: each element of class b_algo whose
// first heading link carries a decodable target URL, as {url, title}, in page order.
func BingSources(html string) []docSource {
	var out []docSource
	for pos := 0; pos < len(html); {
		m := bingOpen.FindStringSubmatchIndex(html[pos:])
		if m == nil {
			break
		}
		start, end := pos+m[0], pos+m[1]
		name := html[pos+m[2] : pos+m[3]]
		closeAt := indexFold(html[end:], "</"+name+">")
		if closeAt < 0 {
			pos = start + 1
			continue
		}
		block := html[end : end+closeAt]
		pos = end + closeAt + len(name) + 3
		a := bingAnchor.FindStringSubmatch(block)
		if a == nil {
			continue
		}
		if target, ok := decodeBingHref(a[1]); ok {
			out = append(out, docSource{target, docCollapse(a[2])})
		}
	}
	return out
}

func indexFold(s, sub string) int {
	return strings.Index(strings.ToLower(s), strings.ToLower(sub))
}

func decodeBingHref(href string) (string, bool) {
	decoded := docUnescape(href)
	u, err := url.Parse(decoded)
	if err != nil || u.RawQuery == "" {
		return "", false
	}
	values, err := url.ParseQuery(u.RawQuery)
	if err != nil {
		return "", false
	}
	list := values["u"]
	if len(list) == 0 || list[len(list)-1] == "" {
		return "", false
	}
	encoded := strings.TrimRight(strings.TrimPrefix(list[len(list)-1], "a1"), "=")
	if strings.ContainsAny(encoded, "\r\n") {
		return "", false
	}
	encoded += strings.Repeat("=", (4-len(encoded)%4)%4)
	raw, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil {
		return "", false
	}
	target := string(raw)
	if !docHTTPURL(target) {
		return "", false
	}
	return target, true
}

func docUnescape(s string) string {
	for _, p := range [][2]string{{"&amp;", "&"}, {"&lt;", "<"}, {"&gt;", ">"}, {"&quot;", `"`}, {"&#39;", "'"}, {"&apos;", "'"}} {
		s = strings.ReplaceAll(s, p[0], p[1])
	}
	return s
}

func docCollapse(s string) string {
	s = tagPattern.ReplaceAllString(s, "")
	s = docUnescape(s)
	s = spaces.ReplaceAllString(s, " ")
	return strings.TrimSpace(s)
}

// docUTF8 is the body as valid UTF-8: each invalid byte becomes U+FFFD, and an incomplete
// sequence at the very end one.
func docUTF8(b []byte) string {
	var out strings.Builder
	for i := 0; i < len(b); {
		r, size := utf8.DecodeRune(b[i:])
		if r == utf8.RuneError && size == 1 {
			out.WriteRune(utf8.RuneError)
			if !utf8.FullRune(b[i:]) {
				break
			}
			i++
			continue
		}
		out.Write(b[i : i+size])
		i += size
	}
	return out.String()
}

// docFit shrinks the result until its JSON is at most 16384 bytes: sources go last-first
// once the body is small, the body halves otherwise, an untrusted body always keeps the
// marker. After 24 rounds only the marker (untrusted) or nothing is left.
func docFit(r docResult) docResult {
	for left := 24; ; left-- {
		if left == 0 {
			r.Body = ""
			if r.Untrusted {
				r.Body = docMarker
			}
			r.Sources, r.Truncated = nil, true
			return r
		}
		if b, err := encodeJSON(r.value()); err == nil && len(b) <= docOutputLimit {
			return r
		}
		switch {
		case len(r.Sources) > 0 && len(r.Body) <= 64:
			r.Sources = r.Sources[:len(r.Sources)-1]
			r.Truncated = true
		case len(r.Body) > 0:
			body := validPrefix(r.Body[:len(r.Body)/2])
			if r.Untrusted && !strings.Contains(body, docMarker) {
				body = docMarker + body
			}
			r.Body, r.Truncated = body, true
		default:
			r.Sources, r.Truncated = nil, true
		}
	}
}
