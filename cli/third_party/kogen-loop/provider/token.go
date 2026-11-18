package provider

import (
	"net/url"
	"strconv"
	"time"

	"github.com/KogenAI/kogen-loop/sys"
)

const (
	chatgptScope    = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct"
	chatgptResource = "https://api.openai.com/v1"
	chatgptRedirect = "http://127.0.0.1:1455/auth/callback"

	supergrokClient = "b1a00492-073a-47ea-816f-4c329264a828"
	supergrokScope  = "openid profile email offline_access grok-cli:access api:access"
)

type refreshReason int

const (
	refreshProactive refreshReason = iota
	refreshAfter401
)

func (k *call) unix() int64 { return k.c.now().Unix() }

// accessToken is the access token to use now, refreshed first when it expires within 60
// seconds (GPT-6).
func (k *call) accessToken() (string, error) {
	if err := k.check(); err != nil {
		return "", err
	}
	if k.info.key {
		// An API key does not expire or refresh. An optional key may be absent: "" sends no
		// Authorization header. A compatible key is bound to the origin it was saved for.
		if k.info.external() {
			return k.compatibleToken()
		}
		return storedKey(k.home, k.info)
	}
	c, err := storedCredentials(k.home, k.info)
	if err != nil {
		return "", err
	}
	if c.hasMode() {
		return k.managedToken(c)
	}
	if c.expiresAt()-60 <= k.unix() {
		return k.refreshed(text(c["access_token"]), refreshProactive)
	}
	return text(c["access_token"]), nil
}

// managedToken is the access token of a valid managed access snapshot. It only reads: no
// lock, no token endpoint, no write. An expired or regressed snapshot stops the call until
// the external owner publishes a newer one.
func (k *call) managedToken(c credentials) (string, error) {
	k.managed = true
	exp := c.expiresAt()
	if !c.managedFresh(k.unix()) {
		return "", managedStop("expired")
	}
	if !k.c.acceptManaged(credentialsPath(k.home, k.info), exp) {
		return "", managedStop("regressed")
	}
	return text(c["access_token"]), nil
}

// managedStop is the refusal of a managed access snapshot that cannot serve a request.
func managedStop(what string) *sys.Error {
	return providerFail("login", "managed access snapshot "+what+"; owner refresh required")
}

// refreshed refreshes under the exclusive credentials lock; another Kogen may already have
// rotated the token, in which case its newer one is used.
func (k *call) refreshed(stale string, reason refreshReason) (string, error) {
	return k.withLock(func() (string, error) {
		c, err := storedCredentials(k.home, k.info)
		if err != nil {
			return "", err
		}
		if text(c["access_token"]) != stale && c.expiresAt()-60 > k.unix() {
			return text(c["access_token"]), nil
		}
		return k.refresh(c, reason)
	})
}

func (k *call) refresh(c credentials, reason refreshReason) (string, error) {
	sg := k.info.supergrok()
	form := url.Values{"grant_type": {"refresh_token"}, "client_id": {text(c["client_id"])}, "refresh_token": {text(c["refresh_token"])}}
	ua := ""
	if sg {
		ua = k.c.userAgent()
	} else {
		form.Set("resource", chatgptResource)
	}
	status, tok, err := k.postForm(k.authBase()+k.tokenPath(), form, ua, time.Time{})
	if err != nil {
		return "", err
	}
	if status == 200 && nonempty(tok["access_token"]) {
		next := make(credentials, len(c))
		for key, v := range c {
			next[key] = v
		}
		next["access_token"] = tok["access_token"]
		if rt, ok := tok["refresh_token"].(string); ok {
			next["refresh_token"] = rt
		}
		next["expires_at"] = k.unix() + expiresIn(tok["expires_in"])
		if err := writeCredentials(k.home, k.info, next); err != nil {
			return "", err
		}
		return text(tok["access_token"]), nil
	}
	if tok["error"] == "invalid_grant" || reason == refreshAfter401 {
		return "", k.rejected(nil)
	}
	return "", providerFail("login", "the "+k.info.Label+" sign-in expired and could not be refreshed; "+loginHint(k.info))
}

func (k *call) tokenPath() string {
	if k.info.supergrok() {
		return "/oauth2/token"
	}
	return "/api/accounts/oauth/token"
}

// expiresIn is the lifetime in seconds of a token answer: the integer given, else an hour.
func expiresIn(v any) int64 {
	switch n := v.(type) {
	case int64:
		return n
	case float64:
		return int64(n)
	}
	return 3600
}

// rejected is the refusal when the sign-in no longer works; diag are the provider
// diagnostics of the failure that led here.
func (k *call) rejected(diag map[string]any) error {
	if k.managed {
		return withDiagnostics(managedStop("was rejected"), diag)
	}
	e := providerFail("login", "the "+k.info.Label+" sign-in was rejected; "+loginHint(k.info))
	return withDiagnostics(e, diag)
}

func itoa(n int64) string { return strconv.FormatInt(n, 10) }
