package process

import (
	"strings"
	"testing"
)

func patchBinaryResolvers(t *testing.T) {
	t.Helper()
	origLook := binaryLookPathFn
	origOutput := binaryOutputFn
	t.Cleanup(func() {
		binaryLookPathFn = origLook
		binaryOutputFn = origOutput
	})
}

func TestResolveConfiguredBinary_PythonFallsBackToPython(t *testing.T) {
	patchBinaryResolvers(t)
	t.Setenv("FN_PYTHON_BIN", "")

	binaryLookPathFn = func(file string) (string, error) {
		switch file {
		case "python3":
			return "", errBinaryNotFound
		case "python":
			return "/usr/local/bin/python", nil
		default:
			return "", errBinaryNotFound
		}
	}
	binaryOutputFn = func(command string, args ...string) (string, error) {
		if !strings.Contains(command, "python") {
			t.Fatalf("unexpected version probe command: %s %v", command, args)
		}
		return "3.11.7", nil
	}

	resolution, err := ResolveConfiguredBinary("python")
	if err != nil {
		t.Fatalf("ResolveConfiguredBinary(python) error = %v", err)
	}
	if resolution.Path != "/usr/local/bin/python" {
		t.Fatalf("python path = %q", resolution.Path)
	}
}

func TestResolveConfiguredBinary_PythonRejectsExplicitPython2(t *testing.T) {
	patchBinaryResolvers(t)
	t.Setenv("FN_PYTHON_BIN", "python2.7")

	binaryLookPathFn = func(file string) (string, error) {
		if file == "python2.7" {
			return "/usr/bin/python2.7", nil
		}
		return "", errBinaryNotFound
	}
	binaryOutputFn = func(command string, args ...string) (string, error) {
		return "2.7.18", nil
	}

	_, err := ResolveConfiguredBinary("python")
	if err == nil {
		t.Fatalf("expected explicit python2 override to fail")
	}
	if !strings.Contains(err.Error(), "requires >=") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestParseBinaryAssignments(t *testing.T) {
	got, err := ParseBinaryAssignments("python=python,node=node18,php=php8.3")
	if err != nil {
		t.Fatalf("ParseBinaryAssignments error = %v", err)
	}
	if got["FN_PYTHON_BIN"] != "python" {
		t.Fatalf("FN_PYTHON_BIN = %q", got["FN_PYTHON_BIN"])
	}
	if got["FN_NODE_BIN"] != "node18" {
		t.Fatalf("FN_NODE_BIN = %q", got["FN_NODE_BIN"])
	}
	if got["FN_PHP_BIN"] != "php8.3" {
		t.Fatalf("FN_PHP_BIN = %q", got["FN_PHP_BIN"])
	}
}
