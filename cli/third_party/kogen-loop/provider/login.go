package provider

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"net/url"
	"strings"
	"time"

	"kogen-loop/sys"
)

// RedirectFunc delivers the browser's redirect for a ChatGPT sign-in: it shows or opens
// authURL, waits on the http://127.0.0.1:1455/auth/callback listener or a pasted redirect
// URL, and returns the redirect's query. Login calls it again after ignoring a redirect
// with the wrong state, and gives up waiting after 300 seconds or an interrupt (the
// function may then still be blocked; the process is about to exit).
type RedirectFunc func(authURL string) (url.Values, error)

// RedirectWait is how long a ChatGPT sign-in waits for the redirect.
const RedirectWait = 300 * time.Second

// Login signs in to the named provider (`kogen provider login <name>`): ChatGPT with the
// browser PKCE flow (redirect supplies the redirect), SuperGrok with the device flow
// (redirect is unused), OpenCode Go and Anthropic by saving the key read from Client.Input
// (stdin by default; redirect is unused). Output lines go to s.Stdout; failures are
// *sys.Error provider/login_failed (provider/login for Anthropic), exit 4.
func (c *Client) Login(ctx context.Context, s *sys.Session, name string, redirect RedirectFunc) error {
	info, ok := Lookup(name)
	if name == ClaudeCodeName {
		info, ok = claudeCodeInfo, true
	}
	if !ok || name == "" {
		return sys.Fail("provider", "login_failed", "unknown provider "+name, 4)
	}
	if err := CheckSeams(s); err != nil {
		return err
	}
	k := c.newCall(ctx, s, info, 0)
	defer k.cancel()
	if info.key {
		in := StdinInput()
		if c.Input != nil {
			in = *c.Input
		}
		if info.Name == ClaudeCodeName {
			return k.loginToken(in)
		}
		return k.loginKey(in)
	}
	if info.supergrok() {
		return k.loginSuperGrok()
	}
	return k.loginChatGPT(redirect)
}

func loginFailed(detail string) error { return providerFail("login_failed", detail) }

func b64url(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }

func randomB64(n int) string {
	b := make([]byte, n)
	rand.Read(b)
	return b64url(b)
}

// last is Elixir's URI.decode_query lookup: the last value of a repeated key.
func last(q url.Values, key string) (string, bool) {
	v, ok := q[key]
	if !ok || len(v) == 0 {
		return "", false
	}
	return v[len(v)-1], true
}

// jwtClaims is the payload object of a JWT, or {} when it cannot be read.
func jwtClaims(jwt any) map[string]any {
	s, ok := jwt.(string)
	if !ok {
		return map[string]any{}
	}
	parts := strings.Split(s, ".")
	if len(parts) < 2 {
		return map[string]any{}
	}
	raw, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return map[string]any{}
	}
	v, err := decodeJSON(raw)
	if m, ok := asMap(v); err == nil && ok {
		return m
	}
	return map[string]any{}
}

