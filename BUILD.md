# BUILD.md — build journal for adams-review

This is the running build journal. `DESIGN.md` is the normative design (rev 8). This file tracks **execution**: where we are, what's landed, what surprised us, and what still needs attention.

If you are a Claude Code session starting fresh (after compaction or on a new day), **read this file first**, then open `DESIGN.md`. Skim "Current state" and the active stage's section; you can treat the rest as reference.

---

## Current state

**As of 2026-04-17 (mid-stage compaction checkpoint)** — Stage 1 in progress, 13 of 17 commits landed. Compacting now to keep context quality high; the next session finishes Stage 1.

- Design doc: `DESIGN.md` (rev 8 — implementation-language split applied)
- Stage 1 plan: `plans/stage-1-foundation.md` (user-approved; sync'd with confirmed decisions)
- Symlink `~/.claude/commands/_shared → commands/_shared` is live
- `uv` (already installed at `/opt/homebrew/bin/uv 0.7.15`) supplies `jsonschema` to Python scripts via PEP 723 inline-script shebangs — deviation from original "plain pip" plan documented in cross-stage notes below

**Stage 1 commits so far (on `main`):**

```
17a18a4 Add claude-md-paths.sh (DESIGN §21.7, §23)
53cc516 Add log-phase.sh and log-tokens.sh (DESIGN §11, §12, §21.6)
fe032d0 Add artifact-read.sh (DESIGN §8.1, §21.1)
8fca196 Add artifact-validate.sh (DESIGN §8.3, §21.3)
a3bede7 Add artifact-render.py (DESIGN §7, §21.6)
83ee47a Add artifact-patch.py --dry-run
d669d5f Add artifact-patch.py --append-fix-attempt (combinable with --set)
2504b09 Add artifact-patch.py --set mode (transitions + coupling)
926d9fe Add artifact-patch.py --add-finding mode
cd1991c Add artifact-patch.py --init mode (DESIGN §8.2, §21.2)
f374a36 Add _common.py: shared Python helpers for writer scripts
98c0fb5 Add schema-v1.json codifying artifact shape (DESIGN §5, §6)
3c82a1e Scaffold Stage 1 layout: symlink, READMEs, durable plan
bd6b610 Bootstrap repo with design doc (rev 8) and build journal
```

**Remaining for Stage 1 (4 commits):**

1. **Commit 14 — `staleness.sh`** (DESIGN §21.4). `git diff --name-only <reviewed_sha>..HEAD` intersected with `--reviewed-files` list. Emits `safe` / `warn` / `unsafe` on stdout; exit 0 safe/warn, non-zero unsafe.
2. **Commit 15 — `artifact-publish.sh`** (DESIGN §21.6). PR-mode `gh api` comment discovery (comment_id arg → PR issue-comments list filtered by current `gh` user + `<!-- adams-review-v1 -->` marker → most recent), PATCH/POST, `{"comment_id": N}` stdout emit for the orchestrator to persist via `artifact-patch.py --set comment_id=<n>`. Local-mode no-op. Per user decision, real-PR exercise is **deferred to Stage 2**; Stage 1 verifies only the shell path + local no-op.
3. **Commit 16 — Smoke harness** (`test/smoke.sh` + `test/fixtures/`). Walks the 12-assertion Stage 1 done-when flow from `plans/stage-1-foundation.md` §7. Hand-authored `artifact-seed.json` + `expected.md`; `diff` check against the rendered Markdown must be empty.
4. **Commit 17 — BUILD.md close-out + DESIGN §21.2 exit-code footnote.** Flip Stage 1 status in the index table; fill Files landed / Verification evidence / Open issues; add the exit-code clarification (1/2/3/4/5/64) to DESIGN.md §21.2 as a footnote per the BUILD.md "Adjusting the design" protocol.

Plus one deferred Stage-1 item not yet done:
- **§8.7 grant probe** (Task #29, still pending). Set up `~/.claude/commands/_shared-probe.md` with a single `Bash(/abs/path/probe.sh:*)` grant; user runs in a separate Claude Code `default`-mode session and reports whether the absolute-path grant resolves through the symlink. Results recorded in cross-stage notes. Can run in parallel with any remaining commit.

**Next action after compact:** resume with commit 14 (`staleness.sh`). Scripts and their DESIGN references are listed above; `plans/stage-1-foundation.md` §4–§5 describe each in full.

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

- **2026-04-17 — Exit-code clarifications for `artifact-patch.py` (DESIGN §21.2).** §21.2 only says "non-zero" on failure. Standardized in `_common.py`: `1=validation`, `2=invalid-transition`, `3=dry-run-invalid`, `4=unexpected`, `5=missing-dep`, `64=usage`. Clarification-level update per BUILD.md protocol. DESIGN §21.2 footnote is part of Stage 1 commit 17 (close-out) — not yet applied to DESIGN.md.

- **2026-04-17 — `artifact-validate.sh` uses a uv heredoc pattern, not a companion `.py`.** DESIGN §9.1 lists `artifact-validate.sh` only; no companion `.py`. Implemented as a Bash script that invokes Python via `uv run --with jsonschema python3 -` with an inline heredoc, importing `_common.py` via `PYTHONPATH`. Single file, matches §9.1. Same pattern available for any future thin Bash-fronted validator.

- **2026-04-17 — Bash scripts target portable Bash 3.2 features.** Shebang is `#!/usr/bin/env bash`, which resolves to macOS default `/bin/bash` (Bash 3.2, no associative arrays). `claude-md-paths.sh` used `declare -A` in its first draft and failed; rewrote to use `awk '!seen[$0]++' | sort` for dedup. Rule: avoid `declare -A`, `mapfile`, `readarray`, and `${var,,}` (lowercase) — they're all Bash 4+. `nameref` and process substitution ok; `set -euo pipefail` ok. Apply to all future Bash helpers across stages.

- **2026-04-17 — Detail-block auto-fixable row ordering by finding id.** `artifact-render.py` first iterated `DEEP_AUTO_FIX_DISPOSITIONS = (confirmed_auto, partial, regression, resolved)` in order, which put partials before resolveds inside the same Auto-fixable table. Changed to sort by finding id for stable natural order. Matches DESIGN §7's implicit natural ordering of F001→F002→F003 in the worked example. Not a DESIGN change; just a rendering decision.

- **2026-04-17 — Status-column behavior in Auto-fixable table.** DESIGN §7 says "the Auto-fixable table gains a Status column with `✓ verified` / `⚠ partial` / `✗ regression (reverted)`". Implemented: the column appears automatically when any row has a `fix_attempts` entry; it's absent pre-fix. Each cell shows outcome + short `output_sha` link or "(no commit)" for regression-reverted attempts. Matches §7 wording.

- **2026-04-17 — `--set` allowlists are explicit** (`SETTABLE_FINDING_FIELDS`, `SETTABLE_ARTIFACT_FIELDS` in `artifact-patch.py`). DESIGN §21.2 doesn't enumerate patchable fields; I chose an allowlist over a blocklist for safer error-as-prompt UX. Finding-level allowed: scalar enums, reason, confirmed_strength, score_phase3/4, introduced_in_sha, suggested_follow_up, related_parent_finding_id, plus the coupling triple (current_state, disposition, is_actionable). Top-level allowed: comment_id, trivial_mode, pr_state, pr_number. Arrays/objects and immutable fields (id, file, claim, sources, score_history, fix_attempts, validation_result, line_range) are rejected with a listing of allowed names. Stage 2 may need to add top-level `metrics` / `subagent_tokens` setters — will add a `--set-json` flag when that comes up, rather than overloading `--set`.

- **2026-04-17 — `--append-fix-attempt` combines with `--set` per DESIGN §26.** In one patch: `--set current_state=resolved --set disposition=resolved --append-fix-attempt '...'`. Order within the call is `--set` first (transitions + coupling checks run), then the attempt is appended. Cleaner than forcing two sequential `artifact-patch.py` invocations for every Phase 9 step.

---

## Handoff protocol — what to update at stage close-out

When a stage completes, before the user compacts:

1. **Current state** section at the top: update date, current stage, next action.
2. **Stage index table**: flip status for the completed stage, update close-out notes link.
3. **Completed stage's section**: fill in *Files landed*, *Verification evidence*, *Open issues / deviations*.
4. **Cross-stage notes**: append anything worth remembering across stages (e.g., a DESIGN ambiguity that we resolved one way, and the rationale).
5. Commit the `BUILD.md` update in its own commit before compacting.

The user will typically compact after step 5. The next session uses this file + `DESIGN.md` + the next stage's plan as its starting context.
