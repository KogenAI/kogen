package provider

import (
	"context"
	"net/http"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"
)

func tokenAnswer(access, refresh string, expires int64) handler {
	body := map[string]any{"access_token": access, "expires_in": expires}
	if refresh != "" {
		body["refresh_token"] = refresh
	}
	return jsonAnswer(200, body)
}

func unauthorized() handler {
	return jsonAnswer(401, map[string]any{"error": map[string]any{"code": "unauthorized", "type": "authentication_error", "message": "rejected"}})
}

func bearer(r recorded) string { return r.Header.Get("Authorization") }

func lockFile(e *env, name string) string {
	return filepath.Join(e.home, ".kogen", "credentials", name+".lock")
}

func mustNotExist(t *testing.T, path string) {
	t.Helper()
	if _, err := os.Lstat(path); err == nil {
		t.Fatalf("%s exists", path)
	}
}

// features/08-chatgpt: an expired access token is refreshed and the rotated refresh token is saved (GPT-6).
func TestExpiredChatGPTTokenIsRefreshedAndRotationSaved(t *testing.T) {
	f := newFake(t, textAnswer("ok")).authScript(tokenAnswer("rotated-access", "rotated-refresh", 3600))
	e := newEnv(t, f)
	e.saveCreds("chatgpt", e.chatgptCreds("expires_at", e.clk.Now().Unix()+30, "email", "u@example.com", "scope", "openid", "extra", "kept"))
	if _, err := e.respond(Request{}); err != nil {
		t.Fatal(err)
	}
	auth := f.authRequests()
	if len(auth) != 1 || auth[0].Path != "/api/accounts/oauth/token" {
		t.Fatalf("auth requests = %+v", auth)
	}
	want := map[string][]string{"grant_type": {"refresh_token"}, "client_id": {"oaiapp_fixture"}, "refresh_token": {"fake-refresh-token"}, "resource": {"https://api.openai.com/v1"}}
	if !reflect.DeepEqual(map[string][]string(auth[0].Form), want) {
		t.Fatalf("refresh form = %v (no scope is sent)", auth[0].Form)
	}
	if auth[0].Header.Get("Accept") != "application/json" || auth[0].Header.Get("Content-Type") != "application/x-www-form-urlencoded" || auth[0].Header.Get("User-Agent") != "" {
		t.Fatalf("refresh headers = %v", auth[0].Header)
	}
	if bearer(f.requests()[0]) != "Bearer rotated-access" {
		t.Fatal("the new access token was not used")
	}
	saved := e.readCreds("chatgpt")
	if saved["access_token"] != "rotated-access" || saved["refresh_token"] != "rotated-refresh" || saved["email"] != "u@example.com" || saved["extra"] != "kept" || saved["client_id"] != "oaiapp_fixture" || saved["scope"] != "openid" {
		t.Fatalf("saved = %v", saved)
	}
	if saved["expires_at"] != e.clk.Now().Unix()+3600 {
		t.Fatalf("expires_at = %v", saved["expires_at"])
	}
	if st, _ := os.Stat(e.credPath("chatgpt")); st.Mode().Perm() != 0o600 {
		t.Fatal("mode")
	}
	mustNotExist(t, lockFile(e, "chatgpt"))
}

func TestRefreshKeepsOldRefreshTokenWhenNotRotated(t *testing.T) {
	f := newFake(t, textAnswer("ok")).authScript(tokenAnswer("a2", "", 0))
	e := newEnv(t, f)
	e.saveCreds("chatgpt", e.chatgptCreds("expires_at", int64(0)))
	// expires_in 0 is an integer, so it is honoured; a missing one defaults to an hour.
	if _, err := e.respond(Request{}); err != nil {
		t.Fatal(err)
	}
	if got := e.readCreds("chatgpt"); got["refresh_token"] != "fake-refresh-token" || got["expires_at"] != e.clk.Now().Unix() {
		t.Fatalf("saved = %v", got)
	}
	f2 := newFake(t, textAnswer("ok")).authScript(jsonAnswer(200, map[string]any{"access_token": "a3"}))
	e2 := newEnv(t, f2)
	e2.saveCreds("chatgpt", e2.chatgptCreds("expires_at", int64(0)))
	e2.respond(Request{})
	if got := e2.readCreds("chatgpt"); got["expires_at"] != e2.clk.Now().Unix()+3600 {
		t.Fatalf("default expiry = %v", got["expires_at"])
	}
}

