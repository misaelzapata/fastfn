package process

import (
	"errors"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	"github.com/fsnotify/fsnotify"
)

func TestNewWatcher_ResolveSymlinkRoot(t *testing.T) {
	root := t.TempDir()
	linkPath := filepath.Join(t.TempDir(), "root-link")
	if err := os.Symlink(root, linkPath); err != nil {
		t.Skipf("symlink not supported in this environment: %v", err)
	}

	w, err := NewWatcher(linkPath, func(_ fsnotify.Event) {})
	if err != nil {
		t.Fatalf("new watcher failed: %v", err)
	}
	defer w.Stop()

	resolved, err := filepath.EvalSymlinks(linkPath)
	if err != nil {
		t.Fatalf("failed to resolve test symlink: %v", err)
	}
	if filepath.Clean(w.RootPath) != filepath.Clean(resolved) {
		t.Fatalf("expected watcher root to resolve symlink: got=%s want=%s", w.RootPath, resolved)
	}
}

func TestNewWatcher_AbsFallbackToRawRoot(t *testing.T) {
	oldAbs := watcherAbsFn
	oldEval := watcherEvalSymlinksFn
	defer func() {
		watcherAbsFn = oldAbs
		watcherEvalSymlinksFn = oldEval
	}()

	watcherAbsFn = func(string) (string, error) {
		return "", errors.New("abs failed")
	}
	watcherEvalSymlinksFn = func(string) (string, error) {
		return "", errors.New("no symlink")
	}

	w, err := NewWatcher("./relative-root", func(_ fsnotify.Event) {})
	if err != nil {
		t.Fatalf("new watcher failed: %v", err)
	}
	defer w.Stop()

	if w.RootPath != "relative-root" {
		t.Fatalf("expected cleaned raw root fallback, got %q", w.RootPath)
	}
}

func TestWatcherStart_RenameTriggersOnChange(t *testing.T) {
	root := t.TempDir()
	oldFile := filepath.Join(root, "old.js")
	newFile := filepath.Join(root, "new.js")
	if err := os.WriteFile(oldFile, []byte("module.exports=1;\n"), 0o644); err != nil {
		t.Fatalf("seed file write failed: %v", err)
	}

	var changes int32
	w, err := NewWatcher(root, func(_ fsnotify.Event) {
		atomic.AddInt32(&changes, 1)
	})
	if err != nil {
		t.Fatalf("new watcher failed: %v", err)
	}
	defer w.Stop()

	if err := w.Start(); err != nil {
		t.Fatalf("watcher start failed: %v", err)
	}

	if err := os.Rename(oldFile, newFile); err != nil {
		t.Fatalf("rename failed: %v", err)
	}

	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if atomic.LoadInt32(&changes) > 0 {
			return
		}
		time.Sleep(25 * time.Millisecond)
	}
	t.Fatal("expected onChange callback after rename event")
}

func TestWatcherAddRecursive_SkipsDirectoryOutsideRoot(t *testing.T) {
	root := t.TempDir()
	outside := t.TempDir()

	w, err := NewWatcher(root, func(_ fsnotify.Event) {})
	if err != nil {
		t.Fatalf("new watcher failed: %v", err)
	}
	defer w.Stop()

	if err := w.addRecursive(outside); err != nil {
		t.Fatalf("addRecursive outside root returned error: %v", err)
	}
}

func TestWatcherIsWithinRoot_RelErrorReturnsFalse(t *testing.T) {
	root := t.TempDir()

	oldRel := watcherRelFn
	defer func() { watcherRelFn = oldRel }()
	watcherRelFn = func(string, string) (string, error) {
		return "", errors.New("rel failed")
	}

	w, err := NewWatcher(root, func(_ fsnotify.Event) {})
	if err != nil {
		t.Fatalf("new watcher failed: %v", err)
	}
	defer w.Stop()

	if w.isWithinRoot(filepath.Join(root, "handler.js")) {
		t.Fatal("expected isWithinRoot to return false when filepath.Rel fails")
	}
}

func TestWatcherIsWithinRoot_ExactParentReturnsFalse(t *testing.T) {
	root := t.TempDir()
	childRoot := filepath.Join(root, "child")
	if err := os.MkdirAll(childRoot, 0o755); err != nil {
		t.Fatal(err)
	}

	w := &Watcher{RootPath: childRoot}
	if w.isWithinRoot(root) {
		t.Fatal("expected exact parent path to be outside root")
	}
}

