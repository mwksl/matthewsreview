---
allowed-tools: Bash(artifact-read.sh:*), Bash(review-config.sh:*), Bash(review-root.sh:*), Bash(doctor.sh:*), Bash(artifact-patch.py:*), Bash(artifact-validate.sh:*), Bash(artifact-render.py:*), Bash(artifact-publish.sh:*), Bash(claude-md-paths.sh:*), Bash(staleness.sh:*), Bash(prior-fix-diff.sh:*), Bash(line-range-check.sh:*), Bash(assign-finding-ids.sh:*), Bash(origin-crosscheck.sh:*), Bash(parse-with-repair.py:*), Bash(parse-validator-result.py:*), Bash(source-family-map.py:*), Bash(log-phase.sh:*), Bash(log-tokens.sh:*), Bash(tally-subagent-tokens.sh:*), Bash(orchestrator-tokens.sh:*), Bash(repo-slug.sh:*), Bash(freshness-gate.sh:*), Bash(trivial-check.sh:*), Bash(artifact-seed.sh:*), Bash(codex-poll.sh:*), Bash(agent-dispatch.sh:*), Bash(codex login status), Bash(sync-degraded.py:*), Bash(git:*), Bash(gh:*), Bash(jq:*), Bash(date:*), Bash(mkdir:*), Bash(mv:*), Bash(rm:*), Bash(mktemp:*), Bash(cat:*), Bash(printf:*), Bash(echo:*), Bash(grep:*), Bash(awk:*), Bash(sed:*), Bash(tr:*), Bash(wc:*), Bash(head:*), Bash(tail:*), Bash(cut:*), Bash(sort:*), Bash(diff:*), Bash(openssl:*), Bash(python3:*), Bash(node:*), Bash(find:*), AskUserQuestion, Agent, Read, BashOutput, KillShell
argument-hint: "[--effort <low|medium|high|xhigh|max|ultra>] [--full] [--profile <name>] [--models \"<csv>\"]"
description: Codex-driven deep code review producing the same artifact.json shape as :review (drop-in for /matthewsreview:fix, :add, :walkthrough, :promote).
disable-model-invocation: false
---

Flags (optional):
- `--effort <level>` controls Codex reasoning depth (`low`, `medium`,
  `high`, `xhigh`, `max`, `ultra`). Default `high`. Higher = deeper analysis but
  longer wall-clock and higher cost.
  `max` and `ultra` require the authenticated standalone Codex transport.
- `--full` forces `trivial_mode=false` for this run (overrides the
  doc/config-PR early-exit). Same semantics as `:review --full`.

Note: this command has **no `--ensemble` flag** — it is purpose-built
for Codex-only review. If you want internal Claude lenses pooled with
the Codex CLI + a PR bot-comment scrape, run `/matthewsreview:review
--ensemble` instead.

**Read `fragments/_prelude-shared.md` before proceeding — it lists
rules that apply to every phase below (sub-agent return handling,
helper-script error-as-prompt).**

## Execution overview

This command orchestrates the same phases as `/matthewsreview:review`
(Phases 0–6 plus Phase 5.5 auto-fix-hint generation), swapping the
Claude sub-agent dispatches for **Codex jobs**. It prefers the
`codex-companion.mjs` background primitive and falls back to the
standalone Codex CLI through `agent-dispatch.sh` when the companion is
unavailable.

- **Phase 1 detection** — 7 parallel Codex lenses (L1–L7) instead of
  Claude `Agent` blocks.
- **Phase 4a deep validation** — one parallel Codex job per surviving
  finding instead of one Opus sub-agent per finding.
- **Phase 4b light confirmation** — chunked-batch Codex (≤25 candidates
  per chunk) instead of chunked-batch Sonnet.
- **Phase 5 cross-cutting** — one Codex pass instead of one Opus pass.

Claude sub-agents (Sonnet) are still used for the "shape-fixer" /
normalizer / dedup / scoring work where structured output matters
more than reasoning depth — all of these phases execute the SAME
fragments as `:review`:

- **Phase 0 preflight** — `fragments/00-preflight.md` verbatim.
- **Phase 2 dedup** — `fragments/03-dedup.md` verbatim.
- **Phase 3 scoring gate** — `fragments/04-scoring-gate.md` verbatim.
- **Phase 6 finalize** — `fragments/07-finalize.md` verbatim.

Each phase below is defined in a fragment under `fragments/NN-<name>.md`.
At each phase boundary, read the named fragment with the `Read` tool
and execute the instructions inside before proceeding to the next phase.

**Before you start, build a TaskList that mirrors the phases below**
(one task per phase, plus one for argument parsing). Mark each
`in_progress` when you start it and `completed` when you finish.

