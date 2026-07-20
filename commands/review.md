---
allowed-tools: Bash(artifact-read.sh:*), Bash(review-config.sh:*), Bash(doctor.sh:*), Bash(artifact-patch.py:*), Bash(artifact-validate.sh:*), Bash(artifact-render.py:*), Bash(artifact-publish.sh:*), Bash(claude-md-paths.sh:*), Bash(staleness.sh:*), Bash(external-scrape.sh:*), Bash(comment-freshness.sh:*), Bash(prior-fix-diff.sh:*), Bash(line-range-check.sh:*), Bash(assign-finding-ids.sh:*), Bash(origin-crosscheck.sh:*), Bash(parse-with-repair.py:*), Bash(parse-validator-result.py:*), Bash(source-family-map.py:*), Bash(log-phase.sh:*), Bash(log-tokens.sh:*), Bash(tally-subagent-tokens.sh:*), Bash(orchestrator-tokens.sh:*), Bash(repo-slug.sh:*), Bash(freshness-gate.sh:*), Bash(trivial-check.sh:*), Bash(artifact-seed.sh:*), Bash(agent-dispatch.sh:*), Bash(git:*), Bash(gh:*), Bash(jq:*), Bash(date:*), Bash(mkdir:*), Bash(mv:*), Bash(rm:*), Bash(mktemp:*), Bash(cat:*), Bash(printf:*), Bash(echo:*), Bash(grep:*), Bash(awk:*), Bash(sed:*), Bash(tr:*), Bash(wc:*), Bash(head:*), Bash(tail:*), Bash(cut:*), Bash(sort:*), Bash(diff:*), Bash(openssl:*), Bash(python3:*), Bash(node:*), Bash(find:*), AskUserQuestion, Agent, Read, BashOutput, KillShell
argument-hint: "[--ensemble] [--full] [--profile <name>] [--models \"<csv>\"]"
description: Deep code review producing artifact.json, artifact.md, and (PR mode) a review comment on the PR.
disable-model-invocation: false
---

Flags (optional):
- `--ensemble` adds Phase 1.5 external-reviewer dispatch (Codex CLI +
  GitHub PR bot-comment scrape, followed by a unified normalizer). Off
  by default — enable for a richer review at higher cost.
- `--full` forces `trivial_mode=false` for this run (overrides the
  doc/config-PR early-exit).
- `--profile <name>` applies a named model profile from
  `profiles.<name>` in `<repo>/.matthewsreview.json` or
  `~/.matthews-reviews/config.json` (repo first).
- `--models "<k=v,k=v>"` overrides tiers or roles for this run
  (e.g. `--models "utility=claude:haiku,deep_validate=claude:sonnet"`).
  Beats `--profile`. Unknown keys abort with the valid-key list.

**Read `fragments/_prelude-shared.md` before proceeding — it lists
rules that apply to every phase below (sub-agent return handling,
helper-script error-as-prompt).**

## Execution overview

This command orchestrates Phases 0–6 in order. Each phase is
defined in a fragment under `fragments/NN-<name>.md`. At each phase
boundary below, read the named fragment with the `Read` tool and
execute the instructions inside before proceeding to the next phase.

**Before you start, build a TaskList that mirrors the phases below**
(one task per phase, plus one for argument parsing). Mark each
`in_progress` when you start it and `completed` when you finish.

Under `--ensemble`, Phase 1 and Phase 1.5 dispatch as a joint fan-out
in one orchestrator turn. The TaskList can still carry two tasks —
mark both `in_progress` when you fire the dispatch turn, and both
`completed` after the join step at 01-detection.md 1.5 commits the
pooled findings.

If a phase genuinely cannot run, mark the task `completed` with a
one-line `trace.md` note and move on. Phase 6 (finalize) runs
unconditionally — a partial review is still worth rendering and
publishing so the user can inspect what did succeed.

Sub-agent failures (non-zero, unparseable output, timeouts) get
logged to `trace.md` and drop that candidate from the run — they
don't abort the whole command.

## Sub-agent dispatch pattern

Every Agent tool-use specifies:
- `subagent_type: general-purpose`. (The Codex CLI under `--ensemble`
  runs as a background Bash invocation of `codex-companion.mjs`, not
  an Agent dispatch — see `fragments/02-ensemble-adapter.md`.)
- `model:` explicitly — the model segment of the role string the
  fragment names (roles resolve via the model plan; see
  `_prelude-shared.md` §Model plan & role resolution).

**Parallel fan-outs** happen by issuing every DISPATCH in one batch
(Prelude §3.4: N Agent blocks in one turn on CC; one `parallel()` eval
cell on omp; N `agent-dispatch.sh start` calls on Codex). Always batch
within one turn.

## Argument handling

Parse `$ARGUMENTS` (whitespace-split) for:
- `--ensemble` → `ensemble_mode=true` (else `false`)
- `--full` → `force_full=true` (else `false`)
- `--profile <name>` → `profile=<name>` (else unset)
- `--models "<csv>"` → `models_csv=<csv>` (else unset; the CSV is one
  quoted argument)
- Any other token → stop and ask the user to clarify.

Capture all four in your working context before executing Phase 0.
`profile` and `models_csv` are consumed by Phase 0 step 0.14b (model
plan resolution).

---

**Phase 0 — Preflight.** Read `fragments/00-preflight.md` and execute
the instructions inside before proceeding to Phase 1.

---

**Phase 1 — Detection.** Read `fragments/01-detection.md` and execute
the instructions inside before proceeding to Phase 1.5.

---

**Phase 1.5 — External ensemble dispatch (conditional).** If
`--ensemble` was passed, read `fragments/02-ensemble-adapter.md` and
execute the instructions inside; otherwise skip to Phase 2.

---

**Phase 2 — Dedup.** Read `fragments/03-dedup.md` and execute the
instructions inside before proceeding to Phase 3.

---

**Phase 3 — Scoring gate.** Read `fragments/04-scoring-gate.md` and
execute the instructions inside before proceeding to Phase 4.

---

**Phase 4 — Validation.** Read `fragments/05-validation.md` and execute
the instructions inside before proceeding to Phase 5.

---

**Phase 5 — Cross-cutting.** Read `fragments/06-cross-cutting.md` and
execute the instructions inside before proceeding to Phase 5.5.

---

**Phase 5.5 — Auto-fix-hint generation.** Read
`fragments/06b-auto-fix-hint.md` and execute the instructions inside
before proceeding to Phase 6.

---

**Phase 6 — Finalize.** Read `fragments/07-finalize.md` and execute
the instructions inside.

---

## What this command does NOT do

- No git operations except a single `git push` in Phase 0 step 0.9 (PR mode only, after user dirty-tree confirmation). No commits, tags, branches, deletes, or renames anywhere in the working tree.
- No review of closed/merged PRs — bail at Phase 0 step 0.4 with a
  user-visible message.
