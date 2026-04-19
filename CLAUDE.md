# CLAUDE.md — operational guide for adams-review

Read this first on a fresh session. It's procedural (how to work in the repo).

**Context discipline.** This file is self-contained for routine work — don't auto-open anything under `docs/` unless you need something this file doesn't cover. `docs/DESIGN.md` is a **reference manual keyed by `§X.Y` anchors**; grep for the anchor, don't Read the file end-to-end (it's ~2400 lines). `docs/BUILD.md` is **historical journal**; grep by date (`2026-04-18`) or stage name (`Stage 2.7`). The fragments under `commands/_shared/` cite DESIGN sections inline (e.g., "per §13.1") — that's your entry point, not the top of the file.

```bash
grep -n '^### 13\.1 ' docs/DESIGN.md      # §13.1 score decision table
grep -n '^## '        docs/DESIGN.md      # full section index (~80 lines)
grep -n '2026-04-18'  docs/BUILD.md       # everything that happened that day
```

## What this repo is

Build repo for three personal Claude Code slash commands:

- **`/adams-review`** — multi-lens code review of a branch or PR (Phases 0–6).
- **`/adams-review-fix`** — automated fix loop for auto-fixable findings (Phases 7–9).
- **`/adams-review-promote`** — human override that promotes a single finding to auto-fixable, bypassing the Phase 8 impact_type lane filter and score threshold (see DESIGN §27). Metadata-only; run `/adams-review-fix` afterwards to apply.

All three are **built and in production use** as of 2026-04-18 (Stages 1, 2, 2.5, 2.6, 2.7, 2.8, 3 closed). The only unexecuted scope is Stage 4 (fragment shrink), scoped in `plans/stage-4-fragment-shrink.md`.

## Layout

```
adams-review/
├── CLAUDE.md                       ← this file
├── README.md                       ← setup + layout
├── docs/
│   ├── DESIGN.md                   ← normative spec (rev 8); cite by §X.Y
│   └── BUILD.md                    ← historical build journal
├── plans/                          ← stage plans (1–3 closed; stage-4 live)
├── commands/
│   ├── adams-review.md             ← top-level slash command (Phases 0–6)
│   ├── adams-review-fix.md         ← top-level slash command (Phases 7–9)
│   └── _shared/                    ← symlinked into ~/.claude/commands/_shared
│       ├── 00-preflight.md … 10-post-fix-and-commit.md   ← phase fragments
│       ├── lens-{ux,security}-reference.md
│       ├── schema-v1.json
│       └── tools/                  ← helper scripts
└── test/
    ├── smoke.sh                    ← 105-assertion harness
    └── fixtures/
```

Top-level command files (`~/.claude/commands/adams-review.md`, `adams-review-fix.md`) need **per-command symlinks** to be reachable as slash commands. The `_shared/` directory symlink propagates fragments + helpers automatically, but new `commands/*.md` files require `ln -s $PWD/commands/<name>.md ~/.claude/commands/<name>.md`.

## How to test

```bash
test/smoke.sh
```

Expects `smoke: PASS (122 assertions)`. Every helper script and renderer path is covered. Existing assertions should stay green across changes; new helpers should add 2-3 assertions in the OC-* / FR-* / RH-* / FX-* naming style.

## Dependencies

| Tool | Version | Notes |
|---|---|---|
| `uv` | 0.7+ | PEP 723 inline-script shebang (`#!/usr/bin/env -S uv run --script`) — no venv, no pip install. `brew install uv`. |
| `bash` | 4+ | Helpers use `#!/usr/bin/env bash`; macOS default `/bin/bash` is 3.2 so `brew install bash` or user's newer default is required. |
| `jq` | 1.6+ | `brew install jq`. |
| `gh` | 2.x | `brew install gh`, `gh auth login`. |
| `git` | 2.x | Standard. |

## Operational rules

Enough to work without opening `docs/`. Each rule links a grep target if you need rationale.

1. **Bash 3.2 portable.** Helpers run under macOS `/bin/bash` 3.2 in practice. Avoid `declare -A`, `mapfile`/`readarray`, `${var,,}`. `awk '!seen[$0]++' | sort` beats associative arrays for dedup. `set -euo pipefail` and process substitution are fine.

