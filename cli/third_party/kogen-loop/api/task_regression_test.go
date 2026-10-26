package api_test

import (
	"strings"
	"testing"

	"kogen-loop/api"
)

func TestDecodeTaskRequiresExactlyOneObject(t *testing.T) {
	for _, text := range []string{
		`null`,
		`{}]`,
		`{}}`,
		`{} garbage`,
	} {
		t.Run(text, func(t *testing.T) {
			if _, err := api.DecodeTask(strings.NewReader(text)); err == nil {
				t.Fatal("accepted a task that is not exactly one JSON object")
			}
		})
	}
	got, err := api.DecodeTask(strings.NewReader(" \n{\"prompt\":\"hello\"}\t\n"))
	if err != nil || got.Prompt != "hello" {
		t.Fatalf("valid object with surrounding whitespace: task %+v, error %v", got, err)
	}
}
