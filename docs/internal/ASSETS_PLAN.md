# 🎨 Visual Assets & Marketing Plan

To make **fastfn** stand out like top-tier projects (FastAPI, Stripe, Next.js), we need high-quality visual assets. This document tracks what is needed.

## 1. Graphics & Diagrams 📊

We need a consistent visual language. Use Excalidraw or Mermaid for clean, "hand-drawn" technical feel.

### Architecture
- [ ] **High-Level Flow**: Request -> Nginx -> Lua Router -> Unix Socket -> Python Worker.
  - *Goal*: Show "zero latency" path.
- [ ] **File-System Mapping**: `functions/` folder structure -> URL mapping.
  - *Goal*: Show "it's just files".
- [ ] **Security Layer**: Visualizing the "Defense in Depth" (Path Traversal, Symlinks, Timeouts).

### Comparisons
- [ ] **Cold Start vs Prefork**: Bar chart showing Lambda cold start (200ms+) vs fastfn (0ms).
- [ ] **Complexity vs Utility**: Graph showing k8s/Knative complexity vs fastfn simplicity.

## 2. Videos 🎥

Short, punchy videos for the README and Social Media.

- [ ] **"The 30-Second Sell"**:
  1. Open `app.py`.
  2. Change `return "Hello"` to `return "Hello World"`.
  3. `curl localhost:8080`.
  4. Instant update. No build.
- [ ] **Full Walkthrough (2 min)**:
  - Docker Compose up.
  - Creating a Python function.
  - Creating a Node.js function.
  - Viewing the Swagger UI.
  - Checking the logs.

## 3. Screenshots 📸

High-DPI screenshots with good padding and shadows.

- [ ] **Swagger UI**: Show the auto-generated docs.
- [ ] **Terminal Output**: Colorful logs showing a fast boot.
- [ ] **VS Code Integration**: Show the folder structure next to the code.
- [ ] **Error Handling**: Friendly error page when a function fails (showing stack trace in dev mode).

## 4. Branding 🌟

- [ ] **Logo**: A simple, geometric logo (maybe a router icon or a lightning bolt).
- [ ] **Color Palette**:
  - Primary: Deep Purple (`#5e35b1`) - Creative/Magic.
  - Secondary: Teal (`#00e676`) - Success/Speed.
  - Accent: Orange (`#ff9100`) - OpenResty heritage.

## 5. Copywriting Tweaks ✍️

- [ ] **"Zero-Friction"**: Emphasize this everywhere.
- [ ] **"No YAML"**: Attack the pain point of Kubernetes manifests.
- [ ] **"Just Files"**: The mental model is just a file explorer.

---

> *Action Item*: Start with the "30-Second Sell" video and add it to the top of the README.
