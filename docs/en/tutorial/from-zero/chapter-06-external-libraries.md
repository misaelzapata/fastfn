# Chapter 6 - External Libraries (Dependencies)

**Goal**: Install dependencies per function (auto-install) and understand Cold Starts.

## How it works

FastFN automatically detects dependency files in your function folder and installs them for you:

- **Node.js**: `package.json` -> `npm install`
- **Python**: `requirements.txt` -> `pip install`
- **PHP**: `composer.json` -> `composer install`
- **Rust/Go**: compiled at build time.

## Node.js Example

### Step 1: Create `package.json`

Create `functions/hello-world/package.json`:

```json
{
  "name": "hello-world",
  "private": true,
  "dependencies": {
    "dayjs": "^1.11.13"
  }
}
```

### Step 2: Use the library

Modify `functions/hello-world/get.js`:

```js
const dayjs = require("dayjs");

exports.handler = async () => ({
  status: 200,
  headers: { "Content-Type": "application/json" },
  body: JSON.stringify({ 
    message: "Using external lib",
    now: dayjs().toISOString() 
  }),
});
```

### Step 3: Invoke (Cold Start)

```bash
curl -sS 'http://127.0.0.1:8080/hello-world'
```

!!! warning "The Cold Start"
    The **first request** after adding dependencies might take longer (e.g., 2-5 seconds).
    
    Why?
    1. FastFN detects the new `package.json`.
    2. It runs `npm install` inside the isolated environment.
    3. It starts the function process.
    
    Subsequent requests will be instant (milliseconds) because the environment is kept warm.

## Python Example

For clarity, use a separate Python function (so we don't mix runtimes in the same folder).

### Step 1: Create the function

Create:

- `functions/http-client/get.py`
- `functions/http-client/requirements.txt`

`functions/http-client/requirements.txt`:

```text
requests==2.31.0
```

`functions/http-client/get.py`:

```python
import requests

def main(req):
    return {"requests_version": requests.__version__}
```

### Step 2: Invoke (Cold Start)

```bash
curl -sS 'http://127.0.0.1:8080/http-client'
```

**Note**: Python also has a Cold Start on the first import of heavy libraries.
