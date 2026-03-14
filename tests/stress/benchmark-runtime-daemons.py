#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from collections import Counter
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path


@dataclass(frozen=True)
class RuntimeTarget:
    runtime: str
    path: str


TARGETS = [
    RuntimeTarget(runtime="node", path="/slow-node"),
    RuntimeTarget(runtime="python", path="/slow-python"),
    RuntimeTarget(runtime="php", path="/slow-php"),
    RuntimeTarget(runtime="rust", path="/slow-rust"),
]


def pick_free_port() -> int:
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    return port


def http_get_json(url: str, timeout: float = 2.0) -> tuple[int, dict | list | str]:
    req = urllib.request.Request(url, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            code = resp.getcode()
            body = resp.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as exc:
        code = exc.code
        body = exc.read().decode("utf-8", errors="replace")
    except (urllib.error.URLError, TimeoutError, OSError):
        return 0, ""
    try:
        parsed = json.loads(body)
    except Exception:
        parsed = body
    return code, parsed


def run_burst(base_url: str, path: str, concurrency: int, timeout: float) -> dict:
    counter = {"sent": 0, "status": Counter()}
    lock = threading.Lock()

    def worker() -> None:
        while True:
            with lock:
                if counter["sent"] >= concurrency:
                    return
                counter["sent"] += 1
            req = urllib.request.Request(base_url + path, method="GET")
            code = 0
            try:
                with urllib.request.urlopen(req, timeout=timeout) as resp:
                    code = resp.getcode()
                    _ = resp.read()
            except urllib.error.HTTPError as exc:
                code = exc.code
            except Exception:
                code = 0
            with lock:
                counter["status"][code] += 1

    t0 = time.perf_counter()
    threads = [threading.Thread(target=worker, daemon=True) for _ in range(max(1, concurrency))]
    for item in threads:
        item.start()
    for item in threads:
        item.join()
    elapsed_ms = round((time.perf_counter() - t0) * 1000.0, 1)
    return {
        "elapsed_ms": elapsed_ms,
        "status": dict(sorted(counter["status"].items())),
    }


def wait_for_endpoint_ready(base_url: str, path: str, timeout: float, attempts: int = 20) -> None:
    for _ in range(max(1, attempts)):
        result = run_burst(base_url, path, 1, timeout)
        if result["status"] == {200: 1}:
            return
        time.sleep(0.5)
    raise RuntimeError(f"endpoint did not become ready after warmup: {path}")


class StackRunner:
    def __init__(
        self,
        root_dir: Path,
        mode: str,
        fixture: Path,
        port: int,
        runtimes: str,
        daemon_counts: str,
        python_bin: str,
        build_docker: bool,
    ) -> None:
        self.root_dir = root_dir
        self.mode = mode
        self.fixture = fixture
        self.port = port
        self.runtimes = runtimes
        self.daemon_counts = daemon_counts
        self.python_bin = python_bin
        self.build_docker = build_docker
        self.process: subprocess.Popen[str] | None = None
        self.log_path = Path(tempfile.mkstemp(prefix=f"fastfn-{mode}-runtime-daemons.", suffix=".log")[1])
        self.log_handle = None

    @property
    def base_url(self) -> str:
        return f"http://127.0.0.1:{self.port}"

    def _command(self) -> list[str]:
        fastfn = str(self.root_dir / "bin" / "fastfn")
        if self.mode == "native":
            return [fastfn, "dev", "--native", str(self.fixture)]
        args = [fastfn, "dev"]
        if self.build_docker:
            args.append("--build")
        args.append(str(self.fixture))
        return args

    def start(self) -> None:
        env = os.environ.copy()
        env.update(
            {
                "FN_ADMIN_TOKEN": "test-admin-token",
                "FN_UI_ENABLED": "0",
                "FN_CONSOLE_WRITE_ENABLED": "0",
                "FN_OPENAPI_INCLUDE_INTERNAL": "0",
                "FN_RUNTIMES": self.runtimes,
                "FN_RUNTIME_DAEMONS": self.daemon_counts,
                "FN_HOST_PORT": str(self.port),
            }
        )
        if self.mode == "docker":
            subprocess.run(
                ["docker", "compose", "down", "--remove-orphans"],
                cwd=self.root_dir,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )
        if self.mode == "native" and self.python_bin:
            env["FN_PYTHON_BIN"] = self.python_bin
            env.setdefault("PYTHON_BIN", self.python_bin)
        self.log_handle = self.log_path.open("w", encoding="utf-8")
        self.process = subprocess.Popen(
            self._command(),
            cwd=self.root_dir,
            env=env,
            stdout=self.log_handle,
            stderr=subprocess.STDOUT,
            text=True,
            start_new_session=True,
        )
        self.wait_for_health()

    def wait_for_health(self, timeout: int = 180) -> None:
        deadline = time.time() + timeout
        required = [part.strip() for part in self.runtimes.split(",") if part.strip()]
        while time.time() < deadline:
            if self.process is not None and self.process.poll() is not None:
                raise RuntimeError(
                    f"{self.mode} stack exited before ready; see {self.log_path}\n"
                    + self.log_path.read_text(encoding="utf-8", errors="replace")[-8000:]
                )
            code, payload = http_get_json(self.base_url + "/_fn/health", timeout=2.0)
            if code == 200 and isinstance(payload, dict):
                runtimes = payload.get("runtimes") or {}
                ok = True
                for name in required:
                    health = ((runtimes.get(name) or {}).get("health") or {})
                    if health.get("up") is not True:
                        ok = False
                        break
                if ok:
                    return
            time.sleep(1)
        raise RuntimeError(f"{self.mode} stack did not become healthy; see {self.log_path}")

    def stop(self) -> None:
        if self.process is not None and self.process.poll() is None:
            os.killpg(self.process.pid, signal.SIGTERM)
            try:
                self.process.wait(timeout=20)
            except subprocess.TimeoutExpired:
                os.killpg(self.process.pid, signal.SIGKILL)
                self.process.wait(timeout=10)
        self.process = None
        if self.log_handle is not None:
            self.log_handle.close()
            self.log_handle = None
        if self.mode == "native":
            self._kill_native_runtime_processes()
        else:
            subprocess.run(
                ["docker", "compose", "down", "--remove-orphans"],
                cwd=self.root_dir,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )

    def _kill_native_runtime_processes(self) -> None:
        if not self.log_path.exists():
            return
        runtime_dir = ""
        for line in self.log_path.read_text(encoding="utf-8", errors="replace").splitlines():
            marker = "Runtime extracted to: "
            if marker in line:
                runtime_dir = line.split(marker, 1)[1].strip()
        if not runtime_dir:
            return
        patterns = [
            f"{runtime_dir}/openresty",
            f"{runtime_dir}/srv/fn/runtimes/python-daemon.py",
            f"{runtime_dir}/srv/fn/runtimes/node-daemon.js",
            f"{runtime_dir}/srv/fn/runtimes/php-daemon.py",
            f"{runtime_dir}/srv/fn/runtimes/rust-daemon.py",
            f"{runtime_dir}/srv/fn/runtimes/go-daemon.py",
        ]
        for pattern in patterns:
            subprocess.run(["pkill", "-f", pattern], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def summarize_case(samples_ms: list[float]) -> dict:
    return {
        "samples_ms": [round(item, 1) for item in samples_ms],
        "avg_ms": round(sum(samples_ms) / len(samples_ms), 1),
        "min_ms": round(min(samples_ms), 1),
        "max_ms": round(max(samples_ms), 1),
    }


def run_mode(
    *,
    mode: str,
    root_dir: Path,
    fixture: Path,
    runtimes: str,
    daemon_counts: list[int],
    concurrency: int,
    repeats: int,
    warmup_requests: int,
    timeout: float,
    python_bin: str,
    out_path: Path,
) -> dict:
    baseline_avg: dict[str, float] = {}
    cases: list[dict] = []
    first_docker_launch = True

    for daemon_count in daemon_counts:
        count_env = ",".join(f"{runtime}={daemon_count}" for runtime in runtimes.split(",") if runtime)
        port = pick_free_port()
        runner = StackRunner(
            root_dir=root_dir,
            mode=mode,
            fixture=fixture,
            port=port,
            runtimes=runtimes,
            daemon_counts=count_env,
            python_bin=python_bin,
            build_docker=(mode == "docker" and first_docker_launch),
        )
        try:
            runner.start()
            if mode == "docker":
                first_docker_launch = False
            for target in TARGETS:
                if target.runtime not in runtimes.split(","):
                    continue
                wait_for_endpoint_ready(runner.base_url, target.path, max(timeout, 30.0))
                for _ in range(max(0, warmup_requests)):
                    warm = run_burst(runner.base_url, target.path, 1, max(timeout, 12.0))
                    if warm["status"] != {200: 1}:
                        raise RuntimeError(
                            f"warmup failed for {target.runtime} daemons={daemon_count}: {warm['status']}"
                        )
                samples_ms: list[float] = []
                for _ in range(repeats):
                    result = run_burst(runner.base_url, target.path, concurrency, timeout)
                    if result["status"] != {200: concurrency}:
                        raise RuntimeError(
                            f"benchmark failed for {target.runtime} daemons={daemon_count}: {result['status']}"
                        )
                    samples_ms.append(float(result["elapsed_ms"]))
                case = {
                    "runtime": target.runtime,
                    "path": target.path,
                    "daemons": daemon_count,
                    **summarize_case(samples_ms),
                }
                if daemon_count == daemon_counts[0]:
                    baseline_avg[target.runtime] = float(case["avg_ms"])
                else:
                    baseline = baseline_avg[target.runtime]
                    delta = round(baseline - float(case["avg_ms"]), 1)
                    pct = round((delta / baseline) * 100.0, 1) if baseline else 0.0
                    case["improvement_ms"] = delta
                    case["improvement_pct"] = pct
                cases.append(case)
        finally:
            runner.stop()

    report = {
        "generated_at": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "mode": mode,
        "fixture": str(fixture.relative_to(root_dir)),
        "concurrency": concurrency,
        "repeats": repeats,
        "warmup_requests_per_case": warmup_requests,
        "cases": cases,
    }
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(report, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")
    return report

def parse_int_csv(raw: str) -> list[int]:
    out: list[int] = []
    for part in raw.split(","):
        part = part.strip()
        if not part:
            continue
        out.append(int(part))
    if not out:
        raise SystemExit("empty daemon count set")
    return out


def main() -> None:
    parser = argparse.ArgumentParser(description="Benchmark FastFN runtime daemons in native or docker mode")
    parser.add_argument("--mode", choices=["native", "docker", "both"], default="both")
    parser.add_argument("--fixture", default="tests/fixtures/worker-pool")
    parser.add_argument("--runtimes", default="node,python,php,rust")
    parser.add_argument("--daemon-counts", default="1,3")
    parser.add_argument("--concurrency", type=int, default=6)
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--warmup-requests", type=int, default=2)
    parser.add_argument("--timeout", type=float, default=6.0)
    parser.add_argument("--python-bin", default="")
    parser.add_argument("--out-prefix", default="")
    args = parser.parse_args()

    root_dir = Path(__file__).resolve().parents[2]
    fixture = (root_dir / args.fixture).resolve()
    python_bin = args.python_bin.strip() or os.environ.get("PYTHON_BIN") or os.environ.get("FN_PYTHON_BIN") or sys.executable
    daemon_counts = parse_int_csv(args.daemon_counts)
    modes = ["native", "docker"] if args.mode == "both" else [args.mode]

    for mode in modes:
        if args.out_prefix:
            out_path = Path(args.out_prefix.format(mode=mode))
        else:
            out_path = root_dir / "tests" / "stress" / "results" / f"{time.strftime('%Y-%m-%d')}-runtime-daemon-scaling-{mode}.json"
        report = run_mode(
            mode=mode,
            root_dir=root_dir,
            fixture=fixture,
            runtimes=args.runtimes,
            daemon_counts=daemon_counts,
            concurrency=args.concurrency,
            repeats=args.repeats,
            warmup_requests=args.warmup_requests,
            timeout=args.timeout,
            python_bin=python_bin,
            out_path=out_path,
        )
        print(f"saved: {out_path}")
        for case in report["cases"]:
            print(
                f"{mode},{case['runtime']},daemons={case['daemons']},avg_ms={case['avg_ms']},"
                f"min_ms={case['min_ms']},max_ms={case['max_ms']}"
            )


if __name__ == "__main__":
    main()
