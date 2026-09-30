package main

import (
	"log/slog"
	"os"
	"strings"

	"github.com/patrick-stephens/observability-workshop-airgapped/app/internal/server"
)

func main() {
	nextURL := strings.TrimSpace(os.Getenv("BACKEND_URL"))
	if nextURL == "" {
		nextURL = "http://backend:8080"
	}

	if err := server.Run("api", nextURL); err != nil {
		slog.Error("service stopped with an error", "error", err)
		os.Exit(1)
	}
}
