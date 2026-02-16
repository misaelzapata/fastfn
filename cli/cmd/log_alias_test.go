package cmd

import (
	"bytes"
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
