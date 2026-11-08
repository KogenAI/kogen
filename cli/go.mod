module kogen

go 1.27.2

require (
	github.com/KogenAI/kogen-build v0.0.0-20261108054949-323fb18f8674
	github.com/KogenAI/kogen-coordinator v0.0.0-20261107115359-b1f2988eb753
	github.com/KogenAI/kogen-executor v0.0.0-20261108021340-12bb6262e745
	github.com/KogenAI/kogen-loop v0.0.0
	github.com/KogenAI/kogen-review v0.0.0-20261106124750-cdcbbe3e357a
	github.com/KogenAI/kogen-setup v0.0.0-20261107142057-7efd6111eab5
	github.com/KogenAI/kogen-shaping v0.0.0-20261108042036-b0f37f303b41
	github.com/KogenAI/kogen-verification v0.0.0-20261107141518-8ab533354ae9
)

require golang.org/x/text v0.43.0 // indirect

replace github.com/KogenAI/kogen-loop => ./third_party/kogen-loop
