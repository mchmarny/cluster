package main

import (
	"github.com/mchmarny/cluster/pkg/cluster"
)

var (
	version = "v0.0.0-dev"
	commit  = "unknown"
)

func main() {
	cluster.Execute(version, commit)
}
