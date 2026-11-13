module kogen

go 1.27.2

require (
	github.com/KogenAI/kogen-build v0.0.0-20261113022426-ba5ac125300a
	github.com/KogenAI/kogen-coordinator v0.0.0-20261113021958-d5efab69ee6b
	github.com/KogenAI/kogen-executor v0.0.0-20261113023227-61a48f154880
	github.com/KogenAI/kogen-loop v0.0.0
	github.com/KogenAI/kogen-review v0.0.0-20261113053800-5395037611ae
	github.com/KogenAI/kogen-setup v0.0.0-20261113030035-7ffe554b3341
	github.com/KogenAI/kogen-shaping v0.0.0-20261113060429-ad317f1f9954
	github.com/KogenAI/kogen-verification v0.0.0-20261113024304-b1572e671c95
)

require golang.org/x/text v0.43.0 // indirect

replace github.com/KogenAI/kogen-loop => ./third_party/kogen-loop
