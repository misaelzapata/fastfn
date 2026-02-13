import json
from pathlib import Path


COUNT_PATH = Path(__file__).with_name("count.txt")


def _read_count() -> int:
    try:
        raw = COUNT_PATH.read_text(encoding="utf-8").strip()
        return int(raw) if raw else 0
    except Exception:
        return 0


def _write_count(v: int) -> None:
    COUNT_PATH.write_text(str(int(v)) + "\n", encoding="utf-8")


def handler(event):
    query = event.get("query") or {}
    action = query.get("action", "read")

    count = _read_count()
    if action == "inc":
        count += 1
        _write_count(count)

    return {
        "status": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({"function": "cron_tick", "action": action, "count": count}),
    }

