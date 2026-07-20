# Tuning `/matthews-review` against `feat/import-apple` — three-cycle A/B/C

Companion to [`ray-finance-feat-import-apple.md`](ray-finance-feat-import-apple.md).
Where that doc compares `/matthews-review` to `/ultrareview` across moving
snapshots of the branch, **this doc compares `/matthews-review` to itself**
across three consecutive runs against a fixed target, as pipeline-tuning
commits landed between them.

## Why this doc exists

`/ultrareview`'s correctness-finding list on this PR (bug_001, bug_002,
bug_003, bug_005, bug_008) is a convenient external rubric — five
independently-identified bugs that the pipeline should, ideally, also
surface. Holding the diff fixed and running the pipeline three times
with targeted prompt changes between runs gives us a cleaner read on
what's actually moving the needle than the cross-snapshot comparison
can.

The honest caveat up front: LLM-lens pipelines are non-deterministic.
Three runs is enough to see direction; it is not enough to isolate
signal from sampling variance. That qualification is carried through
the observations below.

## The fixed target

All three runs reviewed the same commit of `feat/import-apple`:
**19 files changed, +2591 / −174 (2765 lines)**. All three ran in
`--ensemble` mode (Claude + Codex + CodeRabbit).

| Run | `rev_*` ULID | Started (UTC) | Elapsed |
|---|---|---|---|
| review-1 | `01KPMPFW1SZYHYHPCYPRKQY14N` | 2026-04-20T05:41Z | ~26 min |
| review-2 | `01KPNVKJ861MDM36JX6W8DX2DZ` | 2026-04-20T16:29Z | ~34 min |
| review-3 | `01KPP38V0VZ5TDZ1WQN84HPNRW` | 2026-04-20T18:44Z | ~36 min |

## What landed between each run

From `git log` on `main`, in chronological order:

**Between review-1 and review-2 (09:15 PDT):**

- `50001ee` — _Detection: sharpen L2 + Codex prompts for careful-reader
  bugs._ Added explicit invariant-checking instructions to the
  L2-structural lens prompt (catch-scope audits, validator-function
  parallel-path diffing, etc.) and mirror-aligned the Codex reviewer
  prompt.
- `ef6f8d5` — _Phase 4 deep validator: mandatory adjacent-bug sweep
  around confirmed site._ Added a step to the deep-lane validator
  prompt that instructs it, while confirming the input claim, to also
  sweep the same code block for distinct adjacent bugs and return them
  as additional candidates.

**Between review-2 and review-3 (11:25–11:37 PDT):**

- `ea35753` — _Detection: drop unparseable lens output explicitly; log
  origin-crosscheck skips._ Observability-only ("Item A"): tightens
  the unparseable-lens drop policy, adds a pre-check in front of
  `origin-crosscheck.sh`, and counts dropped lenses + skipped
  helper-calls in the Phase 1 summary.
- `ddef667` — _Fix/post-fix: expand validator + sibling context for
  fix and review agents._ Affects `/matthews-review-fix` Phases 8–9 only.
  **No effect on `/matthews-review` alone.**
- `b5108df` — _Detection: fix A3 grep fallback producing `0\n0` on
  no-match._ Follow-up bug fix on `ea35753`'s counters.

The crucial point: between review-2 and review-3, **no commits
modified any lens or validator prompt**. Item A is pure observability;
Items B/C/D don't fire in a bare `/matthews-review` run. Any
coverage delta between review-2 and review-3 is attributable to
sampling variance, not to reviewer design.

## Coverage summary

| | review-1 | review-2 | review-3 |
|---|---|---|---|
| total findings | 13 | 34 | 25 |
| `confirmed_auto` | 1 | 9 | 9 |
| `confirmed_manual` | 2 | — (no light-lane promotions) | — |
| `below_gate` | 9 | 16 | 12 |
| `pre_existing_report` | 0 | 3 | 1 |
| `disproven` | 1 | 4 | 3 |
| `uncertain` | 0 | 2 | 0 |
| L2-structural candidates (lens-raw) | 4¹ | 21 | 11 |

