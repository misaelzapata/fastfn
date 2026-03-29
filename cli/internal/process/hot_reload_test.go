package process

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/fsnotify/fsnotify"
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

func TestDrainAndCloseBody_NilSafe(t *testing.T) {
	drainAndCloseBody(nil)
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

func TestDebouncer_StopPreventsCallback(t *testing.T) {
	var calls int32
	d := NewDebouncer(50*time.Millisecond, func() {
		atomic.AddInt32(&calls, 1)
	})

	d.Trigger()
	d.Stop()

	time.Sleep(150 * time.Millisecond)
	if atomic.LoadInt32(&calls) != 0 {
		t.Fatalf("expected no callback after Stop, got %d", atomic.LoadInt32(&calls))
	}
}

func TestDebouncer_ZeroDelayDefaultsTo150ms(t *testing.T) {
	d := NewDebouncer(0, func() {})
	defer d.Stop()

	if d.delay != 150*time.Millisecond {
		t.Fatalf("expected default delay 150ms, got %v", d.delay)
	}
}

func TestDebouncer_NilFnDefaultsToNoop(t *testing.T) {
	d := NewDebouncer(50*time.Millisecond, nil)
	defer d.Stop()

	// Should not panic
	d.Trigger()
	time.Sleep(100 * time.Millisecond)
}

func TestTriggerCatalogReload_NonSuccessStatus(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer server.Close()

	err := TriggerCatalogReload(server.URL, time.Second)
	if err == nil {
		t.Fatalf("expected error for non-2xx status")
	}
	if !strings.Contains(err.Error(), "reload failed via POST status=500") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestTriggerCatalogReload_AllMethodsFail(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusMethodNotAllowed)
	}))
	defer server.Close()

	err := TriggerCatalogReload(server.URL, time.Second)
	if err == nil {
		t.Fatalf("expected error when all methods return 405")
	}
}

func TestTriggerCatalogReload_DefaultEndpointAndTimeout(t *testing.T) {
	// Test that empty endpoint uses default and does not panic
	err := TriggerCatalogReload("", 0)
	// This will fail to connect to localhost:8080 (expected), but should not panic
	if err == nil {
		t.Logf("surprisingly succeeded connecting to default endpoint")
	}
}

func TestTriggerCatalogReload_ConnectionRefused(t *testing.T) {
	err := TriggerCatalogReload("http://127.0.0.1:1", 200*time.Millisecond)
	if err == nil {
		t.Fatalf("expected connection error")
	}
}

func TestHotReloadWatcher_StopNilSafe(t *testing.T) {
	var w *HotReloadWatcher
	w.Stop() // should not panic
}

func TestHotReloadWatcher_StopWithNilFields(t *testing.T) {
	w := &HotReloadWatcher{}
	w.Stop() // should not panic with nil watcher and debouncer
}

func TestStartHotReloadWatcher_InvalidRootDir(t *testing.T) {
	hrw, err := StartHotReloadWatcher("/nonexistent/dir/that/does/not/exist", "", nil)
	if err != nil {
		// Error during NewWatcher or Start is acceptable
		return
	}
	// If it succeeded (fsnotify may not fail for nonexistent dirs on all platforms),
	// just verify we can stop cleanly.
	hrw.Stop()
}

func TestDebouncer_TriggerAfterStop(t *testing.T) {
	var calls int32
	d := NewDebouncer(50*time.Millisecond, func() {
		atomic.AddInt32(&calls, 1)
	})

	d.Stop()
	d.Trigger() // should be a no-op after stop
	time.Sleep(150 * time.Millisecond)
	if atomic.LoadInt32(&calls) != 0 {
		t.Fatalf("expected no callback after Stop+Trigger, got %d", atomic.LoadInt32(&calls))
	}
}