2. **uv shebang for Python helpers.** `#!/usr/bin/env -S uv run --script` with a `# /// script` inline dep spec. Never `pip install` directly (PEP 668 blocks it on Homebrew Python 3.12+).

3. **Exit codes are a contract.** Python helpers: `0=OK, 1=validation, 2=invalid-transition, 3=dry-run-invalid, 4=unexpected, 5=missing-dep, 64=usage`. Defined in `tools/_common.py`; reuse, don't invent.

4. **Error-as-prompt on every helper.** Non-zero exits emit `ERROR:` / `Valid input:` / `Did you mean:` / `Action:` stderr sections. No stack traces on expected errors. See `tools/_common.py:suggest()`.

5. **Atomic writes.** Writers go tmp-file → `rename` (see `tools/_common.py:atomic_write`). The on-disk artifact is never in an invalid state mid-run.

6. **Reviews root is `~/.adams-reviews/`, not `~/.claude/reviews/`.** Claude Code hardcodes a sensitive-file prompt on writes to `~/.claude/` that survives `bypassPermissions` mode. Overridable via `$ADAMS_REVIEW_REVIEWS_ROOT`.

7. **`repo_slug` comes from one helper.** `tools/repo-slug.sh --repo-root <path>` is the single source of truth. Phase 0 and Phase 7 both call it. Never reimplement inline.

8. **Commit messages via `git commit -F <file>`, not `-m "$(…)"`.** Finding claims can contain quotes/backticks/newlines. Temp-file message bodies sidestep the whole escape surface.

9. **Fix-group agents may not delete or rename files.** Layered enforcement: prompt prohibition + Phase 9.pre `git status --porcelain` scan for `D ` entries.

10. **Absolute paths in `allowed-tools` grants.** Under the `_shared/` symlink, `Bash(/Users/.../tools/<script>.sh:*)` resolves cleanly. No relative-name + `PATH` fallback needed.

## How to work on new changes

- **Plan mode by default.** Per user's global CLAUDE.md: present plan, get approval, then execute. "Plan-and-execute" requests skip the approval round-trip. Bug fixes can go direct.
- **Blast-radius discipline before committing.** Check every writer, every consumer, parallel code paths, full function bodies, and stale comments. Self-review as if you were a reviewer.
- **If you touch pipeline behavior, keep `docs/DESIGN.md` in sync.** Clarification-level drift → update the relevant `§X.Y` section inline. Behavioral divergence → surface to user before shipping.
- **New stages get a `plans/stage-N-<name>.md`** drafted in plan mode, user-approved before execution.

## Batched-helper pattern

Three `artifact-patch.py` modes (`--apply-decisions`, `--apply-fix-start`, `--apply-fix-outcomes`) share a pattern: JSON array of tuples, per-tuple atomic writes, first-failure halt, one summary line. If you add a fourth batched mode, reuse the scaffolding (`_check_*_tuple` validator + `_load_or_fail` per tuple + `_write_and_emit(silent=True)`). Accept that mid-batch failure leaves tuples 0..N-1 persisted; callers re-invoke with the remainder.

## Commits

Imperative mood. Reference DESIGN section where relevant (e.g., "Add comment-freshness.sh (§13.13, §21.10)"). Commit at natural breakpoints, not one giant final commit.

## Grep targets if you need more than this file

The schema (`commands/_shared/schema-v1.json`) is the source of truth for artifact shape — read it directly, no prose needed. For everything else:

| Question | Grep target |
|---|---|
| What does Phase N do? | `grep -n '^## 4\.' docs/DESIGN.md` (pipeline overview) |
| Specific phase algorithm (e.g. §13.1 score decision) | `grep -n '^### 13\.1 ' docs/DESIGN.md` |
| Sub-agent prompt essence (§19.x) | `grep -n '^### 19\.' docs/DESIGN.md` |
| Helper contract (§21.x) | `grep -n '^### 21\.' docs/DESIGN.md` |
| Working-set variables passed between phases | `grep -n '^## 25' docs/DESIGN.md` |
| Why a past decision was made | `grep -n 'Stage 2\.5' docs/BUILD.md` or grep a date |
| Why a file lives where it does | `grep -n 'repo-slug\|reviews-root\|sensitive-file' docs/BUILD.md` |

Read one section at a time (`Read docs/DESIGN.md offset=1142 limit=70` for §13.1). The file is a reference manual; reading it sequentially wastes context.
