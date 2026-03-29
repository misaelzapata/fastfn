# Request Validation and Schemas

> Verified status as of **March 13, 2026**.

## Quick View

- Complexity: Intermediate
- Typical time: 30-40 minutes
- Outcome: predictable input contracts with clear `400`/`422` errors

## Example handler (Node, Python, Rust, PHP)

Path used in this guide: `functions/orders/[id]/post.*`

=== "Node.js"
    ```js
    const ISO_DATE = /^\d{4}-\d{2}-\d{2}$/;

    exports.handler = async (event, { id }) => {
      const orderId = Number(id);
      if (!Number.isInteger(orderId) || orderId < 1 || orderId > 999999) {
        return { status: 422, body: { error: "id must be an integer between 1 and 999999" } };
      }

      const source = event.query?.source || "web";
      if (source.length < 2 || source.length > 20) {
        return { status: 422, body: { error: "source length must be between 2 and 20" } };
      }

      let body;
      try { body = JSON.parse(event.body || "{}"); }
      catch { return { status: 400, body: { error: "invalid JSON body" } }; }

      if (!body.customer || typeof body.customer.name !== "string") {
        return { status: 422, body: { error: "customer.name is required" } };
      }
      if (!Array.isArray(body.items) || body.items.length === 0) {
        return { status: 422, body: { error: "items must be a non-empty array" } };
      }
      if (body.delivery_date && !ISO_DATE.test(body.delivery_date)) {
        return { status: 422, body: { error: "delivery_date must use YYYY-MM-DD" } };
      }

      return { status: 201, body: { order_id: orderId, source, customer: body.customer, items: body.items, delivery_date: body.delivery_date || null, gift: Boolean(body.gift) } };
    };
    ```

=== "Python"
    ```python
    import json
    import re

    ISO_DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")

    def handler(event, params):
        order_id = int(params.get("id", 0))
        if order_id < 1 or order_id > 999999:
            return {"status": 422, "body": {"error": "id must be an integer between 1 and 999999"}}

        query = event.get("query") or {}
        source = query.get("source", "web")
        if len(source) < 2 or len(source) > 20:
            return {"status": 422, "body": {"error": "source length must be between 2 and 20"}}

        try:
            body = json.loads(event.get("body") or "{}")
        except Exception:
            return {"status": 400, "body": {"error": "invalid JSON body"}}

        if not isinstance(body.get("customer"), dict) or not isinstance(body["customer"].get("name"), str):
            return {"status": 422, "body": {"error": "customer.name is required"}}
        if not isinstance(body.get("items"), list) or len(body["items"]) == 0:
            return {"status": 422, "body": {"error": "items must be a non-empty array"}}
        if body.get("delivery_date") and not ISO_DATE.match(body["delivery_date"]):
            return {"status": 422, "body": {"error": "delivery_date must use YYYY-MM-DD"}}

        return {"status": 201, "body": {"order_id": order_id, "source": source, "customer": body["customer"], "items": body["items"], "delivery_date": body.get("delivery_date"), "gift": bool(body.get("gift"))}}
    ```

=== "Rust"
    ```rust
    use regex::Regex;
    use serde_json::{json, Value};

    pub fn handler(event: Value, params: Value) -> Value {
        let order_id = params.get("id").and_then(|x| x.as_str()).and_then(|x| x.parse::<i64>().ok()).unwrap_or(0);
        if !(1..=999999).contains(&order_id) {
            return json!({"status": 422, "body": {"error": "id must be an integer between 1 and 999999"}});
        }

        let source = event.get("query").and_then(|q| q.get("source")).and_then(|x| x.as_str()).unwrap_or("web");
        if source.len() < 2 || source.len() > 20 {
            return json!({"status": 422, "body": {"error": "source length must be between 2 and 20"}});
        }

        let raw = event.get("body").and_then(|b| b.as_str()).unwrap_or("{}");
        let body: Value = match serde_json::from_str(raw) {
            Ok(v) => v,
            Err(_) => return json!({"status": 400, "body": {"error": "invalid JSON body"}}),
        };

        if body.get("customer").and_then(|c| c.get("name")).and_then(|n| n.as_str()).is_none() {
            return json!({"status": 422, "body": {"error": "customer.name is required"}});
        }
        if !body.get("items").map(|v| v.is_array()).unwrap_or(false) || body["items"].as_array().unwrap().is_empty() {
            return json!({"status": 422, "body": {"error": "items must be a non-empty array"}});
        }

        if let Some(date) = body.get("delivery_date").and_then(|d| d.as_str()) {
            let re = Regex::new(r"^\d{4}-\d{2}-\d{2}$").unwrap();
            if !re.is_match(date) {
                return json!({"status": 422, "body": {"error": "delivery_date must use YYYY-MM-DD"}});
            }
        }

        json!({"status": 201, "body": {"order_id": order_id, "source": source, "customer": body["customer"], "items": body["items"], "delivery_date": body.get("delivery_date"), "gift": body.get("gift").and_then(|g| g.as_bool()).unwrap_or(false)}})
    }
    ```

