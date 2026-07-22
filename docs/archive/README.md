# docs/archive

Frozen historical references as of **2026-04-19**.

These predate the rename to **matthewsreview**: any `~/.adams-reviews` path or `ADAMS_REVIEW_*` env var mentioned inside is now `~/.matthews-reviews` / `MATTHEWS_REVIEW_*` (`bin/doctor.sh` flags leftovers).

- **`DESIGN.md`** — rev 8 normative design doc. Covers the pipeline spec, state model, helper contracts, and cross-cutting decisions at the time the pipeline was built (Stages 1–3 + 2.5 / 2.6 / 2.7 / 2.8 + walkthrough).
- **`BUILD.md`** — stage-by-stage build journal covering 2026-04-17 → 2026-04-19.

**These files are not maintained.** Current behavior lives in:

- `AGENTS.md` — operational guide; self-contained for routine work.
- `fragments/*.md` — executable phase fragments.
- `bin/schema-v1.json` — artifact shape (source of truth).
- `bin/*` — helpers (`docs/helpers.md` inventory), with `test/smoke.sh` as the living spec.

Consult the archive only when you need the rationale behind a specific historical decision. Fragment-level citations of the form `per §X.Y` still resolve — `grep '^### 13\.1 ' docs/archive/DESIGN.md` etc.