If a phase genuinely cannot run, mark the task `completed` with a
one-line `trace.md` note and move on. Phase 6 (finalize) runs
unconditionally — a partial review is still worth rendering and
publishing so the user can inspect what did succeed.

Codex job failures (non-zero exit, malformed output, sentinel timeout)
are handled per the **adaptive retry-with-orchestrator-judgment**
policy: retry up to 3 times with the same prompt; on persistent
failure, drop the affected unit (lens / finding / chunk) and escalate
to the user via ASK ("L2 failed; continue with 6 lenses
or abort?"). Log every drop to `trace.md` with tag
`phase_<N>_codex_dropped:<unit_id>`. This policy is restated where it
applies in each Codex-using fragment.

## Sub-agent dispatch pattern

Two dispatch transports in this command:

**Companion mode** (`codex_launch_mode=companion`) launches through
`codex-companion.mjs` and polls through `codex-poll.sh`. The watchdog
remains the single source of truth for companion-job liveness: it wraps
`status --json`, applies the two-signal stall check, enforces the
effort-derived ceiling, and returns normalized `raw_output`.

**Standalone mode** (`codex_launch_mode=agent-dispatch`) launches
`agent-dispatch.sh start --engine codex`, polls with
`agent-dispatch.sh poll`, and cancels with `agent-dispatch.sh stop`.
Poll adds terminal `cancelled`. Stop itself returns exactly one of
`cancelled` (verified gone), `already_finished` (completion won; re-poll the
same job), or non-zero `stop_failed` (do not retry because the old engine may
still be running). Never parse malformed/partial stop output and never issue a
redundant stop after polled cancellation. The model and effort come from the
resolved `codex_detect`, `codex_validate`, or `codex_crosscut` role.

Launch ALL jobs in a phase within one orchestrator turn so they run
concurrently; poll all in-flight jobs together on subsequent turns.
Each Codex fragment contains the exact mode-aware launch/poll/stop
branch. Never call raw companion `status` or `result` commands:
companion mode must go through `codex-poll.sh`, and standalone mode
must go through `agent-dispatch.sh poll`.

**Normalizer sub-agents** (resolved roles `normalizer`, `dedup`, and `scoring`):

Every DISPATCH specifies:
- `subagent_type: general-purpose`
- `model:` the model segment of the role string (`normalizer` for
  shape-fixer / normalizer dispatches; `scoring` for Phase 3 — both
  default claude:sonnet)

Parallel fan-outs happen by issuing every DISPATCH in one batch
(Prelude §3.4).

## Argument handling

Parse `$ARGUMENTS` (whitespace-split) for:
- `--effort <value>` → `effort=<value>` and `effort_explicit=true`
  (validate against `low|medium|high|xhigh|max|ultra`; reject other
  values with a usage message)
- `--full` → `force_full=true` (else `false`)
- `--profile <name>` → `profile=<name>` (else unset)
- `--models "<csv>"` → `models_csv=<csv>` (else unset)
- Any other token → stop and ask the user to clarify.

`--effort` explicitly overrides the effort segment of the
`codex_detect` / `codex_validate` / `codex_crosscut` roles after Phase
0 resolves the model plan (see the preflight fragment). `--profile`
and `--models` behave as in `:review`.

If `--effort` is omitted, set `effort=""` and
`effort_explicit=false`. The resolved per-role config values remain
authoritative; an empty resolved effort means use the Codex CLI
default.

Set the following working-context values BEFORE executing Phase 0:

- `effort` and `effort_explicit` — only an explicit CLI value overrides
  the three resolved Codex role efforts.
- `force_full` (default `false`) — consumed by Phase 0 step 0.11.
- `reviewer_sources_label="internal-codex"` — consumed by Phase 0 step
  0.15 (the orchestrator passes it to `artifact-seed.sh
  --reviewer-sources` so the seeded artifact carries
  `reviewer_sources: ["internal-codex"]`).
- `ensemble_mode=false` — codex-review never runs the ensemble adapter;
  setting this explicitly keeps fragments shared with `:review` from
  branching on an undefined value.

## Codex readiness gate

Before Phase 0, choose the Codex transport. Codex remains mandatory,
but the Claude Code companion plugin is not: a working standalone
`codex` CLI plus `agent-dispatch.sh` is a complete fallback.

```bash
CODEX_COMPANION="$(find ~/.claude/plugins -type f -name codex-companion.mjs -path '*codex*' 2>/dev/null | head -1)"
codex_launch_mode=""
codex_readiness_note=""

if [[ -n "$CODEX_COMPANION" ]]; then
    codex_setup_json=$(node "$CODEX_COMPANION" setup --json 2>&1)
    codex_ready=$(jq -r '.ready // false' <<<"$codex_setup_json" 2>/dev/null)
    if [[ "$codex_ready" == "true" ]]; then
        codex_launch_mode="companion"
    else
        # Shared-mode cold start: the broker socket appears only after the
        # first task. Preserve the existing safe bypass.
        cx_mode=$(jq -r '.sessionRuntime.mode // ""' <<<"$codex_setup_json" 2>/dev/null)
        cx_cli=$(jq -r '.codex.available // false' <<<"$codex_setup_json" 2>/dev/null)
        cx_auth_detail=$(jq -r '.auth.detail // ""' <<<"$codex_setup_json" 2>/dev/null)
        if [[ "$cx_mode" == "shared" && "$cx_cli" == "true" \
              && "$cx_auth_detail" == *"ENOENT"*"broker.sock"* ]]; then
            codex_launch_mode="companion"
            codex_readiness_note="shared-mode cold-start broker ENOENT bypassed"
        fi
    fi
fi

codex_cli_ready=false
if [[ -z "$codex_launch_mode" ]] \
   && command -v codex >/dev/null 2>&1 \
   && codex login status >/dev/null 2>&1; then
    codex_cli_ready=true
fi
if [[ "$codex_cli_ready" == "true" ]] \
   && { [[ -n "${MRB:-}" && -x "${MRB}agent-dispatch.sh" ]] \
        || command -v agent-dispatch.sh >/dev/null 2>&1; }; then
    codex_launch_mode="agent-dispatch"
    codex_readiness_note="companion unavailable or not ready; using authenticated standalone Codex CLI"
fi

if [[ -z "$codex_launch_mode" ]]; then
    echo "ERROR: no usable Codex transport." >&2
    echo "Action: run /codex:setup, or install/authenticate the codex CLI." >&2
    [[ -n "${codex_setup_json:-}" ]] && printf '%s\n' "$codex_setup_json" >&2
    exit 1
fi
```

Capture `CODEX_COMPANION`, `codex_launch_mode`, and
`codex_readiness_note` in working context. Phase 1 writes the note to
`trace.md` after Phase 0 has created the review directory. There is no
fallback to Claude lenses: only the transport changes.

---

**Phase 0 — Preflight.** Read `fragments/00-preflight.md` and execute
the instructions inside before proceeding to Phase 1.

---

**Phase 1 — Codex detection.** Read `fragments/01-codex-detection.md`
and execute the instructions inside before proceeding to Phase 2.

---

**Phase 1.5 — Skipped.** codex-review has no `--ensemble`; no
external sources are pooled. Log one line to `trace.md`:

```
Phase 1.5 skipped — /matthewsreview:codex-review has no external sources
```

---

**Phase 2 — Dedup.** Read `fragments/03-dedup.md` and execute the
instructions inside before proceeding to Phase 3.

---

**Phase 3 — Scoring gate.** Read `fragments/04-scoring-gate.md` and
execute the instructions inside before proceeding to Phase 4.

---

**Phase 4 — Codex validation.** Read `fragments/05-codex-validation.md`
and execute the instructions inside before proceeding to Phase 5.

---

**Phase 5 — Codex cross-cutting.** Read `fragments/06-codex-cross-cutting.md`
and execute the instructions inside before proceeding to Phase 5.5.

---

**Phase 5.5 — Auto-fix-hint generation.** Read
`fragments/06b-auto-fix-hint.md` and execute the instructions inside
before proceeding to Phase 6. Same fragment as `:review` — it's
Sonnet-driven and validator-agnostic, so the codex-review path runs
it identically once Phase 5's cross-cutting (Codex variant) has
returned.

---

**Phase 6 — Finalize.** Read `fragments/07-finalize.md` and execute
the instructions inside.

---

## What this command does NOT do

- No git operations except a single `git push` in Phase 0 step 0.9 (PR mode only, after user dirty-tree confirmation). No commits, tags, branches, deletes, or renames anywhere in the working tree.
- No review of closed/merged PRs — bail at Phase 0 step 0.4 with a
  user-visible message.
- No fallback to Claude lenses if Codex is unavailable — codex-review
  is Codex-only by design. The readiness gate accepts either the
  companion plugin or the authenticated standalone Codex CLI and exits
  before token spend only when neither transport is usable.
- No Phase 1.5 external-source pooling (PR-comment scrape, secondary
  Codex CLI). Run `/matthewsreview:review --ensemble` if you want that on
  top of internal Claude lenses.
