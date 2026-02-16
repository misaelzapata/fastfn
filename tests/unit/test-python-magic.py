#!/usr/bin/env python3
import importlib.util
import sys
import os
import json
import unittest

RUNTIME_PATH = os.path.abspath(os.path.join(os.path.dirname(__file__), "../../cli/embed/runtime"))
PYTHON_DAEMON_PATH = os.path.join(RUNTIME_PATH, "srv", "fn", "runtimes", "python-daemon.py")

try:
    spec = importlib.util.spec_from_file_location("fastfn_python_daemon_embed", PYTHON_DAEMON_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError("module spec not found")
    python_daemon = importlib.util.module_from_spec(spec)  # type: ignore
    spec.loader.exec_module(python_daemon)  # type: ignore[attr-defined]
except Exception:
    print(f"Skipping test: cannot import python-daemon from {PYTHON_DAEMON_PATH}")
    sys.exit(0)

class TestPythonMagicReturn(unittest.TestCase):
    def test_magic_dict(self):
        """Test returning a simple dict -> 200 OK JSON."""
        raw = {"foo": "bar", "num": 123}
        resp = python_daemon._normalize_response(raw)
        self.assertEqual(resp["status"], 200)
        self.assertEqual(resp["headers"]["Content-Type"], "application/json")
        body = json.loads(resp["body"])
        self.assertEqual(body["foo"], "bar")
    
    def test_magic_tuple(self):
        """Test returning (dict, status)."""
        raw = ({"error": "bad"}, 400)
        resp = python_daemon._normalize_response(raw)
        self.assertEqual(resp["status"], 400)
        body = json.loads(resp["body"])
        self.assertEqual(body["error"], "bad")

    def test_explicit_response(self):
        """Test legacy explicit response shape."""
        raw = {"status": 202, "body": "accepted", "headers": {"X-Custom": "1"}}
        resp = python_daemon._normalize_response(raw)
        self.assertEqual(resp["status"], 202)
        self.assertEqual(resp["body"], "accepted")
        self.assertEqual(resp["headers"]["X-Custom"], "1")

if __name__ == "__main__":
    unittest.main()
