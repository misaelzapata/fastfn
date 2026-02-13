# 🧪 User & AI Manual Test Guide

This guide ensures that FastFn is working correctly from end-to-end. We will follow these steps together to verify the system.

## 📋 Pre-flight Check

- [ ] **Docker is running**: Ensure Docker Desktop is active.
- [ ] **Go Installed**: `go version` should return 1.20+.
- [ ] **Ports Free**: Ensure port `8080` is available.

## 🚀 Step 1: Clean Slate

We will start by cleaning up any previous artifacts.

```bash
make clean
rm -f bin/fastfn
```

## 🛠️ Step 2: Build the CLI

Verify the Go CLI builds correctly.

```bash
make build-cli
# Expected: "Building fastfn CLI..." and existence of ./bin/fastfn
./bin/fastfn --help
# Expected: List of commands (dev, docs, help, init, logs, run)
```

## 🏗️ Step 3: Initialize a New Function

We will use the CLI to scaffold a new function.

```bash
cd examples
../bin/fastfn init my-demo-function
# Follow prompts (Select "node" or "python")
```

## 🏃 Step 4: Run Development Mode (Dry Run)

Verify the orchestration logic without starting containers yet.

```bash
../bin/fastfn dev my-demo-function --dry-run
# Expected: YAML output showing volume mount to /app/srv/fn/functions
```

## 🔁 Step 5: Live Hot-Reload Test

This is the big one. We will start the system and modify code.

1. **Start Dev Server**:
   ```bash
   ../bin/fastfn dev my-demo-function
   ```
2. **Verify Endpoint**:
   Open http://localhost:8080/my-demo-function/
   Expected: JSON response from the function.

3. **Modify Code**:
   Edit `examples/my-demo-function/index.js` (or `main.py`).
   Change the message to `"Hello from FastFn Hot Reload!"`.

4. **Verify Change**:
   Refresh http://localhost:8080/my-demo-function/
   Expected: The new message appears immediately.

## 🧪 Step 6: Automated Verification

Run the full test suite to ensure no regressions.

```bash
cd ..
make test-unit
# Expected: All SDK and Handler tests pass.
```

## 🧹 Step 7: Teardown

```bash
make down
```
