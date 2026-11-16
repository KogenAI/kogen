module kogen

go 1.27.2

require (
	github.com/KogenAI/kogen-build v0.0.0-20261116120409-1f2da81eb52e
	github.com/KogenAI/kogen-coordinator v0.0.0-20261116091129-82a472da24c3
	github.com/KogenAI/kogen-executor v0.0.0-20261116083337-09ead0ed7404
	github.com/KogenAI/kogen-loop v0.0.0
	github.com/KogenAI/kogen-review v0.0.0-20261116111137-dafb2c21a9bd
	github.com/KogenAI/kogen-setup v0.0.0-20261116093014-c257d91e81b7
	github.com/KogenAI/kogen-shaping v0.0.0-20261116092506-8b1a7e91477f
	github.com/KogenAI/kogen-verification v0.0.0-20261116114754-2033fb4e8817
)

require golang.org/x/text v0.43.0 // indirect

replace github.com/KogenAI/kogen-loop => ./third_party/kogen-loop
