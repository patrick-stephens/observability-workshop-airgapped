package main

import (
	_ "embed"
	"log/slog"
	"os"
	"strings"

	"github.com/patrick-stephens/observability-workshop-airgapped/app/internal/server"
)

//go:embed index.html
var indexHTML []byte

func main() {
	nextURL := strings.TrimSpace(os.Getenv("API_URL"))
	if nextURL == "" {
		nextURL = "http://api:8080"
	}

	if err := server.Run("frontend", nextURL, indexHTML); err != nil {
		slog.Error("service stopped with an error", "error", err)
		os.Exit(1)
	}
}