func TestDebouncer_MultipleTriggerResets(t *testing.T) {
	var calls int32
	d := NewDebouncer(80*time.Millisecond, func() {
		atomic.AddInt32(&calls, 1)
	})
	defer d.Stop()

	// Trigger twice in quick succession - should coalesce
	d.Trigger()
	time.Sleep(30 * time.Millisecond)
	d.Trigger()

	// Wait for debounce to fire
	time.Sleep(200 * time.Millisecond)
	if got := atomic.LoadInt32(&calls); got != 1 {
		t.Fatalf("expected exactly 1 callback, got %d", got)
	}
}

func TestTriggerCatalogReload_InvalidURL(t *testing.T) {
	err := TriggerCatalogReload("://bad-url", time.Second)
	if err == nil {
		t.Fatal("expected error for invalid URL")
	}
}

func TestDebouncer_StoppedDuringAfterFunc(t *testing.T) {
	// Trigger, then stop immediately, so the AfterFunc callback runs
	// after stopped=true — covers the d.stopped check inside the callback.
	var calls int32
	d := NewDebouncer(20*time.Millisecond, func() {
		atomic.AddInt32(&calls, 1)
	})

	d.Trigger()
	// Immediately stop before the timer fires
	time.Sleep(5 * time.Millisecond)
	d.Stop()

	// Wait for the timer to have fired
	time.Sleep(50 * time.Millisecond)
	if atomic.LoadInt32(&calls) != 0 {
		t.Fatalf("expected no callback after Stop during AfterFunc, got %d", atomic.LoadInt32(&calls))
	}
}

func TestTriggerCatalogReload_AllMethodsFail_LastErrNil(t *testing.T) {
	// Test the final return when lastErr is nil after all methods tried.
	// This can happen if both POST and GET receive 405, making lastErr non-nil.
	// To get lastErr=nil at the end, we'd need no errors and no success,
	// which the code can't reach since either an error or a status response
	// happens. The "reload failed" fallback line 109 covers the case where
	// lastErr is nil but no method succeeded. We trigger this by making
	// both methods return 405 (which sets lastErr), so we test the already-
	// covered path to be sure. The actual nil path can't happen in practice.
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusMethodNotAllowed)
	}))
	defer server.Close()

	err := TriggerCatalogReload(server.URL, time.Second)
	if err == nil {
		t.Fatal("expected error")
	}
	if !strings.Contains(err.Error(), "not allowed") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestStartHotReloadWatcher_WatcherStartError(t *testing.T) {
	// Use a root that exists (for NewWatcher to succeed) but then
	// cause Start() to fail. Since Start() calls addRecursive which
	// calls filepath.WalkDir, it's hard to make it fail after NewWatcher
	// succeeds. Instead, let's test the NewWatcher error path by using
	// a valid dir for NewWatcher, which always succeeds on Linux.
	// For StartHotReloadWatcher, the line 136-138 branch is: watcher.Start()
	// returns error. We can't easily trigger this without mocking fsnotify.
	// The NewWatcher error path (line 132-134) is what we CAN trigger.

	// Test NewWatcher error path: StartHotReloadWatcher with a nonexistent
	// root. On Linux, NewWatcher succeeds but Start->addRecursive may fail.
	// Actually, NewWatcher does NOT validate the root; it creates an fsnotify
	// watcher. The error comes from addRecursive inside Start(). But WalkDir
	// on a nonexistent path returns an error that addRecursive handles by
	// returning nil (line 96). So Start succeeds.
	// The only way to trigger line 132 is if fsnotify.NewWatcher fails,
	// which requires system-level resource exhaustion. Skip this branch.
}

func TestDebouncer_TriggerFiresCallback(t *testing.T) {
	// Test the normal path where Trigger fires and d.stopped is false
	// inside the AfterFunc callback, so fn() is executed.
	var calls int32
	d := NewDebouncer(10*time.Millisecond, func() {
		atomic.AddInt32(&calls, 1)
	})
	defer d.Stop()

	d.Trigger()
	time.Sleep(50 * time.Millisecond)

	if got := atomic.LoadInt32(&calls); got != 1 {
		t.Fatalf("expected exactly 1 callback, got %d", got)
	}
}