func (k *call) loginChatGPT(redirect RedirectFunc) error {
	previous := readCredentials(k.home, k.info)
	verifier := randomB64(32)
	state := randomB64(16)
	nonce := randomB64(16)
	challenge := sha256.Sum256([]byte(verifier))

	registration := url.Values{}
	if id, _ := previous["client_id"].(string); strings.HasPrefix(id, "oaiapp_") {
		registration.Set("client_id", id)
	} else {
		host, err := hostID(k.home)
		if err != nil {
			return err
		}
		registration.Set("client_id", "dynamic_agent_client")
		registration.Set("agent_name_hint", "Kogen")
		registration.Set("ext_agent_host_id", host)
	}
	params := url.Values{}
	for key, v := range registration {
		params[key] = v
	}
	for key, v := range map[string]string{
		"response_type": "code", "redirect_uri": chatgptRedirect, "scope": chatgptScope,
		"resource": chatgptResource, "state": state, "nonce": nonce,
		"code_challenge_method": "S256", "code_challenge": b64url(challenge[:]),
	} {
		params.Set(key, v)
	}
	authURL := k.authBase() + "/api/accounts/authorize?" + params.Encode()
	k.s.Puts("Continue with ChatGPT")
	k.s.Puts(authURL)

	query, err := k.awaitRedirect(redirect, authURL, state)
	if err != nil {
		return err
	}
	if e, ok := last(query, "error"); ok {
		detail := e
		if d, ok := last(query, "error_description"); ok {
			detail += ": " + d
		}
		return loginFailed(detail)
	}
	clientID := registration.Get("client_id")
	if id, ok := last(query, "client_id"); ok {
		clientID = id
	}
	if !strings.HasPrefix(clientID, "oaiapp_") {
		return loginFailed("the sign-in did not register Kogen (no issued client ID)")
	}
	code, _ := last(query, "code")
	status, tok, err := k.postForm(k.authBase()+"/api/accounts/oauth/token", url.Values{
		"grant_type": {"authorization_code"}, "client_id": {clientID}, "code": {code},
		"code_verifier": {verifier}, "redirect_uri": {chatgptRedirect}, "resource": {chatgptResource},
	}, "", time.Time{})
	if err != nil {
		return err
	}
	if status != 200 {
		return loginFailed("the token exchange failed (" + itoa(int64(status)) + " " + text(tok["error"]) + ")")
	}
	granted := false
	for _, sc := range strings.Fields(text(tok["scope"])) {
		if sc == "chatgpt.tokens.use.direct" {
			granted = true
		}
	}
	if !granted {
		return providerFail("login_failed", "ChatGPT plan usage was not granted; sign in again and allow it")
	}
	claims := jwtClaims(tok["id_token"])
	if claims["nonce"] != nonce {
		return loginFailed("the sign-in answer does not match this login")
	}
	email := claims["email"]
	_, err = k.withLock(func() (string, error) {
		return "", writeCredentials(k.home, k.info, credentials{
			"client_id":     clientID,
			"access_token":  tok["access_token"],
			"refresh_token": tok["refresh_token"],
			"expires_at":    k.unix() + expiresIn(tok["expires_in"]),
			"scope":         tok["scope"],
			"email":         email,
		})
	})
	if err != nil {
		return err
	}
	k.s.Puts("chatgpt signed in" + emailSuffix(email))
	return nil
}

// awaitRedirect waits up to 300 s for a redirect that carries this login's state.
func (k *call) awaitRedirect(redirect RedirectFunc, authURL, state string) (url.Values, error) {
	deadline := k.c.now().Add(RedirectWait)
	for {
		remaining := deadline.Sub(k.c.now())
		if remaining <= 0 {
			return nil, loginFailed("no sign-in arrived within 300 seconds")
		}
		type answer struct {
			q   url.Values
			err error
		}
		got := make(chan answer, 1)
		go func() {
			q, err := redirect(authURL)
			got <- answer{q, err}
		}()
		timeout := make(chan struct{}, 1)
		tctx, stop := context.WithCancel(k.ctx)
		go func() {
			if k.c.sleep(tctx, remaining) == nil {
				timeout <- struct{}{}
			}
		}()
		var a answer
		select {
		case a = <-got:
			stop()
		case <-timeout:
			stop()
			return nil, loginFailed("no sign-in arrived within 300 seconds")
		case <-k.ctx.Done():
			stop()
			if err := k.interrupted(); err != nil {
				return nil, err
			}
			return nil, k.ctx.Err()
		}
		if a.err != nil {
			if _, ok := sys.AsError(a.err); ok {
				return nil, a.err
			}
			if _, ok := a.err.(*sys.Interrupted); ok {
				return nil, a.err
			}
			return nil, loginFailed(a.err.Error())
		}
		if got, _ := last(a.q, "state"); got == state {
			return a.q, nil
		}
		k.s.Progress("kogen: ignored a sign-in redirect with the wrong state")
	}
}

// ---- SuperGrok device authorization (RFC 8628) ----

func httpsURL(v any) bool {
	s, ok := v.(string)
	if !ok {
		return false
	}
	u, err := url.Parse(s)
	return err == nil && u.Scheme == "https" && u.Hostname() != ""
}

func answerText(status int, body map[string]any) string {
	s := itoa(int64(status))
	if nonempty(body["error"]) {
		s += " " + text(body["error"])
	}
	return s
}