=== "PHP"
    ```php
    <?php

    function handler(array $event, array $params): array {
        $orderId = intval($params['id'] ?? 0);
        if ($orderId < 1 || $orderId > 999999) {
            return ['status' => 422, 'body' => ['error' => 'id must be an integer between 1 and 999999']];
        }

        $query = $event['query'] ?? [];
        $source = $query['source'] ?? 'web';
        if (strlen($source) < 2 || strlen($source) > 20) {
            return ['status' => 422, 'body' => ['error' => 'source length must be between 2 and 20']];
        }

        $raw = $event['body'] ?? '{}';
        $body = json_decode($raw, true);
        if (!is_array($body)) return ['status' => 400, 'body' => ['error' => 'invalid JSON body']];

        if (!isset($body['customer']['name']) || !is_string($body['customer']['name'])) {
            return ['status' => 422, 'body' => ['error' => 'customer.name is required']];
        }
        if (!isset($body['items']) || !is_array($body['items']) || count($body['items']) === 0) {
            return ['status' => 422, 'body' => ['error' => 'items must be a non-empty array']];
        }
        if (!empty($body['delivery_date']) && !preg_match('/^\d{4}-\d{2}-\d{2}$/', $body['delivery_date'])) {
            return ['status' => 422, 'body' => ['error' => 'delivery_date must use YYYY-MM-DD']];
        }

        return ['status' => 201, 'body' => ['order_id' => $orderId, 'source' => $source, 'customer' => $body['customer'], 'items' => $body['items'], 'delivery_date' => $body['delivery_date'] ?? null, 'gift' => (bool)($body['gift'] ?? false)]];
    }
    ```

## Validation curls (per runtime)

=== "Node.js"
    ```bash
    curl -sS -X POST 'http://127.0.0.1:8080/orders/7?source=w' -H 'Content-Type: application/json' -d '{"customer":{"name":"Ana"},"items":[{"sku":"A1","qty":1}]}'
    curl -sS -X POST 'http://127.0.0.1:8080/orders/0' -H 'Content-Type: application/json' -d '{"customer":{"name":"Ana"},"items":[{"sku":"A1","qty":1}]}'
    curl -sS -X POST 'http://127.0.0.1:8080/orders/7' -H 'Content-Type: application/json' -d '{"items":[{"sku":"A1","qty":1}]}'
    ```

=== "Python"
    ```bash
    curl -sS -X POST 'http://127.0.0.1:8080/orders/7?source=w' -H 'Content-Type: application/json' -d '{"customer":{"name":"Ana"},"items":[{"sku":"A1","qty":1}]}'
    curl -sS -X POST 'http://127.0.0.1:8080/orders/0' -H 'Content-Type: application/json' -d '{"customer":{"name":"Ana"},"items":[{"sku":"A1","qty":1}]}'
    curl -sS -X POST 'http://127.0.0.1:8080/orders/7' -H 'Content-Type: application/json' -d '{"items":[{"sku":"A1","qty":1}]}'
    ```

=== "Rust"
    ```bash
    curl -sS -X POST 'http://127.0.0.1:8080/orders/7?source=w' -H 'Content-Type: application/json' -d '{"customer":{"name":"Ana"},"items":[{"sku":"A1","qty":1}]}'
    curl -sS -X POST 'http://127.0.0.1:8080/orders/0' -H 'Content-Type: application/json' -d '{"customer":{"name":"Ana"},"items":[{"sku":"A1","qty":1}]}'
    curl -sS -X POST 'http://127.0.0.1:8080/orders/7' -H 'Content-Type: application/json' -d '{"items":[{"sku":"A1","qty":1}]}'
    ```

=== "PHP"
    ```bash
    curl -sS -X POST 'http://127.0.0.1:8080/orders/7?source=w' -H 'Content-Type: application/json' -d '{"customer":{"name":"Ana"},"items":[{"sku":"A1","qty":1}]}'
    curl -sS -X POST 'http://127.0.0.1:8080/orders/0' -H 'Content-Type: application/json' -d '{"customer":{"name":"Ana"},"items":[{"sku":"A1","qty":1}]}'
    curl -sS -X POST 'http://127.0.0.1:8080/orders/7' -H 'Content-Type: application/json' -d '{"items":[{"sku":"A1","qty":1}]}'
    ```

## Path + body contract

| Field | Source | Required | Type | Rule |
|---|---|---|---|---|
| `id` | path | yes | integer | 1..999999 |
| `source` | query | no | string | default `web`, len 2..20 |
| `customer.name` | body | yes | string | non-empty |
| `items` | body | yes | array | at least 1 element |
| `delivery_date` | body | no | string | `YYYY-MM-DD` |

## Validation checklist

- Invalid JSON returns `400`
- Contract violations return `422`
- Valid payload returns `201`
- Endpoint appears in OpenAPI at `/openapi.json`

## Related links

- [Part 2: Routing and data](./from-zero/2-routing-and-data.md)
- [Request metadata and files](./request-metadata-and-files.md)
- [HTTP API reference](../reference/http-api.md)
