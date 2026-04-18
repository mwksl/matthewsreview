## Phase 4 — Validation (lane-aware)

Deep lane (Phase 4a, Opus per candidate) for `correctness` + `security`
outside trivial-mode; light lane (Phase 4b, Sonnet per candidate) for
everything else and for every candidate when `trivial_mode == true`. Chain-wave
retry at the orchestrator level — hard cap 2 waves. Pre-existing re-assertion
after the score table runs.

## TODO (Commit 9)

Fills in lane routing, Wave 1 + Wave 2 dispatch, §13.1 Phase-4 decision,
validation_result persistence via `--set-json`, and the post-Phase-4
pre-existing override re-assertion.
