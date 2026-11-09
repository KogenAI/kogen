module kogen

go 1.27.2

require (
	github.com/KogenAI/kogen-build v0.0.0-20261108092723-ef44947c3da8
	github.com/KogenAI/kogen-coordinator v0.0.0-20261107115359-b1f2988eb753
	github.com/KogenAI/kogen-executor v0.0.0-20261108021340-12bb6262e745
	github.com/KogenAI/kogen-loop v0.0.0
	github.com/KogenAI/kogen-review v0.0.0-20261108105409-1a55cd0ae6ca
	github.com/KogenAI/kogen-setup v0.0.0-20261108153100-12e60aeacf73
	github.com/KogenAI/kogen-shaping v0.0.0-20261109043102-da24854cbd9f
	github.com/KogenAI/kogen-verification v0.0.0-20261108105000-d6656152c5dd
)

require golang.org/x/text v0.43.0 // indirect

replace github.com/KogenAI/kogen-loop => ./third_party/kogen-loop
