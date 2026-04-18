## Phase 1 — Detection

Six internal lenses run in parallel to produce candidate findings. Each lens
returns a list of candidates tagged with routing fields (`impact_type`,
`origin`, `origin_confidence`, `source_family`). The orchestrator merges
all lens outputs into `artifact.findings[]` as one call per candidate to
`artifact-patch.py --add-finding`.

**Dispatch parallelism.** To get actual wall-clock parallelism across lenses,
send every applicable lens's `Agent` tool-use block inside a single
orchestrator turn. Claude Code then runs them concurrently. Collecting the
results happens on the next turn.

### 1.1. Decide which lenses run

Based on the Phase 0 variables:

| Lens | Model | Runs when |
|---|---|---|
| L1 — diff-local scan | `haiku` | always |
| L2 — structural / blast-radius | `opus` | `trivial_mode != true` |
| L3 — CLAUDE.md compliance | `sonnet` | always |
| L4 — comment compliance | `sonnet` | always |
| L5 — UX | `sonnet` | `user_facing == true AND trivial_mode != true` |
| L6 — lightweight security | `sonnet` | `trivial_mode != true` |

Skipped lenses get a one-line note in `trace.md`:
```
Phase 1: L2/L5/L6 skipped (trivial_mode=true)
```

Log them via `log-phase.sh --summary` at step 1.6 as part of the Phase 1
summary.

### 1.2. Build the shared input

Compute the diff once against `$comparison_ref` (not `$base_branch`; see
Phase 0 step 0.2a / §13.10 — when the user chose "compare against
`origin/$base_branch`", `comparison_ref` points at the remote ref while
`base_branch` stays the human name):

```bash
git diff "$comparison_ref..HEAD"
```

All lenses see this full diff. L1, L3, L4, L5, L6 operate primarily on the
diff; L2 additionally reads surrounding files.

For lenses that receive CLAUDE.md content (L3, L4, L5, L6), pass
`claude_md_paths` (the list captured in Phase 0, step 0.7). Each lens
reads only what it needs.

### 1.2a. Ensemble readiness gate (§13.12)

This gate runs before the dispatch turn so missing-CLI prompts surface
ahead of any token spend. Under `ensemble_mode=false` it's a one-line
no-op; under `ensemble_mode=true` it probes CodeRabbit + Codex, may
prompt the user via `AskUserQuestion`, and prepares the scratch
directory + Codex prompt file for the joint dispatch at step 1.3.

**When `ensemble_mode != true`:**

Skip the gate. Record one line in `trace.md`:

```
Phase 1 ensemble readiness gate skipped — --ensemble not set
```

Set `coderabbit_available=false`, `codex_available=false` in your
working context (so downstream fragments can short-circuit uniformly)
and continue to step 1.3.

**When `ensemble_mode == true`:**

Capture `phase_1_5_start_epoch`:

```bash
phase_1_5_start_epoch=$(date +%s)
```

Phase 1.5's elapsed clock starts here — immediately before dispatch —
so `phase_1_5.elapsed_sec` at 02-ensemble-adapter.md step 1.5.7
reflects the wall-clock from dispatch to normalizer return.

Create the scratch directory for CLI outputs (DESIGN §9.3 keeps
`$review_dir` free of transient noise):

```bash
scratch_dir="/tmp/adams-review-$review_id"
mkdir -p "$scratch_dir"
```

Check CodeRabbit availability:

```bash
coderabbit --version 2>&1 && coderabbit auth status 2>&1 | head -3
```