// features/08-chatgpt: a 401 refreshes once and retries once.
func TestUnauthorizedRefreshesOnceThenRetries(t *testing.T) {
	f := newFake(t, unauthorized(), textAnswer("ok")).authScript(tokenAnswer("rotated-access", "rotated-refresh", 3600))
	e := newEnv(t, f)
	e.saveCreds("chatgpt", e.chatgptCreds())
	resp, err := e.respond(Request{})
	if err != nil || len(resp.Items) != 1 {
		t.Fatal(err)
	}
	reqs := f.requests()
	if len(reqs) != 2 || len(f.authRequests()) != 1 || bearer(reqs[0]) != "Bearer fake-access-token" || bearer(reqs[1]) != "Bearer rotated-access" {
		t.Fatalf("%d requests, %d refreshes: %q %q", len(reqs), len(f.authRequests()), bearer(reqs[0]), bearer(reqs[len(reqs)-1]))
	}
	if len(e.clk.slept()) != 0 {
		t.Fatal("the retry after a refresh waits for nothing")
	}
}

// provider_diagnostics_test: context and login wrappers preserve known response metadata
// (the second 401 is rejected without a second refresh).
func TestSecond401IsRejectedWithDiagnostics(t *testing.T) {
	f := newFake(t, unauthorized(), unauthorized(), textAnswer("never")).authScript(tokenAnswer("rotated-access", "rotated-refresh", 3600))
	e := newEnv(t, f)
	e.saveCreds("chatgpt", e.chatgptCreds())
	_, err := e.respond(Request{})
	se := mustErr(t, err)
	if se.Reason != "login" || se.Exit != 4 || se.Detail != "the ChatGPT sign-in was rejected; run kogen provider login chatgpt" {
		t.Fatalf("err = %v", se)
	}
	if !reflect.DeepEqual(se.ProviderFailure, map[string]any{"code": "unauthorized", "type": "authentication_error", "http_status": int64(401)}) {
		t.Fatalf("provider failure = %v", se.ProviderFailure)
	}
	if len(f.authRequests()) != 1 || len(f.requests()) != 2 {
		t.Fatalf("%d refreshes, %d requests", len(f.authRequests()), len(f.requests()))
	}
}

// features/08-chatgpt: a rejected access token and refresh token ask for a new login.
func TestRejectedTokenAndRejectedRefreshAskForNewLogin(t *testing.T) {
	for _, auth := range []handler{jsonAnswer(400, map[string]any{"error": "invalid_grant"}), jsonAnswer(500, map[string]any{}), jsonAnswer(200, map[string]any{})} {
		f := newFake(t, unauthorized(), textAnswer("never")).authScript(auth)
		e := newEnv(t, f)
		bytes := mustEncode(e.chatgptCreds())
		e.saveCreds("chatgpt", e.chatgptCreds())
		_, err := e.respond(Request{})
		se := mustErr(t, err)
		if se.Detail != "the ChatGPT sign-in was rejected; run kogen provider login chatgpt" || se.ProviderFailure["http_status"] != int64(401) {
			t.Fatalf("err = %v", se)
		}
		got, _ := os.ReadFile(e.credPath("chatgpt"))
		if string(got) != string(bytes) || len(f.requests()) != 1 {
			t.Fatal("credentials changed or the request was retried")
		}
		mustNotExist(t, lockFile(e, "chatgpt"))
	}
}

