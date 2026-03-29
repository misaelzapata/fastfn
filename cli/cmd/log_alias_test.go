package cmd

import (
	"bytes"
	"fmt"
	"strings"
	"testing"
)

func TestAliasDockerLogChunk_RewritesKnownTokens(t *testing.T) {
	in := "Attaching to openresty-1\nopenresty-1  | hello\nfastfn-openresty-1 started\n"
	out := aliasDockerLogChunk(in)

	if bytes.Contains([]byte(out), []byte("openresty-1  |")) {
		t.Fatalf("expected openresty prefix to be rewritten, got: %q", out)
	}
	if bytes.Contains([]byte(out), []byte("fastfn-openresty-1")) {
		t.Fatalf("expected compose container name alias to be rewritten, got: %q", out)
	}
	if !bytes.Contains([]byte(out), []byte("Attaching to fastfn")) {
		t.Fatalf("expected attach line alias, got: %q", out)
	}
	if !bytes.Contains([]byte(out), []byte("fastfn  | hello")) {
		t.Fatalf("expected log prefix alias, got: %q", out)
	}
	if !bytes.Contains([]byte(out), []byte("fastfn started")) {
		t.Fatalf("expected container name alias, got: %q", out)
	}
}

func TestAliasDockerLogChunk_NoChangeForOtherText(t *testing.T) {
	in := "random line\nanother line\n"
	out := aliasDockerLogChunk(in)
	if out != in {
		t.Fatalf("expected unchanged output, got: %q", out)
	}
}

func TestLogAliasWriter_WriteReturnsInputLenAndRewritesOutput(t *testing.T) {
	var dst bytes.Buffer
	w := &logAliasWriter{out: &dst}
	in := []byte("openresty-1  | ping\n")

	n, err := w.Write(in)
	if err != nil {
		t.Fatalf("unexpected write error: %v", err)
	}
	if want := len(in); n != want {
		t.Fatalf("expected write count %d, got %d", want, n)
	}

	got := dst.String()
	want := "fastfn  | ping\n"
	if got != want {
		t.Fatalf("unexpected aliased output: want %q got %q", want, got)
	}
}

func TestAliasDockerLogChunk_FiltersKnownNoiseByDefault(t *testing.T) {
	t.Setenv("FN_DEV_VERBOSE_LOGS", "")
	in := strings.Join([]string{
		"#1 [openresty internal] load build definition from Dockerfile",
		`fastfn  | {"component":"node_daemon","event":"deps_preinstall_start","functions":0}`,
		`fastfn  | 2026/02/16 01:39:51 notice 1#1: start worker process 35`,
		"fastfn  | service ready",
		"",
	}, "\n")

	out := aliasDockerLogChunk(in)
	if strings.Contains(out, "deps_preinstall_start") {
		t.Fatalf("expected preinstall noise to be filtered, got: %q", out)
	}
	if strings.Contains(out, "start worker process") {
		t.Fatalf("expected nginx startup notice to be filtered, got: %q", out)
	}
	if strings.Contains(out, "#1 [openresty internal]") {
		t.Fatalf("expected build progress to be filtered, got: %q", out)
	}
	if !strings.Contains(out, "service ready") {
		t.Fatalf("expected normal lines to be preserved, got: %q", out)
	}
}

func TestAliasDockerLogChunk_KeepsNoiseInVerboseMode(t *testing.T) {
	t.Setenv("FN_DEV_VERBOSE_LOGS", "1")
	in := `fastfn  | {"component":"node_daemon","event":"deps_preinstall_start","functions":0}` + "\n"
	out := aliasDockerLogChunk(in)
	if !strings.Contains(out, "deps_preinstall_start") {
		t.Fatalf("expected verbose mode to keep raw logs, got: %q", out)
	}
}

