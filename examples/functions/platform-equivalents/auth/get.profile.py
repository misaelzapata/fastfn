# GET /auth/profile — Verify a bearer token and return the user profile
import base64
import hashlib
import hmac
import json
import time

DEFAULT_SECRET = "fastfn-auth-secret"


def handler(event):
    # Extract the bearer token from the Authorization header
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    auth = headers.get("authorization", "")
    if not auth.startswith("Bearer "):
        return {"status": 401, "body": json.dumps({"error": "Missing Authorization: Bearer <token>"})}

    token = auth[len("Bearer "):]
    parts = token.split(".")
    if len(parts) != 2:
        return {"status": 401, "body": json.dumps({"error": "Malformed token"})}

    encoded_payload, received_sig = parts

    # Verify the HMAC signature
    secret = ((event.get("env") or {}).get("AUTH_SECRET") or DEFAULT_SECRET)
    expected_sig = hmac.new(secret.encode(), encoded_payload.encode(), hashlib.sha256).hexdigest()
    if not hmac.compare_digest(received_sig, expected_sig):
        return {"status": 401, "body": json.dumps({"error": "Invalid signature"})}

    # Decode and check expiration
    padding = "=" * (-len(encoded_payload) % 4)
    payload = json.loads(base64.urlsafe_b64decode(encoded_payload + padding))

    if payload.get("exp", 0) <= int(time.time()):
        return {"status": 401, "body": json.dumps({"error": "Token expired"})}

    return {
        "status": 200,
        "body": json.dumps({
            "sub": payload.get("sub"),
            "role": payload.get("role"),
            "expires_at": payload.get("exp"),
        }),
    }
