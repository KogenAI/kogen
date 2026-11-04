module kogen

go 1.27.2

require (
	github.com/KogenAI/kogen-build v0.0.0-20261103154529-b9990a3d0903
	github.com/KogenAI/kogen-coordinator v0.0.0-20261103214825-03d7341feab7
	github.com/KogenAI/kogen-executor v0.0.0-20261104021843-9021591798ac
	github.com/KogenAI/kogen-review v0.0.0-20261103161351-e5005fa1daf8
	github.com/KogenAI/kogen-setup v0.0.0-20261103140900-9316891471b5
	github.com/KogenAI/kogen-shaping v0.0.0-20261103154530-f04edcea9896
	github.com/KogenAI/kogen-verification v0.0.0-20261103201747-3cb7305a5690
	kogen-loop v0.0.0
)

replace kogen-loop => ./third_party/kogen-loop
