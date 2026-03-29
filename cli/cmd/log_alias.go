package cmd

import (
	"io"
	"os"
	"strings"
)

type logAliasWriter struct {
	out io.Writer
}

func envEnabled(name string) bool {
	raw := strings.TrimSpace(strings.ToLower(os.Getenv(name)))
	return raw == "1" || raw == "true" || raw == "yes" || raw == "on"
}

func keepDockerLogLine(trimmed string) bool {
	if trimmed == "" {
		return true
	}

	lower := strings.ToLower(trimmed)
	// Keep any explicit failure/error signal.
	if strings.Contains(lower, " error") ||
		strings.Contains(lower, "error:") ||
		strings.Contains(lower, " failed") ||
		strings.Contains(lower, "failed ") ||
		strings.Contains(lower, "panic") ||
		strings.Contains(lower, "traceback") ||
		strings.Contains(lower, "crit") {
		return true
	}

	// Drop Docker build progress rows in normal mode.
	if strings.HasPrefix(trimmed, "#") {
		return false
	}

	if strings.Contains(lower, `"component":"node_daemon","event":"deps_preinstall_start"`) {
		return false
	}
	if strings.Contains(lower, `"component":"node_daemon","event":"deps_preinstall_done"`) {
		return false
	}
	if strings.Contains(lower, `catalog watchdog enabled backend=`) {
		return false
	}
	if strings.Contains(lower, `using the "epoll" event method`) {
		return false
	}
	if strings.Contains(lower, "start worker process") || strings.Contains(lower, "start worker processes") {
		return false
	}
	if strings.Contains(lower, "built by gcc") {
		return false
	}
	if strings.Contains(lower, "os: linux") {
		return false
	}
	if strings.Contains(lower, "getrlimit(rlimit_nofile)") {
		return false
	}
	if strings.Contains(lower, "openresty/") && strings.Contains(lower, "notice") {
		return false
	}

	return true
}

func filterDockerNoise(input string) string {
	if input == "" {
		return input
	}

	parts := strings.SplitAfter(input, "\n")
	var b strings.Builder
	for _, part := range parts {
		line := strings.TrimSuffix(part, "\n")
		trimmed := strings.TrimSpace(line)
		if !keepDockerLogLine(trimmed) {
			continue
		}
		b.WriteString(part)
	}
	return b.String()
}

func aliasDockerLogChunk(input string) string {
	out := input
	out = strings.ReplaceAll(out, "Attaching to openresty-1", "Attaching to fastfn")
	out = strings.ReplaceAll(out, "fastfn-openresty-1", "fastfn")
	out = strings.ReplaceAll(out, "openresty-1  |", "fastfn  |")
	if !envEnabled("FN_DEV_VERBOSE_LOGS") {
		out = filterDockerNoise(out)
	}
	return out
}

func (w *logAliasWriter) Write(p []byte) (int, error) {
	rewritten := aliasDockerLogChunk(string(p))
	if _, err := w.out.Write([]byte(rewritten)); err != nil {
		return 0, err
	}
	return len(p), nil
}
