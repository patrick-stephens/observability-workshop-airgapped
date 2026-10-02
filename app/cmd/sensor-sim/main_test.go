package main

import (
	"regexp"
	"testing"
	"time"
)

func TestFormatMessageProducesRFC5424Line(t *testing.T) {
	timestamp := time.Date(2026, time.October, 2, 12, 30, 45, 123000000, time.UTC)
	line := formatMessage("sonar-buoy-1", "sonar", 42, 134, "submarine", 45, 12, "high", "Subsurface contact classified", timestamp)
	pattern := regexp.MustCompile(`^<134>1 2026-10-02T12:30:45\.123Z sonar-buoy-1 sonar 42 CONTACT \[demo@32473 contact="submarine" bearing="045" range_nm="12" confidence="high"\] Subsurface contact classified\n$`)
	if !pattern.MatchString(line) {
		t.Fatalf("unexpected RFC5424 message: %q", line)
	}
}

func TestCreateMessageUsesAllowedPrioritiesAndFieldRanges(t *testing.T) {
	for range 100 {
		line := createMessage(sensors[0], 42)
		match := regexp.MustCompile(`^<(131|132|134)>1 .* bearing="([0-9]{3})" range_nm="([0-9]+)" confidence="(high|medium|low)"`).FindStringSubmatch(line)
		if match == nil {
			t.Fatalf("unexpected sensor message: %q", line)
		}
		bearing := 0
		rangeNM := 0
		for _, digit := range match[2] {
			bearing = bearing*10 + int(digit-'0')
		}
		for _, digit := range match[3] {
			rangeNM = rangeNM*10 + int(digit-'0')
		}
		if bearing > 359 || rangeNM < 5 || rangeNM > 40 {
			t.Fatalf("out-of-range sensor fields: bearing=%d range_nm=%d", bearing, rangeNM)
		}
	}
}
