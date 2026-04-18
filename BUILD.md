# BUILD.md — build journal for adams-review

This is the running build journal. `DESIGN.md` is the normative design (rev 8). This file tracks **execution**: where we are, what's landed, what surprised us, and what still needs attention.

If you are a Claude Code session starting fresh (after compaction or on a new day), **read this file first**, then open `DESIGN.md`. Skim "Current state" and the active stage's section; you can treat the rest as reference.

---

## Current state

**As of 2026-04-17** — Planning complete (DESIGN.md at rev 8). Stage 1 not yet started.

- Design doc: `DESIGN.md` in this repo (rev 8 — implementation-language split applied)
- Per-stage plans: `plans/` directory (empty — drafted before each stage starts)
- No source code yet. Only `DESIGN.md`, `BUILD.md`, and `plans/`.
- Git state: initial commit(s) bootstrapping the journal. `main` branch.

**Next action:** draft Stage 1 plan in `plans/stage-1-foundation.md`, user reviews, then execute.

---

## Stage index

| # | Name | Status | Plan | Close-out notes |
|---|------|--------|------|-----------------|
| 1 | Foundation (data layer + shared helpers) | not started | `plans/stage-1-foundation.md` *(not yet drafted)* | — |
| 2 | `/adams-review` end-to-end (Phases 0–6) | not started | `plans/stage-2-review.md` | — |
| 3 | `/adams-review-fix` (Phases 7–9 + terminal cleanup) | not started | `plans/stage-3-fix.md` | — |

### Stage 1 — Foundation

**Scope (target, subject to plan refinement):**
- JSON Schema for `artifact.json` (codifies DESIGN §5–§6)
- `artifact-patch.py` — field-level mutations, state-transition whitelist, `--append-fix-attempt`, `--init`, `--add-finding`, `--dry-run`
- `artifact-render.py` — `artifact.json` → `artifact.md` (filter-by-`disposition` sections per §7)
- Shared helpers (Bash): `artifact-publish.sh`, error-as-prompt wrappers, repo-context / reviewer-sources / mode-detection / CLAUDE.md-paths fragments
- `phases.jsonl` / `trace.md` / `tokens.jsonl` loggers
- Directory scaffolding per DESIGN §9

**Done when:** I can hand-author a synthetic `artifact.json`, run `artifact-patch.py` + `artifact-render.py` against it, and produce a correct `artifact.md`. Schema validation rejects malformed inputs with error-as-prompt messages. No slash command runs yet.

**Status:** not started.

**Files landed:** —

**Verification evidence:** —

**Open issues / deviations:** —

### Stage 2 — `/adams-review`

**Scope (target):** top-level `adams-review.md` command, Phase 0–6 fragments, sub-agent dispatch pattern, effort inheritance, trivial-mode gate, publish path.

**Done when:** `/adams-review` run on a real repo produces a valid artifact; PR mode posts/edits the comment; local mode is a no-op on publish.

**Status:** not started. Will plan after Stage 1 closes.

### Stage 3 — `/adams-review-fix`

**Scope (target):** top-level `adams-review-fix.md`, leftover-`attempted` hard abort, clean-tree gate, staleness gate, Phase 8 fix-group agent dispatch with touched-file return, **9.pre overlap guard**, per-finding Phase 9 sub-agent, aggregation + per-group revert, commit SHA capture, **terminal cleanup** in the deterministic order (artifact records → push → publish → stash pop), error-recovery helper scripts.

**Done when:** full loop works. Mixed-outcome runs transition state correctly. Regression groups revert cleanly. Overlap abort leaves `current_state=attempted` and the next run's hard abort fires. Terminal cleanup ordering holds under push-fail and publish-fail.

**Status:** not started. Will plan after Stage 2 closes.

---

## Conventions

### Language split (rev 8)
- **Python** for JSON-heavy scripts: `artifact-patch.py`, `artifact-render.py`. Schema validation via `jsonschema`. Prefer stdlib + one dependency where possible.
- **Bash** for shell-glue scripts: `artifact-publish.sh`, error-as-prompt wrappers, any helper that's mostly `git` / `gh` calls.
- All scripts live at `~/.claude/commands/_shared/tools/` per DESIGN §9. Symlinked from this repo during development, or copied via install script at stage close-out (TBD — decide in Stage 1 planning).

