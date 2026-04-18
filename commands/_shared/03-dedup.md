## Phase 2 — Dedup (LLM-only)

Single Sonnet pass groups Phase 1 + Phase 1.5 candidates into sets representing
the same underlying issue. Merge each group to one canonical candidate;
delete the rest; union `sources` + `source_families`.

## TODO (Commit 7)

Fills in §19.3 prompt, the merge pass, and the `--delete-finding` call.
