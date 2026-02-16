package process

import (
	"io/fs"
	"log"
	"path/filepath"
	"strings"

	"github.com/fsnotify/fsnotify"
)

// Watcher monitors a directory for changes and triggers a callback
type Watcher struct {
	RootPath string
	Ignored  []string
	OnChange func(event fsnotify.Event)

	watcher *fsnotify.Watcher
	stop    chan struct{}
}

func NewWatcher(root string, onChange func(fsnotify.Event)) (*Watcher, error) {
	w, err := fsnotify.NewWatcher()
	if err != nil {
		return nil, err
	}

	resolvedRoot := root
	if real, realErr := filepath.EvalSymlinks(root); realErr == nil && real != "" {
		resolvedRoot = real
	}

	return &Watcher{
		RootPath: resolvedRoot,
		Ignored:  []string{".git", "__pycache__", "node_modules", ".DS_Store"},
		OnChange: onChange,
		watcher:  w,
		stop:     make(chan struct{}),
	}, nil
}

func (w *Watcher) Start() error {
	err := w.addRecursive(w.RootPath)
	if err != nil {
		return err
	}

	go func() {
		for {
			select {
			case event, ok := <-w.watcher.Events:
				if !ok {
					return
				}
				if w.shouldIgnore(event.Name) {
					continue
				}

				// Handle new directory creation for recursive watch
				if event.Op&fsnotify.Create == fsnotify.Create {
					_ = w.addRecursive(event.Name)
				}

				if event.Op&fsnotify.Write == fsnotify.Write ||
					event.Op&fsnotify.Create == fsnotify.Create ||
					event.Op&fsnotify.Remove == fsnotify.Remove ||
					event.Op&fsnotify.Rename == fsnotify.Rename {

					// Simple debouncing could happen here or in the callback
					w.OnChange(event)
				}

			case err, ok := <-w.watcher.Errors:
				if !ok {
					return
				}
				log.Printf("Watcher error: %v", err)
			case <-w.stop:
				return
			}
		}
	}()

	return nil
}

func (w *Watcher) Stop() {
	close(w.stop)
	w.watcher.Close()
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
			if addErr := w.watcher.Add(current); addErr != nil {
				log.Printf("watch add failed for %s: %v", current, addErr)
			}
		}
		return nil
	})
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
	for _, ign := range w.Ignored {
		if base == ign {
			return true
		}
	}
	// Ignore temporary files
	if strings.HasSuffix(path, "~") || strings.HasPrefix(base, ".") {
		return true
	}
	return false
}
