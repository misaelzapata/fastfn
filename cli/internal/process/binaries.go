package process

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

type binaryVersion struct {
	Major int
	Minor int
	Patch int
}

type binarySpec struct {
	Key               string
	Label             string
	EnvVar            string
	DefaultCandidates []string
	MinVersion        *binaryVersion
	VersionArgs       []string
	VersionParser     func(string) (binaryVersion, error)
}

type BinaryResolution struct {
	Key     string
	Label   string
	EnvVar  string
	Command string
	Path    string
	Version string
}

var (
	errBinaryNotFound = errors.New("binary not found")

	binaryLookPathFn = func(file string) (string, error) {
		return lookPathFn(file)
	}
	binaryOutputFn   = func(command string, args ...string) (string, error) {
		out, err := exec.Command(command, args...).CombinedOutput()
		return strings.TrimSpace(string(out)), err
	}
)

var binarySpecs = map[string]binarySpec{
	"cargo": {
		Key:               "cargo",
		Label:             "Cargo",
		EnvVar:            "FN_CARGO_BIN",
		DefaultCandidates: []string{"cargo"},
	},
	"composer": {
		Key:               "composer",
		Label:             "Composer",
		EnvVar:            "FN_COMPOSER_BIN",
		DefaultCandidates: []string{"composer"},
	},
	"docker": {
		Key:               "docker",
		Label:             "Docker",
		EnvVar:            "FN_DOCKER_BIN",
		DefaultCandidates: []string{"docker"},
	},
	"go": {
		Key:               "go",
		Label:             "Go",
		EnvVar:            "FN_GO_BIN",
		DefaultCandidates: []string{"go"},
		MinVersion:        &binaryVersion{Major: 1, Minor: 21},
		VersionArgs:       []string{"version"},
		VersionParser:     parseGoVersion,
	},
	"node": {
		Key:               "node",
		Label:             "Node.js",
		EnvVar:            "FN_NODE_BIN",
		DefaultCandidates: []string{"node"},
		MinVersion:        &binaryVersion{Major: 18},
		VersionArgs:       []string{"--version"},
		VersionParser:     parseNodeVersion,
	},
	"npm": {
		Key:               "npm",
		Label:             "npm",
		EnvVar:            "FN_NPM_BIN",
		DefaultCandidates: []string{"npm"},
	},
	"openresty": {
		Key:               "openresty",
		Label:             "OpenResty",
		EnvVar:            "FN_OPENRESTY_BIN",
		DefaultCandidates: []string{"openresty"},
	},
	"php": {
		Key:               "php",
		Label:             "PHP",
		EnvVar:            "FN_PHP_BIN",
		DefaultCandidates: []string{"php"},
		MinVersion:        &binaryVersion{Major: 8},
		VersionArgs:       []string{"-r", "echo PHP_MAJOR_VERSION.'.'.PHP_MINOR_VERSION.'.'.PHP_RELEASE_VERSION;"},
		VersionParser:     parseSimpleVersion,
	},
	"python": {
		Key:               "python",
		Label:             "Python",
		EnvVar:            "FN_PYTHON_BIN",
		DefaultCandidates: []string{"python3", "python"},
		MinVersion:        &binaryVersion{Major: 3, Minor: 10},
		VersionArgs:       []string{"-c", "import sys; print('.'.join(str(x) for x in sys.version_info[:3]))"},
		VersionParser:     parseSimpleVersion,
	},
}

var binaryConfigEnvVars = func() map[string]string {
	out := map[string]string{}
	for key, spec := range binarySpecs {
		out[key] = spec.EnvVar
	}
	return out
}()

var binaryConfigOrder = []string{"openresty", "docker", "python", "node", "npm", "php", "composer", "cargo", "go"}

func BinaryEnvVarName(key string) (string, bool) {
	spec, ok := binarySpecs[strings.ToLower(strings.TrimSpace(key))]
	if !ok {
		return "", false
	}
	return spec.EnvVar, true
}

func BinarySpecKeys() []string {
	keys := make([]string, 0, len(binarySpecs))
	for _, key := range binaryConfigOrder {
		if _, ok := binarySpecs[key]; ok {
			keys = append(keys, key)
		}
	}
	return keys
}

func NormalizeBinaryConfigValue(raw any) (map[string]string, bool) {
	if raw == nil {
		return nil, false
	}
	if s, ok := raw.(string); ok {
		parsed, err := ParseBinaryAssignments(s)
		if err != nil || len(parsed) == 0 {
			return nil, false
		}
		return parsed, true
	}

	var source map[string]any
	switch typed := raw.(type) {
	case map[string]any:
		source = typed
	case map[any]any:
		source = map[string]any{}
		for key, value := range typed {
			source[strings.TrimSpace(fmt.Sprint(key))] = value
		}
	default:
		return nil, false
	}

	if len(source) == 0 {
		return nil, false
	}

	out := map[string]string{}
	for key, value := range source {
		normalizedKey := strings.ToLower(strings.TrimSpace(key))
		envVar, ok := binaryConfigEnvVars[normalizedKey]
		if !ok {
			continue
		}
		candidate := strings.TrimSpace(fmt.Sprint(value))
		if candidate == "" {
			continue
		}
		out[envVar] = candidate
	}
	if len(out) == 0 {
		return nil, false
	}
	return out, true
}

