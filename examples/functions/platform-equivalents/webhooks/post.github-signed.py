import hashlib
import hmac
import json
from pathlib import Path
from typing import Any, Dict, List

DEFAULT_WEBHOOK_SECRET = "fastfn-webhook-secret"


def _json(status: int, payload: Dict[str, Any]) -> Dict[str, Any]:
    return {
        "status": status,
        "headers": {"Content-Type": "application/json; charset=utf-8"},
        "body": json.dumps(payload, separators=(",", ":")),
    }


def _headers_lower(event: Dict[str, Any]) -> Dict[str, str]:
    raw = event.get("headers") or {}
    out: Dict[str, str] = {}
    if isinstance(raw, dict):
        for k, v in raw.items():
            out[str(k).lower()] = str(v)
    return out


def _state_file() -> Path:
    state_dir = Path("/tmp/fastfn-platform-equivalents")
    state_dir.mkdir(parents=True, exist_ok=True)
    return state_dir / "processed-webhooks.json"


def _load_deliveries(path: Path) -> List[str]:
    if not path.exists():
        return []
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
        if isinstance(raw, list):
            return [str(x) for x in raw]
    except Exception:
        pass
    return []


def _save_deliveries(path: Path, deliveries: List[str]) -> None:
    path.write_text(json.dumps(deliveries, indent=2), encoding="utf-8")


def handler(event: Dict[str, Any]) -> Dict[str, Any]:
    headers = _headers_lower(event)
    signature = headers.get("x-hub-signature-256", "")
    if not signature:
        return _json(401, {"error": "missing_signature", "message": "Expected x-hub-signature-256 header."})

    body_raw = event.get("body")
    if body_raw is None:
        body_raw = ""
    if not isinstance(body_raw, str):
        body_raw = json.dumps(body_raw, separators=(",", ":"))

    secret = str((event.get("env") or {}).get("WEBHOOK_SECRET") or DEFAULT_WEBHOOK_SECRET)
    expected = "sha256=" + hmac.new(secret.encode("utf-8"), body_raw.encode("utf-8"), hashlib.sha256).hexdigest()
    if not hmac.compare_digest(signature, expected):
        return _json(401, {"error": "invalid_signature", "message": "Webhook signature mismatch."})

    delivery_id = headers.get("x-github-delivery", "").strip()
    if not delivery_id:
        delivery_id = hashlib.sha256(body_raw.encode("utf-8")).hexdigest()

    state = _state_file()
    processed = _load_deliveries(state)
    if delivery_id in processed:
        return _json(
            200,
            {
                "ok": True,
                "duplicate": True,
                "delivery_id": delivery_id,
                "message": "Delivery already processed.",
            },
        )

    processed.append(delivery_id)
    _save_deliveries(state, processed[-500:])

    payload: Dict[str, Any]
    try:
        maybe = json.loads(body_raw or "{}")
        payload = maybe if isinstance(maybe, dict) else {}
    except Exception:
        payload = {}

    return _json(
        202,
        {
            "ok": True,
            "duplicate": False,
            "delivery_id": delivery_id,
            "event": headers.get("x-github-event", "unknown"),
            "summary": {
                "action": payload.get("action"),
                "repository": ((payload.get("repository") or {}).get("full_name") if isinstance(payload.get("repository"), dict) else payload.get("repository")),
            },
        },
    )
