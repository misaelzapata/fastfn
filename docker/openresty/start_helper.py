#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import shlex
import socket
import sys
from typing import Any


RUNTIME_ENV = {
    "python": "FN_PY_SOCKET",
    "node": "FN_NODE_SOCKET",
    "php": "FN_PHP_SOCKET",
    "rust": "FN_RUST_SOCKET",
    "go": "FN_GO_SOCKET",
}


def parse_counts(raw: str) -> dict[str, int]:
    out: dict[str, int] = {}
    if not raw:
        return out
    for token in raw.split(","):
        part = token.strip()
        if not part:
            continue
        if "=" not in part:
            raise SystemExit(f"invalid FN_RUNTIME_DAEMONS entry: {part}")
        runtime_name, count_raw = part.split("=", 1)
        runtime_name = runtime_name.strip().lower()
        count_raw = count_raw.strip()
        if not runtime_name or not count_raw:
            raise SystemExit(f"invalid FN_RUNTIME_DAEMONS entry: {part}")
        count = int(count_raw)
        if count < 1:
            raise SystemExit(f"invalid daemon count for runtime {runtime_name}: {count_raw}")
        out[runtime_name] = count
    return out


def normalize_socket_list(raw_value: Any) -> list[str]:
    if isinstance(raw_value, list):
        out: list[str] = []
        for item in raw_value:
            if item is None:
                continue
            value = str(item).strip()
            if value:
                out.append(value)
        return out
    if raw_value is None:
        return []
    value = str(raw_value).strip()
    return [value] if value else []


def build_runtime_socket_env() -> dict[str, str]:
    runtimes = [part.strip().lower() for part in os.getenv("FN_RUNTIMES", "python,node,php,lua").split(",") if part.strip()]
    socket_base = "/tmp/fastfn"
    explicit_raw = (os.getenv("FN_RUNTIME_SOCKETS") or "").strip()
    counts_raw = (os.getenv("FN_RUNTIME_DAEMONS") or "").strip()
    supported = set(RUNTIME_ENV)

    explicit: dict[str, Any] = {}
    if explicit_raw:
        try:
            parsed = json.loads(explicit_raw)
        except Exception as exc:
            raise SystemExit(f"invalid FN_RUNTIME_SOCKETS JSON: {exc}")
        if isinstance(parsed, dict):
            explicit = parsed

    counts = parse_counts(counts_raw)
    sockets_by_runtime: dict[str, list[str]] = {}
    for runtime_name in runtimes:
        if runtime_name not in supported:
            continue
        sockets = normalize_socket_list(explicit.get(runtime_name))
        if not sockets:
            count = counts.get(runtime_name, 1)
            if count <= 1:
                sockets = [f"unix:{socket_base}/fn-{runtime_name}.sock"]
            else:
                sockets = [f"unix:{socket_base}/fn-{runtime_name}-{idx}.sock" for idx in range(1, count + 1)]
        sockets_by_runtime[runtime_name] = sockets

    payload = {
        runtime_name: sockets[0] if len(sockets) == 1 else sockets
        for runtime_name, sockets in sockets_by_runtime.items()
    }
    env_map: dict[str, str] = {
        "FN_RUNTIME_SOCKETS_RESOLVED": json.dumps(payload, separators=(",", ":")),
    }
    for runtime_name, sockets in sockets_by_runtime.items():
        prefix = f"RT_{runtime_name.upper()}"
        env_map[f"{prefix}_COUNT"] = str(len(sockets))
        for idx, socket_uri in enumerate(sockets, 1):
            socket_path = socket_uri[5:] if socket_uri.startswith("unix:") else socket_uri
            env_map[f"{prefix}_SOCKET_{idx}"] = socket_path
            env_map[f"{prefix}_URI_{idx}"] = socket_uri
    return env_map


def resolve_runtime_sockets(output_format: str) -> None:
    env_map = build_runtime_socket_env()
    if output_format == "json":
        print(json.dumps(env_map, separators=(",", ":"), sort_keys=True))
        return

    for key in sorted(env_map):
        print(f"export {key}=" + shlex.quote(env_map[key]))


def socket_in_use(socket_path: str) -> None:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(0.2)
    try:
        sock.connect(socket_path)
    except Exception:
        raise SystemExit(1)
    finally:
        try:
            sock.close()
        except Exception:
            pass
    raise SystemExit(0)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)

    resolve = sub.add_parser("resolve-runtime-sockets")
    resolve.add_argument("--format", choices=("env", "json"), default="env")
    resolve.set_defaults(func=lambda args: resolve_runtime_sockets(args.format))

    in_use = sub.add_parser("socket-in-use")
    in_use.add_argument("--path", required=True)
    in_use.set_defaults(func=lambda args: socket_in_use(args.path))
    return parser


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