### Commit cadence
Commit **inside** each stage at natural breakpoints (one per shared fragment, one per helper script, one per phase in Stage 2). Stage close-outs also commit `BUILD.md` updates. Don't batch into one giant stage-final commit.

Commit messages: imperative mood, reference DESIGN section where relevant (e.g., "Add artifact-patch.py with state-transition whitelist (DESIGN §5.2)").

### Stage flow
1. Draft stage plan in `plans/stage-N-name.md` (plan mode).
2. User reviews and approves.
3. Execute, committing regularly.
4. Update this file's stage section (Status, Files landed, Verification evidence, Open issues).
5. Compact session between stages.
6. Next session reads `BUILD.md` → `DESIGN.md` → relevant stage plan.

### Plan mode vs direct execution
Per user's CLAUDE.md: default is plan-mode-before-changes. For tactical mid-stage fixes (bug in a single script, typo, small refactor), direct execution is fine. For anything that touches stage scope or the design, re-enter plan mode.

---

## Adjusting the design as we build

**DESIGN.md is normative, not frozen.** Building always surfaces things the design didn't anticipate, got slightly wrong, or under-specified. Don't blindly follow a stage's design section if reality has shifted — but don't silently diverge either.

When a discrepancy comes up during a stage:

1. **Is it a clarification or a behavioral change?**
   - **Clarification** (design under-specified, you're filling in a detail that doesn't alter observable behavior — e.g., "DESIGN doesn't say what exit code `artifact-patch.py --dry-run` returns on invalid JSON; standardizing on 2"): update DESIGN inline as you make the call, note it in *Cross-stage notes* below with a one-line rationale. No approval round-trip needed.
   - **Behavioral change** (DESIGN says X, you now believe the right answer is Y — e.g., "§9.pre should also check files_modified vs files_created separately, not as a union"): stop, surface it to the user, agree on the change, then update DESIGN and proceed. Don't ship the divergence and leave DESIGN stale.

2. **Does it affect later stages?** After any DESIGN update, scan the unbuilt stages' scope. If a later stage depends on the thing you changed (e.g., Stage 3's terminal cleanup assumes a schema field Stage 1 ended up naming differently), add a line to that stage's section in the *Stage index* and/or append to *Cross-stage notes*. The goal: the next stage's plan draft should inherit these adjustments automatically, not rediscover them.

3. **When in doubt, check with the user.** Cheap to ask; expensive to ship a quiet divergence that surfaces as a bug two stages later. Err on the side of asking — especially for anything touching schemas, state transitions, file layout, or cross-command contracts.

Bias is toward **making DESIGN track reality**, not defending the rev-8 wording. If DESIGN and the code disagree at stage close-out, that's a defect to fix before compacting.

---

## Cross-stage notes

*Deviations from DESIGN, deferred items, things to revisit. Append as discovered.*

- **2026-04-17 — Python dep strategy changed from plain `pip install` to `uv` inline-script shebang (PEP 723).** Stage 1 plan §3 assumed plain pip would work. PEP 668 (Homebrew Python 3.12+) refuses direct pip installs, even with `--user`. Switched to `#!/usr/bin/env -S uv run --script` with `# /// script` inline dep spec; `uv` (already installed at `/opt/homebrew/bin/uv`) fetches `jsonschema` on first invocation and caches it. No venv, no activation. Behavioral deviation (affects shebangs and the runtime dep on every machine that runs these commands) — surfaced and approved before any Python script was written. README.md deps table updated. DESIGN doesn't prescribe a Python install mechanism, so no DESIGN change needed; this is a build-time implementation choice, not a design drift.

---

## Handoff protocol — what to update at stage close-out

When a stage completes, before the user compacts:

1. **Current state** section at the top: update date, current stage, next action.
2. **Stage index table**: flip status for the completed stage, update close-out notes link.
3. **Completed stage's section**: fill in *Files landed*, *Verification evidence*, *Open issues / deviations*.
4. **Cross-stage notes**: append anything worth remembering across stages (e.g., a DESIGN ambiguity that we resolved one way, and the rationale).
5. Commit the `BUILD.md` update in its own commit before compacting.

The user will typically compact after step 5. The next session uses this file + `DESIGN.md` + the next stage's plan as its starting context.
