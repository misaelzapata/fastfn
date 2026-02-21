#!/usr/bin/env python3
import importlib.util
import json
import socket
import struct
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RUNTIME_DIR = ROOT / "srv/fn/runtimes"
GO_DAEMON_PATH = RUNTIME_DIR / "go-daemon.py"

_GO_SPEC = importlib.util.spec_from_file_location("fastfn_go_daemon", GO_DAEMON_PATH)
if _GO_SPEC is None or _GO_SPEC.loader is None:
    raise RuntimeError(f"failed to load runtime module: {GO_DAEMON_PATH}")
go_daemon = importlib.util.module_from_spec(_GO_SPEC)  # type: ignore
_GO_SPEC.loader.exec_module(go_daemon)  # type: ignore


def _recvall(conn: socket.socket, size: int) -> bytes:
    data = bytearray()
    while len(data) < size:
        chunk = conn.recv(size - len(data))
        if not chunk:
            break
        data.extend(chunk)
    return bytes(data)


def _read_frame(conn: socket.socket) -> dict:
    header = _recvall(conn, 4)
    assert len(header) == 4, "expected 4-byte frame header"
    (length,) = struct.unpack("!I", header)
    payload = _recvall(conn, length)
    assert len(payload) == length, "expected full frame payload"
    return json.loads(payload.decode("utf-8"))


def _write_raw_frame(conn: socket.socket, payload: bytes) -> None:
    conn.sendall(struct.pack("!I", len(payload)) + payload)


def test_write_frame_roundtrip() -> None:
    left, right = socket.socketpair()
    with left, right:
        expected = {"status": 200, "headers": {"Content-Type": "application/json"}, "body": '{"ok":true}'}
        go_daemon._write_frame(left, expected)
        actual = _read_frame(right)
        assert actual == expected, actual


def test_write_frame_fallback_for_unserializable_payload() -> None:
    left, right = socket.socketpair()
    with left, right:
        go_daemon._write_frame(left, {"bad": {"set"}})
        actual = _read_frame(right)
        assert actual.get("status") == 500, actual
        body = json.loads(actual.get("body") or "{}")
        assert "encode failure" in str(body.get("error", "")), body


def test_write_frame_fallback_for_oversized_payload() -> None:
    left, right = socket.socketpair()
    original_max = go_daemon.MAX_FRAME_BYTES
    try:
        go_daemon.MAX_FRAME_BYTES = 1024
        with left, right:
            go_daemon._write_frame(left, {"status": 200, "headers": {}, "body": "x" * 5000})
            actual = _read_frame(right)
            assert actual.get("status") == 500, actual
            body = json.loads(actual.get("body") or "{}")
            assert "response too large" in str(body.get("error", "")), body
    finally:
        go_daemon.MAX_FRAME_BYTES = original_max


def test_read_frame_invalid_utf8() -> None:
    left, right = socket.socketpair()
    with left, right:
        _write_raw_frame(right, b"\xff\xfe\xfa")
        try:
            go_daemon._read_frame(left)
        except ValueError as exc:
            assert "invalid utf-8 payload" in str(exc), str(exc)
            return
        raise AssertionError("expected invalid utf-8 payload error")


def test_read_frame_invalid_json() -> None:
    left, right = socket.socketpair()
    with left, right:
        _write_raw_frame(right, b"{bad json")
        try:
            go_daemon._read_frame(left)
        except ValueError as exc:
            assert "invalid json payload" in str(exc), str(exc)
            return
        raise AssertionError("expected invalid json payload error")


def test_read_frame_non_object_json() -> None:
    left, right = socket.socketpair()
    with left, right:
        _write_raw_frame(right, b"[]")
        try:
            go_daemon._read_frame(left)
        except ValueError as exc:
            assert "request must be an object" in str(exc), str(exc)
            return
        raise AssertionError("expected request must be an object error")


def test_read_frame_oversized_length() -> None:
    left, right = socket.socketpair()
    with left, right:
        too_large = go_daemon.MAX_FRAME_BYTES + 1
        right.sendall(struct.pack("!I", too_large))
        try:
            go_daemon._read_frame(left)
        except ValueError as exc:
            assert "invalid frame length" in str(exc), str(exc)
            return
        raise AssertionError("expected invalid frame length error")


def test_serve_conn_ignores_client_disconnect_on_write() -> None:
    original_read_frame = go_daemon._read_frame
    original_handle_request = go_daemon._handle_request
    left, right = socket.socketpair()
    try:
        go_daemon._read_frame = lambda _conn: {"fn": "any", "event": {}}  # type: ignore[assignment]
        go_daemon._handle_request = lambda _req: {"status": 200, "headers": {}, "body": "ok"}  # type: ignore[assignment]
        right.close()
        go_daemon._serve_conn(left)
    finally:
        go_daemon._read_frame = original_read_frame
        go_daemon._handle_request = original_handle_request
        try:
            left.close()
        except Exception:
            pass


def test_prepare_socket_path_tolerates_stat_race() -> None:
    old_stat = go_daemon.os.stat
    try:
        go_daemon.os.stat = lambda _p: (_ for _ in ()).throw(FileNotFoundError("gone"))  # type: ignore[assignment]
        go_daemon._prepare_socket_path("/tmp/fastfn/fn-go.sock")
    finally:
        go_daemon.os.stat = old_stat


def main() -> None:
    test_write_frame_roundtrip()
    test_write_frame_fallback_for_unserializable_payload()
    test_write_frame_fallback_for_oversized_payload()
    test_read_frame_invalid_utf8()
    test_read_frame_invalid_json()
    test_read_frame_non_object_json()
    test_read_frame_oversized_length()
    test_serve_conn_ignores_client_disconnect_on_write()
    test_prepare_socket_path_tolerates_stat_race()
    print("go runtime unit tests passed")


if __name__ == "__main__":
    main()
