---
allowed-tools: Bash(/Users/adammiller/.claude/commands/_shared/tools/artifact-read.sh:*), Bash(/Users/adammiller/.claude/commands/_shared/tools/artifact-patch.py:*), Bash(/Users/adammiller/.claude/commands/_shared/tools/artifact-validate.sh:*), Bash(/Users/adammiller/.claude/commands/_shared/tools/artifact-render.py:*), Bash(/Users/adammiller/.claude/commands/_shared/tools/artifact-publish.sh:*), Bash(/Users/adammiller/.claude/commands/_shared/tools/repo-slug.sh:*), Bash(git:*), Bash(gh:*), Bash(jq:*), Bash(date:*), Bash(cat:*), Bash(printf:*), Bash(mkdir:*), Bash(mv:*), Bash(rm:*), Bash(tr:*), Read, AskUserQuestion
argument-hint: "<finding_id> [--reason \"...\"] [--fix-hint \"...\"] [--force]"
description: Promote a finding to auto-fixable via human override. Patches artifact, re-renders, re-publishes to PR.
disable-model-invocation: false
---

Promote a single finding from the most recent `/adams-review` on this
branch to `disposition=confirmed_auto`, recording full provenance in
`human_confirmation` so `/adams-review-fix` will pick it up on its next
run. See DESIGN §27 for the contract and §5.2.1 for how the Phase 8
eligibility bypass works.

## Arguments

- `<finding_id>` (required, positional) — matches `^F[0-9]+$`. The id
  shown in the artifact's PR comment or `artifact.md`.
- `--reason "..."` (optional) — free-form justification recorded in
  `human_confirmation.reason`. Audit-focused ("why I promoted"). If
  omitted, you'll be prompted.
