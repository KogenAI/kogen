module kogen

go 1.27.2

require (
	github.com/KogenAI/kogen-build v0.0.0-20261112231933-8047f608ab74
	github.com/KogenAI/kogen-coordinator v0.0.0-20261112230013-e5af25b9bcf9
	github.com/KogenAI/kogen-executor v0.0.0-20261113000446-8024c0614b51
	github.com/KogenAI/kogen-loop v0.0.0
	github.com/KogenAI/kogen-review v0.0.0-20261112223424-214cc9e8bbbc
	github.com/KogenAI/kogen-setup v0.0.0-20261113005301-2349f50a5c15
	github.com/KogenAI/kogen-shaping v0.0.0-20261113000534-600f67c6587c
	github.com/KogenAI/kogen-verification v0.0.0-20261112220532-7f1b6ce64450
)

require golang.org/x/text v0.43.0 // indirect

replace github.com/KogenAI/kogen-loop => ./third_party/kogen-loop
