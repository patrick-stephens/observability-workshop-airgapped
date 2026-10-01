package alerts

import "sync"

const Capacity = 50

// Store is a bounded, in-memory, newest-first view of recent operational events. Nothing is persisted.
type Store struct {
	mutex  sync.Mutex
	events [Capacity]Event
	next   int
	count  int
	// active holds the latest firing event per alert, which drives the UI banner.
	active map[string]Event
}

func NewStore() *Store {
	return &Store{active: map[string]Event{}}
}

func alertKey(event Event) string {
	if event.Fingerprint != "" {
		return event.Fingerprint
	}
	return event.AlertName
}

// Add records an event. Alertmanager re-sends firing alerts on every group interval, so a repeat of an
// already-firing alert does not add a duplicate feed entry.
func (s *Store) Add(event Event) {
	s.mutex.Lock()
	defer s.mutex.Unlock()

	key := alertKey(event)
	if event.Status == StatusFiring {
		if _, alreadyFiring := s.active[key]; alreadyFiring {
			return
		}
		s.active[key] = event
	} else {
		delete(s.active, key)
	}

	s.events[s.next] = event
	s.next = (s.next + 1) % Capacity
	if s.count < Capacity {
		s.count++
	}
}

// Events returns up to Capacity events, newest first.
func (s *Store) Events() []Event {
	s.mutex.Lock()
	defer s.mutex.Unlock()

	events := make([]Event, 0, s.count)
	for i := 1; i <= s.count; i++ {
		events = append(events, s.events[(s.next-i+Capacity)%Capacity])
	}
	return events
}

// Firing returns the currently firing alerts, most severe first.
func (s *Store) Firing() []Event {
	s.mutex.Lock()
	defer s.mutex.Unlock()

	firing := make([]Event, 0, len(s.active))
	for _, event := range s.active {
		if event.Severity == SeverityCritical {
			firing = append([]Event{event}, firing...)
		} else {
			firing = append(firing, event)
		}
	}
	return firing
}
