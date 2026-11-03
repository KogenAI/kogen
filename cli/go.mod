module kogen

go 1.27.2

require (
	github.com/KogenAI/kogen-build v0.0.0-20261102194452-3109cd105f75
	github.com/KogenAI/kogen-coordinator v0.0.0-20261102193107-c4a49a4fe84f
	github.com/KogenAI/kogen-executor v0.0.0-20261102193603-1aea0728c24b
	github.com/KogenAI/kogen-setup v0.0.0-20261103070454-e58099611999
	github.com/KogenAI/kogen-shaping v0.0.0-20261102194440-94eabe5d492d
	github.com/KogenAI/kogen-verification v0.0.0-20261103052035-11a5244e95ee
	kogen-loop v0.0.0
)

replace kogen-loop => ./third_party/kogen-loop
