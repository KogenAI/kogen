module kogen

go 1.27.2

require (
	github.com/KogenAI/kogen-build v0.0.0-20261117183810-6cbedd9ba0ad
	github.com/KogenAI/kogen-coordinator v0.0.0-20261118001611-e643661cb646
	github.com/KogenAI/kogen-executor v0.0.0-20261118022434-c793e7b00050
	github.com/KogenAI/kogen-loop v0.0.0
	github.com/KogenAI/kogen-review v0.0.0-20261118021131-ae4458026be7
	github.com/KogenAI/kogen-setup v0.0.0-20261118070919-41701ecb667a
	github.com/KogenAI/kogen-shaping v0.0.0-20261119055204-862b3ba35857
	github.com/KogenAI/kogen-verification v0.0.0-20261116140247-a02a7f9e2a36
)

require golang.org/x/text v0.43.0 // indirect

replace github.com/KogenAI/kogen-loop => ./third_party/kogen-loop
