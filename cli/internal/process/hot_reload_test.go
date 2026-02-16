package process

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestTriggerCatalogReload_PostSuccess(t *testing.T) {
	var calls int32
	var method string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&calls, 1)
		method = r.Method
		w.WriteHeader(http.StatusOK)
	}))
	defer server.Close()

	if err := TriggerCatalogReload(server.URL, time.Second); err != nil {
		t.Fatalf("trigger failed: %v", err)
	}
	if atomic.LoadInt32(&calls) != 1 {
		t.Fatalf("expected 1 call, got %d", atomic.LoadInt32(&calls))
	}
	if method != http.MethodPost {
		t.Fatalf("expected POST, got %s", method)
	}
}

func TestTriggerCatalogReload_FallbackToGet(t *testing.T) {
	var calls int32
	var mu sync.Mutex
	seen := make([]string, 0, 2)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&calls, 1)
		mu.Lock()
		seen = append(seen, r.Method)
		mu.Unlock()
		if r.Method == http.MethodPost {
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		w.WriteHeader(http.StatusOK)
	}))
	defer server.Close()

	if err := TriggerCatalogReload(server.URL, time.Second); err != nil {
		t.Fatalf("trigger failed: %v", err)
	}
	if atomic.LoadInt32(&calls) != 2 {
		t.Fatalf("expected 2 calls, got %d", atomic.LoadInt32(&calls))
	}
	mu.Lock()
	defer mu.Unlock()
	if len(seen) != 2 || seen[0] != http.MethodPost || seen[1] != http.MethodGet {
		t.Fatalf("unexpected method sequence: %#v", seen)
	}
}

func TestDebouncer_CoalescesBurst(t *testing.T) {
	var calls int32
	d := NewDebouncer(50*time.Millisecond, func() {
		atomic.AddInt32(&calls, 1)
	})
	defer d.Stop()

	for i := 0; i < 5; i++ {
		d.Trigger()
		time.Sleep(10 * time.Millisecond)
	}

	time.Sleep(140 * time.Millisecond)
	if atomic.LoadInt32(&calls) != 1 {
		t.Fatalf("expected 1 callback, got %d", atomic.LoadInt32(&calls))
	}
}

func TestStartHotReloadWatcher_RecursiveChangeTriggersReload(t *testing.T) {
	root := t.TempDir()
	sub := filepath.Join(root, "app", "users")
	if err := os.MkdirAll(sub, 0o755); err != nil {
		t.Fatalf("mkdir failed: %v", err)
	}

	var reloadCalls int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&reloadCalls, 1)
		w.WriteHeader(http.StatusOK)
	}))
	defer server.Close()

	watcher, err := StartHotReloadWatcher(root, server.URL, nil)
	if err != nil {
		t.Fatalf("failed to start watcher: %v", err)
	}
	defer watcher.Stop()

	target := filepath.Join(sub, "index.js")
	if err := os.WriteFile(target, []byte("module.exports = 1;\n"), 0o644); err != nil {
		t.Fatalf("write failed: %v", err)
	}

	deadline := time.Now().Add(4 * time.Second)
	for time.Now().Before(deadline) {
		if atomic.LoadInt32(&reloadCalls) > 0 {
			return
		}
		time.Sleep(40 * time.Millisecond)
	}
	t.Fatalf("expected at least one reload call, got %d", atomic.LoadInt32(&reloadCalls))
}
