module kogen

go 1.27.2

require (
	github.com/KogenAI/kogen-build v0.0.0-20261105185407-165a027e8229
	github.com/KogenAI/kogen-coordinator v0.0.0-20261105163147-c8126f4156ba
	github.com/KogenAI/kogen-executor v0.0.0-20261105143305-dcf38d72a0c3
	github.com/KogenAI/kogen-loop v0.0.0
	github.com/KogenAI/kogen-review v0.0.0-20261105185714-66be20d31658
	github.com/KogenAI/kogen-setup v0.0.0-20261105091508-8958731c2ff5
	github.com/KogenAI/kogen-shaping v0.0.0-20261105181959-c3f9c5e099e7
	github.com/KogenAI/kogen-verification v0.0.0-20261105151659-f5babef00998
)

require golang.org/x/text v0.43.0 // indirect

replace github.com/KogenAI/kogen-loop => ./third_party/kogen-loop