func TestWatcherIsWithinRoot_TrueAndFalsePaths(t *testing.T) {
	root := t.TempDir()
	outside := t.TempDir()

	w, err := NewWatcher(root, func(_ fsnotify.Event) {})
	if err != nil {
		t.Fatalf("new watcher failed: %v", err)
	}
	defer w.Stop()

	if !w.isWithinRoot(filepath.Join(root, "nested", "handler.js")) {
		t.Fatal("expected nested file under root to be allowed")
	}
	if w.isWithinRoot(filepath.Join(outside, "handler.js")) {
		t.Fatal("expected outside file to be rejected")
	}
}

func TestWatcherIsWithinRoot_AbsFallbackUsesOriginalPath(t *testing.T) {
	root := t.TempDir()
	target := filepath.Join(root, "handler.js")

	oldAbs := watcherAbsFn
	oldRel := watcherRelFn
	oldEval := watcherEvalSymlinksFn
	defer func() {
		watcherAbsFn = oldAbs
		watcherRelFn = oldRel
		watcherEvalSymlinksFn = oldEval
	}()

	watcherAbsFn = func(string) (string, error) {
		return "", errors.New("abs failed")
	}
	watcherEvalSymlinksFn = func(path string) (string, error) {
		return "", errors.New("no symlink for " + path)
	}
	watcherRelFn = func(base, targetPath string) (string, error) {
		if base == root && targetPath == target {
			return ".", nil
		}
		return "..", nil
	}

	w, err := NewWatcher(root, func(_ fsnotify.Event) {})
	if err != nil {
		t.Fatalf("new watcher failed: %v", err)
	}
	defer w.Stop()

	w.RootPath = root
	if !w.isWithinRoot(target) {
		t.Fatal("expected original path fallback when Abs fails")
	}
}

func TestWatcherDepthExceedsLimit_Disabled(t *testing.T) {
	root := t.TempDir()

	oldMaxDepth := watcherMaxDepth
	defer func() { watcherMaxDepth = oldMaxDepth }()
	watcherMaxDepth = 0

	w, err := NewWatcher(root, func(_ fsnotify.Event) {})
	if err != nil {
		t.Fatalf("new watcher failed: %v", err)
	}
	defer w.Stop()

	deepPath := filepath.Join(root, "a", "b", "c", "d", "e")
	if w.depthExceedsLimit(deepPath) {
		t.Fatal("expected unlimited depth when watcherMaxDepth <= 0")
	}
}

func TestShouldIgnore_Patterns(t *testing.T) {
	root := t.TempDir()
	w, err := NewWatcher(root, func(_ fsnotify.Event) {})
	if err != nil {
		t.Fatalf("new watcher failed: %v", err)
	}
	defer w.Stop()

	tests := []struct {
		path    string
		ignored bool
	}{
		{path: filepath.Join(root, ".git", "config"), ignored: true},
		{path: filepath.Join(root, "node_modules", "pkg", "index.js"), ignored: true},
		{path: filepath.Join(root, "__pycache__", "mod.pyc"), ignored: true},
		{path: filepath.Join(root, ".DS_Store"), ignored: true},
		{path: filepath.Join(root, ".fastfn", "state"), ignored: true},
		{path: filepath.Join(root, ".rust-build", "out"), ignored: true},
		{path: filepath.Join(root, "file~"), ignored: true},
		{path: filepath.Join(root, ".hidden"), ignored: true},
		{path: filepath.Join(root, "handler.js"), ignored: false},
		{path: filepath.Join(root, "src", "main.py"), ignored: false},
	}

	for _, tc := range tests {
		t.Run(tc.path, func(t *testing.T) {
			got := w.shouldIgnore(tc.path)
			if got != tc.ignored {
				t.Fatalf("shouldIgnore(%q) = %v, want %v", tc.path, got, tc.ignored)
			}
		})
	}
}

