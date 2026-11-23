module kogen

go 1.27.2

require (
	github.com/KogenAI/kogen-build v0.0.0-20261123050929-a5216d13edb1
	github.com/KogenAI/kogen-coordinator v0.0.0-20261123070705-a5e054b57738
	github.com/KogenAI/kogen-executor v0.0.0-20261123090514-e6fbc333e9a9
	github.com/KogenAI/kogen-loop v0.0.0
	github.com/KogenAI/kogen-review v0.0.0-20261123055332-b32358a08764
	github.com/KogenAI/kogen-setup v0.0.0-20261123090759-647d33826339
	github.com/KogenAI/kogen-shaping v0.0.0-20261121135858-a656ea90524b
	github.com/KogenAI/kogen-verification v0.0.0-20261123070037-583d28a58016
)

require golang.org/x/text v0.43.0 // indirect

replace github.com/KogenAI/kogen-loop => ./third_party/kogen-loop
