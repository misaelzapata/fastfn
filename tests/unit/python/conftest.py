"""Shared fixtures and helpers for Python-based unit tests."""
import importlib.util
import json
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[3]
_THIS_DIR = str(Path(__file__).resolve().parent)
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
if _THIS_DIR not in sys.path:
    sys.path.insert(0, _THIS_DIR)


def load_module(path: Path):
    """Load a Python module from *path* without adding it to sys.modules."""
    spec = importlib.util.spec_from_file_location(path.stem, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Cannot load {path}")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)  # type: ignore[attr-defined]
    return mod


def load_handler(path: Path):
    """Load a Python module and return its ``handler`` attribute."""
    return load_module(path).handler


def assert_response_contract(resp):
    assert isinstance(resp, dict), "response must be an object"
    assert isinstance(resp.get("status"), int), "status must be int"
    assert isinstance(resp.get("headers"), dict), "headers must be object"
    assert isinstance(resp.get("body"), str), "body must be string"


def assert_binary_response_contract(resp):
    assert isinstance(resp, dict), "response must be an object"
    assert isinstance(resp.get("status"), int), "status must be int"
    assert isinstance(resp.get("headers"), dict), "headers must be object"
    if resp.get("is_base64") is True:
        assert isinstance(resp.get("body_base64"), str), "body_base64 must be string"
    else:
        assert isinstance(resp.get("body"), str), "body must be string"


def require_demo(path: Path) -> bool:
    if path.exists():
        return True
    pytest.skip(f"missing optional demo {path}")
    return False


@pytest.fixture
def tmp_dir(tmp_path):
    """Provide a temporary directory (alias for pytest's tmp_path)."""
    return tmp_path
