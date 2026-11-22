module kogen

go 1.27.2

require (
	github.com/KogenAI/kogen-build v0.0.0-20261122033809-b98dc9a52f9e
	github.com/KogenAI/kogen-coordinator v0.0.0-20261118001611-e643661cb646
	github.com/KogenAI/kogen-executor v0.0.0-20261118022434-c793e7b00050
	github.com/KogenAI/kogen-loop v0.0.0
	github.com/KogenAI/kogen-review v0.0.0-20261121211900-1ce74571c08d
	github.com/KogenAI/kogen-setup v0.0.0-20261118070919-41701ecb667a
	github.com/KogenAI/kogen-shaping v0.0.0-20261121135858-a656ea90524b
	github.com/KogenAI/kogen-verification v0.0.0-20261121214801-c317414b6ceb
)

require golang.org/x/text v0.43.0 // indirect

replace github.com/KogenAI/kogen-loop => ./third_party/kogen-loop
