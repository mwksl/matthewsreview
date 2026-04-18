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

Log them via `log-phase.sh --summary` at step 1.4 as part of the Phase 1
summary.

### 1.2. Build the shared input

Compute the diff once:

```bash
git diff "$base_branch..HEAD"
```

All lenses see this full diff. L1, L3, L4, L5, L6 operate primarily on the
diff; L2 additionally reads surrounding files.

For lenses that receive CLAUDE.md content (L3, L4, L5, L6), pass
`claude_md_paths` (the list captured in Phase 0, step 0.7). Each lens
reads only what it needs.

### 1.3. Dispatch the lenses (one turn, one Agent call per applicable lens)

#### L1 — diff-local scan (Haiku)

Launch one `Agent` tool-use with `model: haiku`, `subagent_type: general-purpose`.
Prompt essence:

> Read ONLY the diff between `$base_branch` and HEAD. Do not open other
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

> For every function, type, field, or API the diff between `$base_branch`
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
> For every rule in those files, check whether the diff between `$base_branch`
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

> Read the diff between `$base_branch` and HEAD, plus the current content
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
> Read the diff between `$base_branch` and HEAD and the CLAUDE.md files in
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
> Read the diff between `$base_branch` and HEAD. If structural reasoning
> (similar to L2 — walking callers and writers) suggests a security
> implication, flag it even when the immediate code isn't obviously a
> security surface. **Over-flag.**
>
> Return the same candidate shape as L1 with `impact_type: "security"`,
> `source_family: "security-family"`.

### 1.4. Collect lens results + log tokens

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

2. **Light JSON repair** if the output isn't a parseable array — strip code
   fences, extract the JSON block. If still unparseable, retry once with
   prompt addendum: "Your prior response was not valid JSON. Return only
   the JSON array described in the schema." If still unparseable, log to
   `trace.md` and drop that lens's output per §24.1.

3. **Append each candidate to the artifact.** Auto-assign finding ids in
   sequence: the first candidate across all lenses gets `F001`, the second
   `F002`, etc. Fill fields the lens didn't provide with schema defaults:

   | Field | Default |
   |---|---|
   | `id` | `F001`, `F002`, ... (monotonic) |
   | `sources` | `["detection"]` (runs under the "internal detection" provider) |
   | `source_families` | `[<the lens's source_family>]` (array form — Phase 2 may union more) |
   | `actionability` | `"auto_fixable"` for correctness/security; `"manual"` for ux/policy; `"report_only"` if L3/L4 flagged the issue as pre-existing (set by the lens if applicable) |
   | `validation_lane` | `"deep"` for `correctness` + `security` outside trivial_mode; `"light"` otherwise |
   | `current_state` | `"open"` |
   | `disposition` | leave unset for now — Phase 3/4 will set |
   | `is_actionable` | `false` initially (pre-validation) |
   | `reason` | `null` |
   | `confirmed_strength` | `null` |
   | `score_phase3` | `null` (set in Phase 3) |
   | `score_phase4` | `null` |
   | `score_history` | `[]` |
   | `validation_result` | `null` |
   | `fix_attempts` | `[]` |
   | `introduced_in_sha` | `null` |
   | `suggested_follow_up` | `null` |
   | `related_parent_finding_id` | `null` |

   But wait — Phase 3 needs a value in `disposition` because §6 requires
   it (enum). Before Phase 3 runs, `disposition` is unset. Handle this by
   having `artifact-patch.py --add-finding` default `disposition` to
   `"below_gate"` + `is_actionable: false` when the lens doesn't provide
   one. Phase 3's gate then re-scores and may promote above the gate. This
   matches §13.1's "below gate" default for unscored candidates.

   (Stage 1's `_common.py` schema validator will catch any field missing —
   if `--add-finding` rejects the candidate, the stderr will name the
   missing field. Use it to debug.)

   Call per candidate:

   ```bash
   ~/.claude/commands/_shared/tools/artifact-patch.py \
     --path "$artifact_path" --add-finding "$candidate_json"
   ```

   On non-zero exit, read the error-as-prompt, adjust, retry once.

### 1.5. Log Phase 1 summary

After every lens result is aggregated:

```bash
phase_1_elapsed=$(( $(date +%s) - phase_1_start_epoch ))

# Per-lens candidate count via artifact-read
counts_by_lens=$(~/.claude/commands/_shared/tools/artifact-read.sh \
  --path "$artifact_path" \
  --filter '[.findings[] | .source_families[]?] | group_by(.) | map({key:.[0], value:length}) | from_entries')

total_candidates=$(~/.claude/commands/_shared/tools/artifact-read.sh \
  --path "$artifact_path" --filter '.findings | length')

~/.claude/commands/_shared/tools/log-phase.sh \
  --review-dir "$review_dir" --phase 1 --name detection \
  --elapsed "$phase_1_elapsed" \
  --summary "total=$total_candidates; counts_by_family=$counts_by_lens; skipped_lenses=<list-if-any>"

~/.claude/commands/_shared/tools/log-phase.sh \
  --review-dir "$review_dir" --phase 1 --record "$(jq -nc \
    --arg name detection \
    --argjson elapsed "$phase_1_elapsed" \
    --argjson total "$total_candidates" \
    '{name:$name, elapsed_sec:$elapsed, counts_by_state:{open:$total}, counts_by_disposition:{unassigned:$total}, delta:"+\($total) open"}')"
```

Capture `phase_1_start_epoch` via `phase_1_start_epoch=$(date +%s)` immediately
before the first Agent dispatch.

### Working-set delta after Phase 1

- `artifact.findings[]` populated with candidates.
- `tokens.jsonl` grew one entry per lens sub-agent.
- `phases.jsonl` grew a Phase 1 record.
- `trace.md` grew a Phase 1 section.
