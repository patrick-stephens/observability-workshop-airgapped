package main

import (
	"fmt"
	"io"
	"log"
	"math/rand"
	"net"
	"os"
	"strconv"
	"time"
)

const (
	emissionInterval = 2 * time.Second
	reconnectDelay   = time.Second
	dialTimeout      = 5 * time.Second
)

type sensor struct {
	hostname string
	appName  string
}

var sensors = []sensor{
	{hostname: "sonar-buoy-1", appName: "sonar"},
	{hostname: "sonar-buoy-2", appName: "sonar"},
	{hostname: "radar-array-1", appName: "radar"},
}

var contactMessages = []string{
	"Subsurface contact classified",
	"Surface track acquired",
	"Contact lost",
}

func main() {
	logger := log.New(os.Stderr, "[sensor-sim] ", log.LstdFlags)
	target := os.Getenv("SYSLOG_TARGET")
	if target == "" {
		logger.Print("SYSLOG_TARGET is empty; retrying until it is configured")
	}

	ticker := time.NewTicker(emissionInterval)
	defer ticker.Stop()
	var connection net.Conn
	sensorIndex := 0

	for {
		if target == "" {
			time.Sleep(5 * time.Second)
			continue
		}
		if connection == nil {
			var err error
			connection, err = net.DialTimeout("tcp", target, dialTimeout)
			if err != nil {
				logger.Printf("connect to %s failed: %v", target, err)
				time.Sleep(reconnectDelay)
				continue
			}
			logger.Printf("connected to %s", target)
		}

		line := createMessage(sensors[sensorIndex], os.Getpid())
		written, err := io.WriteString(connection, line)
		if err == nil && written != len(line) {
			err = io.ErrShortWrite
		}
		if err != nil {
			logger.Printf("write to %s failed: %v; reconnecting", target, err)
			_ = connection.Close()
			connection = nil
			time.Sleep(reconnectDelay)
			continue
		}

		sensorIndex = (sensorIndex + 1) % len(sensors)
		<-ticker.C
	}
}

func createMessage(source sensor, processID int) string {
	contactKinds := []string{"submarine", "surface"}
	confidences := []string{"high", "medium", "low"}
	priority := 134
	switch roll := rand.Intn(10); {
	case roll == 0:
		priority = 131
	case roll <= 2:
		priority = 132
	}

	return formatMessage(
		source.hostname,
		source.appName,
		processID,
		priority,
		contactKinds[rand.Intn(len(contactKinds))],
		rand.Intn(360),
		5+rand.Intn(36),
		confidences[rand.Intn(len(confidences))],
		contactMessages[rand.Intn(len(contactMessages))],
		time.Now().UTC(),
	)
}

func formatMessage(hostname, appName string, processID, priority int, contact string, bearing, rangeNM int, confidence, message string, timestamp time.Time) string {
	return fmt.Sprintf(
		"<%d>1 %s %s %s %s CONTACT [demo@32473 contact=\"%s\" bearing=\"%03d\" range_nm=\"%d\" confidence=\"%s\"] %s\n",
		priority,
		timestamp.Format(time.RFC3339Nano),
		hostname,
		appName,
		strconv.Itoa(processID),
		contact,
		bearing,
		rangeNM,
		confidence,
		message,
	)
}
