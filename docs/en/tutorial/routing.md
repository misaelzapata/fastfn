# Routing

FastFN uses **file-system routing**, similar to Next.js.

The file structure of your project determines the public URL paths.

## Basic Routing

| File Path | URL Path |
| :--- | :--- |
| `functions/users.py` | `/fn/users` |
| `functions/settings/profile.js` | `/fn/settings/profile` |

## Dynamic Segments

You can use brackets `[]` to create dynamic path parameters.

| File Path | URL Path | Example Match |
| :--- | :--- | :--- |
| `functions/users/[id].py` | `/fn/users/:id` | `/fn/users/42` |
| `functions/posts/[category]/[slug].py` | `/fn/posts/:category/:slug` | `/fn/posts/tech/fastfn-intro` |

### Accessing Parameters

Inside your handler, the parameters are available in the `context` (Node) or `event` (Python).

**Python (`event`)**:
```python
def handler(event):
    # For /fn/users/42, user_id will be "42"
    user_id = event.get("params", {}).get("id")
    return {"status": 200, "body": user_id}
```

**Node (`event` or `context`)**:
```javascript
exports.handler = async (event) => {
    // For /fn/users/42, userId will be "42"
    const userId = event.params.id;
    return { status: 200, body: userId };
};
```

## Route Precedence

If you have overlapping routes, FastFN follows strict precedence:

1.  **Static Routes**: `functions/users/settings.py` (Specific)
2.  **Dynamic Routes**: `functions/users/[id].py` (General)
3.  **Catch-all Routes**: `functions/users/[...slug].py` (Most General)

## HTTP Methods

By default, a handler file accepts **ALL** methods (`GET`, `POST`, `PUT`, `DELETE`).

To restrict methods or handle them differently:

### Option 1: Logic inside handler

```python
def handler(event):
    method = event.get("method")
    
    if method == "POST":
         return create_item(event)
    elif method == "GET":
         return get_item(event)
    
    return {"status": 405, "body": "Method not allowed"}
```

### Option 2: `fn.config.json`

Add a config file next to your handler:

`functions/users/[id]/fn.config.json`:
```json
{
  "invoke": {
    "methods": ["GET"]
  }
}
```

Now `POST /fn/users/42` will automatically return `405 Method Not Allowed`.

[Next: Operational Recipes :arrow_right:](../how-to/operational-recipes.md)
