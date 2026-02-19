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
