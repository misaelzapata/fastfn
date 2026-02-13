# 🏗️ FastFn Master improvement Plan

This is the definitive roadmap to making FastFn a world-class, "elegant" repository with excellent Developer Experience (DX), complete test coverage, and easy distribution via Homebrew.

## 🔥 Priority 1: The "Elegant Repo" Restructure

The goal is to stop using "scripts hacking" and move to a standard build system.

### 1.1 Makefile Standardization
Create a root `Makefile` to serve as the single entry point for all operations.

- [x] **`make up`**: Runs the full stack (replaces `docker compose up`).
- [x] **`make dev`**: specific helper for dev mode (watching logs).
- [x] **`make test`**: Runs all unit and integration tests.
- [x] **`make clean`**: Cleans up docker artifacts and temp files.
- [x] **`make build-cli`**: Compiles the Go CLI.

### 1.2 Repository Cleanup
- [ ] Move `scripts/*.sh` to `cli/legacy_ops/` (archive them, don't delete yet).
- [ ] Move `srv/fn` to `examples/functions`. The `srv` folder structure confuses new users; "examples" is clearer.
- [ ] Create `packages/` or `sdk/` as the official home for language bindings (Done: `sdk/`).

---

## 🛠️ Priority 2: The FastFn CLI (Golang)

We will build a single binary tool `fastfn` to replace the shell scripts. This allows us to distribute via Homebrew easily.

### 2.1 CLI Structure (`cli/`)
- Language: **Go** (for easy static binary compilation).
- Libraries: `cobra` (commands), `viper` (config).

### 2.2 Core Commands (FastAPI parity)
- [x] **`fastfn dev [dir]`** (Basic Implementation):
    - The "Magic" command.
    - **Architecture**: The Go CLI wraps `docker compose` for local orchestration.
    - Mounts your local folder `[dir]` (or current dir) into the container in real-time.
    - Enables `FN_HOT_RELOAD=true`.
    - prints URLs: `Checking endpoints at http://localhost:8080/docs`
    - **Note**: Currently requires `docker-compose.yml` in path (Repo dependency).
- [ ] **`fastfn dev` Enhancements** (Planned):
    - [ ] **Native Mode (Bare Metal)**: Support running `openresty` directly on the host (macOS/Linux).
        - Requires user to install OpenResty (`brew install openresty`).
        - The CLI generates `nginx.conf` and manages the process.
        - **Why**: Zero-overhead local development, no Docker volume latency.
    - [ ] **Embedded Build (Self-Contained)**:
        - The CLI binary will embed the `openresty/` and `docker/` folders.
        - If Docker is used, it builds the image on-the-fly from the embedded context.
        - No dependency on external registries or cloning the repo.
    - [ ] **Config Support**: Read `fastfn.toml` or `fastfn.json` to find default `functions_dir`.
    - [ ] **Watch Mode**: optimize file watching.
- [ ] **`fastfn run [dir]`**:
    - Production mode (no hot reload, optimized logging).
    - Similar to `fastapi run`.
- [x] **`fastfn init`** (or `new`):
    - Interactive scaffolding.
    - "Select template: [Node, Python, Go, Rust]".
- [x] **`fastfn docs`**:
    - Shortcut to open `http://localhost:8080/docs` in the default browser.
- [ ] **`fastfn logs`**: 
    - Tail logs from the running stack.

### 2.3 CLI Robustness & Portability (Detailed) [*New*]
- [ ] **Pre-flight Checks**: Validate Docker installation and Daemon status before running commands.
- [ ] **Project Detection**: Intelligent filtering of root directory (recursively searching for config/docker-compose).
- [ ] **Self-Contained**: (Future) Embed `docker-compose.yml` to support standalone usage outside git repo.

### 2.4 Homebrew Distribution
- [ ] Create `homebrew-tap` repo.
- [ ] CI Action to build binaries for macOS (ARM64/x86) and Linux.
- [ ] Formula: `brew install fastfn`.

---

## 📦 Priority 3: SDKs & Code Completion (The DX Layer)

We must provide typed experiences for ALL 4 supported runtimes.

### 3.1 Node.js SDK (`sdk/js`)
- [x] **Types**: `index.d.ts` created.
- [ ] **Package**: Add `package.json`.
- [ ] **Tests**: Create unit tests verifying the types match the actual runtime runtime payload.

### 3.2 Python SDK (`sdk/python`)
- [x] **Types**: `fastfn/types.py` created (TypedDicts).
- [ ] **Package**: Add `pyproject.toml` or `setup.py`.
- [ ] **Tests**: Unit tests using `pytest` to validate structure.

### 3.3 PHP SDK (`sdk/php`)
- [x] **Types**: `FastFn.php` created (Classes/Interfaces).
- [ ] **Package**: Add `composer.json`.
- [ ] **Tests**: Unit tests using `PHPUnit`.

### 3.4 Rust SDK (`sdk/rust`)
- [x] **Types**: `src/lib.rs` created (Serde structs).
- [ ] **Package**: `Cargo.toml` created.
- [ ] **Tests**: Unit tests in `lib.rs` (`#[test]`) to verify JSON serialization matches Runtime contract.

---

## 📚 Priority 4: Documentation (The "FastAPI Feel")

Mirror the quality of modern framework docs.

### 4.1 Content Rewrite
- [ ] **Tutorials**: Rewrite `build-complete-api.md` and others to:
    - Use the new SDKs in code snippets.
    - Use "Tabs" for language selection (Node, Python, Go, Rust).
- [ ] **"Magic" Auto-Docs**: Ensure the Swagger UI (`/docs`) is highlighted as a first-class feature in `index.md`.

---

## 🧪 Priority 5: Universal Testing

Ensure robust CI for the entire ecosystem.
CLI Tests**:
    - Integration test: `fastfn dev` -> create file -> curl endpoint (verify mount works).
    - Unit tests: Verify config loader (`fastfn.toml`) prioritizes args > config > default.
- [ ] **
- [ ] **E2E Tests**: Existing Playwright tests are good. Expand them to cover:
    - The new SDK response formats.
    - Edge cases for all 4 languages (not just Node/Python).
- [ ] **Structure**: One script `test-all.sh` (called by `make test`) that runs:
    1. SDK Unit tests.
    2. Docker Integration tests.
    3. Playwright UI tests.

---

## 🚦 Execution Order (Immediate Next Steps)

1.  **Repo Structure**: Create `Makefile` and re-org folders.
2.  **SDK Tests**: Add tests for the new SDK code in `sdk/`.
3.  **CLI Prototype**: Initialize the Go module in `cli/`.