If either returns non-zero, record `coderabbit_available=false` with
the specific failure reason (e.g., "not installed", "not authenticated
— run `coderabbit auth login`"). Otherwise `coderabbit_available=true`.

Check Codex availability:

```bash
CODEX_COMPANION="$(find ~/.claude/plugins -type f -name codex-companion.mjs -path '*codex*' 2>/dev/null | head -1)"
if [[ -z "$CODEX_COMPANION" ]]; then
    codex_available=false
    codex_reason="companion script not found — run /codex:setup"
else
    if node "$CODEX_COMPANION" ready 2>&1 | grep -q ready; then
        codex_available=true
    else
        codex_available=false
        codex_reason="ready check failed — run /codex:setup to diagnose"
    fi
fi
```

**If both CLIs are available**, proceed silently. **If either is
unavailable**, dispatch `AskUserQuestion` **once** with two options:

- **Proceed with what's available** — continue with the available
  reviewer(s) plus the PR scrape. Note skipped reviewers in the final
  report's source breakdown and in `trace.md`.
- **Stop so I can set them up first** — exit the command. Print the
  exact remediation commands (`coderabbit auth login`, `/codex:setup`)
  and let the user fix first.

Stopping here costs zero lens tokens — the whole point of hoisting the
gate ahead of dispatch.

**If `codex_available=true`**, also write the Codex prompt file here so
the dispatch turn at 1.3 is pure launches with no side effects:

```bash
cat > "/tmp/adams-review-codex-$review_id.md" <<PROMPT
Review the code changes in this repository between $comparison_ref and HEAD.
Focus on potential bugs, correctness issues, security concerns, and violations
of project conventions. Return a structured list of findings with file, line
range, and concrete description for each.
PROMPT
```

### 1.3. Dispatch the lenses (one turn, one Agent call per applicable lens)

#### L1 — diff-local scan (Haiku)

Launch one `Agent` tool-use with `model: haiku`, `subagent_type: general-purpose`.
Prompt essence:

> Read ONLY the diff between `$comparison_ref` and HEAD. Do not open other
> files or grep the repo. Flag off-by-one errors, inverted conditions, typos
> in identifiers, dead branches, obvious null-deref patterns, and
> mismatched quotes or parens. **Over-flag — Phase 3 will filter.** Ignore
> style issues; ignore anything a linter would catch.
>
> Return a JSON array of candidates. Each candidate:
> ```
> {
>   "file": "src/path/to/file.ts",
>   "line_range": [start, end],
>   "claim": "one-sentence description of the issue",
>   "evidence_snippet": "the exact code lines implicated",
>   "impact_type": "correctness",
>   "origin": "introduced_by_pr" | "pre_existing" | "unknown",
>   "origin_confidence": "high" | "medium" | "low",
>   "source_family": "diff-family"
> }
> ```
>
> Default `origin: "introduced_by_pr"`, `origin_confidence: "high"` unless
> the implicated code is clearly unchanged by this diff.

#### L2 — structural / blast-radius (Opus; skipped if `trivial_mode`)

Launch one `Agent` tool-use with `model: opus`, `subagent_type: general-purpose`,
with `Read` and `Bash(git:*)` + `Bash(grep:*)` permissions (the sub-agent
inherits the parent command's grants — this already covers it).

Prompt essence:

> For every function, type, field, or API the diff between `$comparison_ref`
> and HEAD changes, **trace into the rest of the repo**:
> - Who calls this? Are callers updated consistently?
> - Who writes to this field? Do all writers share the same contract?
> - Is there a parallel code path (e.g. `foo()` and `fooAsync()`) that
>   should receive a matching change?
> - What invariants does the surrounding code assume? Does the diff
>   preserve them?
>
> Read function bodies, not just signatures. Flag contract changes,
> nullability shifts, return-shape changes, concurrent-write assumption
> violations, and missing matching updates in parallel paths. **This lens
> exists specifically to catch incomplete fixes — be thorough.** Over-flag.
>
> Return a JSON array of candidates with `impact_type: "correctness"`,
> `source_family: "structural-family"`, and the same field shape as L1.

#### L3 — CLAUDE.md compliance (Sonnet)

Launch one `Agent` tool-use with `model: sonnet`.

Prompt essence:

> Read each CLAUDE.md file in this list (absolute paths, root-first):
> `$claude_md_paths`
>
> For every rule in those files, check whether the diff between `$comparison_ref`
> and HEAD violates it. For each violation, cite the exact CLAUDE.md file
> and line number in `evidence_snippet`.
>
> **Tag each violation's `impact_type`:** `correctness` if the rule concerns
> runtime behavior, error handling, invariants, or safety; `policy` if it
> concerns style, conventions, preferences, or formatting.
>
> Skip any violation that's silenced by an explicit ignore comment on the
> relevant code.
>
> Return the same candidate shape as L1 with `source_family: "policy-family"`.

#### L4 — comment compliance (Sonnet)

Launch one `Agent` tool-use with `model: sonnet`.

Prompt essence:

> Read the diff between `$comparison_ref` and HEAD, plus the current content
> of every modified file. Focus on comments and doc strings (JSDoc, TSDoc,
> Python docstrings, Rust doc comments, etc.) adjacent to changed code.
>
> Flag when the diff contradicts a comment's claim — e.g., a docstring says
> "returns non-null" but the change now returns null; a function comment
> says "idempotent" but the change introduces state mutation.
>
> If the contradiction is runtime-impactful, upgrade `impact_type` to
> `correctness`; otherwise `policy`.
>
> Return the same candidate shape as L1 with `source_family: "policy-family"`.

#### L5 — UX (Sonnet; skipped if `trivial_mode` or `user_facing == false`)

Launch one `Agent` tool-use with `model: sonnet`. Inline the UX reference
content into the prompt via a preprocessor include — in the fragment as
consumed, the reference is inlined by the top-level command file via
`` !`cat ~/.claude/commands/_shared/lens-ux-reference.md` `` so the
sub-agent sees the full reference in its prompt.

Prompt essence:

> UX reference:
>
> !`cat ~/.claude/commands/_shared/lens-ux-reference.md`
>
> Read the diff between `$comparison_ref` and HEAD and the CLAUDE.md files in
> `$claude_md_paths` (project-specific UX conventions take precedence over
> the generic reference above).
>
> Focus on behavioral gaps visible from the diff: missing loading / empty /
> error states; inadequate confirmation on destructive actions; silent
> failures; missing keyboard / accessibility affordances; copy that doesn't
> match existing patterns in the codebase.
>
> Return the same candidate shape as L1 with `impact_type: "ux"`,
> `source_family: "ux-family"`.

#### L6 — lightweight security (Sonnet; skipped if `trivial_mode`)

Launch one `Agent` tool-use with `model: sonnet`. Inline the security
reference via preprocessor include (same mechanism as L5).

Prompt essence:

> Security reference:
>
> !`cat ~/.claude/commands/_shared/lens-security-reference.md`
>
> Read the diff between `$comparison_ref` and HEAD. If structural reasoning
> (similar to L2 — walking callers and writers) suggests a security
> implication, flag it even when the immediate code isn't obviously a
> security surface. **Over-flag.**
>
> Return the same candidate shape as L1 with `impact_type: "security"`,
> `source_family: "security-family"`.

#### Ensemble fan-out (same turn, when `ensemble_mode == true`)

Per DESIGN §13.12, the dispatch turn also launches the external
reviewers and PR scrape when `ensemble_mode=true`. These run as
tool-use blocks in the same orchestrator turn as the lens `Agent`
dispatches above — waiting a turn between them serializes what's
meant to be parallel and negates the whole point of §13.12.

Total tool-use blocks in the dispatch turn:

| Condition | Blocks |
|---|---|
| `ensemble_mode=false` | applicable lenses (6 max) |
| `ensemble_mode=true`, both CLIs available, `mode=pr` | lenses + 2 background Bash + 1 foreground Bash |
| `ensemble_mode=true`, both CLIs available, `mode=local` | lenses + 2 background Bash |
| `ensemble_mode=true`, one CLI unavailable | lenses + 1 background Bash + (1 foreground Bash if PR mode) |

The ensemble launch specs live in `02-ensemble-adapter.md`:

- **CodeRabbit** (background Bash) — see `02-ensemble-adapter.md`
  step 1.5.2. Skip if `coderabbit_available=false`. Capture
  `coderabbit_shell_id`.
- **Codex** (background Bash) — see `02-ensemble-adapter.md` step
  1.5.2. Skip if `codex_available=false`. The prompt file was already
  written in step 1.2a; the launch block just invokes `node
  "$CODEX_COMPANION" task …`. Capture `codex_shell_id`.
- **PR comment scrape** (foreground Bash, PR mode only) — see
  `02-ensemble-adapter.md` step 1.5.3. Skipped in local mode. This
  call is synchronous, but it's short (seconds of `gh api`) so staying
  foreground in the dispatch turn doesn't meaningfully delay the
  background launches — it just means the turn returns a hair later.

Under `ensemble_mode=false`, none of these launches happen; the
02-ensemble-adapter fragment's top-level skip note fires when
execution reaches it and execution proceeds straight to Phase 2.

### 1.4. Collect lens candidates into pool

Collection runs per-lens as each sub-agent result returns — but under
§13.12 nothing gets an `id` and nothing is `--add-finding`'d during
collection. Candidates accumulate in an in-context pool
(`internal_candidates`) and are committed at the join step 1.5.

Initialize the pool and capture the phase epoch before the first lens
dispatch (at the top of step 1.3's dispatch turn):

```bash
phase_1_start_epoch=$(date +%s)
internal_candidates='[]'
```

For each sub-agent result, in the order it returns:

1. **Log tokens first** (§24.4 — "cost accounted even for failed agents").
   Parse the sub-agent's `<usage>total_tokens: N</usage>` block. If the
   Agent tool result exposes a structured `usage` field directly, prefer
   that. On parse failure, use `--tokens null` per the §11 fallback.

   ```bash
   ~/.claude/commands/_shared/tools/log-tokens.sh \
     --review-dir "$review_dir" \
     --phase phase_1 --agent-role <lens-name> \
     --agent-id <id-from-Agent-result> \
     --model <model> \
     --tokens <N or null>
   ```

   `<lens-name>` is one of `lens_1_diff_local`, `lens_2_structural`,
   `lens_3_claude_md`, `lens_4_comments`, `lens_5_ux`, `lens_6_security`.
   The paired per-finding `sources[]` entry — used in the jq builder at
   step 1.5 — is the shorter lens tag: `L1-diff-local`, `L2-structural`,
   `L3-claude-md`, `L4-comments`, `L5-ux`, `L6-security` (DESIGN §6).

2. **Light JSON repair** if the output isn't a parseable array — strip code
   fences, extract the JSON block. If still unparseable, retry once with
   prompt addendum: "Your prior response was not valid JSON. Return only
   the JSON array described in the schema." If still unparseable, log to
   `trace.md` and drop that lens's output per §24.1.

2a. **Origin cross-check (§13.11).** Hand the lens's candidate array to
   `origin-crosscheck.sh` so any candidate whose blame range is entirely
   ancestor of `$comparison_ref` gets `origin=pre_existing,
   origin_confidence=high` — which then triggers the §13.1 pre-existing
   override at Phase 3. `introduced_by_pr` candidates that blame confirms
   as PR-modified are respected; lens-supplied `pre_existing` whose blame
   disagrees gets downgraded to medium confidence so the override doesn't
   fire.

   ```bash
   corrected_candidates=$(
     ~/.claude/commands/_shared/tools/origin-crosscheck.sh \
       --comparison-ref "$comparison_ref" \
       --candidates "$lens_candidates_json" \
       2> >(tee -a "$trace_log_path" >&2)
   )
   ```

   Stderr (one `origin_crosscheck: id=... action=...` line per
   candidate) flows directly into `trace.md` via the process
   substitution. On non-zero exit: the helper does NOT abort per-
   candidate blame failures (those surface as `action=skipped`), so a
   non-zero exit means something structural (unknown ref, bad JSON).
   Log the stderr to `trace.md` and fall through using
   `$lens_candidates_json` unchanged — respecting the lens across the
   board is the safe default when cross-check can't run.

3. **Tag with `sources` and append to the pool.** Do NOT call
   `--add-finding` here; do NOT assign an id. The full-finding jq build
   moves to step 1.5 where ids are assigned atomically across the
   combined pool.

   Tag each corrected candidate with `sources: [<lens-tag>]` so the
   join step's helper (`assign-finding-ids.sh`) can sort by source
   priority. The lens-tag is the same short tag used in the token log
   above (`L1-diff-local`, `L2-structural`, etc., per DESIGN §6):

   ```bash
   tagged=$(echo "$corrected_candidates" \
     | jq --arg tag "$lens_source_tag" '[.[] | . + {sources: [$tag]}]')

   internal_candidates=$(jq -nc \
     --argjson accum "$internal_candidates" \
     --argjson new "$tagged" \
     '$accum + $new')
   ```

   The pool lives in your working context, not on disk — no intermediate
   artifact writes. If the orchestrator loses context mid-collection,
   Phase 1 has to re-run from dispatch.

   A common lens failure is `line_range: null` instead of `[N, N]`.
   Default to `[1, 1]` with a one-line `trace.md` note at collection
   time so the join step's jq builder doesn't blow up on a schema-
   invalid pool entry:

   ```bash
   tagged=$(echo "$tagged" \
     | jq '[.[] | .line_range //= [1,1]]')
   ```

### 1.5. Join + assign IDs + add-finding (§13.12)

Wait until every internal lens has returned AND (if `ensemble_mode ==
true`) the ensemble normalizer has emitted its candidate array into
`external_candidates` per `02-ensemble-adapter.md` step 1.5.5. Under
`ensemble_mode=false`, `external_candidates` defaults to `[]`.

**Step 1. Combine the two pools:**

```bash
pooled=$(jq -nc \
  --argjson internal "$internal_candidates" \
  --argjson external "${external_candidates:-[]}" \
  '$internal + $external')
```

**Step 2. Assign monotonic finding ids via the helper:**

```bash
ided=$(printf '%s' "$pooled" \
  | ~/.claude/commands/_shared/tools/assign-finding-ids.sh)
```

`assign-finding-ids.sh` sorts by source priority (L1, L2, L3, L4, L5,
L6, external-pr, codex, coderabbit — stable within source = input
order preserved) and assigns `F001…F0NN`. See the helper's header for
the full priority table.

On non-zero exit (malformed pool JSON), log stderr to `trace.md` and
bail — the whole detection phase must re-run because the pool is
corrupt. This is a structural failure, not a per-candidate drop.

**Step 3. Build full schema-valid findings + single `--add-finding`
sweep.** `artifact-patch.py --add-finding` does NOT default fields —
it validates the payload against the full schema and rejects if
anything required is missing. Partial candidates (from lenses) and
normalizer candidates both need to be fleshed out to schema shape.

For each element in `$ided`, bind it to `$candidate` in the jq call
below and call `--add-finding`. The jq builder matches the pre-§13.12
logic (DESIGN §6 shape) with `.id` already populated from the helper:

```bash
while IFS= read -r candidate; do
    full_finding=$(jq -n \
      --argjson trivial "$trivial_mode" \
      --argjson cand "$candidate" \
      '$cand + {
        source_families: [($cand.source_family // "diff-family")],
        actionability: (if ($cand.impact_type == "correctness" or $cand.impact_type == "security") then "auto_fixable"
                       elif ($cand.impact_type == "architecture") then "report_only"
                       else "manual" end),
        validation_lane: (if $trivial then "light"
                          elif ($cand.impact_type == "correctness" or $cand.impact_type == "security") then "deep"
                          else "light" end),
        current_state: "open",
        disposition: "pending_validation",
        is_actionable: false,
        reason: null,
        confirmed_strength: null,
        score_phase3: null,
        score_phase4: null,
        score_history: [],
        validation_result: null,
        fix_attempts: [],
        introduced_in_sha: null,
        suggested_follow_up: null,
        related_parent_finding_id: null
      } | del(.source_family, .evidence_snippet)')   # strip candidate-only fields — schema additionalProperties:false

    ~/.claude/commands/_shared/tools/artifact-patch.py \
      --path "$artifact_path" --add-finding "$full_finding"
done < <(printf '%s' "$ided" | jq -c '.[]')
```

For trivial-mode runs (`trivial_mode=true`), the jq builder above
forces `validation_lane="light"` for every candidate — Phase 4b
handles the whole pool per §19.6. The `$trivial` argjson binding
drives that branch so the stored lane is honest.

On non-zero exit for any single `--add-finding`, read the error-as-
prompt (it names the offending field and id), adjust your `jq` build,
retry once. On second failure, log the finding id to `trace.md` and
drop it — the rest of the pool still commits. This matches the pre-
§13.12 per-candidate failure policy.

**`pending_validation` is the Phase-1 parking disposition.** Schema
requires `disposition` non-null, so we can't leave it unset.
`is_actionable: false` + `disposition: "pending_validation"` keeps the
§5.2.1 coupling happy. Phase 3's gate either locks a gate-fail finding
into `below_gate` with the "below validation gate (score X)" reason,
or leaves it at `pending_validation` for Phase 4 to overwrite with the
final verdict. Pre-existing overrides set `pre_existing_report` at
Phase 3.1 before any of that runs.

### 1.6. Log Phase 1 summary

After every lens result is aggregated and the join step has committed
the pool to the artifact:

```bash
phase_1_elapsed=$(( $(date +%s) - phase_1_start_epoch ))

# Per-lens candidate count via artifact-read
counts_by_family=$(~/.claude/commands/_shared/tools/artifact-read.sh \
  --path "$artifact_path" \
  --filter '[.findings[] | .source_families[]?] | group_by(.) | map({key:.[0], value:length}) | from_entries')

total_candidates=$(~/.claude/commands/_shared/tools/artifact-read.sh \
  --path "$artifact_path" --filter '.findings | length')

~/.claude/commands/_shared/tools/log-phase.sh \
  --review-dir "$review_dir" --phase 1 --name detection \
  --elapsed "$phase_1_elapsed" \
  --summary "total=$total_candidates; counts_by_family=$counts_by_family; skipped_lenses=<list-if-any>"

~/.claude/commands/_shared/tools/log-phase.sh \
  --review-dir "$review_dir" --phase 1 --record "$(jq -nc \
    --arg name detection \
    --argjson elapsed "$phase_1_elapsed" \
    --argjson total "$total_candidates" \
    '{name:$name, elapsed_sec:$elapsed, counts_by_state:{open:$total}, counts_by_disposition:{pending_validation:$total}, delta:"+\($total) open"}')"
```

Under joint dispatch (§13.12), `phase_1_elapsed` and the Phase 1.5
elapsed logged by `02-ensemble-adapter.md` step 1.5.7 will overlap
because both phases share a dispatch-turn start boundary. That overlap
is the intended observability signal.

### Working-set delta after Phase 1

- `internal_candidates` (orchestrator-context pool) was built during
  1.4 and consumed at 1.5.
- `artifact.findings[]` populated with IDed candidates at 1.5.
- `tokens.jsonl` grew one entry per lens sub-agent.
- `phases.jsonl` grew a Phase 1 record (ts overlaps Phase 1.5's under
  `--ensemble` per §13.12).
- `trace.md` grew a Phase 1 section.
