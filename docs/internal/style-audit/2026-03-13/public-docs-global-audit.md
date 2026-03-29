# Public Docs Global Audit

Date: 2026-03-13

## Scope

This audit reviewed public docs under `docs/en/**` and `docs/es/**` with two goals:

1. confirm the core editorial path (sections A-F) reads clearly and stays friendly
2. measure how much older wording/template debt still exists outside that core path

## Current status

- Core A-F path: passed dual review from Claude and Gemini at `>=4/5` for tone, simplicity, practicality, and interlinks
- Public docs still contain older editorial patterns outside the A-F path

## Repo-wide signals

- Files with legacy template headings (`Problem`, `Mental Model`, `Objective`, `Prerequisites`, `Validation Checklist`, and ES equivalents): `80`
- Files containing `Next step` / `Related links` style navigation blocks: `66`
- Total legacy template heading occurrences: `233`
- Total `Related links` heading occurrences: `94`
- Total `Next step` heading occurrences: `66`

## Repeated wording to simplify

- `contract` / `contrato`: `96`
- `polyglot` / `poliglota` / `políglota`: `82`
- `baseline`: `15`
- `guard` / `guardrails`: `17`

These are not all wrong. They are signals for manual review because they often make pages sound more internal or platform-heavy than user-friendly.

## Main conclusion

The main docs path is now aligned with the intended writing style.

The broader docs set is not yet fully aligned. Most remaining drift comes from:

- older pages with scaffold headings left visible
- duplicated navigation blocks
- heavier platform wording in reference/explanation pages

## Recommended cleanup order

1. remove legacy scaffold headings from older tutorials/how-to pages
2. collapse duplicate `Next step` / `Related links` blocks
3. simplify repeated platform wording where plain language is enough
4. keep internal generation/review mechanics out of public docs
