module kogen

go 1.27.2

require (
	github.com/KogenAI/kogen-build v0.0.0-20261106191737-45d5823fa40c
	github.com/KogenAI/kogen-coordinator v0.0.0-20261107083354-7e4fcd1a50a8
	github.com/KogenAI/kogen-executor v0.0.0-20261108021340-12bb6262e745
	github.com/KogenAI/kogen-loop v0.0.0
	github.com/KogenAI/kogen-review v0.0.0-20261106124750-cdcbbe3e357a
	github.com/KogenAI/kogen-setup v0.0.0-20261106184805-43be668ea101
	github.com/KogenAI/kogen-shaping v0.0.0-20261107074600-cb9498a719ef
	github.com/KogenAI/kogen-verification v0.0.0-20261107101842-25884c52dde4
)

require golang.org/x/text v0.43.0 // indirect

replace github.com/KogenAI/kogen-loop => ./third_party/kogen-loop
