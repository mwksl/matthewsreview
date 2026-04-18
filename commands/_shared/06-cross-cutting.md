## Phase 5 — Cross-cutting review (deep lane only)

Single Opus sub-agent receives all deep-lane `is_actionable: true` findings
(with `validation_result.fix_proposal`) and emits `cross_cutting_groups` plus
optional per-finding annotations. Skipped when no deep-lane actionable
findings exist (trivial-mode runs and runs where Phase 4a disproved everything).

## TODO (Commit 10)

Fills in the serialize-findings-to-prompt step, dispatch, and
`cross_cutting_groups` persistence via `--set-json --top-level`.
