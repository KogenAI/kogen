module kogen

go 1.27.2

require (
	github.com/KogenAI/kogen-build v0.0.0-20261106191737-45d5823fa40c
	github.com/KogenAI/kogen-coordinator v0.0.0-20261106121202-e91a9e0ac65b
	github.com/KogenAI/kogen-executor v0.0.0-20261106121702-55b372c4dd31
	github.com/KogenAI/kogen-loop v0.0.0
	github.com/KogenAI/kogen-review v0.0.0-20261106124750-cdcbbe3e357a
	github.com/KogenAI/kogen-setup v0.0.0-20261106184805-43be668ea101
	github.com/KogenAI/kogen-shaping v0.0.0-20261107043208-7bcfc8d32b83
	github.com/KogenAI/kogen-verification v0.0.0-20261107034536-67617548616c
)

require golang.org/x/text v0.43.0 // indirect

replace github.com/KogenAI/kogen-loop => ./third_party/kogen-loop