func TestProactiveRefreshFailures(t *testing.T) {
	cases := []struct {
		name   string
		answer handler
		detail string
	}{
		{"invalid_grant", jsonAnswer(400, map[string]any{"error": "invalid_grant"}), "the ChatGPT sign-in was rejected; run kogen provider login chatgpt"},
		{"temporarily_unavailable", jsonAnswer(503, map[string]any{"error": "temporarily_unavailable"}), "the ChatGPT sign-in expired and could not be refreshed; run kogen provider login chatgpt"},
		{"no token", jsonAnswer(200, map[string]any{}), "the ChatGPT sign-in expired and could not be refreshed; run kogen provider login chatgpt"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			f := newFake(t, textAnswer("never")).authScript(tc.answer)
			e := newEnv(t, f)
			e.saveCreds("chatgpt", e.chatgptCreds("expires_at", int64(0)))
			before, _ := os.ReadFile(e.credPath("chatgpt"))
			_, err := e.respond(Request{})
			se := mustErr(t, err)
			if se.Reason != "login" || se.Exit != 4 || se.Detail != tc.detail {
				t.Fatalf("err = %v", se)
			}
			after, _ := os.ReadFile(e.credPath("chatgpt"))
			if string(before) != string(after) || len(f.requests()) != 0 {
				t.Fatal("credentials changed or a request was sent")
			}
			mustNotExist(t, lockFile(e, "chatgpt"))
		})
	}
}

func TestInvalidGrantAfterAcceptedSessionIsRejectedNotExpired(t *testing.T) {
	// The server may answer with the OAuth error in a 200-less body of any status.
	f := newFake(t, textAnswer("never")).authScript(jsonAnswer(401, map[string]any{"error": "invalid_grant"}))
	e := newEnv(t, f)
	e.saveCreds("chatgpt", e.chatgptCreds("expires_at", int64(0)))
	_, err := e.respond(Request{})
	if mustErr(t, err).Detail != "the ChatGPT sign-in was rejected; run kogen provider login chatgpt" {
		t.Fatal(err)
	}
}

// features/08-chatgpt: two commands that start at once with an expired access token
// refresh it once (GPT-3 lock, re-read under the lock).
func TestConcurrentProactiveRefreshHappensOnceUnderTheLock(t *testing.T) {
	for _, name := range []string{"chatgpt", "supergrok"} {
		t.Run(name, func(t *testing.T) {
			var mu sync.Mutex
			refreshes := 0
			slow := func(w http.ResponseWriter, r *http.Request) {
				mu.Lock()
				refreshes++
				mu.Unlock()
				time.Sleep(200 * time.Millisecond)
				tokenAnswer("rotated-access", "rotated-refresh", 3600)(w, r)
			}
			f := newFake(t, textAnswer("a"), textAnswer("b"))
			f.authAll = slow
			e := newEnv(t, f).realClock()
			role := fixtureRole
			if name == "supergrok" {
				e.saveCreds(name, e.supergrokCreds("expires_at", int64(0)))
				role = grokRole
			} else {
				e.saveCreds(name, e.chatgptCreds("expires_at", int64(0)))
			}
			var wg sync.WaitGroup
			errs := make([]error, 2)
			for i := range errs {
				wg.Add(1)
				go func() {
					defer wg.Done()
					c := &Client{Version: e.c.Version, ResponseBudget: 20 * time.Second} // two Kogens: separate clients, one home
					_, errs[i] = c.Respond(context.Background(), e.s, Request{Role: role, Instructions: "p"}, nil)
				}()
			}
			wg.Wait()
			for _, err := range errs {
				if err != nil {
					t.Fatal(err)
				}
			}
			if refreshes != 1 {
				t.Fatalf("%d refresh requests, want 1", refreshes)
			}
			for _, r := range f.requests() {
				if bearer(r) != "Bearer rotated-access" {
					t.Fatalf("a request used %q", bearer(r))
				}
			}
			if e.readCreds(name)["refresh_token"] != "rotated-refresh" {
				t.Fatal("rotation not saved")
			}
			mustNotExist(t, lockFile(e, name))
		})
	}
}

