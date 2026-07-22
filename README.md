# matthewsreview

Multi-stage code review for **Claude Code, Codex, and Oh My Pi** — parallel sub-agent detection, validation passes, per-stage model selection, persistent JSON state, and an automated fix loop that re-reviews and reverts regressions before committing.

Fork of [adamsreview](https://github.com/adamjgmiller/adamsreview) (v0.4.3), expanded: runs from three harnesses instead of one, every pipeline stage's model is configurable, and the pipeline is tuned from ~100 real review runs' telemetry.

The six commands:

- **`review`** — multi-lens code review of a branch or PR. Up to seven parallel sub-agent lenses (correctness, security, UX, etc.) feed a dedup pass, a cheap-then-deep validation gate, and a holistic cross-cutting pass. High-confidence auto-fix proposals are pre-computed so `fix` and `walkthrough` can batch-accept them in one confirm. `--ensemble` adds a Codex pass and PR bot-comment scrape on top of the internal lenses; `--full` forces every lens even on small/docs-only diffs.
- **`codex-review`** — Codex-driven peer to `review`. Same artifact shape, drop-in for everything downstream. Effort tunable via `--effort low|medium|high|xhigh|max|ultra` (default `high`); `--full` forces all detection lenses.
- **`add`** — inject externally-sourced findings (a cloud `/ultrareview` paste, an Opus once-over, a teammate's note) into the most recent review's artifact. Deduped, validated by the same gates, re-published to the existing PR comment.
- **`walkthrough`** — interactive driver for findings `fix` would skip. Per-finding briefing + options + recommendation; promote what you want auto-fixed.
- **`fix`** — automated fix loop. Per-fix-group agents, post-fix review, **reverts regressions, commits survivors** (`--granular-commits` for one commit per group).
- **`promote`** — human override that promotes a single finding to auto-fixable.

## Install

| Harness | Install | Invoke |
|---|---|---|
| Claude Code | `/plugin marketplace add mwksl/matthewsreview` then `/plugin install matthewsreview@matthewsreview` | `/matthewsreview:review` |
| Oh My Pi | `omp plugin marketplace add mwksl/matthewsreview` then `omp plugin install matthewsreview@matthewsreview` — **or zero-install**: if the plugin is already installed in Claude Code, omp discovers it automatically | `/matthewsreview:review` |
| Codex | clone, then `./install.sh --codex` (generates `$matthewsreview-*` skills from `commands/*.md` and links them into `~/.agents/skills/`; also `~/.codex/skills/` when present) | `$matthewsreview-review` or select `matthewsreview-review` from `/skills` |

Runtime deps (all harnesses): `uv`, `jq`, `gh`, `git`, bash 3.2+. Run `bin/doctor.sh` after install — it checks deps, harness CLIs, config validity, and stale pre-rename remnants, printing the exact fix for anything off.

Codex generated skills are an install artifact, not another source tree. Re-run `./install.sh --codex` after updates. To uninstall them:

```bash
for root in ~/.agents/skills ~/.codex/skills; do
  for skill in "$root"/matthewsreview "$root"/matthewsreview-*; do
    [ -L "$skill" ] && rm "$skill"
  done
done
```

### Local checkout installs

- **Claude Code**: `/plugin marketplace add /path/to/matthewsreview` then `/plugin install matthewsreview@matthewsreview`; or one-shot `claude --plugin-dir /path/to/matthewsreview`.
- **Oh My Pi**: `omp plugin marketplace add /path/to/matthewsreview` then `omp plugin install matthewsreview@matthewsreview`.
- **Codex**: `./install.sh --codex` from the clone. Re-run after moving or updating the clone (generated skills bake an absolute `MREVIEW_ROOT`).

## Recommended flow

1. **Review.** `/matthewsreview:review --ensemble --full` (the daily-driver combination: full lens coverage + pooled Codex/bot-comment sources). Or `codex-review` for a Codex-driven pass.
2. **Add** *(optional)* — inject findings from a parallel review.
3. **Walkthrough** *(optional)* — the review's **Next steps** block tells you exactly how many findings need human judgment.
4. **Fix** — applies every auto-eligible finding (including walkthrough-promoted ones).

Each command is independent; steps 2–4 can land days or weeks after step 1 — review state persists under `~/.matthews-reviews/<repo-slug>/<branch>/<review_id>/`.

## Model selection

Every sub-agent dispatches through a named **role**; you choose the model per role. Role strings are `engine:model[:effort-or-thinking]`:

- **Engines**: `claude` (native in Claude Code/omp sessions), `codex` (CLI subprocess, billed by Codex), `omp` (any omp provider model, native in omp only).
- **Tiers** hold the defaults: `deep=claude:opus` (deep lenses, deep validation, cross-cutting, fix agents, post-fix review), `light=claude:sonnet` (light lenses/validation), `utility=claude:sonnet` (classifier, normalizer, dedup, scoring, fix-hint, briefer, drafter). Codex lanes (`ensemble_detect`, `codex_detect/validate/crosscut`) default `codex::high`.
- **Overrides**: any role individually, e.g. `deep_validate=claude:sonnet`, `light=codex::medium`, `utility=claude:haiku`.

Where config lives (later wins): built-in defaults → `~/.matthews-reviews/config.json` → `<repo>/.matthewsreview.json` → `--profile <name>` → `--models "<csv>"`.

```jsonc
// ~/.matthews-reviews/config.json
{
  "tiers": { "utility": "claude:haiku" },
  "roles": { "deep_validate": "claude:sonnet" },
  "gates": { "phase3_gate": 45, "phase4_bands": [45, 60, 75], "fix_threshold": 60, "walkthrough_threshold": 60 },
  "profiles": {
    "max":   { "tiers": { "light": "claude:opus" } },
    "cheap": { "tiers": { "utility": "claude:haiku", "light": "claude:haiku" } }
  },
  // Per-harness defaults: applied between built-ins and your tiers, so
  // omp sessions get omp-native models while Claude Code keeps claude:*.
  "orchestrator_defaults": {
    "omp": {
      "tiers": { "deep": "omp:moonshot/kimi-k3", "light": "omp:moonshot/kimi-k3", "utility": "omp:moonshot/kimi-k3" }
    }
  }
}
```

**Running from Codex.** Defaults stay harness-invariant: deep roles use `claude:opus`, light/utility roles use `claude:sonnet`, and dedicated Codex lanes use `codex::high`. A Codex-orchestrated run shells out to an authenticated Claude CLI for `claude:*` roles. Use `orchestrator_defaults.codex.tiers`, a profile, or `--models` when you want an all-Codex run.

**Running on omp models.** Role strings with the `omp:` engine dispatch through omp's eval bridge to any model your omp installation serves (`omp models` lists the registry). Append an omp thinking level when the model supports one, e.g. `omp:openai-codex/gpt-5.6-sol:max`. Example per-run: `--models "deep=omp:openai-codex/gpt-5.6-sol:max,light=omp:openai-codex/gpt-5.6-sol:max,utility=omp:openai-codex/gpt-5.6-sol:max"`. To make it permanent, set `orchestrator_defaults.omp.tiers` (above) — Claude Code sessions are unaffected. Without it, `claude:*` roles under omp require Anthropic auth in omp; if a role's model isn't servable, the preflight Model plan prints a warning and lens dispatches 404 (the run is then marked **REVIEW DEGRADED** in the report). `bin/doctor.sh` probes this upfront.

```bash
/matthewsreview:review --full --models "utility=claude:haiku"
/matthewsreview:review --profile cheap
```

The preflight prints the resolved **Model plan** table (role / engine / model / effort-or-thinking / source) before any sub-agent launches; the plan is stored in the artifact (`model_plan`) and each dispatch's role string lands in `tokens.jsonl`. Codex effort supports `low|medium|high|xhigh|max|ultra`; omp thinking supports `off|minimal|low|medium|high|xhigh|max`.

### Gate thresholds

Score gates are config values with unchanged defaults: `phase3_gate=45`, `phase4_bands=[45,60,75]`, `fix_threshold=60`, `walkthrough_threshold=60`. `bin/calibration-report.py ~/.matthews-reviews` aggregates your review history (demote rates, waste ratios, band→disposition matrix, per-phase token medians) so you can tune them from evidence. CLI thresholds on `fix`/`walkthrough` still override per run.

## Token counts

`subagent_tokens` is always rolled up from the review's own `tokens.jsonl`.
Claude Code can also capture the orchestrator's main-session spend:

```bash
export MATTHEWS_REVIEW_TALLY_ORCHESTRATOR=1
```

The `SessionStart` hook records the active session ID and exact transcript path.
Each tally reads only that file, filters to matching assistant turns at or after
the review start, and merges the session's counters into the artifact. It never
scans sibling transcripts. Later `fix`, `add`, or `walkthrough` sessions retain
earlier lifecycle-session counters; re-tallying the same session replaces its
row rather than double-counting it.

This remains opt-in because reading a Claude Code transcript can trigger macOS's
“access data from other apps” prompt (`com.apple.provenance`). Grant Full Disk
Access to the terminal/Claude Code host if macOS blocks the read. Without the
export, the helper skips and leaves any previously captured value untouched.
The legacy `ADAMS_REVIEW_TALLY_ORCHESTRATOR=1` export still works. Codex- and
omp-orchestrated runs have no Claude `SessionStart` transcript metadata, so this
field remains absent; their dispatched-agent usage still appears under
`subagent_tokens`.

## The artifact as a work queue

- **Dispositions export** — one row per finding with suggested actions, replacing hand-built ENGAGE/SKIP passes:
  ```bash
  bin/artifact-render.py --input <review_dir>/artifact.json --format dispositions > DISPOSITIONS.md
  ```
- **Calibration** — `bin/calibration-report.py` (see above).
- **Doctor** — `bin/doctor.sh` for environment problems.

## Command reference

```
/matthewsreview:review [--ensemble] [--full] [--profile <name>] [--models "<csv>"]
/matthewsreview:codex-review [--effort <low|medium|high|xhigh|max|ultra>] [--full] [--profile <name>] [--models "<csv>"]
/matthewsreview:add [<paste...>] [--file <path> --line <N> --claim "..."] [--impact <type>] [--no-dedup] [--profile <name>] [--models "<csv>"]
/matthewsreview:walkthrough [threshold] [--profile <name>] [--models "<csv>"]
/matthewsreview:fix [threshold] [--granular-commits] [--profile <name>] [--models "<csv>"]
/matthewsreview:promote <finding_id> [--reason "..."] [--fix-hint "..."] [--force] [--defer-publish]
```

## Maintenance

- **Version bumps**: patch for fixes, minor for new commands or breaking output-shape changes — bump `.claude-plugin/plugin.json` or `/plugin marketplace update` / `omp plugin upgrade` won't pick up changes.
- **CI**: `.github/workflows/smoke.yml` runs `test/smoke.sh` (495 assertions) on ubuntu + macOS, plus shellcheck and a bash-3.2 portability gate. Run `test/smoke.sh` locally before pushing.
- **Upgrading**: Claude Code `/plugin marketplace update matthewsreview && /plugin update`; omp `omp plugin upgrade matthewsreview@matthewsreview`; Codex `git pull && ./install.sh --codex`.
- **Working on the pipeline itself**: read `AGENTS.md` first. `docs/state-and-gates.md` (state model, gates, lanes) is the normative spec; `docs/pipeline.md` has phase trees; `docs/helpers.md` the helper inventory.

## Migrating from adamsreview

The pipeline reads the old identity's state with a migration nudge, so nothing breaks mid-transition:

1. `mv ~/.adams-reviews ~/.matthews-reviews` (or keep the old root via `MATTHEWS_REVIEW_REVIEWS_ROOT=~/.adams-reviews`).
2. Rename any `ADAMS_REVIEW_*` exports to `MATTHEWS_REVIEW_*` (old vars still work as fallbacks).
3. In Claude Code: `/plugin uninstall adamsreview@adamsreview`, then install matthewsreview. Update any project `.claude/settings.json` `enabledPlugins` entries from `adamsreview@adamsreview` to `matthewsreview@matthewsreview`, and delete stale `plugins/cache/adamsreview/.../bin` PATH allowlist lines in `settings.local.json`.
4. `bin/doctor.sh` flags anything you missed.

## Layout

```
matthewsreview/
├── AGENTS.md                  ← operational guide (read first when hacking on the repo)
├── .claude-plugin/            ← plugin.json + marketplace.json (Claude Code)
├── .omp-plugin/               ← marketplace.json (Oh My Pi)
├── commands/                  ← the six commands (single source for all harnesses)
├── fragments/                 ← shared phase fragments, lens prompts, Dispatch Protocol
├── skills/matthewsreview/     ← workflow front-door skill (all three harnesses)
├── bin/                       ← helpers (review-config.sh, agent-dispatch.sh, doctor.sh,
│                                 calibration-report.py, artifact-*, codex-poll.sh, …)
├── scripts/build-codex-skills.sh + install.sh   ← Codex skill generation/install
├── hooks/                     ← SessionStart dependency check + exact transcript/session export
├── docs/                      ← state-and-gates.md, pipeline.md, helpers.md, case-studies/
├── test/                      ← smoke.sh + fixtures
└── .github/workflows/smoke.yml
```

## Troubleshooting

- **First helper invocation is slow** — `uv` resolves Python + `jsonschema` on first run per machine; cached thereafter.
- **`omp` sessions show `--tokens null` rows** — the eval bridge doesn't always expose sub-agent usage; logged as null rather than estimated. Codex dispatches report real counts from `token_count` events.
- **Codex skills stopped working after moving the clone** — re-run `./install.sh --codex` (absolute paths are baked).
- **Reviews root moved** — `~/.matthews-reviews` is canonical; `MATTHEWS_REVIEW_REVIEWS_ROOT` overrides; `~/.adams-reviews` still works read-side with a migrate warning.

## Status

Current release: **v1.0.6** — backlog close-out: `comment-freshness.sh` missing-dep exits now honor the exit-5 contract, signals re-raise as true signal deaths (WIFSIGNALED) after cleanup, behavioral coverage for codex-poll's stalled-vs-desynced fork, timing-independent dispatch assertions, and `head -60` contract reads with every helper's exit docs inside the window (smoke 493 → 495). Previously (v1.0.5): temp-file/signal hygiene and jq entry guards for `freshness-gate.sh` and `codex-poll.sh`, plus behavioral coverage for the dispatch engine's rapid-completion, malformed-output, malformed-terminal, watchdog-verdict, and parallel-isolation paths; (v1.0.4): Bash 3.2 Codex-skill generation no longer stalls macOS CI, rebrand + multi-harness (Claude Code / Codex / Oh My Pi), per-stage model selection, telemetry-informed efficiency tuning. Fork of adamsreview v0.4.3 by Adam Miller.
