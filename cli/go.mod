module kogen

go 1.27.2

require (
	github.com/KogenAI/kogen-build v0.0.0-20261111123625-6250e3b66ae6
	github.com/KogenAI/kogen-coordinator v0.0.0-20261111122047-3a80bd41043f
	github.com/KogenAI/kogen-executor v0.0.0-20261111115604-e41db3d2d2e4
	github.com/KogenAI/kogen-loop v0.0.0
	github.com/KogenAI/kogen-review v0.0.0-20261111115833-3fecb984726a
	github.com/KogenAI/kogen-setup v0.0.0-20261110123838-e31ed73a8071
	github.com/KogenAI/kogen-shaping v0.0.0-20261111121242-f3ad527a2671
	github.com/KogenAI/kogen-verification v0.0.0-20261111114253-4a379220bdb1
)

require golang.org/x/text v0.43.0 // indirect

replace github.com/KogenAI/kogen-loop => ./third_party/kogen-loop