¹ review-1's L2 emitted 6 candidates, 2 of which were line-range
hallucinations dropped by `line-range-check.sh` before Phase 2.
review-1's `trace.md` records `structural-family: 4` post-drop.

### Coverage against `/ultrareview`'s correctness-bug list

The same five correctness bugs, across runs (review-1 ran against a
snapshot where `/ultrareview` produced its Case-3 report — the 5-bug
list this cross-ref uses):

| Ultrareview bug | File:line | review-1 | review-2 | review-3 |
|---|---|---|---|---|
| bug_001 — try/catch post-commit | `commands.ts:932+` | ✗ | ✓ F001 (72) | ✓ F002 (72) |
| bug_002 — parseDate range-check | `apple-import.ts:169-173` | ✗ | ✓ F002 (82) | **✗ regressed — F005 score 25, below_gate** |
| bug_003 — parseFloat prompts | `commands.ts:786-815` | ✗ | ✗ | **✓ NEW F003 (72)** |
| bug_005 — negative-balance filter | `queries/index.ts:511+` | ✗² | ✗ | ✗ (F008 at same block, score 25, wrong direction) |
| bug_008 — parseCsv EOF unterminated | `apple-import.ts:160-167` | ✗ | ✗ | **✓ NEW F004 (78)** |

² review-1 did catch a *different* bug in the same `getDebts` SQL
block (F001, multi-liability-row double-counting). Orthogonal to the
negative-balance filter path.

Score, in bugs-caught-per-run: **0 → 2 → 3**.

## What we think actually happened

### review-1 → review-2: prompt sharpening appears to have worked

Two concurrent prompt changes (`50001ee` + `ef6f8d5`) and three
coverage deltas we can attribute with moderate confidence:

- **L2 structural yield jumped** from ~4 surviving candidates to 21
  raw / 20 post-dedup. The sharpened L2 prompt explicitly asks for
  catch-block scope audits (which produced bug_001 / F001) and
  validator-function parallel-path diffing (which produced bug_002 /
  F002). Both of those bugs match the prompt's new attention direction.
- **Phase 4 adjacent-bug sweep surfaced F005** (daily-sync
  backfill-gap achievements) — a bug not on the ultrareview list but
  on the same file as a lens-identified candidate. Exactly the shape
  `ef6f8d5` was designed to produce.
- **No corresponding jump in Codex yield on this run.** Codex
  normalized 3 findings in review-2 vs 4 in review-1 despite the
  shared prompt-sharpening commit. F034 (replace-range notes/labels
  loss) was a codex-unique confirmed_auto; the rest was
  corroboration-or-miss. The codex half of `50001ee` didn't visibly
  move this run.

Net: 2 previously-missed ultrareview bugs caught, plus an orthogonal
correctness bug (F005). Strong signal that the L2 half of the prompt
sharpening helped on the bugs it was aimed at; ambiguous signal on
the codex half.

### review-2 → review-3: variance dominated

With no coverage-affecting changes between runs, the deltas are:

- **+2 previously-missed bugs caught** (bug_003, bug_008). bug_008
  was caught by L2-structural alone; bug_003 was co-signed by
  L2-structural and codex. Both lenses were sharpened in the prior
  cycle. A reasonable read: the sharpened prompts have coverage for
  these bugs *probabilistically*, and review-3 sampled into them
  where review-2 didn't.
- **−1 regression** (bug_002 demoted from score-82 confirmed_auto to
  score-25 below_gate). Same lens flagged the same location with
  similar claim wording; Phase 3's cheap scoring scored it
  differently this run.
- **L2 yield roughly halved** (21 → 11) but hit-rate doubled (10% →
  36% of L2 findings reached confirmed_auto). The lens produced less
  noise and kept most of the signal.
- **Codex jumped substantially** (normalized 3 → 7; confirmed_auto
  contributions went from 1 unique to 1 corroboration + 2 uniques —
  F021 notes-labels-loss and F023 remove-account cleanup). With no
  codex prompt change between runs, this is the clearest standalone
  datapoint for between-run model sampling variance in the dataset.