- `--fix-hint "..."` (optional) — free-form steering instruction
  recorded in `human_confirmation.fix_hint` and surfaced to the
  Phase 8 fix-group agent. Instruction-focused ("how to fix"). Use
  this when the claim is ambiguous about which side of a code/text
  mismatch to change (e.g. "update the docstring to match the code;
  do not modify the code"). Auto-prompted when omitted on a
  light-lane finding (one whose `validation_result` is null) so the
  fix agent isn't left guessing. Deep-lane findings can still pass
  it explicitly to override the validator's `fix_proposal.approach`.
- `--force` (optional) — required when promoting a finding currently
  at `disposition=disproven` (validator found positive evidence it's
  wrong). Without `--force`, disproven findings reject promotion with
  a user-visible message pointing to the validator's conclusion.

## What it does

1. Parses args.
2. Locates the artifact via `latest.txt` under
   `~/.adams-reviews/<slug>/<branch>/`.
3. Reads the target finding. Enforces preconditions:
   - `confirmed_auto` already set → no-op (exits 0 with a note).
   - `resolved` → rejects (the fix already ran).
   - `disproven` → requires `--force`.
   - Anything else → proceeds.
4. Patches the finding atomically via `artifact-patch.py`:
   `disposition=confirmed_auto`, `actionability=auto_fixable`,
   `human_confirmation={reviewer, reason, ts, promoted_from:{...}, fix_hint?}`.
   `fix_hint` is included only when provided (via flag or prompt); absent
   otherwise so legacy-style `human_confirmation` objects remain schema-valid.
5. Re-renders `artifact.md`.
6. Re-publishes to the PR (PR mode) or no-ops (local mode) — the same
   `gh api PATCH` flow `/adams-review-fix` uses at Phase 9e.
7. Appends a `## promote (<ts>)` block to `trace.md`.
8. Prints a summary showing what changed.

Does NOT run `/adams-review-fix` for you. Run it yourself when you're
ready to apply promoted findings.

## Execution

Work through the steps below in order. Capture each named variable
into your working context. Mark each task `in_progress` when you start
and `completed` when done. Build a TaskList that mirrors these step
headings.

### 1. Parse arguments

Parse `$ARGUMENTS` (whitespace-split, respecting `"..."` quoted values
for `--reason` and `--fix-hint`):

- First token matching `^F[0-9]+$` → `finding_id`.
- `--reason "..."` → `reason` (strip surrounding quotes).
- `--fix-hint "..."` → `fix_hint` (strip surrounding quotes). Default:
  empty string (treated as "absent" throughout — the jq at step 5
  omits the key entirely when empty).
- `--force` → `force=true` (else `false`).
- Any other token → stop and ask the user to clarify.

If no `finding_id` was provided, error-as-prompt:

> ERROR: missing finding_id.
> Valid input: /adams-review-promote F037 [--reason "..."] [--fix-hint "..."] [--force]
> Action: pass a finding id (matching `^F[0-9]+$`) as the first arg.

If `--reason` was not provided, dispatch `AskUserQuestion` once with
three options:
- "Validator was too conservative — the issue is real."
- "I've verified this manually and want it auto-fixed."
- "Other (I'll supply the reason)."

For the "Other" branch, ask for the free-form reason. For the two
canned options, use the option text as `reason`. Capture the final
`reason` string (non-empty).


### 2. Locate the artifact

```bash
reviews_root="${ADAMS_REVIEW_REVIEWS_ROOT:-$HOME/.adams-reviews}"
head_branch=$(git rev-parse --abbrev-ref HEAD)
repo_root=$(git rev-parse --show-toplevel)
repo_slug=$(~/.claude/commands/_shared/tools/repo-slug.sh --repo-root "$repo_root")
latest_path="$reviews_root/$repo_slug/$head_branch/latest.txt"
```

If `latest.txt` is missing or empty, error-as-prompt:

> ERROR: no review found for branch `$head_branch` under
> `$reviews_root/$repo_slug/`.
> Action: run /adams-review against this branch first.

Otherwise:

```bash
review_id=$(tr -d '[:space:]' < "$latest_path")
review_dir="$reviews_root/$repo_slug/$head_branch/$review_id"
artifact_path="$review_dir/artifact.json"
trace_log_path="$review_dir/trace.md"
```

Capture paths. Schema-validate as a safety rail:

```bash
~/.claude/commands/_shared/tools/artifact-validate.sh --path "$artifact_path"
```

On non-zero: surface the validator stderr and abort — a broken
artifact means something upstream is wrong; promote is not the right
tool to diagnose it.

### 3. Read the target finding

```bash
finding_json=$(~/.claude/commands/_shared/tools/artifact-read.sh \
    --path "$artifact_path" \
    --filter ".findings[] | select(.id == \"$finding_id\")")
```

If empty, error-as-prompt with the list of existing ids. Use
`artifact-read.sh --summary` to pull the id list for the suggestion:

```bash
existing_ids=$(~/.claude/commands/_shared/tools/artifact-read.sh \
    --path "$artifact_path" \
    --filter '[.findings[].id] | join(", ")')
```

Emit `Valid values: $existing_ids` and `Did you mean '...'?` with the
closest match if one is obvious. Abort.

Extract the state variables:

```bash
curr_disp=$(jq -r '.disposition' <<<"$finding_json")
curr_action=$(jq -r '.actionability' <<<"$finding_json")
curr_score=$(jq -r '.score_phase4 // "null"' <<<"$finding_json")
curr_hc=$(jq -c '.human_confirmation // null' <<<"$finding_json")
```

`curr_score` is the literal string `"null"` when the finding is
unscored; pass it through that way (the JSON encoder at step 4 handles
both the integer and null cases).

### 4. Check preconditions

| `curr_disp` | Action |
|---|---|
| `confirmed_auto` and `curr_hc != null` | Exit 0 with: "F$N already promoted by @$reviewer on $ts; no-op." |
| `confirmed_auto` and `curr_hc == null` | Exit 0 with: "F$N already confirmed_auto by validator (score=$curr_score); no-op." |
| `resolved` | Exit 1: "F$N is resolved (fix already ran); cannot promote." |
| `disproven` and `force == false` | Exit 1: "F$N was disproven by Phase 4 (score=$curr_score). Validator found positive evidence this isn't a real issue. Re-run with --force to override." |
| `disproven` and `force == true` | Proceed with a warning line in trace.md: `disproven→confirmed_auto via --force`. |
| `uncertain`, `below_gate`, `pre_existing_report`, `confirmed_manual`, `confirmed_report`, `pending_validation`, `partial`, `regression` | Proceed. |

For each exit-1 case, print a clear user message AND emit a one-line
`## promote (<ts>) — rejected` block to `trace.md` so rejections are
auditable.

### 4.5. Auto-prompt for `--fix-hint` when needed

Decide whether to prompt for `fix_hint` now that preconditions have
passed. The logic keys off `$fix_hint` (possibly empty, from step 1)
and the finding's `validation_result`:

- `$fix_hint` is non-empty → skip the prompt; the user already
  supplied a hint via the flag.
- `$fix_hint` is empty AND `finding.validation_result` is populated
  (the validator already supplied `fix_proposal.approach`) → skip
  the prompt. The flag stays opt-in; users who want to override the
  validator's approach can pass `--fix-hint` on the command line.
- `$fix_hint` is empty AND `finding.validation_result` is `null` (no
  validator fix_proposal exists — common for light-lane findings and
  for deep-lane findings that Phase 4 marked `uncertain` or
  `disproven`) → dispatch one `AskUserQuestion` whose option set
  depends on the claim text.

**Heuristic for the option set.** Lowercase the `claim` and scan for
any of these substrings: `docstring`, `doc comment`, `jsdoc`, `tsdoc`,
`comment`, `documentation`, `description`, `disagrees`, `mismatch`,
`out of date`, `outdated`, `stale`. If any match, the claim is
probably a doc/comment-vs-code mismatch; offer the canned options:

- "Update the text/docstring to match the code"
- "Update the code to match the text/docstring"
- "Other (I'll provide the hint)"
- "Skip — no steering hint"

If none match, skip the canned options and offer only:

- "Provide a hint (free-form)"
- "Skip — no steering hint"

For "Other" and "Provide a hint (free-form)", dispatch a follow-up
`AskUserQuestion` asking for the free-form hint string. For the two
canned options, use the option text verbatim as `fix_hint`. For
"Skip", leave `fix_hint` empty. Capture the final `fix_hint` string
(may be empty — empty means "no hint").

### 5. Build the human_confirmation object

```bash
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

reviewer=$(git config user.email 2>/dev/null)
[[ -z "$reviewer" ]] && reviewer=$(git config user.name 2>/dev/null)
[[ -z "$reviewer" ]] && reviewer="unknown"

hc_tmp=$(mktemp -t adams-promote-hc.XXXXXX)
jq -n \
    --arg reviewer "$reviewer" \
    --arg reason "$reason" \
    --arg fix_hint "${fix_hint:-}" \
    --arg ts "$ts" \
    --arg prior_disp "$curr_disp" \
    --arg prior_action "$curr_action" \
    --argjson prior_score "$curr_score" \
    '{
      reviewer: $reviewer,
      reason: $reason,
      ts: $ts,
      promoted_from: {
        disposition: $prior_disp,
        actionability: $prior_action,
        score_phase4: $prior_score
      }
    }
    + (if $fix_hint != "" then {fix_hint: $fix_hint} else {} end)' > "$hc_tmp"
```

`$curr_score` was extracted as either a JSON integer string (e.g.,
`"45"`) or literal `"null"`; `--argjson` parses either correctly.
`fix_hint` is conditionally merged: omitted entirely (not literal
`null`) when empty, so pre-promote artifacts and promotions-without-
steering keep the legacy object shape.

### 6. Atomic patch

One `artifact-patch.py` call mutates all four fields in a single atomic
write. The helper enforces `is_actionable` coupling automatically:

```bash
~/.claude/commands/_shared/tools/artifact-patch.py \
    --path "$artifact_path" \
    --finding-id "$finding_id" \
    --set disposition=confirmed_auto \
    --set actionability=auto_fixable \
    --set-json "human_confirmation=@$hc_tmp"
rm -f "$hc_tmp"
```

On non-zero exit: surface the helper's error-as-prompt verbatim (it
already follows §8.6 convention) and abort WITHOUT re-rendering —
a failed patch means the artifact is unchanged, so the rendered md is
already correct.

