import base64
import hashlib
import hmac
import json
import time
from typing import Any, Dict, Optional

DEFAULT_AUTH_SECRET = "fastfn-auth-secret"


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


def _decode_payload(encoded: str) -> Dict[str, Any]:
    padding = "=" * (-len(encoded) % 4)
    decoded = base64.urlsafe_b64decode((encoded + padding).encode("utf-8"))
    obj = json.loads(decoded.decode("utf-8"))
    if not isinstance(obj, dict):
        raise ValueError("payload must be an object")
    return obj


def _extract_token(headers: Dict[str, str]) -> Optional[str]:
    auth = headers.get("authorization", "").strip()
    if not auth or " " not in auth:
        return None
    scheme, token = auth.split(" ", 1)
    if scheme.lower() != "bearer":
        return None
    token = token.strip()
    return token or None


def handler(event: Dict[str, Any]) -> Dict[str, Any]:
    headers = _headers_lower(event)
    token = _extract_token(headers)
    if not token:
        return _json(401, {"error": "missing_token", "message": "Use Authorization: Bearer <token>."})

    parts = token.split(".")
    if len(parts) != 2:
        return _json(401, {"error": "invalid_token", "message": "Malformed token format."})

    encoded_payload, received_sig = parts
    secret = str((event.get("env") or {}).get("AUTH_SECRET") or DEFAULT_AUTH_SECRET)
    expected_sig = hmac.new(secret.encode("utf-8"), encoded_payload.encode("utf-8"), hashlib.sha256).hexdigest()
    if not hmac.compare_digest(received_sig, expected_sig):
        return _json(401, {"error": "invalid_token", "message": "Signature mismatch."})

    try:
        payload = _decode_payload(encoded_payload)
    except Exception:
        return _json(401, {"error": "invalid_token", "message": "Token payload decode failed."})

    now = int(time.time())
    exp = int(payload.get("exp") or 0)
    if exp <= now:
        return _json(401, {"error": "expired_token", "message": "Token is expired."})

    return _json(
        200,
        {
            "sub": payload.get("sub"),
            "role": payload.get("role"),
            "issued_at": payload.get("iat"),
            "expires_at": exp,
            "issuer": payload.get("iss"),
            "auth_mode": "hmac-bearer",
        },
    )