The most honest interpretation is that the sharpened L2 prompt gives
higher probability of catching catch-scope and parallel-path bugs
than the pre-sharpening prompt, but that probability is still well
below 100% on any individual run. Over enough runs you'd expect to
see each individual bug caught most of the time, but not always — and
not always the same subset. That matches what review-2 and review-3
show.

### What didn't move

**bug_005 remains uncaught across all three runs.** The negative-
balance filter in `getDebts`. Review-3's F008 examines the exact same
SQL block and produces a claim going the *opposite* direction (flags
that paying-down-to-zero now surfaces as debt, which is arguably not
a bug). No variant of L2-structural or Phase 4 adjacent-sweep has
surfaced the actual bug — requires reasoning about specific Plaid
`last_statement_balance` semantics and the interaction with
`liabilityCoveredIds`. The prompt sharpening didn't add guidance
that would push toward that specific reasoning path.

## What we learned

1. **Targeted prompt sharpening moved coverage on the bugs it was
   written for.** L2's catch-scope and parallel-path additions
   correspond directly to bug_001 and bug_002 catches in review-2.
   That's not conclusive — variance could have produced the same
   result — but the direction of the delta matches the direction of
   the change.

2. **Probabilistic coverage means per-bug hit rate < 100% per run.**
   Three bugs caught at least once across review-2 and review-3,
   only one caught in both. Operating implication: for high-stakes
   review, one run is a lower bound on findings, not an upper
   bound.

3. **Phase 3 cheap scoring is a variance amplifier.** bug_002 was
   caught by L2 in both runs, scored 82 in review-2 and 25 in
   review-3. The lens attention was stable; the scoring rubric
   wasn't. Worth looking at Phase 3's prompt for bugs that produce
   high dispersion on the same finding shape.

4. **"Sharpen the prompt" is asymptotic.** Getting from 0/5 to 3/5 on
   the ultrareview bug list took two commits. The remaining 2/5 are
   plausibly reachable, but each is narrower and more domain-
   specific: bug_005 needs Plaid-balance-semantics reasoning; bug_002
   (when it regresses) needs more robust Phase 3 scoring. The
   low-hanging prompt-level fruit is largely picked.

5. **Observability-only changes still matter for next-cycle debugging.**
   Item A didn't improve coverage but gave us
   `lens_drops=0; origin_crosscheck_skipped=0` in the Phase 1 summary,
   confirming the clean run wasn't hiding silently-dropped lens
   output. That signal is load-bearing when interpreting the next
   sample — we know review-3's 11-candidate L2 yield is the real
   number, not a truncated one.

## Open questions for the next cycle

- **Phase 3 rubric stability.** Does running review-4 and review-5
  with no pipeline changes produce similar variance on bug_002's
  scoring? Worth N=5 runs with fixed prompt to measure dispersion
  before attributing it to a prompt fix.
- **bug_005's reachability.** Would an L2 prompt addendum specifically
  about SQL filter predicate asymmetry (`COALESCE` + `NULLIF` + `>`
  patterns) push toward the actual bug? Cheap to try; non-cheap to
  tune the prompt in a way that doesn't produce false positives in
  other SQL blocks.
- **The `stdin must parse as a JSON array` helper error** surfaced in
  review-3's trace.md comes from a different helper than
  `origin-crosscheck.sh` (different wording — "stdin", not
  "--candidates"). Worth finding and giving it the same diagnostic
  treatment Item A applied to origin-crosscheck.

## Caveats

- **N=3 on one PR.** Every claim above would look different with
  different sampling.
- **review-1 ran before today's tuning.** Coverage drift between
  review-1 and review-2 is not purely attributable to the two
  commits that landed in that window — model sampling variance
  applies there too, just less visibly because the prompt deltas
  dominate.
- **No re-runs on prompt-identical configs.** We don't have a
  review-2b or review-3b with the same commit and same prompts to
  directly measure prompt-held-fixed variance. Next cycle's first
  action should be N=3–5 no-change runs to establish a baseline.
- **`/matthews-review-fix` wasn't exercised.** Items B/C/D landed in
  `ddef667` but their effect on fix-agent context is not yet
  measured. The next evaluation point for those is an actual fix run
  on review-3's confirmed_auto set.
