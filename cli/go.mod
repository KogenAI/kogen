module kogen

go 1.27.2

require (
	github.com/KogenAI/kogen-build v0.0.0-20261111130048-2a63f757b7d2
	github.com/KogenAI/kogen-coordinator v0.0.0-20261112070335-f61ab6badda0
	github.com/KogenAI/kogen-executor v0.0.0-20261112080441-bb5a6d249296
	github.com/KogenAI/kogen-loop v0.0.0
	github.com/KogenAI/kogen-review v0.0.0-20261112070232-e7f9de12cb9b
	github.com/KogenAI/kogen-setup v0.0.0-20261112083410-2aed318282ce
	github.com/KogenAI/kogen-shaping v0.0.0-20261112153856-3d5c9e2909a1
	github.com/KogenAI/kogen-verification v0.0.0-20261112083508-b8bbe50705d1
)

require golang.org/x/text v0.43.0 // indirect

replace github.com/KogenAI/kogen-loop => ./third_party/kogen-loop
