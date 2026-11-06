module kogen

go 1.27.2

require (
	github.com/KogenAI/kogen-build v0.0.0-20261106130303-88b77ba3dbf3
	github.com/KogenAI/kogen-coordinator v0.0.0-20261106121202-e91a9e0ac65b
	github.com/KogenAI/kogen-executor v0.0.0-20261106121702-55b372c4dd31
	github.com/KogenAI/kogen-loop v0.0.0
	github.com/KogenAI/kogen-review v0.0.0-20261106124750-cdcbbe3e357a
	github.com/KogenAI/kogen-setup v0.0.0-20261106122420-c0afc56136fe
	github.com/KogenAI/kogen-shaping v0.0.0-20261106124640-0484edf817f6
	github.com/KogenAI/kogen-verification v0.0.0-20261106121212-e1ff81b79447
)

require golang.org/x/text v0.43.0 // indirect

replace github.com/KogenAI/kogen-loop => ./third_party/kogen-loop
