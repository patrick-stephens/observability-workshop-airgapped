package alerts

import "time"

const (
	SeverityCritical = "critical"
	SeverityWarning  = "warning"
	SeverityOK       = "ok"

	StatusFiring   = "firing"
	StatusResolved = "resolved"

	clearPrefix = "CLEAR — "
)

// Translations maps Alertmanager alert names to the operator-facing event text.
var Translations = map[string]string{
	"DemoHighErrorRate": "Contact lost — elevated error rate",
	"TorpedoDetected":   "TORPEDO DETECTED",
}

type Event struct {
	Timestamp   time.Time `json:"ts"`
	Severity    string    `json:"severity"`
	Text        string    `json:"text"`
	AlertName   string    `json:"alertname"`
	Status      string    `json:"status"`
	Fingerprint string    `json:"fingerprint,omitempty"`
	Summary     string    `json:"summary,omitempty"`
}

// Translate returns the event text and severity for one alert.
// Unmapped names pass through unchanged as warnings, so a new alert rule appears in the UI with no code change.
func Translate(alertName, status, severityLabel string) (string, string) {
	text, mapped := Translations[alertName]
	severity := SeverityWarning
	if mapped {
		if severityLabel == SeverityCritical {
			severity = SeverityCritical
		}
	} else {
		text = alertName
	}
	if status == StatusResolved {
		return clearPrefix + text, SeverityOK
	}
	return text, severity
}
