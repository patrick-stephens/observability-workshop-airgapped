package chaos

import (
	"fmt"
	"sync/atomic"
)

type Mode string

const (
	ModeOK      Mode = "ok"
	ModeSlow    Mode = "slow"
	ModeError   Mode = "error"
	ModeDNS     Mode = "dns"
	ModeTorpedo Mode = "torpedo"
)

type Controller struct {
	mode atomic.Value
}

func New() *Controller {
	controller := &Controller{}
	controller.mode.Store(ModeOK)
	return controller
}

func ParseMode(value string) (Mode, error) {
	mode := Mode(value)
	switch mode {
	case ModeOK, ModeSlow, ModeError, ModeDNS, ModeTorpedo:
		return mode, nil
	default:
		return "", fmt.Errorf("unsupported chaos mode %q", value)
	}
}

func (c *Controller) Set(value string) error {
	mode, err := ParseMode(value)
	if err != nil {
		return err
	}
	c.mode.Store(mode)
	return nil
}

func (c *Controller) Mode() Mode {
	return c.mode.Load().(Mode)
}