func TestRefreshWaitsForAHeldLockAndUsesTheNewerToken(t *testing.T) {
	f := newFake(t, textAnswer("ok"))
	e := newEnv(t, f).realClock()
	e.saveCreds("chatgpt", e.chatgptCreds("expires_at", int64(0)))
	p, _ := Lookup("chatgpt")
	held, err := Locker{}.Acquire(lockPath(e.home, p))
	if err != nil {
		t.Fatal(err)
	}
	go func() {
		time.Sleep(250 * time.Millisecond)
		e.saveCreds("chatgpt", e.chatgptCreds("access_token", "other-process-access", "expires_at", time.Now().Unix()+3600))
		held.Release()
	}()
	e.c.ResponseBudget = 10 * time.Second
	if _, err := e.respond(Request{}); err != nil {
		t.Fatal(err)
	}
	if len(f.authRequests()) != 0 || bearer(f.requests()[0]) != "Bearer other-process-access" {
		t.Fatalf("%d refreshes, bearer %q", len(f.authRequests()), bearer(f.requests()[0]))
	}
}

func TestStaleLockOfADeadProcessDoesNotBlockRefresh(t *testing.T) {
	f := newFake(t, textAnswer("ok")).authScript(tokenAnswer("rotated-access", "rotated-refresh", 3600))
	e := newEnv(t, f)
	e.saveCreds("chatgpt", e.chatgptCreds("expires_at", int64(0)))
	os.WriteFile(lockFile(e, "chatgpt"), []byte("2147483647\n"), 0o644)
	if _, err := e.respond(Request{}); err != nil || len(f.authRequests()) != 1 {
		t.Fatalf("%v, %d refreshes", err, len(f.authRequests()))
	}
	mustNotExist(t, lockFile(e, "chatgpt"))
}

func TestAfter401AnotherProcessAlreadyRefreshed(t *testing.T) {
	f := newFake(t, nil, textAnswer("ok"))
	e := newEnv(t, f)
	e.saveCreds("chatgpt", e.chatgptCreds())
	f.provSeq[0] = func(w http.ResponseWriter, r *http.Request) {
		e.saveCreds("chatgpt", e.chatgptCreds("access_token", "newer-access"))
		unauthorized()(w, r)
	}
	if _, err := e.respond(Request{}); err != nil {
		t.Fatal(err)
	}
	if len(f.authRequests()) != 0 || bearer(f.requests()[1]) != "Bearer newer-access" {
		t.Fatalf("%d refreshes, %q", len(f.authRequests()), bearer(f.requests()[1]))
	}
}

// supergrok_test: refresh rotates privately, re-reads newer credentials under the lock and
// defaults expiry.
func TestSuperGrokRefreshRotatesPrivately(t *testing.T) {
	f := newFake(t).authScript(jsonAnswer(200, map[string]any{"access_token": "new-access", "refresh_token": "new-refresh"}))
	e := newEnv(t, f)
	e.saveCreds("supergrok", e.supergrokCreds("expires_at", int64(0)))
	info, _ := Lookup("supergrok")
	k := e.c.newCall(context.Background(), e.s, info, 3*time.Second)
	defer k.cancel()
	got, err := k.accessToken()
	if err != nil || got != "new-access" {
		t.Fatalf("%q %v", got, err)
	}
	saved := e.readCreds("supergrok")
	if saved["refresh_token"] != "new-refresh" || saved["expires_at"] != e.clk.Now().Unix()+3600 {
		t.Fatalf("saved = %v", saved)
	}
	again, err := k.refreshed("synthetic-access", refreshAfter401)
	if err != nil || again != "new-access" {
		t.Fatalf("%q %v", again, err)
	}
	auth := f.authRequests()
	if len(auth) != 1 {
		t.Fatalf("%d auth requests", len(auth))
	}
	want := map[string][]string{"grant_type": {"refresh_token"}, "refresh_token": {"synthetic-refresh"}, "client_id": {"synthetic-client"}}
	if !reflect.DeepEqual(map[string][]string(auth[0].Form), want) || auth[0].Path != "/oauth2/token" {
		t.Fatalf("form = %v", auth[0].Form)
	}
	if auth[0].Header.Get("User-Agent") != "kogen/dev+12345678" {
		t.Fatalf("user agent = %q", auth[0].Header.Get("User-Agent"))
	}
	if st, _ := os.Stat(e.credPath("supergrok")); st.Mode().Perm() != 0o600 {
		t.Fatal("mode")
	}
	mustNotExist(t, lockFile(e, "supergrok"))
	if saved["referrer"] != "kogen" || saved["scope"] != "api:access" {
		t.Fatal("other fields lost")
	}
}

