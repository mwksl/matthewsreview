# Finding state, score gates, and lanes

Normative spec for finding state, score-gate routing, and lane partitioning.
AGENTS.md keeps a TL;DR; this file is the reference. `bin/schema-v1.json` is
the on-disk source of truth for artifact shape — this doc is the
human-readable companion.

## Artifact-level execution metadata

Three optional top-level objects record the resolved execution contract. Their
absence is valid for artifacts created before v1.0:

- `model_plan` — the current lifecycle command's resolved `orchestrator`,
  complete role map (`engine`, `model`, nullable `effort`, `source`), resolved
  `gates`, and preflight `warnings`. Every lifecycle command resolves this
  afresh, so the field reflects the most recent invocation.
- `gates` — `phase3_gate`, the three strictly ascending `phase4_bands`,
  `fix_threshold`, and `walkthrough_threshold`.
- `degraded` — present when review coverage or finalization is incomplete. It
  may contain `lens_dispatch_failures`, `candidate_drop_failures`, and
  `finalization_failures`, each a nonnegative integer.
  All degraded counters are optional for compatibility; at least one present counter must be positive.
  Lens-dispatch failures and candidate drops denote incomplete review coverage;
  finalization failures denote incomplete finalization even when detection and
  validation coverage was otherwise complete.

## Finding state model

Three states, one disposition enum. States transition; dispositions classify.

**States:** `open` | `attempted` | `resolved`. Valid transitions (enforced by `artifact-patch.py`):

```
open → attempted       (Phase 8 ran)
attempted → resolved   (Phase 9 verified)
attempted → open       (Phase 9 classified partial or regression)
```

Any other transition is rejected. Leftover `attempted` on a fresh `:fix` → **hard abort** with deterministic recovery message.

**Disposition enum** (the primary routing key — filters and report selectors read this, not combinations of prose fields):

| disposition | Meaning | `current_state` | `is_actionable` | Set by |
|---|---|---|---|---|
| `below_gate` | `score_phase3 < gates.phase3_gate` and single source family | `open` | `false` | Phase 3 |
| `pending_validation` | Gate-in parking; awaiting Phase 4 | `open` | `false` | Phase 3 |
| `disproven` | `score_phase4 < B1` | `open` | `false` | Phase 4 |
| `uncertain` | `B1 ≤ score_phase4 < B2` | `open` | `false` | Phase 4 |
| `confirmed_mechanical` | `score_phase4 ≥ B2`, `actionability == auto_fixable` | `open` | `true` | Phase 4 |
| `confirmed_manual` | `score_phase4 ≥ B2`, `actionability == manual` | `open` | `false` | Phase 4 |
| `confirmed_report` | `score_phase4 ≥ B2`, `actionability == report_only` | `open` | `false` | Phase 4 |
| `pre_existing_report` | `origin == pre_existing` AND `origin_confidence == high` (override, regardless of score) | `open` | `false` | Phase 3 / re-asserted Phase 4 |
| `partial` | Phase 9 found fix incomplete; retry-eligible | `open` | `true` | Phase 9 |
| `regression` | Phase 9 found new adjacent issue; group reverted; retry-eligible | `open` | `true` | Phase 9 |
| `resolved` | Phase 9 verified | `resolved` | `false` | Phase 9 |

**Invariants** (enforced by writers):

- `is_actionable` is derived: `true` iff `disposition ∈ {confirmed_mechanical, partial, regression}`. Never set in conflict with `disposition`.
- `current_state == resolved` ⇔ `disposition == resolved`.
- `human_confirmation` is absent/null unless `:promote` has run. Present-and-non-null is a Phase 8 bypass of both lane filter and threshold (see Score gates). Promotion never mutates `score_phase4`.

## Score gates (normative)

Each rule sets `disposition`; `is_actionable` follows by derivation.

**Pre-existing override** (highest priority — evaluated before any score rule, re-asserted at end of Phase 4):

```
origin == "pre_existing" AND origin_confidence == "high"
  → disposition: pre_existing_report
  → is_actionable: false
  → regardless of score
```

**Phase 3 validation gate** (applies after the override):

```
score_phase3 < gates.phase3_gate AND single source family   → disposition: below_gate (does not enter Phase 4)
score_phase3 < gates.phase3_gate AND ≥ 2 source families    → advance to Phase 4 (auto-graduation)
score_phase3 >= gates.phase3_gate                           → advance to Phase 4
```

**Phase 4 validation decision** (after Phase 4a deep / 4b light):

```
score_phase4 < B1        → disposition: disproven,  is_actionable: false
score_phase4 B1..B2-1    → disposition: uncertain,  is_actionable: false
score_phase4 >= B2       → disposition depends on actionability set by validator:
                             auto_fixable  → confirmed_mechanical (is_actionable: true)
                             manual        → confirmed_manual (is_actionable: false)
                             report_only   → confirmed_report (is_actionable: false)
                           confirmed_strength: moderate below B3, strong at B3+
```

**Phase 9 outcome** (for findings attempted in a fix run):

```
verified    → disposition: resolved,   current_state: resolved
partial     → disposition: partial,    current_state: open   (retry-eligible)
regression  → disposition: regression, current_state: open   (retry-eligible;
              fix group reverted; fix_attempts[-1].output_sha = null)
```

**Phase 8 fix gate** (governs what `:fix` will touch):

```
current_state == open
  AND disposition ∈ {confirmed_mechanical, partial, regression}
  AND (
    human_confirmation != null                                      // promote bypass
    OR (
      impact_type ∈ {correctness, security}                         // lane filter
      AND score_phase4 >= threshold                                 // default 60
    )
  )
```

`B1`/`B2`/`B3` are the resolved `gates.phase4_bands` values. "Gate" means three different things: the Phase 3 scoring gate decides Phase-4 entry; the Phase 4 bands map `score_phase4` to disposition/strength; the Phase 8 fix gate is the composite gate above. Defaults are `phase3_gate=45`, `phase4_bands=[45,60,75]`, and `fix_threshold=60`. `human_confirmation != null` bypasses both lane filter and threshold — promotion is additive metadata, not a state mutation. `below_gate` is a *disposition name*, not a threshold; `:walkthrough` at default Qualifying scope excludes it (run `:walkthrough 0` with the Full tier to audit Phase-3 demotions).

## Lanes

- **Deep lane** (correctness, security): per-candidate Phase 4a validation with blast-radius tracing + comprehensive fix proposal; passes through Phase 5 cross-cutting. Phase 8 processes `confirmed_mechanical` here by default. The resolved `deep_validate`/`cross_cutting` roles choose the engines and models.
- **Light lane** (ux, policy, architecture): chunked Phase 4b confirmation, report-biased (validators may emit `auto_fixable` for very mechanical rules, but `manual` and `report_only` are the common outcomes). Phase 8 excludes light-lane `confirmed_mechanical` unless `human_confirmation != null` (set by `:promote` or `:walkthrough`). `:walkthrough` exists to close this asymmetric default, restricted to its own score floor (default 60, independent of fix-gate threshold). The resolved `light_validate` role chooses the engine and model.
