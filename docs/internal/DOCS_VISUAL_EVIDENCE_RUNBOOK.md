# Docs Visual Evidence Runbook (Internal)

Revision: 2026-03-12  
Owner: Docs + Runtime maintainers

## Purpose

Keep public screenshots/GIF assets reproducible and verifiable while keeping the
generation workflow internal-only.

## Scope

- Public assets live under `docs/assets/screenshots/`.
- The operational workflow lives here in `docs/internal/` only.
- CI enforces integrity via manifest verification.

## Tooling

- Manifest verifier/updater: `scripts/docs/visual_manifest.py`
- Browser screenshot capture: `scripts/docs/capture-ui.mjs`
- End-to-end generator: `scripts/docs/generate_visual_evidence.sh`
- Manifest file: `docs/assets/screenshots/manifest.json`

## Standard workflow

1. Ensure FastFN binary is available (`./bin/fastfn`) and fixtures are healthy.
2. Generate evidence:

```bash
bash scripts/docs/generate_visual_evidence.sh
```

3. Verify manifest and integrity:

```bash
python3 scripts/docs/visual_manifest.py verify
```

4. Run strict docs build:

```bash
mkdocs build --strict
```

## Manual capture path (advanced)

If only browser captures need refresh:

```bash
node scripts/docs/capture-ui.mjs
python3 scripts/docs/visual_manifest.py update
python3 scripts/docs/visual_manifest.py verify
```

## CI quality gates

- `.github/workflows/ci.yml` (`Docs Quality` job)
- `.github/workflows/docs.yml`

Both run:

```bash
python3 scripts/docs/visual_manifest.py verify
mkdocs build --strict
```

## Troubleshooting

- `visual manifest verification failed`:
  - Run `python3 scripts/docs/visual_manifest.py update`, then verify again.
  - Confirm referenced image paths in docs are local and exist.
- Missing browser screenshots:
  - Confirm `BASE_URL` target is healthy (`/_fn/health`).
  - Re-run `scripts/docs/generate_visual_evidence.sh`.
- VHS skips:
  - Install `vhs` if terminal GIFs are required.

## Ownership rules

- Public docs must not include operational capture instructions.
- Any workflow change to scripts/docs must update this runbook.
- CI must remain the source of truth for manifest integrity.
