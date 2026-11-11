module kogen

go 1.27.2

require (
	github.com/KogenAI/kogen-build v0.0.0-20261111130048-2a63f757b7d2
	github.com/KogenAI/kogen-coordinator v0.0.0-20261111125053-92152f164993
	github.com/KogenAI/kogen-executor v0.0.0-20261111115604-e41db3d2d2e4
	github.com/KogenAI/kogen-loop v0.0.0
	github.com/KogenAI/kogen-review v0.0.0-20261111124707-1ee8facf41b0
	github.com/KogenAI/kogen-setup v0.0.0-20261110123838-e31ed73a8071
	github.com/KogenAI/kogen-shaping v0.0.0-20261111162753-6c5d49a10563
	github.com/KogenAI/kogen-verification v0.0.0-20261111184504-15d972aab13c
)

require golang.org/x/text v0.43.0 // indirect

replace github.com/KogenAI/kogen-loop => ./third_party/kogen-loop
