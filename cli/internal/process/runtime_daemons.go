package process

import (
	"encoding/json"
	"fmt"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

var runtimeSocketEnvByRuntime = map[string]string{
	"python": "FN_PY_SOCKET",
	"node":   "FN_NODE_SOCKET",
	"php":    "FN_PHP_SOCKET",
	"rust":   "FN_RUST_SOCKET",
	"go":     "FN_GO_SOCKET",
}

func runtimeSupportsDaemonScaling(runtime string) bool {
	_, ok := runtimeSocketEnvByRuntime[runtime]
	return ok
}

func parseRuntimeDaemonCounts(raw string) (map[string]int, []string, error) {
	out := map[string]int{}
	warnings := make([]string, 0)
	if strings.TrimSpace(raw) == "" {
		return out, warnings, nil
	}

	for _, token := range strings.Split(raw, ",") {
		part := strings.TrimSpace(token)
		if part == "" {
			continue
		}

		runtimeName, countRaw, ok := strings.Cut(part, "=")
		if !ok {
			return nil, warnings, fmt.Errorf("invalid FN_RUNTIME_DAEMONS entry %q (expected runtime=count)", part)
		}

		runtimeName = strings.ToLower(strings.TrimSpace(runtimeName))
		countRaw = strings.TrimSpace(countRaw)
		if runtimeName == "" || countRaw == "" {
			return nil, warnings, fmt.Errorf("invalid FN_RUNTIME_DAEMONS entry %q (expected runtime=count)", part)
		}

		count, err := strconv.Atoi(countRaw)
		if err != nil || count < 1 {
			return nil, warnings, fmt.Errorf("invalid daemon count for runtime %s: %q", runtimeName, countRaw)
		}

		if runtimeName == "lua" {
			warnings = append(warnings, "Ignoring runtime daemon count for lua (in-process runtime)")
			continue
		}
		if _, known := nativeRuntimeRequirements[runtimeName]; !known {
			warnings = append(warnings, fmt.Sprintf("Ignoring unknown runtime in FN_RUNTIME_DAEMONS: %s", runtimeName))
			continue
		}

		out[runtimeName] = count
	}

	return out, warnings, nil
}

func firstRuntimeSocket(sockets []string) string {
	if len(sockets) == 0 {
		return ""
	}
	return sockets[0]
}

func resolveRuntimeDaemonCounts(selected []string, raw string) (map[string]int, []string, error) {
	parsed, warnings, err := parseRuntimeDaemonCounts(raw)
	if err != nil {
		return nil, warnings, err
	}

	out := map[string]int{}
	for _, runtimeName := range selected {
		if runtimeSupportsDaemonScaling(runtimeName) {
			out[runtimeName] = 1
		}
	}
	for runtimeName, count := range parsed {
		if !runtimeSupportsDaemonScaling(runtimeName) {
			continue
		}
		out[runtimeName] = count
	}
	return out, warnings, nil
}

func runtimeSocketPaths(socketDir, runtime string, daemonCount int) []string {
	if daemonCount <= 1 {
		return []string{filepath.Join(socketDir, "fn-"+runtime+".sock")}
	}

	out := make([]string, 0, daemonCount)
	for i := 1; i <= daemonCount; i++ {
		out = append(out, filepath.Join(socketDir, fmt.Sprintf("fn-%s-%d.sock", runtime, i)))
	}
	return out
}

func runtimeSocketURIsByRuntime(socketDir string, selected []string, counts map[string]int) map[string][]string {
	out := map[string][]string{}
	for _, runtimeName := range selected {
		if !runtimeSupportsDaemonScaling(runtimeName) {
			continue
		}
		daemonCount := counts[runtimeName]
		if daemonCount < 1 {
			daemonCount = 1
		}
		paths := runtimeSocketPaths(socketDir, runtimeName, daemonCount)
		uris := make([]string, 0, len(paths))
		for _, path := range paths {
			uris = append(uris, "unix:"+path)
		}
		out[runtimeName] = uris
	}
	return out
}

func encodeRuntimeSocketMap(runtimeSockets map[string][]string) (string, error) {
	payload := map[string]any{}
	for runtimeName, sockets := range runtimeSockets {
		if len(sockets) == 1 {
			payload[runtimeName] = sockets[0]
			continue
		}
		dup := append([]string{}, sockets...)
		payload[runtimeName] = dup
	}
	raw, err := json.Marshal(payload)
	if err != nil {
		return "", err
	}
	return string(raw), nil
}

func runtimeServiceEnv(baseEnv []string, runtimeName, socketURI string, daemonIndex, daemonCount int) []string {
	env := append([]string{}, baseEnv...)
	if key := runtimeSocketEnvByRuntime[runtimeName]; key != "" {
		socketPath := strings.TrimPrefix(socketURI, "unix:")
		env = append(env, key+"="+socketPath)
	}
	env = append(env,
		"FN_RUNTIME_INSTANCE_INDEX="+strconv.Itoa(daemonIndex),
		"FN_RUNTIME_INSTANCE_COUNT="+strconv.Itoa(daemonCount),
	)
	return env
}

func runtimeServiceName(runtimeName string, daemonIndex, daemonCount int) string {
	if daemonCount <= 1 {
		return runtimeName
	}
	return fmt.Sprintf("%s#%d", runtimeName, daemonIndex)
}

func canonicalRuntimeDaemonEnvValue(raw string) (string, bool) {
	parsed, _, err := parseRuntimeDaemonCounts(raw)
	if err != nil || len(parsed) == 0 {
		return "", false
	}

	order := make([]string, 0, len(parsed))
	for runtimeName := range parsed {
		order = append(order, runtimeName)
	}
	sort.Strings(order)

	parts := make([]string, 0, len(order))
	for _, runtimeName := range order {
		parts = append(parts, fmt.Sprintf("%s=%d", runtimeName, parsed[runtimeName]))
	}
	return strings.Join(parts, ","), true
}
