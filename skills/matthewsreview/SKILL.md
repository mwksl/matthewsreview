---
name: matthewsreview
description: Multi-stage code review pipeline. Use when reviewing a PR or branch, deciding between matthewsreview commands (review/codex-review/add/walkthrough/fix/promote), choosing flags (--ensemble, --full, --models, --profile, --effort), or acting on an existing review artifact.
---

# matthewsreview — workflow guide

A multi-stage code review pipeline: parallel detection lenses → dedup → scoring gate → validation → auto-fix loop. State lives in `artifact.json` under `~/.matthews-reviews/<repo-slug>/<branch>/<review_id>/` — every command after the first operates on that artifact, so steps can happen days or weeks apart.

Runs from three harnesses: Claude Code (`/matthewsreview:<cmd>`), Oh My Pi (`/matthewsreview:<cmd>`), and Codex (`$matthewsreview-<cmd>` skills).

## Which command, when

| Command | Use it when |
|---|---|
| `review` | Starting a review of the current branch/PR. The entry point for 95% of usage. |
| `codex-review` | You want Codex (not Claude) to drive detection + validation. Produces the same artifact shape; everything downstream works identically. |
| `add` | An external reviewer (cloud `/ultrareview` paste, a teammate's note, another tool's output) found things the review missed. Injects them into the latest artifact, deduped + re-validated. |
| `walkthrough` | The review surfaced findings that need human judgment (deep-manual, deep-report, light-lane). Steps through them one by one; promote what should be auto-fixed. |
| `fix` | Apply auto-fixable findings. Re-reviews its own work, reverts regressions, commits survivors. Safe to run straight after `review` if you only care about mechanical fixes. |
| `promote <id>` | One-off: promote a single finding to auto-fixable, bypassing the lane filter and score threshold. Then run `fix`. |

## The recommended flow

On a non-trivial PR:

1. **`review`** — add `--ensemble` to pool a Codex pass + PR bot-comment scrape on top of the internal lenses (higher token cost, better coverage). Add `--full` on a small/docs-only PR where you still want every lens (opts out of trivial-mode lens skipping).
2. **`add`** *(optional)* — only if you ran a parallel review elsewhere that found things.
3. **`walkthrough`** *(optional)* — only if the review output shows findings needing human judgment. Its "Next steps" block tells you the exact count.
4. **`fix`** — applies everything auto-eligible, including whatever `walkthrough` promoted.

You can stop after any step. The artifact persists; `fix` weeks later uses the same review state.

## Model selection

Every pipeline stage dispatches sub-agents through named **roles** (e.g. `deep_validate`, `light_lens`, `scoring`, `fix_hint`). Three tiers hold the defaults — `deep=claude:opus`, `light=claude:sonnet`, `utility=claude:sonnet` — and each role maps to a tier but can be overridden individually.

- Per-run: `--models "utility=claude:haiku"` or `--models "deep_validate=claude:sonnet,light=codex::medium"`.
- Named presets: `--profile <name>` from `profiles.<name>` in `~/.matthews-reviews/config.json` or `<repo>/.matthewsreview.json`.
- Merge order: built-in defaults → user config → repo config → `--profile` → `--models`.

Two useful starting profiles:

- **`max`** — quality first: everything deep stays Opus, `light=claude:opus`, utility stays Sonnet. Use on security-sensitive PRs.
- **`cheap`** — cost first: `utility=claude:haiku`, `light=claude:haiku`, deep stays Opus (validation is where correctness lives). Roughly halves token spend on large PRs.

The preflight output prints the resolved **Model plan** table (role / engine / model / source) before any sub-agent launches — check it, not your memory of the config.

Role strings are `engine:model[:effort]`; the effort segment is codex-only (`low|medium|high|xhigh|max|ultra`).

## After the review: the artifact as a work queue

- **Dispositions table** — `bin/artifact-render.py --format dispositions --artifact <path>/artifact.json > DISPOSITIONS.md` emits the full findings table with suggested actions (fix / walkthrough / issue / judge / skip) and engage/skip totals. This replaces hand-built ENGAGE/SKIP passes.
- **Calibration** — `bin/calibration-report.sh ~/.matthews-reviews` aggregates your review history: demote rates, waste ratios, per-phase token medians, lens retries. Use it to tune `gates` and tiers in `~/.matthews-reviews/config.json`.
- **Setup problems** — `bin/doctor.sh` checks deps, harness CLIs, config validity, and stale pre-rename remnants, printing the exact fix per finding.

## Gotchas

- `--full` and `--ensemble` are independent: `--full` controls *lens coverage*, `--ensemble` controls *reviewer sources*. On a big PR you usually want `--ensemble`; on a tiny PR you want neither; on a tiny-but-critical PR, `--full`.
- `codex-review --effort` accepts `low|medium|high|xhigh|max|ultra` (default `high`).
- A re-run of `review` overwrites the artifact — `add`ed findings are lost. Re-add after re-review.
- Review state root moved from `~/.adams-reviews` to `~/.matthews-reviews`. Old state still works (fallback with a migrate warning); `mv ~/.adams-reviews ~/.matthews-reviews` silences it.
