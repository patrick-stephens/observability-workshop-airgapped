package main

import (
	"log/slog"
	"os"

	"github.com/patrick-stephens/observability-workshop-airgapped/app/internal/server"
)

func main() {
	if err := server.Run("backend", "", nil); err != nil {
		slog.Error("service stopped with an error", "error", err)
		os.Exit(1)
	}
}
