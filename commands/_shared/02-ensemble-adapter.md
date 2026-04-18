## Phase 1.5 — Ensemble adapter (conditional on `--ensemble`)

CodeRabbit + Codex CLI invocations in background Bash, plus `external-scrape.sh`
for bot PR comments and a Sonnet normalizer that maps all ensemble output into
the shared candidate schema.

Skipped entirely when `--ensemble` is not set, or when `mode == local`
(no PR to scrape).

## TODO (Commit 6)

Fills in readiness checks, CLI dispatch, parallel polling, normalizer, and the
merge-into-candidate-pool step.
