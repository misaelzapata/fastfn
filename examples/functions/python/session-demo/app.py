"""Session & cookie demo — shows how to access event.session in Python.

Usage:
  Send a request with Cookie header: session_id=abc123; theme=dark
  The handler reads event.session.cookies, event.session.id, and prints debug info.

event.session shape:
  - id:      auto-detected from session_id / sessionid / sid cookies (or null)
  - raw:     the full Cookie header string
  - cookies: dict of parsed cookie key/value pairs
"""
import json


def handler(event):
    session = event.get("session") or {}
    cookies = session.get("cookies") or {}

    # Demonstrate stdout capture — this will appear in Quick Test > stdout
    print(f"[session-demo] session_id = {session.get('id')}")
    print(f"[session-demo] cookies = {cookies}")

    # Check for authentication
    session_id = session.get("id")
    if not session_id:
        return {
            "status": 401,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({
                "error": "No session cookie found",
                "hint": "Send Cookie: session_id=your-token",
            }),
        }

    return {
        "status": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({
            "authenticated": True,
            "session_id": session_id,
            "theme": cookies.get("theme", "light"),
            "all_cookies": cookies,
        }),
    }
