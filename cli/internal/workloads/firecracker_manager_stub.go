//go:build !linux

package workloads

import (
	"context"
	"fmt"
	"runtime"
)

type FirecrackerManager struct {
	cfg ManagerConfig
}

func NewFirecrackerManager(cfg ManagerConfig) (*FirecrackerManager, error) {
	return &FirecrackerManager{cfg: cfg}, nil
}

func (m *FirecrackerManager) Start(context.Context) error {
	if m == nil || (len(m.cfg.Apps) == 0 && len(m.cfg.Services) == 0) {
		return nil
	}
	return fmt.Errorf("firecracker image workloads require a Linux/KVM host; current host is %s", runtime.GOOS)
}

func (m *FirecrackerManager) Stop(context.Context) error {
	return nil
}

func (m *FirecrackerManager) StatePath() string {
	if m == nil {
		return ""
	}
	return m.cfg.StatePath
}
