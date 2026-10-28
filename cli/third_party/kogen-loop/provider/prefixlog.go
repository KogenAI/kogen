package provider

// PrefixEvent describes byte-level differences from the previous model attempt in a conversation.
type PrefixEvent struct {
	ConversationID string
	Role           Role
	Context        map[string]any
	PreviousBytes  *int
	CurrentBytes   int
	Offset         *int
	Status         string
}

func prefixCompare(previous, current []byte) (string, *int) {
	n := min(len(previous), len(current))
	for i := 0; i < n; i++ {
		if previous[i] != current[i] {
			return "diverged", &i
		}
	}
	if len(previous) != len(current) {
		return "diverged", &n
	}
	return "identical", nil
}

func (r *run) logPrefix() {
	c := r.k.c
	if c.PrefixLog == nil {
		return
	}
	id := wireID(r.state.ID)
	key := "id:" + id
	if r.req.CacheID == "" && r.req.Cache == nil && c.Cache == nil {
		id = "scope:" + conversationKey(r.req.Role, r.req.Scope)
		key = id
	}
	c.prefixMu.Lock()
	defer c.prefixMu.Unlock()
	e := PrefixEvent{ConversationID: id, Role: r.req.Role, CurrentBytes: len(r.encoded), Status: "first"}
	if r.req.Context != nil {
		e.Context = make(map[string]any, len(r.req.Context))
		for k, v := range r.req.Context {
			e.Context[k] = v
		}
	}
	if prev, ok := c.prefixBodies[key]; ok {
		n := len(prev)
		e.PreviousBytes = &n
		e.Status, e.Offset = prefixCompare(prev, r.encoded)
	}
	if c.prefixBodies == nil {
		c.prefixBodies = make(map[string][]byte)
	}
	body := make([]byte, len(r.encoded))
	copy(body, r.encoded)
	c.prefixBodies[key] = body
	c.PrefixLog(e)
}

// EndPrefixLog releases the previous body for req's conversation. Call at conversation end,
// including error or cancellation; it does not modify prompt-cache state.
func (c *Client) EndPrefixLog(req Request) {
	if c.PrefixLog == nil {
		return
	}
	id := req.CacheID
	if id == "" {
		cache := req.Cache
		if cache == nil {
			cache = c.Cache
		}
		if cache == nil {
			key := "scope:" + conversationKey(req.Role, req.Scope)
			c.prefixMu.Lock()
			delete(c.prefixBodies, key)
			c.prefixMu.Unlock()
			return
		}
		key := conversationKey(req.Role, req.Scope)
		cache.mu.Lock()
		st := cache.states[key]
		cache.mu.Unlock()
		id = st.ID
	}
	if id == "" {
		return
	}
	c.prefixMu.Lock()
	delete(c.prefixBodies, "id:"+wireID(id))
	c.prefixMu.Unlock()
}
