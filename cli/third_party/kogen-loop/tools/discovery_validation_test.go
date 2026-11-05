package tools

import (
	"context"
	"strings"
	"testing"

	"github.com/KogenAI/kogen-loop/api"
)

func TestDiscoveryArgumentValidation(t *testing.T) {
	tl := newTools(t.TempDir(), ListFilesTool, SearchTextTool)
	for _, name := range []string{ListFilesTool, SearchTextTool} {
		for _, value := range []string{"5", "null", "[]", "{}"} {
			raw := `{"path":` + value + `,"pattern":"needle"}`
			t.Run(name+"/path/"+value, func(t *testing.T) {
				got, err := tl.CallClassified(context.Background(), Call{Name: name, Arguments: raw})
				if err != nil || got.MalformedClass != api.MalformedWrongArgumentType || !strings.Contains(got.Text, "path") {
					t.Fatalf("got %+v, %v", got, err)
				}
			})
		}
		for _, raw := range []string{"not json", "[]", "null"} {
			t.Run(name+"/arguments/"+raw, func(t *testing.T) {
				got, err := tl.CallClassified(context.Background(), Call{Name: name, Arguments: raw})
				if err != nil || got.MalformedClass != api.MalformedWrongArgumentType || !strings.Contains(got.Text, "arguments") {
					t.Fatalf("got %+v, %v", got, err)
				}
			})
		}
	}
}