### 7. Re-render `artifact.md`

```bash
~/.claude/commands/_shared/tools/artifact-render.py \
    --input "$artifact_path" \
    --output "$review_dir/artifact.md"
```

On non-zero: log stderr to `trace.md` with tag `promote_render_failed`,
continue to step 8 (the artifact patch stands; the user can manually
re-render).

### 8. Re-publish to the PR (PR mode only)

Read `mode`, `pr_number`, `comment_id` from the artifact:

```bash
mode=$(jq -r '.mode' "$artifact_path")
pr_number=$(jq -r '.pr_number // empty' "$artifact_path")
comment_id=$(jq -r '.comment_id // empty' "$artifact_path")
```

If `mode == "pr"` AND `pr_number` is non-empty:

```bash
publish_args=(
    --mode pr
    --review-id "$review_id"
    --pr "$pr_number"
    --repo-slug "$repo_slug"
    --branch "$head_branch"
    --review-dir "$review_dir"
)
[[ -n "$comment_id" ]] && publish_args+=(--comment-id "$comment_id")

~/.claude/commands/_shared/tools/artifact-publish.sh "${publish_args[@]}"
```

If `mode == "local"`: call with `--mode local --review-id "$review_id"
--review-dir "$review_dir"` (no-op that appends a trace line).

