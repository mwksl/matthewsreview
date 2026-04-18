## Phase 3 — Cheap scoring + gate

Per-candidate Sonnet scorer (§20 rubric, err-up). Pre-existing override first;
then Phase-3 gate (`score < 45 AND single family` → `disposition: below_gate`,
`is_actionable: false`); otherwise advance to Phase 4.

## TODO (Commit 8)

Fills in per-candidate dispatch + §13.1 Phase-3 gate + pre-existing override.
