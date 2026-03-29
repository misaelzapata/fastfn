#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import os
import urllib.error
import urllib.parse
import urllib.request
from copy import deepcopy
from pathlib import Path
from typing import Any


METHODS = ["get", "post", "put", "patch", "delete", "options", "head"]


def query_param_map(op: dict[str, Any]) -> dict[str, dict[str, Any]]:
    out: dict[str, dict[str, Any]] = {}
    for param in op.get("parameters") or []:
        if isinstance(param, dict) and param.get("in") == "query" and isinstance(param.get("name"), str):
            out[param["name"]] = param
    return out


def assert_examples(openapi_path: str) -> None:
    obj = json.loads(Path(openapi_path).read_text(encoding="utf-8"))
    paths = obj.get("paths") or {}

    assert "/node/fastfn-types/d" not in paths, "must not expose .d.ts helper files as API routes"
    assert "/rust/session-demo/src" not in paths, "must not expose runtime source internals as API routes"

    telegram_send_get = ((paths.get("/telegram-send") or {}).get("get") or {})
    query = query_param_map(telegram_send_get)
    for required in ("chat_id", "text", "dry_run"):
        assert required in query, f"telegram-send GET missing query example param: {required}"

    telegram_send_post = ((paths.get("/telegram-send") or {}).get("post") or {})
    request_body = (((telegram_send_post.get("requestBody") or {}).get("content") or {}).get("application/json") or {})
    examples = request_body.get("examples") or {}
    example_values = [value.get("value") for value in examples.values() if isinstance(value, dict)]
    has_chat = any(isinstance(value, dict) and "chat_id" in value for value in example_values)
    assert has_chat, "telegram-send POST must expose chat_id example payload"

    telegram_ai_reply_post = ((paths.get("/telegram-ai-reply") or {}).get("post") or {})
    request_body = (((telegram_ai_reply_post.get("requestBody") or {}).get("content") or {}).get("application/json") or {})
    examples = request_body.get("examples") or {}
    example_values = [value.get("value") for value in examples.values() if isinstance(value, dict)]
    has_update = False
    for value in example_values:
        if not isinstance(value, dict):
            continue
        msg = value.get("message")
        chat = (msg or {}).get("chat") if isinstance(msg, dict) else None
        if isinstance(chat, dict) and "id" in chat:
            has_update = True
            break
    assert has_update, "telegram-ai-reply POST must expose webhook body example"

    edge_get = ((paths.get("/edge-header-inject") or {}).get("get") or {})
    edge_query = query_param_map(edge_get)
    assert "tenant" in edge_query, "edge-header-inject GET missing tenant query example"

    ip_remote = ((paths.get("/ip-intel/remote") or {}).get("get") or {})
    ip_query = query_param_map(ip_remote)
    for required in ("ip", "mock"):
        assert required in ip_query, f"ip-intel remote missing query param example: {required}"


def schema_example(schema: dict[str, Any] | None) -> Any:
    if not isinstance(schema, dict):
        return None
    if "example" in schema:
        return deepcopy(schema["example"])
    if "default" in schema:
        return deepcopy(schema["default"])
    if "enum" in schema and schema["enum"]:
        return deepcopy(schema["enum"][0])
    schema_type = schema.get("type")
    if schema_type == "string":
        if schema.get("format") == "email":
            return "demo@example.com"
        return "demo"
    if schema_type in ("integer", "number"):
        return 1
    if schema_type == "boolean":
        return True
    if schema_type == "array":
        return []
    if schema_type == "object":
        out: dict[str, Any] = {}
        for key, prop in (schema.get("properties") or {}).items():
            example = schema_example(prop)
            if example is not None:
                out[key] = example
        return out
    for key in ("oneOf", "anyOf", "allOf"):
        options = schema.get(key)
        if isinstance(options, list) and options:
            example = schema_example(options[0])
            if example is not None:
                return example
    return None


def param_value(param: dict[str, Any]) -> Any:
    if "example" in param:
        return deepcopy(param["example"])
    example = schema_example(param.get("schema") or {})
    if example is not None:
        return example
    name = str(param.get("name") or "").lower()
    if "id" in name:
        return "123"
    if "slug" in name or "path" in name or "wildcard" in name:
        return "demo/path"
    return "demo"


def path_with_params(path: str, params: list[dict[str, Any]]) -> str:
    out = path
    for param in params:
        if param.get("in") != "path":
            continue
        key = param.get("name")
        value = str(param_value(param))
        out = out.replace("{" + key + "}", urllib.parse.quote(value, safe=""))
    return out


