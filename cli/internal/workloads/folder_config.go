package workloads

import (
	"encoding/json"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

func LoadConfigured(projectDir, fnDir string, global map[string]any) (Config, bool, error) {
	var combined Config
	seenApps := map[string]string{}
	seenServices := map[string]string{}

	if len(global) > 0 {
		globalCfg, _, err := NormalizeConfigMap(projectDir, global)
		if err != nil {
			return combined, false, err
		}
		if err := mergeConfig(&combined, globalCfg, seenApps, seenServices); err != nil {
			return combined, false, err
		}
	}

	root := strings.TrimSpace(fnDir)
	if root == "" {
		return combined, combined.HasWorkloads(), nil
	}
	info, err := os.Stat(root)
	if err != nil || !info.IsDir() {
		return combined, combined.HasWorkloads(), nil
	}

	folderFiles, err := discoverFolderConfigFiles(root)
	if err != nil {
		return combined, false, err
	}
	for _, configPath := range folderFiles {
		cfg, ok, err := loadFolderConfigFile(configPath)
		if err != nil {
			return combined, false, err
		}
		if !ok {
			continue
		}
		if err := mergeConfig(&combined, cfg, seenApps, seenServices); err != nil {
			return combined, false, err
		}
	}

	return combined, combined.HasWorkloads(), nil
}

func discoverFolderConfigFiles(root string) ([]string, error) {
	files := []string{}
	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if d.IsDir() {
			name := d.Name()
			if name == ".git" || name == ".fastfn" {
				return filepath.SkipDir
			}
			return nil
		}
		if d.Name() == "fn.config.json" {
			files = append(files, path)
		}
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("scan folder configs: %w", err)
	}
	sort.Strings(files)
	return files, nil
}

func loadFolderConfigFile(path string) (Config, bool, error) {
	var raw map[string]any
	data, err := os.ReadFile(path)
	if err != nil {
		return Config{}, false, fmt.Errorf("read %s: %w", path, err)
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		return Config{}, false, fmt.Errorf("parse %s: %w", path, err)
	}
	return normalizeConfigMap(filepath.Dir(path), filepath.Base(filepath.Dir(path)), raw)
}

func mergeConfig(dst *Config, src Config, seenApps, seenServices map[string]string) error {
	for _, spec := range src.Apps {
		key := strings.ToLower(strings.TrimSpace(spec.Name))
		if previous, ok := seenApps[key]; ok {
			return fmt.Errorf("duplicate app %q in %s and %s", spec.Name, previous, spec.ScopeDir)
		}
		seenApps[key] = spec.ScopeDir
		dst.Apps = append(dst.Apps, spec)
	}
	for _, spec := range src.Services {
		key := strings.ToLower(strings.TrimSpace(spec.Name))
		if previous, ok := seenServices[key]; ok {
			return fmt.Errorf("duplicate service %q in %s and %s", spec.Name, previous, spec.ScopeDir)
		}
		seenServices[key] = spec.ScopeDir
		dst.Services = append(dst.Services, spec)
	}
	return nil
}
