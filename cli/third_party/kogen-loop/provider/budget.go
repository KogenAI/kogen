package provider

import (
	"sync"
	"time"

	"github.com/KogenAI/kogen-loop/sys"
)

// RequestBudgetLimits are the limits of one stage's RequestBudget. The zero value of each
// field means no such limit.
type RequestBudgetLimits struct {
	// MaxRequests is the most inference attempts the stage may dispatch.
	MaxRequests int
	// Deadline is the instant after which no attempt is dispatched. It never extends the
	// deadline of the caller's context.
	Deadline time.Time
	// MaxInputBytes is the most bytes of one encoded request body (bytes, never tokens).
	MaxInputBytes int
	// MaxOutputTokens is a per-response ceiling, not an aggregate limit. Only the Messages
	// wire carries an output-token field; other wires refuse a request with this limit.
	MaxOutputTokens int
}

// RequestBudgetSnapshot is the state of a RequestBudget: numbers and a time only, no
// credentials and no provider data. The JSON names are fixed by the tags.
type RequestBudgetSnapshot struct {
	MaxRequests     int       `json:"max_requests"`
	Deadline        time.Time `json:"deadline"`
	MaxInputBytes   int       `json:"max_input_bytes"`
	MaxOutputTokens int       `json:"max_output_ceiling"`
	Reserved        int       `json:"reserved"`
}

// RequestBudget is a caller-owned bound shared by every inference attempt of one stage. Set
// Request.Budget (and loop.Direct.Budget) to the same pointer; a nil budget changes nothing.
// It is safe for concurrent use.
type RequestBudget struct {
	mu       sync.Mutex
	limits   RequestBudgetLimits
	reserved int
	persist  func(reserved int) error
}

func invalidBudget(detail string) *sys.Error {
	return sys.Fail("validation", "invalid_request_budget", detail, 2)
}

// NewRequestBudget validates the limits and returns a budget that already holds reserved
// attempts (restoring a prior count). persist, when not nil, is called with the new reserved
// count while the budget's lock is held, before each dispatch; its error refuses that request
// with provider/request_budget_persist_failed and the count stays reserved.
func NewRequestBudget(limits RequestBudgetLimits, reserved int, persist func(reserved int) error) (*RequestBudget, error) {
	switch {
	case limits.MaxRequests < 0:
		return nil, invalidBudget("MaxRequests must not be negative")
	case limits.MaxInputBytes < 0:
		return nil, invalidBudget("MaxInputBytes must not be negative")
	case limits.MaxInputBytes > InputBudgetBytes:
		return nil, invalidBudget("MaxInputBytes must not exceed " + itoa(InputBudgetBytes))
	case limits.MaxOutputTokens < 0:
		return nil, invalidBudget("MaxOutputTokens must not be negative")
	case limits.MaxOutputTokens > OutputReserveTokens:
		return nil, invalidBudget("MaxOutputTokens must not exceed " + itoa(OutputReserveTokens))
	case reserved < 0:
		return nil, invalidBudget("reserved must not be negative")
	case limits.MaxRequests > 0 && reserved > limits.MaxRequests:
		return nil, invalidBudget("reserved must not exceed MaxRequests")
	}
	return &RequestBudget{limits: limits, reserved: reserved, persist: persist}, nil
}

// Snapshot is the budget's limits and reserved count.
func (b *RequestBudget) Snapshot() RequestBudgetSnapshot {
	b.mu.Lock()
	defer b.mu.Unlock()
	return RequestBudgetSnapshot{
		MaxRequests: b.limits.MaxRequests, Deadline: b.limits.Deadline,
		MaxInputBytes: b.limits.MaxInputBytes, MaxOutputTokens: b.limits.MaxOutputTokens,
		Reserved: b.reserved,
	}
}

// outputCeiling is the per-response token ceiling, 0 for none.
func (b *RequestBudget) outputCeiling() int {
	if b == nil {
		return 0
	}
	return b.limits.MaxOutputTokens
}

// reserve takes one attempt for a request body of the given encoded size. The checks run in
// order — deadline, input bytes, count — and nothing is reserved when one fails. The
// reservation and its persistence are atomic under the lock; a persistence failure keeps the
// reservation.
func (b *RequestBudget) reserve(now time.Time, bodyBytes int) error {
	b.mu.Lock()
	defer b.mu.Unlock()
	if !b.limits.Deadline.IsZero() && !now.Before(b.limits.Deadline) {
		return providerFail("request_budget_deadline", "the stage request budget deadline has passed; nothing was sent")
	}
	if b.limits.MaxInputBytes > 0 && bodyBytes > b.limits.MaxInputBytes {
		return providerFail("request_budget_input_limit", "the encoded request body is "+itoa(int64(bodyBytes))+
			" bytes, above the stage request budget limit of "+itoa(int64(b.limits.MaxInputBytes))+" bytes; nothing was sent")
	}
	if b.limits.MaxRequests > 0 && b.reserved >= b.limits.MaxRequests {
		return providerFail("request_budget_exhausted", "the stage request budget of "+itoa(int64(b.limits.MaxRequests))+" requests is exhausted; nothing was sent")
	}
	b.reserved++
	if b.persist != nil {
		if err := b.persist(b.reserved); err != nil {
			return providerFail("request_budget_persist_failed", "the stage request budget count could not be persisted; nothing was sent")
		}
	}
	return nil
}
