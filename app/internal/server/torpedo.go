package server

import (
	"context"
	"time"

	"github.com/patrick-stephens/observability-workshop-airgapped/app/internal/chaos"
	"github.com/patrick-stephens/observability-workshop-airgapped/app/internal/telemetry"
)

// About 0.3 detections/s normally and 50/s in torpedo mode; the TorpedoDetected threshold of 5/s sits between them.
const (
	TorpedoBaselineInterval = 3300 * time.Millisecond
	TorpedoAttackInterval   = 20 * time.Millisecond
)

// RunTorpedoSensor counts torpedoes.detected in the background, independent of request traffic.
// Torpedo mode only changes this rate; requests are served exactly as in ok mode.
func RunTorpedoSensor(ctx context.Context, controller *chaos.Controller, business *telemetry.BusinessMetrics,
	baseline, attack time.Duration) {
	for {
		interval := baseline
		if controller.Mode() == chaos.ModeTorpedo {
			interval = attack
		}
		timer := time.NewTimer(interval)
		select {
		case <-ctx.Done():
			timer.Stop()
			return
		case <-timer.C:
			business.TorpedoesDetected.Add(ctx, 1)
		}
	}
}
