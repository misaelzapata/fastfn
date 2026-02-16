package process

import (
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
