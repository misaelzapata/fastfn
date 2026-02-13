# Versioning & Rollout <small>🚀</small>

In production, you often need to update an API without breaking existing clients. `fastfn` has built-in support for **Function Versioning**.

---

## 🎯 The Strategy

We will use a "Side-by-Side" deployment strategy:
1.  **V1 (Default)**: The current production version.
2.  **V2 (Beta)**: A new version with changes, accessible via a specific tag.

---

## 1. The Default Version (V1)

Let's assume you have a `hello` function in `functions/python/hello/app.py`.

```python
# functions/python/hello/app.py
def handler(context):
    return {"message": "Hello from V1"}
```

Call it:
```bash
curl 'http://127.0.0.1:8080/fn/hello'
```
**Output:** `{"message": "Hello from V1"}`

---

## 2. Deploy Version 2 (V2) 🆕

To create a new version, simply create a subfolder with the version name.

**Structure:**
```text
functions/
└── python/
    └── hello/
        ├── app.py       <-- Default (V1)
        └── v2/          <-- New Version
            └── app.py
```

Let's create the V2 code:

**File:** `functions/python/hello/v2/app.py`
```python
def handler(context):
    # V2 returns a different structure
    return {
        "status": "success",
        "data": {
            "greeting": "Hello from V2 [BETA]"
        }
    }
```

---

## 3. Accessing Specific Versions 🏷️

`fastfn` uses the `@` syntax to target versions.

### Call V2 Explicitly
```bash
curl 'http://127.0.0.1:8080/fn/hello@v2'
```

**Response:**
```json
{
  "status": "success",
  "data": {
    "greeting": "Hello from V2 [BETA]"
  }
}
```

### Call Default (V1)
The original URL still properly routes to the root `app.py`.
```bash
curl 'http://127.0.0.1:8080/fn/hello'
```

**Response:**
```json
{
  "message": "Hello from V1"
}
```

---

## 4. Rollout Strategy 🔀

This mechanism allows for a smooth migration:

1.  **Deploy V2**: Create the `v2` folder. It is now live at `@v2` but no one uses it yet.
2.  **Internal Testing**: Your QA team verifies `.../hello@v2`.
3.  **Client Migration**: Update your frontend to point to `@v2`.
4.  **Deprecation**: Once V1 traffic drops to zero, you can delete `functions/python/hello/app.py` (and maybe move `v2` to root if desired).

!!! tip "URL Structure"
    The pattern is always `/fn/<function_name>@<version>`.
    Versions can be named anything alphanumeric: `v2`, `beta`, `rc1`, `2023-10`.

[Next: Authentication & Secrets :arrow_right:](./auth-and-secrets.md){ .md-button .md-button--primary }
