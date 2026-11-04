// Package contract pins what kogen-loop's consumers use: the exported API of api, loop,
// provider, sys and tools that they call, the behaviours they rely on, and the file and wire
// formats they read or write. The cases are in the package's tests; README.md lists them
// against the interface members and the consumer tests they were adapted from.
package contract
