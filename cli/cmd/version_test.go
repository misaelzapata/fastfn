package cmd

import (
	"bytes"
	"io"
	"os"
	"testing"
)

func TestVersionCmd_OutputFormat(t *testing.T) {
	origVersion := Version
	t.Cleanup(func() { Version = origVersion })

	Version = "1.2.3"

	r, w, _ := os.Pipe()
	origStdout := os.Stdout
	os.Stdout = w
	t.Cleanup(func() { os.Stdout = origStdout })

	versionCmd.Run(versionCmd, nil)
	w.Close()
	var buf bytes.Buffer
	io.Copy(&buf, r)

	if got := buf.String(); got != "FastFN 1.2.3\n" {
		t.Fatalf("output = %q, want %q", got, "FastFN 1.2.3\n")
	}
}

func TestVersionCmd_DevDefault(t *testing.T) {
	origVersion := Version
	t.Cleanup(func() { Version = origVersion })

	Version = "dev"

	r, w, _ := os.Pipe()
	origStdout := os.Stdout
	os.Stdout = w
	t.Cleanup(func() { os.Stdout = origStdout })

	versionCmd.Run(versionCmd, nil)
	w.Close()
	var buf bytes.Buffer
	io.Copy(&buf, r)

	if got := buf.String(); got != "FastFN dev\n" {
		t.Fatalf("output = %q, want %q", got, "FastFN dev\n")
	}
}
