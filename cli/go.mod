module kogen

go 1.27.2

require (
	github.com/KogenAI/kogen-build v0.0.0-20261113234604-1ed3d0ed6cc8
	github.com/KogenAI/kogen-coordinator v0.0.0-20261113145033-09a169cc6730
	github.com/KogenAI/kogen-executor v0.0.0-20261113140126-0d2a0b86a6d1
	github.com/KogenAI/kogen-loop v0.0.0
	github.com/KogenAI/kogen-review v0.0.0-20261113154643-47c694035e56
	github.com/KogenAI/kogen-setup v0.0.0-20261113030035-7ffe554b3341
	github.com/KogenAI/kogen-shaping v0.0.0-20261113155410-86704c972790
	github.com/KogenAI/kogen-verification v0.0.0-20261113024304-b1572e671c95
)

require golang.org/x/text v0.43.0 // indirect

replace github.com/KogenAI/kogen-loop => ./third_party/kogen-loop