On non-zero exit: log stderr to `trace.md` with tag
`promote_publish_failed`. Surface to user at step 10 (artifact state
persists; user can manually re-publish with the helper).

### 9. Append trace entry

```bash
{
    printf '## promote (%s)\n' "$ts"
    printf 'finding=%s reviewer=%s force=%s\n' "$finding_id" "$reviewer" "${force:-false}"
    printf 'promoted_from: disposition=%s actionability=%s score_phase4=%s\n' \
        "$curr_disp" "$curr_action" "$curr_score"
    printf 'reason: %s\n' "$reason"
    [[ -n "${fix_hint:-}" ]] && printf 'fix_hint: %s\n' "$fix_hint"
    printf '\n'
} >> "$trace_log_path"
```

### 10. User-visible summary

Print a clear summary block to chat (plain text, not a tool call):

```
Promoted $finding_id:
  disposition:    $curr_disp → confirmed_auto
  actionability:  $curr_action → auto_fixable
  score_phase4:   $curr_score (preserved)
  reviewer:       $reviewer
  reason:         $reason

Next: run /adams-review-fix to apply this and any other
confirmed_auto/partial/regression findings.
```

When `fix_hint` is non-empty, append one additional line to the block
BEFORE the blank line and `Next:` footer:

```
  fix_hint:       $fix_hint
```

Omit the line entirely when `fix_hint` is empty — keeps the summary
tidy for promotions that didn't need steering.

If the publish step failed, append:

```
Note: PR comment republish FAILED (see trace.md tag
promote_publish_failed). The artifact patch stands; to republish run:
  artifact-publish.sh --mode pr --review-id $review_id --pr $pr_number \
      --repo-slug $repo_slug --branch $head_branch --review-dir $review_dir
```

## What this command does NOT do

- **No fix-run.** Promote is metadata-only. You must run
  `/adams-review-fix` to apply the promoted finding.
- **No batch promotion.** One finding per invocation. Loop from the
  shell if you need multiple:
  `for id in F003 F037 F039; do /adams-review-promote $id --reason "..."; done`
- **No demotion / undo.** There is no `/adams-review-demote`. If you
  change your mind BEFORE running `/adams-review-fix`, manually patch
  the artifact:
  `artifact-patch.py --path <artifact> --finding-id F037 --set-json human_confirmation=null --set disposition=<prior> --set actionability=<prior>`
- **No persistence across fresh `/adams-review` runs.** A new review
  overwrites the artifact; promotions are lost. Re-promote if needed.
  (Future work: `overrides.json` sidecar keyed by claim fingerprint.)
- **No argument for changing `score_phase4`.** The validator's score is
  preserved for audit. Phase 8 eligibility bypasses the score threshold
  for promoted findings via the `human_confirmation != null` gate.