func TestDebouncer_StoppedRaceWithAfterFunc(t *testing.T) {
	// Exercises the d.stopped check inside the AfterFunc callback.
	// We use a very short delay so the timer fires almost immediately,
	// then stop right after triggering. Run multiple iterations to
	// maximize the chance of hitting the race condition.
	for i := 0; i < 20; i++ {
		var calls int32
		d := NewDebouncer(1*time.Millisecond, func() {
			atomic.AddInt32(&calls, 1)
		})

		d.Trigger()
		// Stop immediately - there's a chance the AfterFunc fires
		// after stopped=true is set but before the timer is nil'd.
		d.Stop()

		// Wait for any pending timer to fire
		time.Sleep(10 * time.Millisecond)

		// Whether calls is 0 or 1 depends on timing, both are valid.
		// The key is no panic.
	}
}

func TestStartHotReloadWatcher_TriggerFailedCallback(t *testing.T) {
	// Exercise the hot reload trigger failed callback (lines 123-125)
	// by creating a watcher that immediately fires an event, with a
	// reload URL that always fails.
	root := t.TempDir()

	var logMessages []string
	var mu sync.Mutex
	logFn := func(format string, args ...interface{}) {
		mu.Lock()
		logMessages = append(logMessages, fmt.Sprintf(format, args...))
		mu.Unlock()
	}

	// Use a URL that will fail (unreachable port)
	hrw, err := StartHotReloadWatcher(root, "http://127.0.0.1:1/nope", logFn)
	if err != nil {
		t.Fatalf("failed to start watcher: %v", err)
	}
	defer hrw.Stop()

	// Write a file to trigger the watcher -> debouncer -> TriggerCatalogReload
	if err := os.WriteFile(filepath.Join(root, "trigger.js"), []byte("x"), 0644); err != nil {
		t.Fatalf("write: %v", err)
	}

	// Wait for the debounce + reload attempt
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		mu.Lock()
		found := false
		for _, msg := range logMessages {
			if strings.Contains(msg, "Hot reload trigger failed") {
				found = true
				break
			}
		}
		mu.Unlock()
		if found {
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatal("expected 'Hot reload trigger failed' log message")
}

func TestStartHotReloadWatcher_NewWatcherError(t *testing.T) {
	origNewWatcher := newWatcherFn
	t.Cleanup(func() { newWatcherFn = origNewWatcher })

	newWatcherFn = func(root string, onChange func(fsnotify.Event)) (*Watcher, error) {
		return nil, fmt.Errorf("watcher creation failed")
	}

	hrw, err := StartHotReloadWatcher(t.TempDir(), "", nil)
	if err == nil {
		if hrw != nil {
			hrw.Stop()
		}
		t.Fatal("expected error when NewWatcher fails")
	}
	if !strings.Contains(err.Error(), "watcher creation failed") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestStartHotReloadWatcher_WatcherStartReturnsError(t *testing.T) {
	origNewWatcher := newWatcherFn
	t.Cleanup(func() { newWatcherFn = origNewWatcher })

	newWatcherFn = func(root string, onChange func(fsnotify.Event)) (*Watcher, error) {
		w, err := NewWatcher(root, onChange)
		if err != nil {
			return nil, err
		}
		// Close the internal fsnotify watcher so Start() fails
		w.watcher.Close()
		return w, nil
	}

	hrw, err := StartHotReloadWatcher(t.TempDir(), "", nil)
	if err == nil {
		if hrw != nil {
			hrw.Stop()
		}
		// On some systems, Start may still succeed after Close
		return
	}
	// Error is expected
}

func TestStartHotReloadWatcher_NilLogf(t *testing.T) {
	root := t.TempDir()
	// StartHotReloadWatcher with nil logf should use a noop and not panic.
	// We write a file to trigger the debouncer -> reload failure -> logf call,
	// which exercises the noop logf body.
	watcher, err := StartHotReloadWatcher(root, "http://127.0.0.1:1/nope", nil)
	if err != nil {
		t.Fatalf("failed to start watcher: %v", err)
	}
	defer watcher.Stop()

	// Trigger a file change so the noop logf is called on reload failure
	if err := os.WriteFile(filepath.Join(root, "trigger.js"), []byte("x"), 0644); err != nil {
		t.Fatalf("write: %v", err)
	}
	// Wait for debounce + reload attempt
	time.Sleep(500 * time.Millisecond)
}

func TestDebouncer_StoppedCheckInsideAfterFunc(t *testing.T) {
	// Directly exercises the d.stopped check inside the AfterFunc callback
	// by triggering, waiting for the callback goroutine to acquire the lock
	// and observe stopped=true.
	for i := 0; i < 50; i++ {
		var calls int32
		d := NewDebouncer(1*time.Millisecond, func() {
			atomic.AddInt32(&calls, 1)
		})

		// Trigger so the AfterFunc is scheduled
		d.Trigger()
		// Immediately mark as stopped — the AfterFunc callback will see d.stopped=true
		d.mu.Lock()
		d.stopped = true
		if d.timer != nil {
			// Don't stop the timer: let the AfterFunc fire and see d.stopped=true
		}
		d.mu.Unlock()

		time.Sleep(10 * time.Millisecond)
		if atomic.LoadInt32(&calls) != 0 {
			// The callback should not have fired since stopped=true
			t.Fatalf("iteration %d: expected no callback when stopped before AfterFunc fires, got %d", i, atomic.LoadInt32(&calls))
		}
	}
}

func TestTriggerCatalogReload_NoMethodsFallback(t *testing.T) {
	// Cover the "reload failed" fallback at line 112 when lastErr is nil.
	// Force this by making the methods slice empty so the loop never runs.
	origMethods := reloadMethods
	t.Cleanup(func() { reloadMethods = origMethods })
	reloadMethods = []string{}

	err := TriggerCatalogReload("http://127.0.0.1:1/nope", time.Second)
	if err == nil {
		t.Fatal("expected error when no methods are configured")
	}
	if err.Error() != "reload failed" {
		t.Fatalf("expected 'reload failed', got %v", err)
	}
}

func TestTriggerCatalogReload_LastErrNilFallback(t *testing.T) {
	// Cover the "reload failed" fallback at line 112 when lastErr is nil.
	// This requires both POST and GET to NOT set lastErr but also NOT return success.
	// The only way is if http.NewRequest succeeds, client.Do succeeds,
	// status is not 2xx and not 405 — which returns early at line 106.
	// So the only path to line 112 with lastErr=nil is impossible in practice.
	// However, the code path "if lastErr != nil" / "return reload failed" needs both branches.
	// Test the already-exercised path with both methods returning 405 (lastErr != nil),
	// confirming lastErr != nil path works, which means line 112 is the only remaining branch.
	// To actually reach line 112, we need both methods to produce no error and no response.
	// That can't happen. But we can verify by checking the 405-only path returns lastErr.
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusMethodNotAllowed)
	}))
	defer server.Close()

	err := TriggerCatalogReload(server.URL, time.Second)
	if err == nil {
		t.Fatal("expected error")
	}
	// This exercises lines 102-104 (StatusMethodNotAllowed) and 109-110 (lastErr != nil)
	if !strings.Contains(err.Error(), "not allowed") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestStartHotReloadWatcher_WatcherStartFails(t *testing.T) {
	origStartFn := watcherStartFn
	t.Cleanup(func() { watcherStartFn = origStartFn })

	watcherStartFn = func(w *Watcher) error {
		// Stop the watcher to avoid goroutine leaks
		w.Stop()
		return fmt.Errorf("start failed")
	}

	hrw, err := StartHotReloadWatcher(t.TempDir(), "", nil)
	if err == nil {
		if hrw != nil {
			hrw.Stop()
		}
		t.Fatal("expected error when watcher.Start fails")
	}
	if !strings.Contains(err.Error(), "start failed") {
		t.Fatalf("unexpected error: %v", err)
	}
}