// supergrok_test: refresh failure retains earlier bytes.
func TestSuperGrokRefreshFailureRetainsEarlierBytes(t *testing.T) {
	cases := []struct {
		reason refreshReason
		name   string
		code   string
		detail string
	}{
		{refreshProactive, "proactive", "temporarily_unavailable", "the SuperGrok sign-in expired and could not be refreshed"},
		{refreshProactive, "proactive", "invalid_grant", "the SuperGrok sign-in was rejected"},
		{refreshAfter401, "after_401", "temporarily_unavailable", "the SuperGrok sign-in was rejected"},
	}
	for _, tc := range cases {
		t.Run(tc.name+"/"+tc.code, func(t *testing.T) {
			f := newFake(t).authScript(jsonAnswer(400, map[string]any{"error": tc.code}))
			e := newEnv(t, f)
			e.saveCreds("supergrok", e.supergrokCreds("expires_at", int64(0)))
			before, _ := os.ReadFile(e.credPath("supergrok"))
			info, _ := Lookup("supergrok")
			k := e.c.newCall(context.Background(), e.s, info, 3*time.Second)
			defer k.cancel()
			_, err := k.refreshed("synthetic-access", tc.reason)
			if se := mustErr(t, err); se.Detail != tc.detail+"; run kogen provider login supergrok" || se.Reason != "login" || se.Exit != 4 {
				t.Fatalf("err = %v", err)
			}
			after, _ := os.ReadFile(e.credPath("supergrok"))
			if string(before) != string(after) {
				t.Fatal("bytes changed")
			}
			mustNotExist(t, lockFile(e, "supergrok"))
		})
	}
}

// supergrok_test: SuperGrok workers refresh once after 401 and preserve routed attempt identity.
func TestSuperGrokWorkersRefreshOnceAfter401(t *testing.T) {
	f := newFake(t, jsonAnswer(401, map[string]any{"error": map[string]any{"code": "unauthorized"}}), textAnswer("completed")).
		authScript(jsonAnswer(200, map[string]any{"access_token": "new-access", "expires_in": int64(60)}))
	e := newEnv(t, f)
	e.saveCreds("supergrok", e.supergrokCreds())
	obs := &observer{}
	resp, err := e.c.Respond(context.Background(), e.s, Request{Role: grokRole, Instructions: "policy", Single: true}, obs)
	if err != nil || len(resp.Items) == 0 {
		t.Fatal(err)
	}
	reqs := f.requests()
	if len(reqs) != 2 || len(f.authRequests()) != 1 {
		t.Fatalf("%d requests, %d refreshes", len(reqs), len(f.authRequests()))
	}
	// A short-lived grant still gets exactly one retry with the refreshed token.
	if bearer(reqs[1]) != "Bearer new-access" {
		t.Fatalf("retry bearer = %q", bearer(reqs[1]))
	}
	recs := obs.records()
	if recs[len(recs)-1]["provider"] != "supergrok" || recs[len(recs)-1]["cache"].(map[string]any)["status"] != "applied" {
		t.Fatalf("record = %v", recs)
	}
	if e.readCreds("supergrok")["refresh_token"] != "synthetic-refresh" {
		t.Fatal("an omitted rotation must keep the old refresh token")
	}
}

func TestSuperGrokSecond401IsRejected(t *testing.T) {
	f := newFake(t, unauthorized(), unauthorized()).authScript(tokenAnswer("new-access", "", 3600))
	e := newEnv(t, f)
	e.saveCreds("supergrok", e.supergrokCreds())
	_, err := e.respond(Request{Role: grokRole})
	se := mustErr(t, err)
	if se.Detail != "the SuperGrok sign-in was rejected; run kogen provider login supergrok" || se.ProviderFailure["http_status"] != int64(401) || len(f.authRequests()) != 1 {
		t.Fatalf("err = %v", se)
	}
	if strings.Contains(se.Render(), "synthetic-access") {
		t.Fatal("token in output")
	}
}
