package shape

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"os"
	"regexp"
	"sort"
	"strings"
	"testing"
)

// forceCapture is one rendered request as the provider received it: its normalized body and the
// relevant headers, reduced to digests so a drift in any byte shows.
type forceCapture struct {
	Bytes   int               `json:"bytes"`
	Body    string            `json:"body_sha256"`
	Headers map[string]string `json:"headers"`
}

var (
	forceHex64   = regexp.MustCompile(`\b[0-9a-f]{64}\b`)
	forceHex40   = regexp.MustCompile(`\b[0-9a-f]{40}\b`)
	forceEvidDir = regexp.MustCompile(`refinements/[0-9a-f]{16}`)
)

// forceNormalize removes what a temporary fixture makes unique (paths, ports, commit and content
// hashes of paths, the conversation's cache identity) and leaves every other byte.
func forceNormalize(f *shpFx, raws []shpRaw) []forceCapture {
	var out []forceCapture
	for _, r := range raws {
		body := string(r.body)
		var decoded map[string]any
		json.Unmarshal(r.body, &decoded)
		replace := func(old, to string) {
			if old != "" {
				body = strings.ReplaceAll(body, old, to)
			}
		}
		cache, _ := decoded["prompt_cache_key"].(string)
		replace(cache, "<CACHE>")
		replace(f.Root, "<ROOT>")
		replace(f.Home, "<HOME>")
		replace(f.Aux, "<AUX>")
		replace(strings.TrimPrefix(f.Prov.srv.URL, "http://"), "<PROVIDER>")
		body = forceEvidDir.ReplaceAllString(body, "refinements/<ID>")
		body = forceHex64.ReplaceAllString(body, "<HEX64>")
		body = forceHex40.ReplaceAllString(body, "<HEX40>")
		headers := map[string]string{}
		for k, v := range r.header {
			switch http.CanonicalHeaderKey(k) {
			case "Connection", "Content-Length", "Accept-Encoding", "User-Agent":
				continue
			}
			value := strings.Join(v, ",")
			if cache != "" {
				value = strings.ReplaceAll(value, strings.TrimPrefix(cache, "conversation-"), "<CACHE>")
			}
			headers[k] = value
		}
		sum := sha256.Sum256([]byte(body))
		out = append(out, forceCapture{Bytes: len(body), Body: hex.EncodeToString(sum[:]), Headers: headers})
	}
	return out
}

// forceOrdinary runs a session that never needs enforcement and returns its normalized requests.
func forceOrdinary(t *testing.T, w *forceWire, owner string) []forceCapture {
	t.Helper()
	if owner == "refine" {
		f := w.newRefine(t, w.readReadme("r1"), w.refineSubmit("c1", refIntentPath, refTitled))
		if exit, err := f.refine(f.hash0); err != nil || exit != 0 {
			t.Fatalf("exit %d: %v", exit, err)
		}
		return forceNormalize(f.shpFx, f.Prov.rawRequests())
	}
	f := w.newShape(t, w.shapeSubmit("c1", shpFiles()), w.shapeAck("c2"))
	if exit, err := f.shape("Add calc.is_even(n)."); err != nil || exit != 0 {
		t.Fatalf("exit %d: %v", exit, err)
	}
	return forceNormalize(f, f.Prov.rawRequests())
}

// forceGolden are the requests of the ordinary sessions as captured before enforcement existed.
func forceGolden(t *testing.T) map[string][]forceCapture {
	t.Helper()
	b, err := os.ReadFile("testdata/force_ordinary_golden.json")
	if err != nil {
		t.Fatal(err)
	}
	var golden map[string][]forceCapture
	if err := json.Unmarshal(b, &golden); err != nil {
		t.Fatal(err)
	}
	return golden
}

func forceGoldenKeys(golden map[string][]forceCapture) []string {
	var keys []string
	for k := range golden {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}
