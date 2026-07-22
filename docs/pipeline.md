# Pipeline detail

Detailed phase trees for each lifecycle command, plus the token-tally semantics.
AGENTS.md keeps a one-paragraph summary per command; this file is the reference.

## `/matthewsreview:review [--ensemble] [--full] [--profile <name>] [--models "<csv>"]`

To select a Codex effort for ensemble detection, use the supported model-plan
override `--models 'ensemble_detect=codex::<effort>'`.

```
├── Phase 0 — Pre-flight (branch/PR detect, base-branch freshness,
│              branch-behind-base advisory at 0.6a, dirty-tree, push,
│              prior-artifact prompt, record review_started_at,
│              trivial-diff detection, CLAUDE.md path lister)
├── Phase 1    ─┐ Detection (6 parallel lens agents, 7 under --ensemble — L7
│               │   is a holistic Opus safety net; origin cross-check corrects
│               │   blame-traceable verdicts; under --ensemble also invokes the
│               │   Codex CLI as a subprocess via the ensemble adapter,
│               │   feeding its output into the Phase 1.5 normalizer)
├── Phase 1.5  ─┘ External-source pooling (PR-comment scrape: gh api → bot
│                 filter → comment-freshness; merged with --ensemble's
│                 Codex CLI output through a single Sonnet normalizer;
│                 ensemble mode only; CLI launch dispatched jointly with
│                 Phase 1, PR scrape deferred to post-CLI)
├── Phase 2 — Dedup (one Sonnet call; merges equivalent candidates, unions source_families)
├── Phase 3 — Cheap scoring + gate (chunked-batch Sonnet err-up rubric, ≤25
│              candidates per chunk-agent; ≥2 families auto-graduate; logs
│              demote_rate + score_phase3_histogram to phases.jsonl for #24 calibration)
├── Phase 4 — Validation (deep Opus per candidate for correctness/security —
│              one Agent per finding, structurally enforced by `--apply-decisions
│              --expected $N`; light Sonnet confirmation for ux/policy/architecture
│              via chunked-batch chunk-agents, ≤25 per chunk)
├── Phase 5 — Cross-cutting review (deep-lane only; dispatched Opus sub-agent)
└── Phase 6 — Finalize (schema-validate, tally-subagent-tokens.sh → subagent_tokens,
               orchestrator-tokens.sh → orchestrator_tokens, phases.jsonl record
               (appended throughout via log-phase.sh; Phase 6's record finalizes),
               render, PR comment POST)
```

## `/matthewsreview:codex-review [--effort <low|medium|high|xhigh|max|ultra>] [--full] [--profile <name>] [--models "<csv>"]`

