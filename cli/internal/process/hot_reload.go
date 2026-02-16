package process

import (
	"fmt"
	"io"
	"net/http"
	"sync"
	"time"

	"github.com/fsnotify/fsnotify"
)

const DefaultReloadURL = "http://localhost:8080/_fn/reload"

// Debouncer coalesces bursts of events into a single callback execution.
type Debouncer struct {
	mu      sync.Mutex
	delay   time.Duration
	timer   *time.Timer
	stopped bool
	fn      func()
}

func NewDebouncer(delay time.Duration, fn func()) *Debouncer {
	if delay <= 0 {
		delay = 150 * time.Millisecond
	}
	if fn == nil {
		fn = func() {}
	}
	return &Debouncer{
		delay: delay,
		fn:    fn,
	}
}

func (d *Debouncer) Trigger() {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.stopped {
		return
	}
	if d.timer != nil {
		d.timer.Stop()
	}
	d.timer = time.AfterFunc(d.delay, func() {
		d.mu.Lock()
		if d.stopped {
			d.mu.Unlock()
			return
		}
		fn := d.fn
		d.mu.Unlock()
		fn()
	})
}

func (d *Debouncer) Stop() {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.stopped = true
	if d.timer != nil {
		d.timer.Stop()
		d.timer = nil
	}
}

// TriggerCatalogReload calls the runtime reload endpoint. It prefers POST and
// falls back to GET for compatibility with older/newer gateway behavior.
func TriggerCatalogReload(endpoint string, timeout time.Duration) error {
	if endpoint == "" {
		endpoint = DefaultReloadURL
	}
	if timeout <= 0 {
		timeout = 1500 * time.Millisecond
	}

	client := &http.Client{Timeout: timeout}
	methods := []string{"POST", "GET"}
	var lastErr error

	for _, method := range methods {
		req, err := http.NewRequest(method, endpoint, nil)
		if err != nil {
			lastErr = err
			continue
		}
		resp, err := client.Do(req)
		if err != nil {
			lastErr = err
			continue
		}
		_, _ = io.Copy(io.Discard, resp.Body)
		resp.Body.Close()

		if resp.StatusCode >= 200 && resp.StatusCode < 300 {
			return nil
		}
		if resp.StatusCode == http.StatusMethodNotAllowed {
			lastErr = fmt.Errorf("reload via %s not allowed", method)
			continue
		}
		return fmt.Errorf("reload failed via %s status=%d", method, resp.StatusCode)
	}

	if lastErr != nil {
		return lastErr
	}
	return fmt.Errorf("reload failed")
}

type HotReloadWatcher struct {
	watcher   *Watcher
	debouncer *Debouncer
}

func StartHotReloadWatcher(root, reloadURL string, logf func(format string, args ...interface{})) (*HotReloadWatcher, error) {
	if logf == nil {
		logf = func(string, ...interface{}) {}
	}

	debouncer := NewDebouncer(180*time.Millisecond, func() {
		if err := TriggerCatalogReload(reloadURL, 1500*time.Millisecond); err != nil {
			logf("Hot reload trigger failed: %v", err)
		}
	})

	watcher, err := NewWatcher(root, func(event fsnotify.Event) {
		_ = event // keep callback signature for potential future diagnostics.
		debouncer.Trigger()
	})
	if err != nil {
		debouncer.Stop()
		return nil, err
	}
	if err := watcher.Start(); err != nil {
		debouncer.Stop()
		return nil, err
	}

	return &HotReloadWatcher{
		watcher:   watcher,
		debouncer: debouncer,
	}, nil
}

func (h *HotReloadWatcher) Stop() {
	if h == nil {
		return
	}
	if h.watcher != nil {
		h.watcher.Stop()
	}
	if h.debouncer != nil {
		h.debouncer.Stop()
	}
}
