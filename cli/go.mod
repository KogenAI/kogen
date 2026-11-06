module kogen

go 1.27.2

require (
	github.com/KogenAI/kogen-build v0.0.0-20261106000240-fdbef3d41add
	github.com/KogenAI/kogen-coordinator v0.0.0-20261105163147-c8126f4156ba
	github.com/KogenAI/kogen-executor v0.0.0-20261106043540-c7382270875a
	github.com/KogenAI/kogen-loop v0.0.0
	github.com/KogenAI/kogen-review v0.0.0-20261106032356-22dc61ec5953
	github.com/KogenAI/kogen-setup v0.0.0-20261106022317-9630cce549f9
	github.com/KogenAI/kogen-shaping v0.0.0-20261106032059-88a929ea41ee
	github.com/KogenAI/kogen-verification v0.0.0-20261106044425-a83b8096ecdb
)

require golang.org/x/text v0.43.0 // indirect

replace github.com/KogenAI/kogen-loop => ./third_party/kogen-loop
