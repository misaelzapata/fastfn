# Chapter 9 - Shared Code & Dependencies

**Goal**: Share common logic (database connections, auth helpers) across multiple functions.

You can keep shared code under `functions/.shared/` and import it from your handlers.

Using a dot-folder keeps it out of the public routing tree.

## 1. Creating Shared Logic

Create `functions/.shared/db.js`:

```js
// This file is available to all Node functions!
const connect = () => {
    return { status: "connected" };
};

module.exports = { connect };
```

## 2. Using Shared Code

Create `functions/users/get.js`:

```js
const db = require("../.shared/db");

exports.handler = async () => {
  const conn = db.connect();
  return {
    status: 200,
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ message: "Users list", db_status: conn.status }),
  };
};
```

## 3. Shared Dependencies (Packs)

If multiple functions use the same dependencies (for example `dayjs`, `pandas`), define a shared pack and reference it from `fn.config.json`.

Packs live under:

```text
functions/.fastfn/packs/node/<pack>/package.json
functions/.fastfn/packs/python/<pack>/requirements.txt
```

Then reference it from any function directory:

`functions/users/fn.config.json`

```json
{ "shared_deps": ["<pack>"] }
```

## Shared env strategy (simple and practical)

Keep per-function `fn.env.json`, but generate it from a base template in CI/CD.

Recommended approach:

1. `env.base.json` in internal tooling repo
2. per-function override files
3. merge script outputs final `fn.env.json`

This keeps runtime simple while avoiding duplicated manual edits.

## One important rule

Keep shared code in a dot-folder like `functions/.shared/`.

FastFN ignores dot-folders for routing, which prevents accidental public endpoints like `/.shared/*`.
