# POST /api/v1/orders — Create a new order
import json
import time
from pathlib import Path

STATE_FILE = Path("/tmp/fastfn-platform-equivalents/orders.json")


def load_orders():
    try:
        return json.loads(STATE_FILE.read_text())
    except Exception:
        return []


def save_orders(orders):
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    STATE_FILE.write_text(json.dumps(orders, indent=2))


def handler(event):
    # Parse the request body
    body = event.get("body", {})
    if isinstance(body, str):
        body = json.loads(body)

    customer = (body.get("customer") or "").strip()
    items = body.get("items", [])

    if not customer:
        return {"status": 400, "body": json.dumps({"error": "customer is required"})}
    if not items:
        return {"status": 400, "body": json.dumps({"error": "items is required"})}

    # Create the order and persist it
    orders = load_orders()
    next_id = max((o.get("id", 0) for o in orders), default=0) + 1

    order = {
        "id": next_id,
        "customer": customer,
        "items": items,
        "status": "pending",
        "created_at": int(time.time()),
    }
    orders.append(order)
    save_orders(orders)

    return {"status": 201, "body": json.dumps({"ok": True, "order": order})}
