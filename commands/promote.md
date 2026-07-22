---
allowed-tools: Bash(artifact-read.sh:*), Bash(review-root.sh:*), Bash(doctor.sh:*), Bash(artifact-patch.py:*), Bash(artifact-validate.sh:*), Bash(artifact-render.py:*), Bash(artifact-publish.sh:*), Bash(tally-subagent-tokens.sh:*), Bash(orchestrator-tokens.sh:*), Bash(repo-slug.sh:*), Bash(git:*), Bash(gh:*), Bash(jq:*), Bash(date:*), Bash(cat:*), Bash(printf:*), Bash(mkdir:*), Bash(mv:*), Bash(rm:*), Bash(tr:*), Bash(mktemp:*), Read, AskUserQuestion
argument-hint: "<finding_id> [--reason \"...\"] [--fix-hint \"...\"] [--force] [--defer-publish]"
description: Promote a finding to auto-fixable via human override. Patches artifact, re-renders, re-publishes to PR.
disable-model-invocation: false
---

Promote a single finding from the most recent `/matthewsreview:review` on this
branch to `disposition=confirmed_mechanical`, recording full provenance in
`human_confirmation` so `/matthewsreview:fix` will pick it up on its next
run.

**Read `fragments/_prelude-shared.md` before proceeding — it lists
rules that apply to every step below (sub-agent return handling,
helper-script error-as-prompt).**

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
- `--defer-publish` (optional) — patch and trace now, but defer token
  tallies, render, and publish so a caller can batch multiple promotions.
  `/matthewsreview:walkthrough` uses this internally. After all deferred
  promotes land, the caller MUST run exactly one tally pair — first
  `tally-subagent-tokens.sh`, then `orchestrator-tokens.sh` — immediately
  before its single final `artifact-render.py` call, and publish afterward.
  Each tally failure is nonfatal and must be logged before continuing to
  render.

Does NOT run `/matthewsreview:fix` for you. Run it yourself when you're
ready to apply promoted findings.

## Execution

Work through the steps below in order. Capture each named variable
into your working context. Mark each task `in_progress` when you start
and `completed` when done. Build a TaskList that mirrors these step
headings.

### 1. Parse arguments

Tokenize `$ARGUMENTS` left-to-right before asking for a reason, locating an
artifact, or doing any config/tree work or mutation. Respect `"..."` quoted
values and retain whether each token was quoted until value validation is
complete:

- First token matching `^F[0-9]+$` → `finding_id`.
- `--reason "..."` → `reason` (strip surrounding quotes).
- `--fix-hint "..."` → `fix_hint` (strip surrounding quotes). Default:
  empty string (treated as "absent" throughout — the jq at step 5
  omits the key entirely when empty).
- For either value-taking flag, an unquoted next token beginning with `--`
  cannot satisfy the value; treat the flag as missing its value and continue
  classifying that token as an option. A quoted value may begin with `--`.
- `--force` → `force=true` (else `false`).
- `--defer-publish` → `defer_publish=true` (else `false`).
- A second finding id, a repeated flag, a missing/empty flag value (including
  an unquoted option-looking value), an unknown option, or any unconsumed token
  is a usage error.

Complete the entire parse before continuing. On any usage error, print the
valid invocation and exit with usage code 64; do not look up or mutate an
artifact.

If no `finding_id` was provided, error-as-prompt:

> ERROR: missing finding_id.
> Valid input: /matthewsreview:promote F037 [--reason "..."] [--fix-hint "..."] [--force]
> Action: pass a finding id (matching `^F[0-9]+$`) as the first arg.

If `--reason` was not provided, ASK once with
three options:
- "Validator was too conservative — the issue is real."
- "I've verified this manually and want it auto-fixed."
- "Other (I'll supply the reason)."

For the "Other" branch, ask for the free-form reason. For the two
canned options, use the option text as `reason`. Capture the final
`reason` string (non-empty).


### 2. Locate the artifact

```bash
reviews_root=$(review-root.sh)
head_branch=$(git rev-parse --abbrev-ref HEAD)
repo_root=$(git rev-parse --show-toplevel)
repo_slug=$(repo-slug.sh --repo-root "$repo_root")
latest_path="$reviews_root/$repo_slug/$head_branch/latest.txt"
```

If `latest.txt` is missing or empty, error-as-prompt:

> ERROR: no review found for branch `$head_branch` under
> `$reviews_root/$repo_slug/`.
> Action: run /matthewsreview:review against this branch first.

Otherwise:

