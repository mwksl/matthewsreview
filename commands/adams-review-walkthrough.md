---
allowed-tools: Bash(/Users/adammiller/.claude/commands/_shared/tools/artifact-read.sh:*), Bash(/Users/adammiller/.claude/commands/_shared/tools/artifact-patch.py:*), Bash(/Users/adammiller/.claude/commands/_shared/tools/artifact-validate.sh:*), Bash(/Users/adammiller/.claude/commands/_shared/tools/artifact-render.py:*), Bash(/Users/adammiller/.claude/commands/_shared/tools/artifact-publish.sh:*), Bash(/Users/adammiller/.claude/commands/_shared/tools/repo-slug.sh:*), Bash(git:*), Bash(gh:*), Bash(jq:*), Bash(date:*), Bash(cat:*), Bash(printf:*), Bash(mkdir:*), Bash(mv:*), Bash(rm:*), Bash(tr:*), Agent, Read, AskUserQuestion
argument-hint: "[threshold]"
description: Walk interactively through findings /adams-review-fix would skip. Per-finding briefing + options + recommendation, then batch re-render/re-publish and post a decisions-log PR comment.
disable-model-invocation: false
---

Walk the reviewer through every finding in the latest `/adams-review`
artifact that `/adams-review-fix [threshold]` would **skip** at the
chosen threshold: deep-manual, light-manual, light-report, light-auto
that fails the impact_type lane filter, and any `confirmed_auto`
below the score threshold. For each finding, dispatch a Sonnet
briefing agent (claim → options → recommendation), ask the reviewer
to decide, and record a promote (via the shared `promote-core.md`
fragment with `--defer-publish` semantics) or a skip. At the end,
render + publish the updated review once, then POST a separate
decisions-log comment to the PR for audit.

See DESIGN §28 for the full contract and `plans/walkthrough-mode.md`
for the design rationale.

## Arguments

- `[threshold]` (optional, positional) — non-negative integer matching
  the threshold the reviewer plans to use for `/adams-review-fix`.
  Default: 60 (DESIGN §13.2). Determines which `confirmed_auto`
  findings would "already be fixed" by the fix command and are
  therefore excluded from the walkthrough scope.

## What it does

1. Parses the threshold.
2. Locates the artifact for the current branch.
3. Computes the walkthrough scope (see §3 below).
4. Shows a pre-flight summary of the scope + asks for go/no-go.
5. For each finding in scope:
   - Dispatches a Sonnet briefing sub-agent → `{summary, options[], recommendation}`.
   - Presents the briefing and asks the reviewer which option to pick.
   - Dispatches a promote (patch + trace, no render/publish) or a skip.
6. Re-renders `artifact.md` once.
7. Re-publishes the main review comment once.
8. Posts a new "Walkthrough decisions" comment to the PR with the
   full log of what was promoted / skipped / why.
9. Appends a `## walkthrough (<ts>)` block to `trace.md`.
10. Prints a user-visible summary.

Does NOT run `/adams-review-fix`. Does NOT surface `disposition=disproven`
findings (those require an explicit `/adams-review-promote <id> --force`).

## Execution

Work through the steps below in order. Capture each named variable
into your working context. Build a TaskList that mirrors these step
headings.

### 1. Parse arguments

Parse `$ARGUMENTS` (whitespace-split):

- First token that parses as a non-negative integer → `threshold`.
- Any other token → stop and ask the user to clarify.

If no integer was provided, `threshold=60` (DESIGN §13.2). Record in
your working context.

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

Capture paths. Schema-validate:

```bash
~/.claude/commands/_shared/tools/artifact-validate.sh --path "$artifact_path"
```

On non-zero: surface the validator stderr and abort.

### 3. Compute walkthrough scope

The scope is the set of findings `/adams-review-fix` would SKIP at
`$threshold`, minus the ones already promoted or in a terminal state.
This is the inverse of the Phase 8 eligibility selector at
`09-fix-execution.md` step 8.1 — **keep the two jq expressions in
sync**.

