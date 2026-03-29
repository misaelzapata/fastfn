package process

import (
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/fsnotify/fsnotify"
)

// Injectable for testing
var fsnotifyNewWatcherFn = fsnotify.NewWatcher
var watcherStatFn = os.Stat
var watcherEvalSymlinksFn = filepath.EvalSymlinks
var watcherAbsFn = filepath.Abs
var watcherRelFn = filepath.Rel

var newDirectoryRescanDelay = 250 * time.Millisecond
var watcherMaxDepth = 12

// Watcher monitors a directory for changes and triggers a callback
type Watcher struct {
	RootPath string
	Ignored  []string
	OnChange func(event fsnotify.Event)

	watcher *fsnotify.Watcher
	stop    chan struct{}
	wg      sync.WaitGroup
}

func NewWatcher(root string, onChange func(fsnotify.Event)) (*Watcher, error) {
	w, err := fsnotifyNewWatcherFn()
	if err != nil {
		return nil, err
	}

	resolvedRoot, absErr := watcherAbsFn(root)
	if absErr != nil {
		resolvedRoot = root
	}
	if real, realErr := watcherEvalSymlinksFn(root); realErr == nil && real != "" {
		resolvedRoot = real
	}
	resolvedRoot = filepath.Clean(resolvedRoot)

	return &Watcher{
		RootPath: resolvedRoot,
		// Ignore internal/runtime-generated paths to avoid hot-reload feedback loops.
		Ignored:  []string{".git", "__pycache__", "node_modules", ".DS_Store", ".fastfn", ".rust-build"},
		OnChange: onChange,
		watcher:  w,
		stop:     make(chan struct{}),
	}, nil
}

func (w *Watcher) Start() error {
	_ = w.addRecursive(w.RootPath)

	w.wg.Add(2)
	go w.drainEvents()
	go w.drainErrors()

	return nil
}

func (w *Watcher) drainEvents() {
	defer w.wg.Done()
	for event := range w.watcher.Events {
		w.handleEvent(event)
	}
}

func (w *Watcher) drainErrors() {
	defer w.wg.Done()
	for err := range w.watcher.Errors {
		w.handleError(err)
	}
}

func (w *Watcher) handleEvent(event fsnotify.Event) {
	if w.shouldIgnore(event.Name) {
		return
	}

	// Handle new directory creation for recursive watch
	if event.Op&fsnotify.Create == fsnotify.Create {
		_ = w.addRecursive(event.Name)
		if info, err := watcherStatFn(event.Name); err == nil && info.IsDir() {
			w.scheduleDirectoryRescan(event.Name)
		}
	}

	if event.Op&fsnotify.Write == fsnotify.Write ||
		event.Op&fsnotify.Create == fsnotify.Create ||
		event.Op&fsnotify.Remove == fsnotify.Remove ||
		event.Op&fsnotify.Rename == fsnotify.Rename {
		w.OnChange(event)
	}
}

func (w *Watcher) handleError(err error) {
	log.Printf("Watcher error: %v", err)
}

func (w *Watcher) Stop() {
	select {
	case <-w.stop:
	default:
		close(w.stop)
	}
	w.watcher.Close()
	w.wg.Wait()
}

func (w *Watcher) scheduleDirectoryRescan(path string) {
	delay := newDirectoryRescanDelay
	if delay <= 0 {
		delay = 250 * time.Millisecond
	}

	w.wg.Add(1)
	go func() {
		defer w.wg.Done()

		timer := time.NewTimer(delay)
		defer timer.Stop()

		select {
		case <-timer.C:
		case <-w.stop:
			return
		}

		if w.shouldIgnore(path) {
			return
		}
		info, err := watcherStatFn(path)
		if err != nil || !info.IsDir() {
			return
		}

		select {
		case <-w.stop:
			return
		default:
		}

		w.OnChange(fsnotify.Event{Name: path, Op: fsnotify.Create})
	}()
}

func (w *Watcher) addRecursive(path string) error {
	return filepath.WalkDir(path, func(current string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if w.shouldIgnore(current) {
			if d != nil && d.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		if d != nil && d.IsDir() {
			if !w.isWithinRoot(current) {
				return filepath.SkipDir
			}
			if w.depthExceedsLimit(current) {
				return filepath.SkipDir
			}
			if addErr := w.watcher.Add(current); addErr != nil {
				log.Printf("watch add failed for %s: %v", current, addErr)
			}
		}
		return nil
	})
}

func (w *Watcher) isWithinRoot(path string) bool {
	absPath, err := watcherAbsFn(path)
	if err != nil {
		absPath = path
	}
	if real, realErr := watcherEvalSymlinksFn(absPath); realErr == nil && real != "" {
		absPath = real
	}
	rel, err := watcherRelFn(w.RootPath, absPath)
	if err != nil {
		return false
	}
	return rel == "." || (!strings.HasPrefix(rel, ".."+string(filepath.Separator)) && rel != "..")
}

func (w *Watcher) depthExceedsLimit(path string) bool {
	if watcherMaxDepth <= 0 {
		return false
	}
	rel, err := watcherRelFn(w.RootPath, path)
	if err != nil || rel == "." {
		return false
	}
	depth := 0
	for _, part := range strings.Split(filepath.Clean(rel), string(filepath.Separator)) {
		if part != "" && part != "." {
			depth++
		}
	}
	return depth > watcherMaxDepth
}

func (w *Watcher) shouldIgnore(path string) bool {
	clean := filepath.Clean(path)
	base := filepath.Base(clean)
	for _, part := range strings.Split(clean, string(filepath.Separator)) {
		for _, ign := range w.Ignored {
			if part == ign {
				return true
			}
		}
	}
	// Ignore temporary files
	if strings.HasSuffix(path, "~") || strings.HasPrefix(base, ".") {
		return true
	}
	return false
}
