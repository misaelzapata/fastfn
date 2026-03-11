import json
import time
from pathlib import Path
from typing import Any, Dict, List


def _json(status: int, payload: Dict[str, Any]) -> Dict[str, Any]:
    return {
        "status": status,
        "headers": {"Content-Type": "application/json; charset=utf-8"},
        "body": json.dumps(payload, separators=(",", ":")),
    }


def _orders_file() -> Path:
    state_dir = Path("/tmp/fastfn-platform-equivalents")
    state_dir.mkdir(parents=True, exist_ok=True)
    return state_dir / "orders.json"


def _load_orders(path: Path) -> List[Dict[str, Any]]:
    if not path.exists():
        return []
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
        if isinstance(raw, list):
            return [x for x in raw if isinstance(x, dict)]
    except Exception:
        pass
    return []


def _save_orders(path: Path, orders: List[Dict[str, Any]]) -> None:
    path.write_text(json.dumps(orders, indent=2), encoding="utf-8")


def _parse_body(event: Dict[str, Any]) -> Dict[str, Any]:
    body = event.get("body")
    if body is None or body == "":
        return {}
    if isinstance(body, dict):
        return body
    if isinstance(body, str):
        parsed = json.loads(body)
        if isinstance(parsed, dict):
            return parsed
        raise ValueError("JSON body must decode to an object")
    raise ValueError("Unsupported body format")


def handler(event: Dict[str, Any]) -> Dict[str, Any]:
    try:
        data = _parse_body(event)
    except Exception:
        return _json(400, {"error": "invalid_json", "message": "Body must be valid JSON."})

    customer = str(data.get("customer") or "").strip()
    items = data.get("items")

    if not customer:
        return _json(400, {"error": "validation_error", "message": "customer is required."})
    if not isinstance(items, list) or not items:
        return _json(400, {"error": "validation_error", "message": "items must be a non-empty array."})

    clean_items: List[Dict[str, Any]] = []
    for idx, item in enumerate(items, start=1):
        if not isinstance(item, dict):
            return _json(400, {"error": "validation_error", "message": f"items[{idx}] must be an object."})
        sku = str(item.get("sku") or "").strip()
        qty = int(item.get("qty") or 0)
        if not sku or qty <= 0:
            return _json(400, {"error": "validation_error", "message": f"items[{idx}] requires sku and qty>0."})
        clean_items.append({"sku": sku, "qty": qty})

    path = _orders_file()
    orders = _load_orders(path)
    next_id = int(max([int(o.get("id") or 0) for o in orders] + [0])) + 1

    order = {
        "id": next_id,
        "customer": customer,
        "items": clean_items,
        "status": "pending",
        "created_at": int(time.time()),
        "tracking_number": None,
    }
    orders.append(order)
    _save_orders(path, orders)

    return _json(201, {"ok": True, "order": order})