def query_pairs(params: list[dict[str, Any]]) -> list[tuple[str, str]]:
    out: list[tuple[str, str]] = []
    for param in params:
        if param.get("in") != "query":
            continue
        value = param_value(param)
        if value is None:
            continue
        if isinstance(value, (dict, list)):
            value = json.dumps(value, separators=(",", ":"))
        out.append((str(param.get("name")), str(value)))
    return out


def request_body(op: dict[str, Any]) -> tuple[str | None, Any]:
    request_body_obj = op.get("requestBody")
    if not isinstance(request_body_obj, dict):
        return None, None
    content = request_body_obj.get("content") or {}
    if "application/json" in content:
        entry = content["application/json"]
        if "example" in entry:
            return "application/json", deepcopy(entry["example"])
        examples = entry.get("examples") or {}
        if isinstance(examples, dict):
            for candidate in examples.values():
                if isinstance(candidate, dict) and "value" in candidate:
                    return "application/json", deepcopy(candidate["value"])
        schema = entry.get("schema") or {}
        example = schema_example(schema)
        if example is not None:
            return "application/json", example
        return "application/json", {}
    if "text/plain" in content:
        return "text/plain", "hello"
    return None, None


def sign_github(payload: str, secret: str) -> str:
    return "sha256=" + hmac.new(secret.encode("utf-8"), payload.encode("utf-8"), hashlib.sha256).hexdigest()


def is_expected_non_2xx(item: dict[str, Any]) -> bool:
    path = item["path"]
    method = item["method"]
    code = item["code"]

    if (path.startswith("/whatsapp") or path.startswith("/node/whatsapp")) and method in ("POST", "DELETE") and code in (400, 405):
        return True

    if path == "/polyglot-db-demo/internal/items/{id}" and method in ("PUT", "DELETE") and code == 404:
        return True
    if path == "/polyglot-db-demo/items/{id}" and method in ("PUT", "DELETE") and code == 404:
        return True

    if path == "/platform-equivalents/api/v1/orders" and method == "POST" and code == 400:
        return True
    if path == "/platform-equivalents/auth/login" and method == "POST" and code == 400:
        return True
    if path == "/platform-equivalents/auth/profile" and method == "GET" and code == 401:
        return True
    if path == "/platform-equivalents/jobs/render-report" and method == "POST" and code == 400:
        return True
    if path == "/platform-equivalents/jobs/render-report/{id}" and method == "GET" and code == 404:
        return True
    if path == "/platform-equivalents/webhooks/github-signed" and method == "POST" and code == 401:
        return True

    if path in ("/node/session-demo", "/php/session-demo", "/python/session-demo") and method == "GET" and code == 401:
        return True

    return False