func ParseBinaryAssignments(raw string) (map[string]string, error) {
	out := map[string]string{}
	for _, chunk := range strings.Split(raw, ",") {
		part := strings.TrimSpace(chunk)
		if part == "" {
			continue
		}
		pieces := strings.SplitN(part, "=", 2)
		if len(pieces) != 2 {
			return nil, fmt.Errorf("invalid runtime-binaries entry %q (expected name=command)", part)
		}
		key := strings.ToLower(strings.TrimSpace(pieces[0]))
		envVar, ok := binaryConfigEnvVars[key]
		if !ok {
			return nil, fmt.Errorf("unknown runtime-binaries key %q", key)
		}
		value := strings.TrimSpace(pieces[1])
		if value == "" {
			return nil, fmt.Errorf("runtime-binaries entry %q has empty command", part)
		}
		out[envVar] = value
	}
	return out, nil
}

func ResolveConfiguredBinary(key string) (BinaryResolution, error) {
	spec, ok := binarySpecs[strings.ToLower(strings.TrimSpace(key))]
	if !ok {
		return BinaryResolution{}, fmt.Errorf("unknown binary key %q", key)
	}
	if configured := strings.TrimSpace(os.Getenv(spec.EnvVar)); configured != "" {
		resolution, err := resolveBinaryCandidate(spec, configured)
		if err != nil {
			return BinaryResolution{}, fmt.Errorf("%s override %s=%q is invalid: %w", spec.Label, spec.EnvVar, configured, err)
		}
		return resolution, nil
	}
	for _, candidate := range spec.DefaultCandidates {
		resolution, err := resolveBinaryCandidate(spec, candidate)
		if err == nil {
			return resolution, nil
		}
	}
	return BinaryResolution{}, fmt.Errorf("%s not found or incompatible; set %s to a compatible executable", spec.Label, spec.EnvVar)
}

func BinaryConfiguredCommand(key string) string {
	spec, ok := binarySpecs[strings.ToLower(strings.TrimSpace(key))]
	if !ok {
		return ""
	}
	if configured := strings.TrimSpace(os.Getenv(spec.EnvVar)); configured != "" {
		return configured
	}
	if len(spec.DefaultCandidates) == 0 {
		return ""
	}
	return spec.DefaultCandidates[0]
}

func BinaryKeysSummary() string {
	parts := make([]string, 0, len(binarySpecs))
	for _, key := range BinarySpecKeys() {
		spec := binarySpecs[key]
		parts = append(parts, fmt.Sprintf("%s=%s", key, spec.EnvVar))
	}
	return strings.Join(parts, ", ")
}

func resolveBinaryCandidate(spec binarySpec, command string) (BinaryResolution, error) {
	path, err := binaryLookPathFn(command)
	if err != nil {
		return BinaryResolution{}, errBinaryNotFound
	}
	version := ""
	if spec.VersionParser != nil && len(spec.VersionArgs) > 0 {
		rawVersion, probeErr := binaryOutputFn(path, spec.VersionArgs...)
		if probeErr != nil {
			return BinaryResolution{}, fmt.Errorf("version probe failed: %w", probeErr)
		}
		parsed, parseErr := spec.VersionParser(rawVersion)
		if parseErr != nil {
			return BinaryResolution{}, fmt.Errorf("could not parse version from %q: %w", rawVersion, parseErr)
		}
		if spec.MinVersion != nil && compareBinaryVersion(parsed, *spec.MinVersion) < 0 {
			return BinaryResolution{}, fmt.Errorf("requires >= %s, got %s", formatBinaryVersion(*spec.MinVersion), formatBinaryVersion(parsed))
		}
		version = formatBinaryVersion(parsed)
	}
	return BinaryResolution{
		Key:     spec.Key,
		Label:   spec.Label,
		EnvVar:  spec.EnvVar,
		Command: command,
		Path:    path,
		Version: version,
	}, nil
}

func compareBinaryVersion(left, right binaryVersion) int {
	if left.Major != right.Major {
		return left.Major - right.Major
	}
	if left.Minor != right.Minor {
		return left.Minor - right.Minor
	}
	return left.Patch - right.Patch
}

func formatBinaryVersion(v binaryVersion) string {
	if v.Patch > 0 {
		return fmt.Sprintf("%d.%d.%d", v.Major, v.Minor, v.Patch)
	}
	return fmt.Sprintf("%d.%d", v.Major, v.Minor)
}

var simpleVersionPattern = regexp.MustCompile(`(\d+)\.(\d+)(?:\.(\d+))?`)
var goVersionPattern = regexp.MustCompile(`\bgo(\d+)\.(\d+)(?:\.(\d+))?\b`)
var nodeVersionPattern = regexp.MustCompile(`v?(\d+)\.(\d+)(?:\.(\d+))?`)

func parseSimpleVersion(raw string) (binaryVersion, error) {
	return parseVersionWithPattern(raw, simpleVersionPattern)
}

func parseNodeVersion(raw string) (binaryVersion, error) {
	return parseVersionWithPattern(raw, nodeVersionPattern)
}

func parseGoVersion(raw string) (binaryVersion, error) {
	return parseVersionWithPattern(raw, goVersionPattern)
}

func parseVersionWithPattern(raw string, pattern *regexp.Regexp) (binaryVersion, error) {
	match := pattern.FindStringSubmatch(strings.TrimSpace(raw))
	if len(match) == 0 {
		return binaryVersion{}, fmt.Errorf("no semantic version found")
	}
	parts := []int{0, 0, 0}
	for idx := 1; idx <= 3 && idx < len(match); idx++ {
		if strings.TrimSpace(match[idx]) == "" {
			continue
		}
		value, err := strconv.Atoi(match[idx])
		if err != nil {
			return binaryVersion{}, err
		}
		parts[idx-1] = value
	}
	return binaryVersion{Major: parts[0], Minor: parts[1], Patch: parts[2]}, nil
}

func sortedBinaryEnvVars() []string {
	names := make([]string, 0, len(binaryConfigEnvVars))
	for _, envVar := range binaryConfigEnvVars {
		names = append(names, envVar)
	}
	sort.Strings(names)
	return names
}
