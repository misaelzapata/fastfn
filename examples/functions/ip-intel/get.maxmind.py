# @summary IP intel via MaxMind database
# @methods GET
# @query {"ip":"8.8.8.8","mock":"1"}

import ipaddress
import json
import os
from pathlib import Path

try:
    import maxminddb
except Exception:  # pragma: no cover - optional dependency in local/dev
    maxminddb = None


def _json_response(status, payload):
    return {
        "status": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(payload, separators=(",", ":"), ensure_ascii=False),
    }


def _pick_db_path(event_env):
    return str(
        event_env.get("MAXMIND_DB_PATH")
        or event_env.get("GEOIP2_DB_PATH")
        or os.environ.get("MAXMIND_DB_PATH")
        or os.environ.get("GEOIP2_DB_PATH")
        or "/tmp/GeoLite2-Country.mmdb"
    )


def _extract_country(record):
    if not isinstance(record, dict):
        return None
    country = record.get("country") or {}
    iso = country.get("iso_code")
    names = country.get("names") or {}
    name = names.get("en") or names.get("es") or names.get("pt-BR") or names.get("fr")
    if not iso:
        return None
    return {"country_code": iso, "country_name": name or ""}


def handler(event):
    event = event or {}
    query = event.get("query") or {}
    client = event.get("client") or {}
    env = event.get("env") or {}

    ip_raw = str(query.get("ip") or client.get("ip") or "").strip()
    if not ip_raw:
        return _json_response(400, {"ok": False, "error": "missing ip. Use ?ip=8.8.8.8"})

    try:
        ip_obj = ipaddress.ip_address(ip_raw)
    except ValueError:
        return _json_response(400, {"ok": False, "error": "invalid ip", "ip": ip_raw})

    # Deterministic mode for tests/CI where GeoLite DB may not exist.
    if str(query.get("mock") or "").lower() in {"1", "true"}:
        return _json_response(
            200,
            {
                "ok": True,
                "provider": "maxmind-mock",
                "ip": ip_raw,
                "country_code": "US",
                "country_name": "United States",
                "database": "mock",
            },
        )

    if maxminddb is None:
        return _json_response(
            501,
            {
                "ok": False,
                "error": "maxminddb package is not installed",
                "hint": "Add maxminddb in requirements.txt and run fastfn dev to auto-install deps",
            },
        )

    db_path = _pick_db_path(env)
    if not Path(db_path).exists():
        return _json_response(
            424,
            {
                "ok": False,
                "error": "maxmind database not found",
                "database": db_path,
                "hint": "Set MAXMIND_DB_PATH to GeoLite2-Country.mmdb",
            },
        )

    with maxminddb.open_database(db_path) as reader:
        record = reader.get(str(ip_obj))

    country = _extract_country(record)
    if country is None:
        return _json_response(
            404,
            {
                "ok": False,
                "provider": "maxmind",
                "ip": ip_raw,
                "database": db_path,
                "message": "country not found for ip",
            },
        )

    return _json_response(
        200,
        {
            "ok": True,
            "provider": "maxmind",
            "ip": ip_raw,
            "country_code": country["country_code"],
            "country_name": country["country_name"],
            "database": db_path,
        },
    )