def run_public_sweep(base_url: str, webhook_secret: str, print_each: bool) -> None:
    openapi = json.load(urllib.request.urlopen(base_url + "/_fn/openapi.json"))
    paths = openapi.get("paths", {})
    results: list[dict[str, Any]] = []
    counter = 0

    for path in sorted(paths.keys()):
        if path.startswith("/_fn/"):
            continue
        spec = paths[path]
        if not isinstance(spec, dict):
            continue
        common_params = spec.get("parameters") or []
        for method in METHODS:
            if method not in spec:
                continue
            op = spec[method]
            params = list(common_params) + list(op.get("parameters") or [])
            route = path_with_params(path, params)
            if path == "/platform-equivalents/api/v1/orders/{id}" and method in ("get", "put"):
                route = "/platform-equivalents/api/v1/orders/1"
            query = query_pairs(params)
            url = base_url + route
            if query:
                url += "?" + urllib.parse.urlencode(query)

            headers = {"accept": "application/json"}
            body_data = None
            if method in ("post", "put", "patch", "delete"):
                content_type, payload = request_body(op)
                if content_type == "application/json":
                    headers["content-type"] = "application/json"
                    body_data = json.dumps(payload).encode("utf-8")
                elif content_type:
                    headers["content-type"] = content_type
                    body_data = payload.encode("utf-8") if isinstance(payload, str) else b""

            if path == "/polyglot-db-demo/items" and method == "post":
                headers["content-type"] = "application/json"
                body_data = json.dumps({"name": "demo-item", "source": "openapi-sweep"}).encode("utf-8")
            if path in ("/polyglot-db-demo/internal/items/{id}", "/polyglot-db-demo/items/{id}") and method == "put":
                headers["content-type"] = "application/json"
                body_data = json.dumps({"name": "demo-item-updated"}).encode("utf-8")
            if path == "/platform-equivalents/api/v1/orders" and method == "post":
                headers["content-type"] = "application/json"
                body_data = json.dumps(
                    {"customer": "OpenAPI Sweep", "items": [{"sku": "demo-1", "qty": 1}]}
                ).encode("utf-8")
            if path == "/platform-equivalents/api/v1/orders/{id}" and method == "put":
                headers["content-type"] = "application/json"
                body_data = json.dumps(
                    {"status": "processing", "tracking_number": "TRACK-OPENAPI-1"}
                ).encode("utf-8")

            if route.startswith("/edge-auth-gateway") or route.startswith("/node/edge-auth-gateway"):
                headers["authorization"] = "Bearer dev-token"
            if route.startswith("/edge-filter") or route.startswith("/node/edge-filter"):
                headers["x-api-key"] = "dev"
            if (route.startswith("/github-webhook-guard") or route.startswith("/node/github-webhook-guard")) and method == "post":
                payload = json.dumps({"zen": "Keep it logically awesome.", "hook_id": 123}, separators=(",", ":"))
                headers["content-type"] = "application/json"
                headers["x-hub-signature-256"] = sign_github(payload, webhook_secret)
                headers["x-github-event"] = "ping"
                headers["x-github-delivery"] = "sweep-1"
                body_data = payload.encode("utf-8")

            request = urllib.request.Request(url=url, method=method.upper(), headers=headers, data=body_data)
            try:
                with urllib.request.urlopen(request, timeout=25) as response:
                    code = response.getcode()
                    body = response.read().decode("utf-8", "replace")
            except urllib.error.HTTPError as err:
                code = err.code
                body = err.read().decode("utf-8", "replace")
            except Exception as err:
                code = 0
                body = str(err)

            results.append(
                {"path": path, "method": method.upper(), "code": code, "url": url, "body": body[:300]}
            )
            if print_each:
                print(f"run {method.upper()} {path} => {code}", flush=True)
            counter += 1
            if counter % 25 == 0:
                print(f"progress {counter}", flush=True)

    ok = [item for item in results if 200 <= item["code"] < 300]
    warn = [item for item in results if item["code"] in (400, 401, 403, 404, 405, 409, 422)]
    fail = [item for item in results if item["code"] == 0 or item["code"] >= 500]
    warn_expected = [item for item in warn if is_expected_non_2xx(item)]
    warn_unexpected = [item for item in warn if not is_expected_non_2xx(item)]
    fail_expected = [item for item in fail if is_expected_non_2xx(item)]
    fail_unexpected = [item for item in fail if not is_expected_non_2xx(item)]

    print(
        json.dumps(
            {
                "total": len(results),
                "ok": len(ok),
                "warn": len(warn),
                "warn_expected": len(warn_expected),
                "warn_unexpected": len(warn_unexpected),
                "fail": len(fail),
                "fail_expected": len(fail_expected),
                "fail_unexpected": len(fail_unexpected),
            },
            indent=2,
        )
    )

    if fail_unexpected:
        print("-- FAILURES --")
        for item in fail_unexpected:
            print(f"{item['method']} {item['path']} => {item['code']} | {item['body'][:200]}")
        raise SystemExit(1)

    if warn_unexpected:
        print("-- UNEXPECTED WARNINGS --")
        for item in warn_unexpected:
            print(f"{item['method']} {item['path']} => {item['code']} | {item['body'][:200]}")
        raise SystemExit(1)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)

    examples = sub.add_parser("assert-examples")
    examples.add_argument("--openapi-file", required=True)
    examples.set_defaults(func=lambda args: assert_examples(args.openapi_file))

    sweep = sub.add_parser("public-sweep")
    sweep.add_argument("--base-url", default=os.environ.get("FASTFN_TEST_BASE_URL", "http://127.0.0.1:8080"))
    sweep.add_argument("--webhook-secret", default="dev")
    sweep.add_argument("--print-each", action="store_true")
    sweep.set_defaults(
        func=lambda args: run_public_sweep(
            args.base_url,
            args.webhook_secret,
            args.print_each or os.getenv("SWEEP_PRINT_EACH", "1").strip() not in ("0", "false", "False"),
        )
    )

    return parser


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
