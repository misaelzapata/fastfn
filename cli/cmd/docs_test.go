package cmd

import (
	"fmt"
	"os/exec"
	"testing"
)

func TestDocsCmd_LinuxOpensBrowser(t *testing.T) {
	origGOOS := docsGOOS
	origExec := docsExecCommand
	origFatalf := docsFatalf
	defer func() {
		docsGOOS = origGOOS
		docsExecCommand = origExec
		docsFatalf = origFatalf
	}()

	var capturedBin string
	var capturedArgs []string
	docsGOOS = "linux"
	docsExecCommand = func(name string, arg ...string) *exec.Cmd {
		capturedBin = name
		capturedArgs = arg
		return exec.Command("true")
	}
	docsFatalf = func(format string, args ...interface{}) {
		t.Fatalf("unexpected fatalf: "+format, args...)
	}

	docsCmd.Run(docsCmd, nil)

	if capturedBin != "xdg-open" {
		t.Errorf("expected xdg-open, got %s", capturedBin)
	}
	if len(capturedArgs) != 1 || capturedArgs[0] != "http://localhost:8080/docs" {
		t.Errorf("unexpected args: %v", capturedArgs)
	}
}

func TestDocsCmd_DarwinOpensBrowser(t *testing.T) {
	origGOOS := docsGOOS
	origExec := docsExecCommand
	origFatalf := docsFatalf
	defer func() {
		docsGOOS = origGOOS
		docsExecCommand = origExec
		docsFatalf = origFatalf
	}()

	var capturedBin string
	docsGOOS = "darwin"
	docsExecCommand = func(name string, arg ...string) *exec.Cmd {
		capturedBin = name
		return exec.Command("true")
	}
	docsFatalf = func(format string, args ...interface{}) {
		t.Fatalf("unexpected fatalf: "+format, args...)
	}

	docsCmd.Run(docsCmd, nil)

	if capturedBin != "open" {
		t.Errorf("expected open, got %s", capturedBin)
	}
}

func TestDocsCmd_WindowsOpensBrowser(t *testing.T) {
	origGOOS := docsGOOS
	origExec := docsExecCommand
	origFatalf := docsFatalf
	defer func() {
		docsGOOS = origGOOS
		docsExecCommand = origExec
		docsFatalf = origFatalf
	}()

	var capturedBin string
	docsGOOS = "windows"
	docsExecCommand = func(name string, arg ...string) *exec.Cmd {
		capturedBin = name
		return exec.Command("true")
	}
	docsFatalf = func(format string, args ...interface{}) {
		t.Fatalf("unexpected fatalf: "+format, args...)
	}

	docsCmd.Run(docsCmd, nil)

	if capturedBin != "rundll32" {
		t.Errorf("expected rundll32, got %s", capturedBin)
	}
}

func TestDocsCmd_UnsupportedPlatform(t *testing.T) {
	origGOOS := docsGOOS
	origExec := docsExecCommand
	origFatalf := docsFatalf
	defer func() {
		docsGOOS = origGOOS
		docsExecCommand = origExec
		docsFatalf = origFatalf
	}()

	docsGOOS = "freebsd"
	var fatalCalled bool
	var fatalMsg string
	docsFatalf = func(format string, args ...interface{}) {
		fatalCalled = true
		fatalMsg = fmt.Sprintf(format, args...)
	}

	docsCmd.Run(docsCmd, nil)

	if !fatalCalled {
		t.Error("expected fatalf to be called for unsupported platform")
	}
	if fatalMsg == "" {
		t.Error("expected non-empty fatal message")
	}
}

func TestDocsCmd_StartError(t *testing.T) {
	origGOOS := docsGOOS
	origExec := docsExecCommand
	origFatalf := docsFatalf
	defer func() {
		docsGOOS = origGOOS
		docsExecCommand = origExec
		docsFatalf = origFatalf
	}()

	docsGOOS = "linux"
	docsExecCommand = func(name string, arg ...string) *exec.Cmd {
		return exec.Command("nonexistent-binary-that-does-not-exist")
	}
	var fatalCalled bool
	docsFatalf = func(format string, args ...interface{}) {
		fatalCalled = true
	}

	docsCmd.Run(docsCmd, nil)

	if !fatalCalled {
		t.Error("expected fatalf to be called when Start fails")
	}
}