func TestWatcherStart_WriteTriggersOnChange(t *testing.T) {
	root := t.TempDir()
	target := filepath.Join(root, "handler.js")
	if err := os.WriteFile(target, []byte("v1"), 0o644); err != nil {
		t.Fatalf("seed file: %v", err)
	}

	var changes int32
	w, err := NewWatcher(root, func(_ fsnotify.Event) {
		atomic.AddInt32(&changes, 1)
	})
	if err != nil {
		t.Fatalf("new watcher: %v", err)
	}
	defer w.Stop()

	if err := w.Start(); err != nil {
		t.Fatalf("start: %v", err)
	}

	if err := os.WriteFile(target, []byte("v2"), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}

	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if atomic.LoadInt32(&changes) > 0 {
			return
		}
		time.Sleep(25 * time.Millisecond)
	}
	t.Fatal("expected onChange callback after write event")
}

func TestWatcherStart_CreateTriggersOnChange(t *testing.T) {
	root := t.TempDir()

	var changes int32
	w, err := NewWatcher(root, func(_ fsnotify.Event) {
		atomic.AddInt32(&changes, 1)
	})
	if err != nil {
		t.Fatalf("new watcher: %v", err)
	}
	defer w.Stop()

	if err := w.Start(); err != nil {
		t.Fatalf("start: %v", err)
	}

	if err := os.WriteFile(filepath.Join(root, "new_file.js"), []byte("new"), 0o644); err != nil {
		t.Fatalf("create: %v", err)
	}

	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if atomic.LoadInt32(&changes) > 0 {
			return
		}
		time.Sleep(25 * time.Millisecond)
	}
	t.Fatal("expected onChange callback after create event")
}

func TestWatcherStart_RemoveTriggersOnChange(t *testing.T) {
	root := t.TempDir()
	target := filepath.Join(root, "remove_me.js")
	if err := os.WriteFile(target, []byte("bye"), 0o644); err != nil {
		t.Fatalf("seed file: %v", err)
	}

	var changes int32
	w, err := NewWatcher(root, func(_ fsnotify.Event) {
		atomic.AddInt32(&changes, 1)
	})
	if err != nil {
		t.Fatalf("new watcher: %v", err)
	}
	defer w.Stop()

	if err := w.Start(); err != nil {
		t.Fatalf("start: %v", err)
	}

	if err := os.Remove(target); err != nil {
		t.Fatalf("remove: %v", err)
	}

	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if atomic.LoadInt32(&changes) > 0 {
			return
		}
		time.Sleep(25 * time.Millisecond)
	}
	t.Fatal("expected onChange callback after remove event")
}

func TestWatcherStart_NewDirectoryRecursiveWatch(t *testing.T) {
	root := t.TempDir()

	var changes int32
	w, err := NewWatcher(root, func(_ fsnotify.Event) {
		atomic.AddInt32(&changes, 1)
	})
	if err != nil {
		t.Fatalf("new watcher: %v", err)
	}
	defer w.Stop()

	if err := w.Start(); err != nil {
		t.Fatalf("start: %v", err)
	}

	subDir := filepath.Join(root, "subdir")
	if err := os.Mkdir(subDir, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}

	time.Sleep(200 * time.Millisecond)

	if err := os.WriteFile(filepath.Join(subDir, "test.js"), []byte("test"), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}

	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if atomic.LoadInt32(&changes) >= 2 {
			return
		}
		time.Sleep(25 * time.Millisecond)
	}
	if atomic.LoadInt32(&changes) < 1 {
		t.Fatal("expected onChange callbacks for new directory and file creation")
	}
}