```bash
scope_ids=$(jq -r --argjson thr "$threshold" '
    [.findings[]
     # Not terminal: skip resolved / disproven / pending_validation.
     | select(.current_state == "open")
     | select(.disposition != "resolved")
     | select(.disposition != "disproven")
     | select(.disposition != "pending_validation")
     # Skip already-promoted (human_confirmation set). Re-running the
     # walkthrough mid-session naturally picks up where it left off.
     | select(.human_confirmation == null)
     # Include iff the Phase 8 gate would skip it — the inverse of
     # 09-fix-execution.md step 8.1 (§13.1, §13.2). Note: jq's `not`
     # is a filter (pipe into it), not a function.
     | select(
         (
           (.disposition == "confirmed_auto" or .disposition == "partial" or .disposition == "regression")
           and (
             (.impact_type == "correctness" or .impact_type == "security")
             and (.score_phase4 != null and .score_phase4 >= $thr)
           )
         ) | not
       )
     | .id
    ] | join(",")
' "$artifact_path")

scope_count=$(echo "$scope_ids" | awk -F, 'NF && $1 != "" {print NF; exit} END { if (NR==0) print 0 }')
```

If `scope_ids` is empty:

```
No findings to walk through at threshold=$threshold.

Either every finding is already auto-eligible (run /adams-review-fix
$threshold to apply them) or the review has no actionable findings
left. Nothing to do.
```

Exit 0.

### 4. Pre-flight summary + go/no-go

Render a compact preview table so the reviewer knows what they're
signing up for. One row per id in `scope_ids`:

```bash
preview=$(jq -r --arg ids "$scope_ids" --argjson thr "$threshold" '
    ($ids | split(",")) as $want
    | [.findings[] | select(.id as $id | $want | index($id)) | {
        id,
        lane: .validation_lane,
        impact: .impact_type,
        disposition,
        score: (.score_phase4 // "—"),
        file: .file,
        claim_first_line: (.claim | split("\n") | .[0])
      }]
    | (["# ", "lane", "impact", "disposition", "score", "file", "claim"] | @tsv),
      (.[] | [.id, .lane, .impact, .disposition, (.score|tostring), .file, .claim_first_line] | @tsv)
' "$artifact_path")
```

Present the preview as a markdown table in chat (one header row + one
row per finding), then dispatch `AskUserQuestion` with two options:

- "Proceed — walk through $scope_count finding(s)."
- "Cancel — don't change anything."

If the reviewer picks Cancel, exit 0 with a one-line note. No mutation.

### 5. Per-finding loop (stubbed in this commit)

[SCAFFOLDING ONLY — commit 4 of `plans/walkthrough-mode.md` wires up
the briefing sub-agent, the AskUserQuestion decision flow, and the
per-iteration promote-core include. This commit lays the command
shape and ensures the scope + preview steps work in isolation.]

For this commit, print a one-line notice:

```
Scaffolding in place. Per-finding briefing loop lands in the next
commit (plans/walkthrough-mode.md §15 commit 4). Exiting without
mutating anything.
```

And exit 0.

### 6. Finalize (stubbed in this commit)

[SCAFFOLDING ONLY — see commit 5 in `plans/walkthrough-mode.md`.]

## What this command does NOT do

- **No fix-run.** Walkthrough is metadata-only (via promote's patch
  primitive). Run `/adams-review-fix [threshold]` afterward to apply.
- **No `disposition=disproven` handling.** Disproven findings need
  `/adams-review-promote <id> --force` with a conscious justification;
  the walkthrough scope filter excludes them.
- **No cross-branch walkthrough.** Operates on `latest.txt` for the
  current branch — same as promote and fix.
- **No resumption state file.** If you quit mid-walkthrough, the
  promotions you already made stand. Re-invoking the walkthrough
  skips them naturally (the scope filter excludes
  `human_confirmation != null`).
