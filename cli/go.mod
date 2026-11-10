module kogen

go 1.27.2

require (
	github.com/KogenAI/kogen-build v0.0.0-20261110064925-0fb2834072be
	github.com/KogenAI/kogen-coordinator v0.0.0-20261107115359-b1f2988eb753
	github.com/KogenAI/kogen-executor v0.0.0-20261109224447-6396bc976408
	github.com/KogenAI/kogen-loop v0.0.0
	github.com/KogenAI/kogen-review v0.0.0-20261108105409-1a55cd0ae6ca
	github.com/KogenAI/kogen-setup v0.0.0-20261110123838-e31ed73a8071
	github.com/KogenAI/kogen-shaping v0.0.0-20261110075949-4c0d87f3cf90
	github.com/KogenAI/kogen-verification v0.0.0-20261110062706-aa21c866ae86
)

require golang.org/x/text v0.43.0 // indirect

replace github.com/KogenAI/kogen-loop => ./third_party/kogen-loop