func TestWatcherStart_DeepDirectoriesAboveLimitIgnored(t *testing.T) {
	root := t.TempDir()
	deepDir := filepath.Join(root, "a", "b", "c")
	if err := os.MkdirAll(deepDir, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	target := filepath.Join(deepDir, "deep.js")
	if err := os.WriteFile(target, []byte("v1"), 0o644); err != nil {
		t.Fatalf("seed file: %v", err)
	}

	origMaxDepth := watcherMaxDepth
	watcherMaxDepth = 1
	defer func() { watcherMaxDepth = origMaxDepth }()

	var changes int32
	w, err := NewWatcher(root, func(_ fsnotify.Event) {
		atomic.AddInt32(&changes, 1)
	})
	if err != nil {
		t.Fatalf("new watcher: %v", err)
	}
	defer w.Stop()

	if err := w.Start(); err != nil {
		t.Fatalf("start: %v", err)
	}

	if err := os.WriteFile(target, []byte("v2"), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	time.Sleep(300 * time.Millisecond)
	if atomic.LoadInt32(&changes) != 0 {
		t.Fatalf("expected no callback for directories deeper than max depth, got %d", atomic.LoadInt32(&changes))
	}
}

func TestWatcherAddRecursive_SkipsResolvedPathsOutsideRoot(t *testing.T) {
	root := t.TempDir()
	outside := t.TempDir()
	link := filepath.Join(root, "escape")
	if err := os.Symlink(outside, link); err != nil {
		t.Skipf("symlink not supported in this environment: %v", err)
	}

	w, err := NewWatcher(root, func(_ fsnotify.Event) {})
	if err != nil {
		t.Fatalf("new watcher: %v", err)
	}
	defer w.Stop()

	if w.isWithinRoot(link) {
		t.Fatal("expected symlinked path outside root to be rejected")
	}
}

func TestWatcher_StopCleanup(t *testing.T) {
	root := t.TempDir()
	w, err := NewWatcher(root, func(_ fsnotify.Event) {})
	if err != nil {
		t.Fatalf("new watcher: %v", err)
	}

	if err := w.Start(); err != nil {
		t.Fatalf("start: %v", err)
	}

	w.Stop()

	if err := os.WriteFile(filepath.Join(root, "after_stop.js"), []byte("ok"), 0o644); err != nil {
		t.Fatalf("write after stop: %v", err)
	}
}

func TestWatcher_StopIsIdempotent(t *testing.T) {
	root := t.TempDir()
	w, err := NewWatcher(root, func(_ fsnotify.Event) {})
	if err != nil {
		t.Fatalf("new watcher: %v", err)
	}

	w.Stop()
	w.Stop()
}

func TestNewWatcher_NonSymlinkRoot(t *testing.T) {
	root := t.TempDir()
	w, err := NewWatcher(root, func(_ fsnotify.Event) {})
	if err != nil {
		t.Fatalf("new watcher failed: %v", err)
	}
	defer w.Stop()

	if w.RootPath != root {
		t.Fatalf("expected root path %q, got %q", root, w.RootPath)
	}
	if w.OnChange == nil {
		t.Fatal("expected OnChange to be set")
	}
	if len(w.Ignored) == 0 {
		t.Fatal("expected Ignored list to be populated")
	}
}

func TestAddRecursive_IgnoredDirSkipped(t *testing.T) {
	root := t.TempDir()
	gitDir := filepath.Join(root, ".git")
	if err := os.MkdirAll(filepath.Join(gitDir, "objects"), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	srcDir := filepath.Join(root, "src")
	if err := os.MkdirAll(srcDir, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}

	var changes int32
	w, err := NewWatcher(root, func(_ fsnotify.Event) {
		atomic.AddInt32(&changes, 1)
	})
	if err != nil {
		t.Fatalf("new watcher: %v", err)
	}
	defer w.Stop()

	if err := w.Start(); err != nil {
		t.Fatalf("start: %v", err)
	}

	if err := os.WriteFile(filepath.Join(gitDir, "test"), []byte("x"), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	time.Sleep(200 * time.Millisecond)

	if err := os.WriteFile(filepath.Join(srcDir, "main.js"), []byte("x"), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}

	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if atomic.LoadInt32(&changes) > 0 {
			return
		}
		time.Sleep(25 * time.Millisecond)
	}
	t.Fatal("expected onChange for non-ignored file write")
}

func TestShouldIgnore_BaseMatchInSecondLoop(t *testing.T) {
	root := t.TempDir()
	w, err := NewWatcher(root, func(_ fsnotify.Event) {})
	if err != nil {
		t.Fatalf("new watcher: %v", err)
	}
	defer w.Stop()

	if !w.shouldIgnore(filepath.Join(root, ".DS_Store")) {
		t.Fatal("expected .DS_Store to be ignored via base name match")
	}
	if !w.shouldIgnore(filepath.Join(root, "node_modules", "pkg.js")) {
		t.Fatal("expected node_modules path to be ignored via component match")
	}
}

func TestWatcher_HandleError(t *testing.T) {
	root := t.TempDir()
	w, err := NewWatcher(root, func(_ fsnotify.Event) {})
	if err != nil {
		t.Fatalf("new watcher: %v", err)
	}
	defer w.Stop()

	// Directly call handleError to deterministically cover the log.Printf path.
	w.handleError(errors.New("test error"))
}

func TestWatcher_HandleEvent_Ignored(t *testing.T) {
	root := t.TempDir()
	var called bool
	w, err := NewWatcher(root, func(_ fsnotify.Event) { called = true })
	if err != nil {
		t.Fatalf("new watcher: %v", err)
	}
	defer w.Stop()

	w.handleEvent(fsnotify.Event{Name: filepath.Join(root, ".hidden"), Op: fsnotify.Write})
	if called {
		t.Fatal("OnChange should not be called for ignored events")
	}
}

func TestWatcher_HandleEvent_Write(t *testing.T) {
	root := t.TempDir()
	var called bool
	w, err := NewWatcher(root, func(_ fsnotify.Event) { called = true })
	if err != nil {
		t.Fatalf("new watcher: %v", err)
	}
	defer w.Stop()

	w.handleEvent(fsnotify.Event{Name: filepath.Join(root, "handler.js"), Op: fsnotify.Write})
	if !called {
		t.Fatal("OnChange should be called for write events")
	}
}

func TestWatcher_HandleEvent_NewDirectorySchedulesFollowUp(t *testing.T) {
	root := t.TempDir()
	subDir := filepath.Join(root, "beta")
	if err := os.Mkdir(subDir, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}

	origDelay := newDirectoryRescanDelay
	newDirectoryRescanDelay = 10 * time.Millisecond
	defer func() { newDirectoryRescanDelay = origDelay }()

	var changes int32
	w, err := NewWatcher(root, func(_ fsnotify.Event) {
		atomic.AddInt32(&changes, 1)
	})
	if err != nil {
		t.Fatalf("new watcher: %v", err)
	}
	defer w.Stop()

	w.handleEvent(fsnotify.Event{Name: subDir, Op: fsnotify.Create})

	deadline := time.Now().Add(500 * time.Millisecond)
	for time.Now().Before(deadline) {
		if atomic.LoadInt32(&changes) >= 2 {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}

	t.Fatalf("expected directory create to trigger immediate + follow-up change, got %d", atomic.LoadInt32(&changes))
}

func TestWatcher_StopCancelsPendingDirectoryRescan(t *testing.T) {
	root := t.TempDir()
	subDir := filepath.Join(root, "beta")
	if err := os.Mkdir(subDir, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}

	origDelay := newDirectoryRescanDelay
	newDirectoryRescanDelay = 50 * time.Millisecond
	defer func() { newDirectoryRescanDelay = origDelay }()

	var changes int32
	w, err := NewWatcher(root, func(_ fsnotify.Event) {
		atomic.AddInt32(&changes, 1)
	})
	if err != nil {
		t.Fatalf("new watcher: %v", err)
	}

	w.handleEvent(fsnotify.Event{Name: subDir, Op: fsnotify.Create})
	w.Stop()

	time.Sleep(80 * time.Millisecond)

	if got := atomic.LoadInt32(&changes); got != 1 {
		t.Fatalf("expected pending follow-up rescan to be canceled on Stop, got %d callbacks", got)
	}
}

func TestWatcher_ScheduleDirectoryRescan_DefaultDelayForNonPositiveValue(t *testing.T) {
	root := t.TempDir()
	origDelay := newDirectoryRescanDelay
	newDirectoryRescanDelay = 0
	t.Cleanup(func() { newDirectoryRescanDelay = origDelay })

	var changes int32
	w, err := NewWatcher(root, func(_ fsnotify.Event) {
		atomic.AddInt32(&changes, 1)
	})
	if err != nil {
		t.Fatalf("new watcher: %v", err)
	}
	defer w.Stop()

	w.scheduleDirectoryRescan(root)

	deadline := time.Now().Add(1 * time.Second)
	for time.Now().Before(deadline) {
		if atomic.LoadInt32(&changes) > 0 {
			return
		}
		time.Sleep(25 * time.Millisecond)
	}
	t.Fatal("expected directory rescan callback with default delay fallback")
}

func TestWatcher_ScheduleDirectoryRescan_IgnoresHiddenMissingAndNonDirectoryPaths(t *testing.T) {
	root := t.TempDir()
	hiddenDir := filepath.Join(root, ".hidden")
	filePath := filepath.Join(root, "handler.js")
	if err := os.MkdirAll(hiddenDir, 0o755); err != nil {
		t.Fatalf("mkdir hidden: %v", err)
	}
	if err := os.WriteFile(filePath, []byte("ok"), 0o644); err != nil {
		t.Fatalf("write file: %v", err)
	}

	origDelay := newDirectoryRescanDelay
	newDirectoryRescanDelay = 10 * time.Millisecond
	t.Cleanup(func() { newDirectoryRescanDelay = origDelay })

	var changes int32
	w, err := NewWatcher(root, func(_ fsnotify.Event) {
		atomic.AddInt32(&changes, 1)
	})
	if err != nil {
		t.Fatalf("new watcher: %v", err)
	}
	defer w.Stop()

	w.scheduleDirectoryRescan(hiddenDir)
	w.scheduleDirectoryRescan(filepath.Join(root, "missing"))
	w.scheduleDirectoryRescan(filePath)
	time.Sleep(100 * time.Millisecond)

	if got := atomic.LoadInt32(&changes); got != 0 {
		t.Fatalf("expected ignored/missing/non-dir rescan targets to be skipped, got %d callbacks", got)
	}
}

func TestWatcher_ScheduleDirectoryRescan_StopAfterStatPreventsCallback(t *testing.T) {
	root := t.TempDir()
	origDelay := newDirectoryRescanDelay
	origStat := watcherStatFn
	newDirectoryRescanDelay = 10 * time.Millisecond
	t.Cleanup(func() {
		newDirectoryRescanDelay = origDelay
		watcherStatFn = origStat
	})

	var changes int32
	w, err := NewWatcher(root, func(_ fsnotify.Event) {
		atomic.AddInt32(&changes, 1)
	})
	if err != nil {
		t.Fatalf("new watcher: %v", err)
	}
	defer w.Stop()

	closed := false
	watcherStatFn = func(path string) (os.FileInfo, error) {
		info, err := os.Stat(path)
		if !closed {
			close(w.stop)
			closed = true
		}
		return info, err
	}

	w.scheduleDirectoryRescan(root)
	time.Sleep(100 * time.Millisecond)

	if got := atomic.LoadInt32(&changes); got != 0 {
		t.Fatalf("expected closed watcher stop channel to suppress callback, got %d", got)
	}
}

func TestWatcher_HandleEvent_NonMatchingOp(t *testing.T) {
	root := t.TempDir()
	var called bool
	w, err := NewWatcher(root, func(_ fsnotify.Event) { called = true })
	if err != nil {
		t.Fatalf("new watcher: %v", err)
	}
	defer w.Stop()

	w.handleEvent(fsnotify.Event{Name: filepath.Join(root, "handler.js"), Op: fsnotify.Chmod})
	if called {
		t.Fatal("OnChange should not be called for chmod-only events")
	}
}

func TestWatcher_DrainEvents(t *testing.T) {
	root := t.TempDir()
	var eventCount int32
	w, err := NewWatcher(root, func(_ fsnotify.Event) {
		atomic.AddInt32(&eventCount, 1)
	})
	if err != nil {
		t.Fatalf("new watcher: %v", err)
	}

	// Must add to WaitGroup before calling drainEvents (normally Start does this).
	w.wg.Add(1)
	done := make(chan struct{})
	go func() {
		w.drainEvents()
		close(done)
	}()

	w.watcher.Events <- fsnotify.Event{Name: filepath.Join(root, "test.js"), Op: fsnotify.Write}
	w.watcher.Events <- fsnotify.Event{Name: filepath.Join(root, "test2.js"), Op: fsnotify.Create}
	time.Sleep(50 * time.Millisecond)

	w.watcher.Close()

	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("drainEvents did not exit after channel close")
	}

	if atomic.LoadInt32(&eventCount) < 2 {
		t.Fatalf("expected at least 2 events, got %d", atomic.LoadInt32(&eventCount))
	}
}

func TestWatcher_DrainErrors(t *testing.T) {
	root := t.TempDir()
	w, err := NewWatcher(root, func(_ fsnotify.Event) {})
	if err != nil {
		t.Fatalf("new watcher: %v", err)
	}

	w.wg.Add(1)
	done := make(chan struct{})
	go func() {
		w.drainErrors()
		close(done)
	}()

	w.watcher.Errors <- errors.New("test error 1")
	w.watcher.Errors <- errors.New("test error 2")
	time.Sleep(50 * time.Millisecond)

	w.watcher.Close()

	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("drainErrors did not exit after channel close")
	}
}

func TestAddRecursive_NonDirIgnored(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "backup~"), []byte("x"), 0644); err != nil {
		t.Fatalf("write: %v", err)
	}
	if err := os.WriteFile(filepath.Join(root, "handler.js"), []byte("x"), 0644); err != nil {
		t.Fatalf("write: %v", err)
	}

	w, err := NewWatcher(root, func(_ fsnotify.Event) {})
	if err != nil {
		t.Fatalf("new watcher: %v", err)
	}
	defer w.Stop()

	if err := w.Start(); err != nil {
		t.Fatalf("start: %v", err)
	}
}

