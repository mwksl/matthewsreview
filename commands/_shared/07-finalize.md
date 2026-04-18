## Phase 6 — Finalize

Schema-validate the in-memory artifact; tally `subagent_tokens` from
`tokens.jsonl`; populate `metrics` (`pr_size_buckets`, `time_elapsed_seconds`);
write phase-6 record to `phases.jsonl`; render `artifact.md`; update
`latest.txt`; publish to PR (PR mode) or no-op (local mode); mirror the report
to chat.

## TODO (Commit 11)

Fills in the validate → tally → metrics → render → latest.txt → publish →
mirror sequence with explicit helper calls.
