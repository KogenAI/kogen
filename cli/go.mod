module kogen

go 1.27.2

require (
	github.com/KogenAI/kogen-build v0.0.0-20261126083538-31f15ae197ef
	github.com/KogenAI/kogen-coordinator v0.0.0-20261126061203-c7baef4a8e89
	github.com/KogenAI/kogen-executor v0.0.0-20261125004010-a9c81c0ca1dd
	github.com/KogenAI/kogen-loop v0.0.0
	github.com/KogenAI/kogen-review v0.0.0-20261125005854-5525f1d100e6
	github.com/KogenAI/kogen-setup v0.0.0-20261125011042-1142707f6ab3
	github.com/KogenAI/kogen-shaping v0.0.0-20261124024815-aac5e7292db2
	github.com/KogenAI/kogen-verification v0.0.0-20261125011210-2ea749d7e799
)

require golang.org/x/text v0.43.0 // indirect

replace github.com/KogenAI/kogen-loop => ./third_party/kogen-loop