func TestShouldIgnore_ReturnFalse(t *testing.T) {
	root := t.TempDir()
	w, err := NewWatcher(root, func(_ fsnotify.Event) {})
	if err != nil {
		t.Fatalf("new watcher: %v", err)
	}
	defer w.Stop()

	if w.shouldIgnore(filepath.Join(root, "src", "handler.js")) {
		t.Fatal("expected normal file to NOT be ignored")
	}
	if w.shouldIgnore(filepath.Join(root, "main.py")) {
		t.Fatal("expected main.py to NOT be ignored")
	}
}

func TestShouldIgnore_TildeAndHiddenFiles(t *testing.T) {
	root := t.TempDir()
	w, err := NewWatcher(root, func(_ fsnotify.Event) {})
	if err != nil {
		t.Fatalf("new watcher: %v", err)
	}
	defer w.Stop()

	if !w.shouldIgnore(filepath.Join(root, "backup~")) {
		t.Fatal("expected tilde file to be ignored")
	}
	if !w.shouldIgnore(filepath.Join(root, ".env")) {
		t.Fatal("expected hidden file to be ignored")
	}
	if w.shouldIgnore(filepath.Join(root, "index.js")) {
		t.Fatal("expected normal file to NOT be ignored")
	}
}

func TestNewWatcher_FsnotifyError(t *testing.T) {
	origNewWatcher := fsnotifyNewWatcherFn
	defer func() { fsnotifyNewWatcherFn = origNewWatcher }()

	fsnotifyNewWatcherFn = func() (*fsnotify.Watcher, error) {
		return nil, errors.New("injected fsnotify error")
	}

	_, err := NewWatcher(t.TempDir(), func(_ fsnotify.Event) {})
	if err == nil {
		t.Fatal("expected error when fsnotify.NewWatcher fails")
	}
	if err.Error() != "injected fsnotify error" {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestWatcherStart_AddRecursiveNonExistentPath(t *testing.T) {
	root := t.TempDir()
	w, err := NewWatcher(root, func(_ fsnotify.Event) {})
	if err != nil {
		t.Fatalf("new watcher: %v", err)
	}
	defer w.Stop()

	w.RootPath = filepath.Join(root, "does-not-exist")
	err = w.Start()
	if err != nil {
		t.Fatalf("Start() should not error for non-existent path: %v", err)
	}
}

func TestWatcherStart_IgnoredEventInGoroutine(t *testing.T) {
	root := t.TempDir()

	var normalChanges int32
	w, err := NewWatcher(root, func(ev fsnotify.Event) {
		atomic.AddInt32(&normalChanges, 1)
	})
	if err != nil {
		t.Fatalf("new watcher: %v", err)
	}
	defer w.Stop()

	if err := w.Start(); err != nil {
		t.Fatalf("start: %v", err)
	}

	if err := os.WriteFile(filepath.Join(root, ".hidden_file"), []byte("x"), 0o644); err != nil {
		t.Fatalf("write hidden: %v", err)
	}
	time.Sleep(200 * time.Millisecond)

	if err := os.WriteFile(filepath.Join(root, "normal.js"), []byte("x"), 0o644); err != nil {
		t.Fatalf("write normal: %v", err)
	}

	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if atomic.LoadInt32(&normalChanges) > 0 {
			return
		}
		time.Sleep(25 * time.Millisecond)
	}
	t.Fatal("expected onChange callback for normal file")
}