func (k *call) loginSuperGrok() error {
	ua := k.c.userAgent()
	status, device, err := k.postForm(k.authBase()+"/oauth2/device/code", url.Values{
		"client_id": {supergrokClient}, "scope": {supergrokScope}, "referrer": {"kogen"},
	}, ua, time.Time{})
	if err != nil {
		return err
	}
	received := k.c.now()
	if status != 200 {
		return loginFailed("the SuperGrok device authorization request failed (" + answerText(status, device) + ")")
	}
	expires, ok := asInt(device["expires_in"])
	if !nonempty(device["device_code"]) || !nonempty(device["user_code"]) || !nonempty(device["verification_uri"]) || !ok || expires <= 0 {
		return loginFailed("the SuperGrok device authorization response is incomplete")
	}
	_, hasComplete := device["verification_uri_complete"]
	if !httpsURL(device["verification_uri"]) || (hasComplete && !httpsURL(device["verification_uri_complete"])) {
		return loginFailed("the SuperGrok verification address is not HTTPS")
	}
	where := text(device["verification_uri"])
	if hasComplete {
		where = text(device["verification_uri_complete"])
	}
	k.s.Puts("Continue with SuperGrok")
	k.s.Puts(where)
	k.s.Puts("Code: " + text(device["user_code"]))
	interval := 5 * time.Second
	switch n := device["interval"].(type) {
	case int64:
		interval = time.Duration(n) * time.Second
	case float64:
		interval = time.Duration(n * float64(time.Second))
	}
	if interval < time.Second {
		interval = time.Second
	}
	tok, err := k.pollDevice(text(device["device_code"]), interval, received.Add(time.Duration(expires)*time.Second))
	if err != nil {
		return err
	}
	if !nonempty(tok["access_token"]) || !nonempty(tok["refresh_token"]) {
		return loginFailed("the SuperGrok sign-in returned no usable tokens")
	}
	scope := supergrokScope
	if sc, ok := tok["scope"].(string); ok {
		scope = sc
	}
	granted := false
	for _, sc := range strings.Fields(scope) {
		if sc == "api:access" {
			granted = true
		}
	}
	if !granted {
		return loginFailed("SuperGrok API access was not granted; sign in again and allow it")
	}
	creds := credentials{
		"client_id": supergrokClient, "referrer": "kogen",
		"access_token": tok["access_token"], "refresh_token": tok["refresh_token"],
		"expires_at": k.unix() + expiresIn(tok["expires_in"]), "scope": scope,
	}
	email, hasEmail := jwtClaims(tok["id_token"])["email"].(string)
	if hasEmail {
		creds["email"] = email
	}
	if _, err := k.withLock(func() (string, error) { return "", writeCredentials(k.home, k.info, creds) }); err != nil {
		return err
	}
	k.s.Puts("supergrok signed in" + emailSuffix(email))
	return nil
}

// pollDevice asks for the token at the server's pace until the device code's lifetime ends.
func (k *call) pollDevice(code string, interval time.Duration, deadline time.Time) (map[string]any, error) {
	expired := loginFailed("the SuperGrok sign-in code expired")
	for {
		wait := deadline.Sub(k.c.now())
		if wait < 0 {
			wait = 0
		}
		if interval < wait {
			wait = interval
		}
		if err := k.c.sleep(k.ctx, wait); err != nil {
			if ie := k.interrupted(); ie != nil {
				return nil, ie
			}
			return nil, err
		}
		if err := k.interrupted(); err != nil {
			return nil, err
		}
		if !k.c.now().Before(deadline) {
			return nil, expired
		}
		status, tok, err := k.postForm(k.authBase()+"/oauth2/token", url.Values{
			"grant_type": {"urn:ietf:params:oauth:grant-type:device_code"}, "device_code": {code}, "client_id": {supergrokClient},
		}, k.c.userAgent(), deadline)
		if err == errLimit {
			return nil, expired
		}
		if err != nil {
			return nil, err
		}
		if !k.c.now().Before(deadline) {
			return nil, expired
		}
		switch e := tok["error"]; {
		case status == 200:
			return tok, nil
		case e == "authorization_pending":
		case e == "slow_down":
			interval += 5 * time.Second
		case e == "access_denied" || e == "authorization_denied":
			return nil, loginFailed("the SuperGrok sign-in was denied")
		case e == "expired_token":
			return nil, expired
		default:
			return nil, loginFailed("the SuperGrok token request failed (" + answerText(status, tok) + ")")
		}
	}
}
