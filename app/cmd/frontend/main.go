package main

import (
	"log/slog"
	"os"
	"strings"

	"github.com/patrick-stephens/observability-workshop-airgapped/app/internal/server"
)

func main() {
	nextURL := strings.TrimSpace(os.Getenv("API_URL"))
	if nextURL == "" {
		nextURL = "http://api:8080"
	}

	if err := server.Run("frontend", nextURL); err != nil {
		slog.Error("service stopped with an error", "error", err)
		os.Exit(1)
	}
}