func TestEnvEnabled_AllVariants(t *testing.T) {
	tests := []struct {
		value    string
		expected bool
	}{
		{"1", true},
		{"true", true},
		{"yes", true},
		{"on", true},
		{"TRUE", true},
		{"YES", true},
		{"ON", true},
		{" true ", true},
		{"0", false},
		{"", false},
		{"false", false},
		{"no", false},
		{"off", false},
		{"random", false},
	}

	for _, tc := range tests {
		t.Run(tc.value, func(t *testing.T) {
			t.Setenv("TEST_ENV_ENABLED", tc.value)
			got := envEnabled("TEST_ENV_ENABLED")
			if got != tc.expected {
				t.Fatalf("envEnabled(%q) = %v, want %v", tc.value, got, tc.expected)
			}
		})
	}
}

func TestKeepDockerLogLine_ErrorKept(t *testing.T) {
	tests := []struct {
		line string
		keep bool
	}{
		{"something error happened", true},
		{"error: bad thing", true},
		{"request failed to complete", true},
		{"failed to start", true},
		{"panic: runtime error", true},
		{"Traceback (most recent call last):", true},
		{"CRIT: out of memory", true},
		{"", true}, // empty lines kept
		{"#1 [internal] load build definition", false},
		{`{"component":"node_daemon","event":"deps_preinstall_start"}`, false},
		{`{"component":"node_daemon","event":"deps_preinstall_done"}`, false},
		{"catalog watchdog enabled backend=fs", false},
		{`using the "epoll" event method`, false},
		{"start worker process 42", false},
		{"start worker processes", false},
		{"built by gcc 12.2.0", false},
		{"OS: Linux 6.1.0", false},
		{"getrlimit(RLIMIT_NOFILE)", false},
		{"openresty/1.21.4.1 notice: hello", false},
		{"normal log line", true},
	}

	for _, tc := range tests {
		t.Run(tc.line, func(t *testing.T) {
			got := keepDockerLogLine(tc.line)
			if got != tc.keep {
				t.Fatalf("keepDockerLogLine(%q) = %v, want %v", tc.line, got, tc.keep)
			}
		})
	}
}

func TestFilterDockerNoise_EmptyInput(t *testing.T) {
	got := filterDockerNoise("")
	if got != "" {
		t.Fatalf("filterDockerNoise(\"\") = %q, want empty", got)
	}
}

func TestFilterDockerNoise_PreservesNonNoisyLines(t *testing.T) {
	in := "line one\nline two\n"
	got := filterDockerNoise(in)
	if got != in {
		t.Fatalf("filterDockerNoise() = %q, want %q", got, in)
	}
}

func TestFilterDockerNoise_FiltersNoisyLines(t *testing.T) {
	in := "#1 build step\nnormal line\nbuilt by gcc 12\n"
	got := filterDockerNoise(in)
	if strings.Contains(got, "#1 build step") {
		t.Fatalf("expected build step to be filtered")
	}
	if strings.Contains(got, "built by gcc") {
		t.Fatalf("expected gcc line to be filtered")
	}
	if !strings.Contains(got, "normal line") {
		t.Fatalf("expected normal line to be preserved")
	}
}

func TestLogAliasWriter_ErrorPath(t *testing.T) {
	w := &logAliasWriter{out: &failWriter{}}
	_, err := w.Write([]byte("hello\n"))
	if err == nil {
		t.Fatalf("expected write error from underlying writer")
	}
}

type failWriter struct{}

func (w *failWriter) Write(p []byte) (int, error) {
	return 0, fmt.Errorf("write failed")
}

func TestAliasDockerLogChunk_VerboseVariants(t *testing.T) {
	for _, val := range []string{"true", "yes", "on"} {
		t.Run(val, func(t *testing.T) {
			t.Setenv("FN_DEV_VERBOSE_LOGS", val)
			in := "#1 build progress line\n"
			out := aliasDockerLogChunk(in)
			if !strings.Contains(out, "#1 build progress line") {
				t.Fatalf("expected verbose mode to keep build progress, got: %q", out)
			}
		})
	}
}