```
├── Codex transport gate (prefer a ready codex-companion; preserve the
│     documented shared-mode cold-start broker-ENOENT bypass; otherwise use
│     an authenticated standalone `codex` CLI through agent-dispatch.sh;
│     fail only when neither transport is usable — never fall back to Claude)
├── Phase 0 — Pre-flight (same fragment as :review; passes `--reviewer-sources
│              internal-codex` to artifact-seed.sh so the seeded artifact
│              carries reviewer_sources: ["internal-codex"])
├── Phase 1 — Codex detection (7 parallel Codex jobs, one per lens L1–L7,
│              launched through the selected companion or agent-dispatch
│              transport; prompt body = fragments/lens-prompts/
│              _shared-invariants.md + fragments/lens-prompts/L<N>.md with
│              $claude_md_paths and $prior_fix_suspects substituted; poll via
│              the selected transport's lifecycle helper
│              [stall→cancel→§3.7 retry watchdog]; one combined Sonnet
│              normalizer over all 7 outputs → parse-with-repair + schema-
│              guard + line-range-check + assign-finding-ids +
│              origin-crosscheck + batched --add-findings; adaptive
│              retry-with-judgment policy; AskUserQuestion escalation on
│              degraded coverage)
├── Phase 1.5 — Skipped (codex-review has no --ensemble; no PR-comment
│              scrape, no secondary Codex pass — purpose-built for
│              Codex purity)
├── Phase 2 — Dedup (same fragment as :review)
├── Phase 3 — Scoring gate (same fragment as :review)
├── Phase 4 — Codex validation
│   ├── Phase 4a deep — one parallel Codex per finding + per-finding Sonnet
│   │     shape-fixer; per-finding atomicity (one bad output → uncertain
│   │     for that finding only; rest of batch applies via --apply-decisions
│   │     --expected $N); polled via codex-poll.sh [watchdog → sentinel
│   │     uncertain on stall]
│   ├── Phase 4b light — chunked-batch Codex (≤25 per chunk) + per-chunk
│   │     Sonnet shape-fixer; per-chunk atomicity; polled via codex-poll.sh
│   │     [watchdog → sentinel uncertain on stall]
│   ├── Wave 2 — DISABLED (bounded scope per plan; mirrors :add policy)
│   ├── Pre-existing override re-assertion — same as :review
│   └── Tree-cleanliness sweep + summary — same as :review
├── Phase 5 — Codex cross-cutting (one Codex pass over confirmed deep-lane
│              actionable findings + one Sonnet shape-fixer; emits
│              cross_cutting_groups; polled via codex-poll.sh [watchdog →
│              skip Phase 5 on stall — observability, not correctness])
└── Phase 6 — Finalize (same fragment as :review; tally-subagent-tokens.sh
               rolls Sonnet shape-fixer + normalizer spend; Codex tokens
               are NOT in tokens.jsonl — billed externally per Phase 1.5
               precedent)
```

## `/matthewsreview:fix [threshold] [--granular-commits]`

```
├── Phase 7 — Load artifact; leftover-attempted abort; clean-tree gate;
│              staleness check; branch-behind-base advisory at 7.6a
├── Phase 8 — Per-fix-group agents edit working tree (no git ops);
│              each group reports files_modified + files_created
└── Phase 9 — Post-fix Opus review pre-commit; aggregate outcomes per group;
              revert regression groups (checkout modified, rm created);
              re-tally subagent_tokens + orchestrator_tokens; commit surviving
              groups with outcome in message (one combined commit by default;
              one per fix group under --granular-commits); push; append
              fix_attempts
              (on 9.pre overlap: offer reconcile | abort | inspect — reconcile
               dispatches one Opus merge agent, collapses fix_groups to FG-RECON
               in memory, then runs Phase 9a/9b/9c unchanged; original
               fix_group_id preserved per-finding in fix_attempts)
```

## `/matthewsreview:add [<paste...>] [--file path --line N --claim "..."] [--impact <type>] [--no-dedup]`

```
└── Locate artifact (latest.txt) → leftover-attempted gate →
    branch-behind-base advisory at 3a → build candidates
    (paste-normalizer Sonnet | structured one-shot | mixed) → dedup against
    existing findings (Sonnet, one-direction) → assign IDs continuing past
    max existing F-id (assign-finding-ids.sh --start-from) → --add-finding loop →
    Phase 4 validation lane-aware, NO Wave 2 (Opus deep one-per-candidate /
    Sonnet light chunked-batch ≤25/chunk) → --apply-decisions --expected $N →
    pre-existing override re-assertion (origin=pre_existing AND
    origin_confidence=high → pre_existing_report, regardless of score) →
    re-tally subagent_tokens + orchestrator_tokens → re-render →
    re-publish to existing comment_id → trace + summary
```

## Working set (what each phase establishes)

**`:review` Phase 0** establishes: `review_id` (ULID), `artifact_path` (absolute), `repo_root`, `repo_slug`, `base_branch`, `comparison_ref` (from `freshness-gate.sh` reconciliation — use this, not `base_branch`, for every diff/blame/lens prompt), `reviewed_sha` (post-push), `review_started_at` (ISO-8601 UTC, captured before any push/stash), `mode` (`pr`/`local`), `pr_number`, `trivial_mode`, `reviewed_files_all` (staleness envelope), `claude_md_paths`, and the three append-only log paths (`trace.md`, `phases.jsonl`, `tokens.jsonl`). `comment_id` is set by Phase 6+ on first POST, or rehydrated at Phase 0.14 from a prior artifact.

