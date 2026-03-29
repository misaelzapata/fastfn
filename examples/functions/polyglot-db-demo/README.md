# Polyglot DB Demo

This demo shows one API backed by a shared local SQLite database (`.db.sqlite3`) used across runtimes.

## Routes

- `POST /items` -> Node (`post.items.js`) creates an item.
- `GET /items` -> Python (`get.items.py`) lists items.
- `PUT /items/:id` -> PHP (`put.items.[id].php`) updates an item.
- `DELETE /items/:id` -> Rust (`delete.items.[id].rs`) deletes an item.
- `POST /counter` -> Node (`post.counter.js`) increments a real shared counter (SQLite) and a local process counter (memory).
- `GET /counter` -> Node (`get.counter.js`) reads counter state; `?inc=1` also increments shared counter.

Internal helper routes (Node, SQLite writer helpers):

- `PUT /internal/items/:id`
- `DELETE /internal/items/:id`

## Run

```bash
./bin/fastfn dev examples/functions/polyglot-db-demo
```

## Try

```bash
curl -sS http://127.0.0.1:8080/items

curl -sS -X POST http://127.0.0.1:8080/items \
  -H 'content-type: application/json' \
  --data '{"name":"first item"}'

curl -sS http://127.0.0.1:8080/items

curl -sS -X PUT http://127.0.0.1:8080/items/1 \
  -H 'content-type: application/json' \
  --data '{"name":"updated item"}'

curl -sS -X DELETE http://127.0.0.1:8080/items/1

curl -sS -X POST http://127.0.0.1:8080/counter

curl -sS http://127.0.0.1:8080/counter

curl -sS 'http://127.0.0.1:8080/counter?inc=1'
```

Notes:

- The SQLite DB file is created automatically on first write.
- `POST /counter` persists the shared value in SQLite, so it survives cross-process calls.
- The response also includes process-local counters to show warm state per worker.
- If you run from `examples/functions` root, this demo uses `examples/functions/polyglot-db-demo/.db.sqlite3`.
- If you run from `examples/functions/polyglot-db-demo`, it uses `examples/functions/polyglot-db-demo/.db.sqlite3`.
