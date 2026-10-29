package provider

import (
	"net"
	"net/url"
	"strconv"
	"strings"
)

// originOf is the origin of an http(s) URL: lower-case scheme and hostname, plus the port
// unless it is the scheme's default. Path, query, fragment and any user info are dropped,
// so an origin never carries a secret. The scheme and the effective port stay part of it.
func originOf(raw string) (string, error) {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil {
		return "", providerFail("refused", "base_url is not a valid URL")
	}
	scheme := strings.ToLower(u.Scheme)
	host := strings.ToLower(u.Hostname())
	if (scheme != "https" && scheme != "http") || host == "" {
		return "", providerFail("refused", "base_url must be an http(s) URL with a host")
	}
	if strings.Contains(host, ":") {
		host = "[" + host + "]"
	}
	port := u.Port()
	if port != "" {
		n, err := strconv.ParseUint(port, 10, 16)
		if err != nil {
			return "", providerFail("refused", "base_url has an invalid port")
		}
		port = strconv.FormatUint(n, 10)
	}
	if port == "" || (scheme == "https" && port == "443") || (scheme == "http" && port == "80") {
		return scheme + "://" + host, nil
	}
	return scheme + "://" + net.JoinHostPort(strings.Trim(host, "[]"), port), nil
}

// plaintextLoopback reports whether an origin is plain HTTP to localhost or a literal
// loopback IP. Names are never resolved to decide.
func plaintextLoopback(origin string) bool {
	u, err := url.Parse(origin)
	if err != nil || u.Scheme != "http" {
		return false
	}
	host := u.Hostname()
	if host == "localhost" {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

// compatibleToken is the key to send to an openai-compatible host, "" for a keyless host.
// The saved key belongs to the origin it was logged in at: a different destination, a
// plaintext destination or a legacy key without an origin sends nothing. Diagnostics name
// origins only.
func (k *call) compatibleToken() (string, error) {
	dest, err := originOf(k.baseURL)
	if err != nil {
		return "", err
	}
	c := readCredentials(k.home, k.info)
	if c == nil {
		if strings.HasPrefix(dest, "http://") && !plaintextLoopback(dest) {
			return "", providerFail("refused", "plaintext HTTP to "+dest+" is refused: HTTP is allowed only for localhost or a loopback IP address; use HTTPS")
		}
		return "", nil
	}
	key, ok := c.apiKey(k.info)
	if !ok {
		return "", providerFail("login", "no usable "+k.info.Label+" key; "+loginHint(k.info))
	}
	saved, _ := c["origin"].(string)
	if saved != "" {
		norm, err := originOf(saved)
		if err != nil {
			return "", providerFail("login", "the saved "+k.info.Label+" origin is invalid; log in again with an HTTPS base URL")
		}
		saved = norm
	}
	if saved == "" {
		return "", providerFail("login", "the saved "+k.info.Label+" key is not bound to an origin; log in again with the base URL it is for ("+loginHint(k.info)+")")
	}
	if !strings.HasPrefix(saved, "https://") {
		return "", providerFail("login", "the saved "+k.info.Label+" key is bound to "+saved+", which is not HTTPS; log in again with an HTTPS base URL")
	}
	if dest != saved {
		return "", providerFail("refused", "the saved "+k.info.Label+" key belongs to "+saved+" but this request goes to "+dest+"; no key was sent. Log in again for that origin or use the saved one")
	}
	return key, nil
}
