import json
import os
import sqlite3
from pathlib import Path

DEMO_DIR = "polyglot-db-demo"


def _resolve_db_path(event):
    root = os.environ.get("FN_FUNCTIONS_ROOT") or str(Path(__file__).resolve().parent)
    req_path = str((event or {}).get("path") or "")
    if req_path.startswith(f"/{DEMO_DIR}/"):
        return Path(root) / DEMO_DIR / ".db.sqlite3"
    return Path(root) / ".db.sqlite3"


def _ensure_schema(conn):
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS items (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            created_by TEXT NOT NULL,
            updated_by TEXT NOT NULL,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        )
        """
    )
    conn.commit()


def handler(event):
    db_path = _resolve_db_path(event or {})
    db_path.parent.mkdir(parents=True, exist_ok=True)

    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    try:
        _ensure_schema(conn)
        rows = conn.execute(
            "SELECT id, name, created_by, updated_by, created_at, updated_at FROM items ORDER BY id ASC"
        ).fetchall()
        items = [
            {
                "id": str(row["id"]),
                "name": row["name"],
                "created_by": row["created_by"],
                "updated_by": row["updated_by"],
                "created_at": row["created_at"],
                "updated_at": row["updated_at"],
            }
            for row in rows
        ]
    finally:
        conn.close()

    return {
        "status": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(
            {
                "runtime": "python",
                "route": "GET /items",
                "items": items,
                "count": len(items),
                "db_file": db_path.name,
                "db_kind": "sqlite",
            }
        ),
    }
