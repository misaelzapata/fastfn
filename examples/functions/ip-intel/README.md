# IP Intel Example

This example combines geolocation lookups from different providers in a single folder using file-based method routing.

## Run

```bash
fastfn dev examples/functions/ip-intel
```

## Routes

| Route | Method | File | What it does |
|-------|--------|------|-------------|
| `/maxmind` | GET | `get.maxmind.py` | Local MaxMind GeoIP lookup. `?ip=8.8.8.8` |
| `/remote` | GET | `get.remote.js` | Remote IP API lookup. `?ip=8.8.8.8` |

## Dependencies

- Python handler: `maxminddb` (from `requirements.txt`)
- Node handler: uses built-in `fetch`

## Test

```bash
curl -sS 'http://127.0.0.1:8080/maxmind?ip=8.8.8.8'
curl -sS 'http://127.0.0.1:8080/remote?ip=8.8.8.8'
```

## Notes

- The MaxMind handler needs a local `.mmdb` database file
- The remote handler calls an external IP geolocation API
- This shows how the same folder can mix runtimes (Python + Node) with file-based routing
