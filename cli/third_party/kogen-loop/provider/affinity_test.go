package provider

import (
	"crypto/sha256"
	"encoding/hex"
	"reflect"
	"strings"
	"testing"
)

func TestChatGPTAffinityRendering(t *testing.T) {
	info, _ := Lookup("chatgpt")
	for _, id := range []string{"conversation-existing", strings.Repeat("x", 64), strings.Repeat("x", 65), strings.Repeat("legacy", 40)} {
		for _, unsupported := range []bool{false, true} {
			want := id
			if len(id) > MaxCacheID {
				sum := sha256.Sum256([]byte(id))
				want = hex.EncodeToString(sum[:])
			}
			r, err := render(info, Request{Role: Role{Model: "gpt-6.1-sol", Effort: "high"}}, wireID(id), unsupported)
			if err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(r.headers, map[string]string{"session_id": want, "conversation_id": want}) {
				t.Fatalf("headers = %v, want identity %q", r.headers, want)
			}
			key, present := r.body["prompt_cache_key"]
			if present == unsupported || (!unsupported && key != want) {
				t.Fatalf("unsupported=%v body key=%v present=%v", unsupported, key, present)
			}
		}
	}
}