```bash
review_id=$(tr -d '[:space:]' < "$latest_path")
review_dir="$reviews_root/$repo_slug/$head_branch/$review_id"
artifact_path="$review_dir/artifact.json"
trace_log_path="$review_dir/trace.md"
```

### 2b. Preserve review-time configuration provenance

`:promote` changes finding metadata only. Do not resolve or overwrite
`model_plan` or `gates`: those fields record the configuration that produced
the existing scores and dispositions. The subsequent `:fix` command resolves
and stores its own current plan before dispatching any agents.

Capture paths. Schema-validate as a safety rail:

```bash
artifact-validate.sh --path "$artifact_path"
```

On non-zero: surface the validator stderr and abort — a broken
artifact means something upstream is wrong; promote is not the right
tool to diagnose it.

### 3–6, 9. Shared promote core

Read `fragments/promote-core.md` and execute steps 3, 4, 4.5, 5, 6, 9 inline.

### 6.5. Refresh cumulative token tallies

Reaching this step means the shared promote core patched the artifact
successfully. When `defer_publish == false`, re-tally immediately before
render so the report includes cumulative spend:

```bash
tally-subagent-tokens.sh \
    --tokens-log "$review_dir/tokens.jsonl" \
    --artifact   "$artifact_path" \
    2>>"$trace_log_path" || printf 'promote_tally_failed\n' >> "$trace_log_path"

review_started_at=$(jq -r '.review_started_at // empty' "$artifact_path")

orchestrator-tokens.sh \
    --artifact "$artifact_path" \
    --since    "$review_started_at" \
    2>>"$trace_log_path" || printf 'promote_orchestrator_tally_failed\n' >> "$trace_log_path"
```

Run the sub-agent tally first and the orchestrator tally second. Either
failure is nonfatal observability loss: log it and continue to render.

When `defer_publish == true`, do not run either helper here. The caller
inherits the explicit batch contract from the argument section: after all
deferred patches, run exactly one pair in the same order immediately before
the one final render. `/matthewsreview:walkthrough` §6.1 is that pair.

### 7. Re-render `artifact.md`

Skip this step entirely when `defer_publish == true` — jump to step
8. The caller runs the required tally pair once after all deferred
promotes, then calls `artifact-render.py` exactly once.

```bash
artifact-render.py \
    --input "$artifact_path" \
    --output "$review_dir/artifact.md"
```

On non-zero: log stderr to `trace.md` with tag `promote_render_failed`,
continue to step 8 (the artifact patch stands; the user can manually
re-render).

### 8. Re-publish to the PR (PR mode only)

Skip this step entirely when `defer_publish == true` — jump to step
10. The caller is expected to run `artifact-publish.sh` once after
all deferred promotes have landed.

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

artifact-publish.sh "${publish_args[@]}"
```

If `mode == "local"`: call with `--mode local --review-id "$review_id"
--review-dir "$review_dir"` (no-op that appends a trace line).

On non-zero exit: log stderr to `trace.md` with tag
`promote_publish_failed`. Surface to user at step 10 (artifact state
persists; user can manually re-publish with the helper).

### 10. User-visible summary

When `defer_publish == true`, print only a terse one-liner so the
caller's own summary (e.g. `/matthewsreview:walkthrough`'s decisions
log) isn't drowned out:

```
Promoted $finding_id (deferred — artifact patched; tallies/render/publish delegated to caller).
```

And skip the rest of this step.

Otherwise, print a clear summary block to chat (plain text, not a
tool call):

```
Promoted $finding_id:
  disposition:    $curr_disp → confirmed_mechanical
  actionability:  $curr_action → auto_fixable
  score_phase4:   $curr_score (preserved)
  reviewer:       $reviewer
  reason:         $reason

Next: run /matthewsreview:fix to apply this and any other
confirmed_mechanical/partial/regression findings.
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

- **No batch promotion.** One finding per invocation. Loop from the
  shell if you need multiple:
  `for id in F003 F037 F039; do /matthewsreview:promote $id --reason "..."; done`
- **No demotion / undo.** There is no `/matthewsreview:demote`. If you
  change your mind BEFORE running `/matthewsreview:fix`, manually patch
  the artifact:
  `artifact-patch.py --path <artifact> --finding-id F037 --set-json human_confirmation=null --set disposition=<prior> --set actionability=<prior>`
- **No persistence across fresh `/matthewsreview:review` runs.** A new review
  overwrites the artifact; promotions are lost. Re-promote if needed.
- **No argument for changing `score_phase4`.** The validator's score is
  preserved for audit. Phase 8 eligibility bypasses the score threshold
  for promoted findings via the `human_confirmation != null` gate.
