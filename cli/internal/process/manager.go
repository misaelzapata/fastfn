package process

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"
)

// Service represents a managed background process (e.g., Python daemon, Nginx)
type Service struct {
	Name    string
	Command string
	Args    []string
	Env     []string
	Dir     string

	cmd    *exec.Cmd
	cancel context.CancelFunc
}

// Manager handles the lifecycle of multiple services
type Manager struct {
	services []*Service
	wg       sync.WaitGroup
	ctx      context.Context
	cancel   context.CancelFunc
}

func NewManager() *Manager {
	ctx, cancel := context.WithCancel(context.Background())
	return &Manager{
		services: make([]*Service, 0),
		ctx:      ctx,
		cancel:   cancel,
	}
}

// AddService registers a process to be managed
func (m *Manager) AddService(name, command string, args []string, env []string, dir string) {
	m.services = append(m.services, &Service{
		Name:    name,
		Command: command,
		Args:    args,
		Env:     env,
		Dir:     dir,
	})
}

// StartAll starts all registered services invoking the optional onStart callback for each
func (m *Manager) StartAll() error {
	for _, svc := range m.services {
		if err := m.startService(svc); err != nil {
			m.StopAll() // Rollback on failure
			return fmt.Errorf("failed to start %s: %w", svc.Name, err)
		}
	}
	return nil
}

func (m *Manager) startService(svc *Service) error {
	// Create a child context for this individual process
	ctx, cancel := context.WithCancel(m.ctx)
	svc.cancel = cancel

	cmd := exec.CommandContext(ctx, svc.Command, svc.Args...)
	cmd.Dir = svc.Dir
	cmd.Env = mergedServiceEnv(svc.Env)

	// Create pipes for stdout/stderr to stream logs with prefix
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		cancel()
		return fmt.Errorf("failed to get stdout pipe: %w", err)
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		cancel()
		return fmt.Errorf("failed to get stderr pipe: %w", err)
	}

	// Set process group ID so we can kill the whole tree if needed
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}

	fmt.Printf("[Process] Starting %s...\n", svc.Name)
	if err := cmd.Start(); err != nil {
		cancel()
		return err
	}
	svc.cmd = cmd

	// Stream logs in background goroutines
	m.wg.Add(2)
	go streamLog(stdout, svc.Name, os.Stdout, &m.wg)
	go streamLog(stderr, svc.Name, os.Stderr, &m.wg)

	// Monitor the process in background
	m.wg.Add(1)
	go func() {
		defer m.wg.Done()
		err := cmd.Wait()
		if err != nil {
			// Check if it was killed intentionally
			if ctx.Err() == nil {
				fmt.Fprintf(os.Stderr, "[%s] Process exited unexpectedly: %v\n", svc.Name, err)

				// CRITICAL FIX: Propagate failure to the entire manager
				// If a core service like OpenResty dies, everything should probably stop.
				// But we don't want to kill watchers on temporary errors.
				// For now, logging the error is enough as per request.
			}
		} else {
			fmt.Printf("[%s] Process exited cleanly\n", svc.Name)
		}
	}()

	return nil
}

func mergedServiceEnv(extra []string) []string {
	envMap := map[string]string{}
	for _, kv := range os.Environ() {
		key, val, ok := splitEnvKV(kv)
		if !ok {
			continue
		}
		envMap[key] = val
	}
	for _, kv := range extra {
		key, val, ok := splitEnvKV(kv)
		if !ok {
			continue
		}
		envMap[key] = val
	}

	// Node warns when both are present; FORCE_COLOR already takes precedence.
	if forceVal, hasForce := envMap["FORCE_COLOR"]; hasForce && strings.TrimSpace(forceVal) != "" {
		delete(envMap, "NO_COLOR")
	}

	keys := make([]string, 0, len(envMap))
	for k := range envMap {
		keys = append(keys, k)
	}
	sort.Strings(keys)

	out := make([]string, 0, len(keys))
	for _, k := range keys {
		out = append(out, k+"="+envMap[k])
	}
	return out
}

func splitEnvKV(kv string) (string, string, bool) {
	if kv == "" {
		return "", "", false
	}
	parts := strings.SplitN(kv, "=", 2)
	if len(parts) != 2 || parts[0] == "" {
		return "", "", false
	}
	return parts[0], parts[1], true
}

func streamLog(r io.Reader, prefix string, w io.Writer, wg *sync.WaitGroup) {
	defer wg.Done()
	scanner := bufio.NewScanner(r)
	for scanner.Scan() {
		// Using Fprintf for thread safety on shared writers (like os.Stdout)
		fmt.Fprintf(w, "[%s] %s\n", prefix, scanner.Text())
	}
}

// StopAll sends signals to stop all services
func (m *Manager) StopAll() {
	fmt.Println("[Process] Stopping all services...")
	m.cancel() // Cancel the parent context, triggering kills in CommandContext

	// Force kill if necessary or wait nicely?
	// The context cancellation sends SIGKILL/SIGTERM depending on implementation,
	// usually CommandContext kills process when context dies.

	// Wait a bit for cleanup
	done := make(chan struct{})
	go func() {
		m.wg.Wait()
		close(done)
	}()

	select {
	case <-done:
		fmt.Println("[Process] All services stopped.")
	case <-time.After(5 * time.Second):
		fmt.Println("[Process] Timeout waiting for services to stop.")
	}
}
