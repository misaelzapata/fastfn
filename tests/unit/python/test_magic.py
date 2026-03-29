#!/usr/bin/env python3
"""Tests for python-daemon.py magic return normalization (embedded runtime)."""
import json
import os
import sys
from pathlib import Path

import pytest

from conftest import load_module

RUNTIME_PATH = Path(__file__).resolve().parents[3] / "cli/embed/runtime"
PYTHON_DAEMON_PATH = RUNTIME_PATH / "srv" / "fn" / "runtimes" / "python-daemon.py"

if not PYTHON_DAEMON_PATH.is_file():
    pytest.skip(
        f"Skipping: cannot import python-daemon from {PYTHON_DAEMON_PATH}",
        allow_module_level=True,
    )

python_daemon = load_module(PYTHON_DAEMON_PATH)


def test_magic_dict():
    """Test returning a simple dict -> 200 OK JSON."""
    raw = {"foo": "bar", "num": 123}
    resp = python_daemon._normalize_response(raw)
    assert resp["status"] == 200
    assert resp["headers"]["Content-Type"] == "application/json"
    body = json.loads(resp["body"])
    assert body["foo"] == "bar"


def test_magic_tuple():
    """Test returning (dict, status)."""
    raw = ({"error": "bad"}, 400)
    resp = python_daemon._normalize_response(raw)
    assert resp["status"] == 400
    body = json.loads(resp["body"])
    assert body["error"] == "bad"


def test_explicit_response():
    """Test explicit response shape."""
    raw = {"status": 202, "body": "accepted", "headers": {"X-Custom": "1"}}
    resp = python_daemon._normalize_response(raw)
    assert resp["status"] == 202
    assert resp["body"] == "accepted"
    assert resp["headers"]["X-Custom"] == "1"