**`:fix` Phase 7** loads the artifact and adds: `run_id` (ULID, `fixrun_<ULID>`), `threshold`, `latest_known_sha`, `stash_taken`, `input_sha` (pre-edit). Phase 8 adds `eligible_finding_ids` (step 8.1) and `fix_groups` (step 8.3, from `group-fixes.py`). Phase 9 adds `phase_9a_outcomes`, `overlap_files`, `reverted_groups`, `surviving_groups`, `commit_sha`.

Path-handling invariants (helpers receive absolute paths; fragments never assume a cwd; `log-phase.sh` writes to the Phase-0-known path) are operational doctrine — see AGENTS.md Rule 11.

## Token tally — `subagent_tokens` and `orchestrator_tokens`

Every lifecycle command re-tallies two sibling fields before its final re-render
so the published PR comment reflects cumulative spend across the review → fix /
add / walkthrough arc:

- **`subagent_tokens`** — rolled up from the review-local `tokens.jsonl` (every
  dispatched sub-agent's cost). Captures native Claude/omp agents and Codex CLI
  jobs whenever the selected transport reports usage; an unavailable or
  unparseable count is preserved as `tokens: null`. Codex provider billing
  remains separate even though its reported usage is recorded.
- **`orchestrator_tokens`** — Claude Code main-session `message.usage`, captured
  from the exact active transcript identified by the `SessionStart` hook. The
  hook persists `session_id` and `transcript_path` through `CLAUDE_ENV_FILE`;
  `orchestrator-tokens.sh` reads that one file and accepts only assistant lines
  whose `sessionId` matches and whose timestamp is at or after
  `review_started_at`. No cwd slug is derived and no sibling transcript is
  opened. **Opt-in via `MATTHEWS_REVIEW_TALLY_ORCHESTRATOR=1`** — default skip
  avoids the macOS Sequoia/Tahoe “access data from other apps” prompt caused by
  Claude Code's `com.apple.provenance` transcript xattr.

The fields are non-overlapping: dispatched-agent API calls versus main-session
turns. Four orchestrator counters — fresh input, output, cache-read, and
cache-creation — remain separate in the artifact because their prices differ
materially. The rendered PR-comment line shows output and fresh input only;
cache counters remain available for offline cost analysis.

### Session accumulation and idempotency

Each `orchestrator_tokens.sessions[]` row stores its own four counters.
Re-tallying the active session replaces its prior row, so a growing transcript
is idempotent. A later lifecycle command in another Claude session retains
earlier rows and adds the new one without reopening old transcript files. The
top-level counters are recomputed from those rows. The first exact-session tally
on a pre-v1.0.2 artifact intentionally replaces the old aggregate because old
rows lack per-session counters and may include cwd-wide contamination.

Codex- and omp-orchestrated commands do not receive Claude Code `SessionStart`
metadata, so `orchestrator_tokens` remains absent there. `subagent_tokens`
continues to work on every harness.

### Remaining attribution limits

Exact file + session-ID filtering removes cross-session over-count. Unrelated
assistant turns in the *same* Claude session after `review_started_at` are still
indistinguishable and can over-count. A final tally also cannot include work
that happens afterward: for example, walkthrough issue-filer agents dispatched
after §6.1 surface on the next lifecycle command's tally.

Malformed JSONL lines are ignored while valid matching lines are retained.
Missing or incomplete hook-derived transcript/session metadata skips without
mutation; a missing explicitly requested `--transcript-file` is an error.

### Stale-data preservation across opt-in toggles

Skip on opt-out deliberately does not wipe a previously written
`orchestrator_tokens` value. An opted-in `/matthewsreview:review` followed by an
opted-out `/matthewsreview:fix` therefore publishes the prior captured value,
which can lag actual spend. Re-enable the export on a later lifecycle command
to refresh it.
