package cmd

import (
	"runtime"
	"strings"
	"testing"
)

func TestInstallHintForBinary_Default(t *testing.T) {
	hint := installHintForBinary("foobar")
	if !strings.Contains(hint, "foobar") {
		t.Fatalf("expected default hint to mention binary name, got: %q", hint)
	}
}

func TestInstallHintForBinary_OpenResty(t *testing.T) {
	hint := installHintForBinary("openresty")
	if !strings.Contains(strings.ToLower(hint), "openresty") {
		t.Fatalf("expected openresty hint, got: %q", hint)
	}
	if runtime.GOOS == "darwin" || runtime.GOOS == "linux" {
		if !strings.Contains(hint, "brew install openresty") {
			t.Fatalf("expected brew hint for openresty on %s, got: %q", runtime.GOOS, hint)
		}
	}
}

func TestInstallHintForBinary_Docker(t *testing.T) {
	hint := installHintForBinary("docker")
	if !strings.Contains(strings.ToLower(hint), "docker") {
		t.Fatalf("expected docker hint, got: %q", hint)
	}
}

func TestInstallHintForBinary_PlatformCombinations(t *testing.T) {
	oldOS, oldArch := doctorGOOS, doctorGOARCH
	t.Cleanup(func() { doctorGOOS, doctorGOARCH = oldOS, oldArch })

	tests := []struct {
		goos     string
		binary   string
		contains string
	}{
		// openresty on darwin
		{goos: "darwin", binary: "openresty", contains: "brew install openresty"},
		// openresty on linux
		{goos: "linux", binary: "openresty", contains: "brew install openresty"},
		// openresty on windows (fallback)
		{goos: "windows", binary: "openresty", contains: "Install OpenResty"},
		// docker on darwin
		{goos: "darwin", binary: "docker", contains: "brew install --cask docker"},
		// docker on linux
		{goos: "linux", binary: "docker", contains: "apt install docker"},
		// docker on windows (fallback)
		{goos: "windows", binary: "docker", contains: "Install Docker CLI"},
		// unknown binary
		{goos: "linux", binary: "unknownbin", contains: "unknownbin"},
	}

	for _, tc := range tests {
		t.Run(tc.binary+"_"+tc.goos, func(t *testing.T) {
			doctorGOOS = tc.goos
			doctorGOARCH = "amd64"
			hint := installHintForBinary(tc.binary)
			if !strings.Contains(hint, tc.contains) {
				t.Fatalf("installHintForBinary(%q) on %s: expected %q in hint, got: %q", tc.binary, tc.goos, tc.contains, hint)
			}
		})
	}
}
