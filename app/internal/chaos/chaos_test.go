package chaos

import "testing"

func TestControllerSwitchesModes(t *testing.T) {
	controller := New()
	if got := controller.Mode(); got != ModeOK {
		t.Fatalf("initial mode = %q, want %q", got, ModeOK)
	}

	for _, mode := range []Mode{ModeSlow, ModeError, ModeDNS, ModeOK} {
		if err := controller.Set(string(mode)); err != nil {
			t.Fatalf("Set(%q): %v", mode, err)
		}
		if got := controller.Mode(); got != mode {
			t.Fatalf("mode = %q, want %q", got, mode)
		}
	}
}

func TestControllerRejectsUnknownMode(t *testing.T) {
	controller := New()
	if err := controller.Set("broken"); err == nil {
		t.Fatal("Set(broken) returned nil")
	}
	if got := controller.Mode(); got != ModeOK {
		t.Fatalf("mode after rejected update = %q, want %q", got, ModeOK)
	}
}
