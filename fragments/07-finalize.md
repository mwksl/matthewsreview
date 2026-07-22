## Phase 6 — Finalize

### 6.1. Schema-validate the artifact

```bash
artifact-validate.sh --path "$artifact_path"
```

On non-zero exit: log the validator stderr verbatim to `trace.md`;
surface to the user as "Final artifact fails schema validation — see
trace.md." Dump a copy to `/tmp/matthews-review-invalid-$(date -u +%Y%m%dT%H%M%SZ).json`
for debugging. Do NOT proceed to publish — a broken artifact
should not shadow the PR comment.

### 6.2. Tally `subagent_tokens` from `tokens.jsonl`

```bash
tally-subagent-tokens.sh \
  --tokens-log "$tokens_log_path" \
  --artifact   "$artifact_path"
```

`tokens: null` entries coerce to 0; an empty log produces a zero
rollup rather than an error. The three lifecycle commands
(`/matthewsreview:fix`, `/matthewsreview:add`, `/matthewsreview:walkthrough`)
each re-invoke it before their final render so the published PR
comment reflects cumulative sub-agent spend.

### 6.2b. Tally `orchestrator_tokens` from the session transcript(s)

```bash
review_started_at=$(artifact-read.sh \
  --path "$artifact_path" --filter '.review_started_at // empty' | jq -r '.')

finalization_record_failed=false
orchestrator_tally_failed=false
if ! orchestrator-tokens.sh \
  --artifact "$artifact_path" \
  --since    "$review_started_at" \
  2>>"$trace_log_path"; then
    orchestrator_tally_failed=true
    printf 'orchestrator_tally_failed\n' >> "$trace_log_path"
    if ! log-phase.sh \
      --review-dir "$review_dir" --phase 6 \
      --record '{"name":"orchestrator-tally","finalization_failures":1}'; then
        finalization_record_failed=true
        printf 'finalization_failure_record_failed: orchestrator-tally\n' \
          >> "$trace_log_path"
    fi
fi
```

Companion to the sub-agent tally; the two are non-overlapping. Missing or
incomplete hook metadata skips without mutation. A scoped empty session
removes only that session's prior row and retains all sibling session totals.
Malformed or unreadable transcript JSONL fails with structured stderr and
leaves the artifact byte-for-byte unchanged. That failure is non-fatal
telemetry: record it as one finalization failure, retain any prior tally
instead of fabricating a zero, and surface it in step 6.10.

The helper is **opt-in** via `MATTHEWS_REVIEW_TALLY_ORCHESTRATOR=1`
(default skip). When opted out it exits 0 with one
`orchestrator-tally: skipped (...)` stdout line and does not touch
the artifact, so the rendered PR comment simply omits the
**Orchestrator tokens** line.

### 6.3a. Recompute `reviewer_sources` from actual findings

Top-level `reviewer_sources` is the union of providers that produced
at least one candidate. Compute it from `findings[].sources[]`:

- `internal` — present when any lens produced a candidate (any
  `sources[]` entry matches `L[0-9]+-.*` — L1–L7 today, forward-compat for future lenses).
- `internal-codex` — same `L<N>-` lens-tag pattern, but emitted by
  `/matthewsreview:codex-review` rather than `/matthewsreview:review`. The
  seeded artifact (Phase 0 step 0.15) carries this label when the
  top-level command set `reviewer_sources_label=internal-codex`;
  preserve it here instead of mapping back to `internal`.
- adapter name (`codex`) — present when any entry matches exactly.
- `external-pr:<bot-login>` — present when any entry starts with
  `external-pr:`.

The L-tag mapping picks `internal` vs `internal-codex` based on the
seeded value (so codex-review's marker survives the recompute):

```bash
finalize_artifact_snapshot=$(artifact-read.sh \
  --path "$artifact_path" --filter '.')

internal_label=$(printf '%s' "$finalize_artifact_snapshot" | jq -r '
  if (.reviewer_sources // []) | any(. == "internal-codex") then "internal-codex"
  else "internal" end
')

reviewer_sources=$(printf '%s' "$finalize_artifact_snapshot" | jq -c --arg internal "$internal_label" '
  [.findings[] | .sources[]]
  | map(
      # Internal lens tags: L1..L7 today (L7 is the ensemble-gated
      # holistic lens, Stage 2.9.D). Regex is [0-9]+ for forward-
      # compatibility — new L-N lenses slot in without this needing
      # an update. Map to whichever internal label the seed indicated
      # ($internal). Any entry that doesn't match falls through to
      # `empty` and gets dropped from the union.
      if test("^L[0-9]+-") then $internal
      elif . == "codex" then .
      elif startswith("external-pr:") then .
      else empty end
    )
  | unique
')

reviewer_sources_tmp=$(mktemp -t matthews-review-rs.XXXXXX)
cleanup_reviewer_sources_tmp() { rm -f "$reviewer_sources_tmp"; }
trap cleanup_reviewer_sources_tmp EXIT HUP INT TERM
printf '%s\n' "$reviewer_sources" > "$reviewer_sources_tmp"
artifact-patch.py \
  --path "$artifact_path" \
  --set-json "reviewer_sources=@$reviewer_sources_tmp"
reviewer_sources_rc=$?
cleanup_reviewer_sources_tmp
trap - EXIT HUP INT TERM
[[ "$reviewer_sources_rc" -eq 0 ]] || exit "$reviewer_sources_rc"
```

If `findings[]` is empty (no candidates detected), the union is `[]` —
the schema accepts an empty array.

### 6.3. Populate `metrics`

```bash
start_epoch=$(date -d "$review_started_at" +%s 2>/dev/null || python3 -c "
import sys
from datetime import datetime
print(int(datetime.fromisoformat('$review_started_at'.replace('Z','+00:00')).timestamp()))
")
now_epoch=$(date +%s)
elapsed=$((now_epoch - start_epoch))

# At review time (Stage 2), phase_9_verified_pct and required_followup
# are null — they're set by /matthewsreview:fix's Phase 9.
metrics=$(jq -n \
  --argjson elapsed "$elapsed" \
  --argjson files_changed "$num_files" \
  --argjson lines_changed "$lines_changed" \
  '{
    phase_9_verified_pct: null,
    required_followup: null,
    time_elapsed_seconds: $elapsed,
    pr_size_buckets: {files_changed: $files_changed, lines_changed: $lines_changed}
  }')

metrics_tmp=$(mktemp -t matthews-review-metrics.XXXXXX)
cleanup_metrics_tmp() { rm -f "$metrics_tmp"; }
trap cleanup_metrics_tmp EXIT HUP INT TERM
printf '%s\n' "$metrics" > "$metrics_tmp"
artifact-patch.py \
  --path "$artifact_path" \
  --set-json "metrics=@$metrics_tmp"
metrics_rc=$?
cleanup_metrics_tmp
trap - EXIT HUP INT TERM
[[ "$metrics_rc" -eq 0 ]] || exit "$metrics_rc"
```

### 6.4. Append Phase 6 record to `phases.jsonl`

```bash
by_disp=$(artifact-read.sh \
  --path "$artifact_path" --summary | jq -c '.counts_by_disposition')
by_state=$(artifact-read.sh \
  --path "$artifact_path" --summary | jq -c '.counts_by_state')

log-phase.sh \
  --review-dir "$review_dir" --phase 6 --name finalize \
  --elapsed 0 \
  --summary "rendering + publishing; total findings=$(artifact-read.sh --path "$artifact_path" --filter '.findings | length' | jq -r '.')"

log-phase.sh \
  --review-dir "$review_dir" --phase 6 --record "$(jq -nc \
    --argjson by_disp "$by_disp" \
    --argjson by_state "$by_state" \
    '{name:"finalize", elapsed_sec:0, counts_by_state:$by_state, counts_by_disposition:$by_disp}')"
```

### 6.4b. Synchronize degraded runs (BEFORE render and AFTER failures)

A zero-finding report is indistinguishable from a clean review unless
failures are surfaced — detection failures live in
`phases.jsonl`/`trace.md`, not in the finding list, and the published
`artifact.md`/PR comment persists long after any chat-only warning scrolls
away. Reconcile the three existing counters through the atomic helper:

```bash
if ! sync-degraded.py \
  --artifact "$artifact_path" \
  --phases-log "$phases_log_path" \
  2>>"$trace_log_path"; then
    finalization_record_failed=true
    printf 'degradation_sync_failed\n' >> "$trace_log_path"
fi

record_finalization_failure() {
    local failure_name="$1"
    log-phase.sh \
      --review-dir "$review_dir" --phase 6 \
      --record "$(jq -nc --arg name "$failure_name" \
        '{name:$name, finalization_failures:1}')" \
      || return
    sync-degraded.py \
      --artifact "$artifact_path" \
      --phases-log "$phases_log_path" \
      || return
}
```

`sync-degraded.py` validates every structured phase row, sums
`lens_dispatch_failures`, `candidate_drop_failures`, and
`finalization_failures`, validates the full artifact, and commits with one
atomic write. A positive aggregate replaces `artifact.degraded` with the
canonical three-counter object; an all-zero aggregate removes the optional
field. On malformed input or validation/write failure it emits structured
stderr and leaves the artifact untouched. Stop before render/publish if this
sync fails.

Every later render or publish failure must call
`record_finalization_failure` only **after** the failing command returns. The
immediate resync makes the renderer's prominent `⚠ REVIEW DEGRADED` block
cover the local/chat report and any later render.

The function is status-preserving: failure to append the phase row returns
immediately without attempting sync, and sync failure returns nonzero. Call it
exactly once per observed operation failure. A caller that sees nonzero sets
`finalization_record_failed=true`, skips recovery render/publication, and
refuses to mirror a clean-looking stale report.

### 6.5. Render `artifact.md`

Stage each render beside the destination and rename only after the renderer
returns zero. A failed renderer therefore cannot leave a truncated report that
looks publishable:

```bash
render_local_report() {
    local staged_path render_rc
    staged_path=$(mktemp "$review_dir/.artifact.md.tmp.XXXXXX") || return 1
    if artifact-render.py \
      --input "$artifact_path" --output "$staged_path" \
      && mv "$staged_path" "$review_dir/artifact.md"; then
        return 0
    else
        render_rc=$?
    fi
    rm -f "$staged_path"
    return "$render_rc"
}

render_failed=false
render_recovery_failed=false
report_ready=false
if [[ "$finalization_record_failed" == "true" ]]; then
    # The degradation state could not be persisted/resynced. Fail closed:
    # no clean-looking render may proceed to publication or chat.
    report_ready=false
elif render_local_report 2>>"$trace_log_path"; then
    report_ready=true
else
    render_failed=true
    printf 'render_failed\n' >> "$trace_log_path"
    if record_finalization_failure "render" 2>>"$trace_log_path"; then
        # One local-only recovery render reflects the newly-synced banner.
        # A render failure permanently disables publication for this run.
        if render_local_report 2>>"$trace_log_path"; then
            report_ready=true
        else
            render_recovery_failed=true
            printf 'render_recovery_failed\n' >> "$trace_log_path"
            if ! record_finalization_failure \
              "render-recovery" 2>>"$trace_log_path"; then
                finalization_record_failed=true
                printf 'finalization_failure_record_failed: render-recovery\n' \
                  >> "$trace_log_path"
            fi
            report_ready=false
        fi
    else
        finalization_record_failed=true
        printf 'finalization_failure_record_failed: render\n' \
          >> "$trace_log_path"
        report_ready=false
    fi
fi
```

Never invoke the publisher when `render_failed == true`, even if the local-only
recovery render succeeds. If both renders fail, do not read an older
`artifact.md`/`published.md` into chat; surface the render errors from
`trace.md` instead.

### 6.6. Re-assert `latest.txt` (atomic)

```bash
tmp="$reviews_root/$repo_slug/$head_branch/latest.txt.tmp.$$"
printf '%s\n' "$review_id" > "$tmp"
mv "$tmp" "$reviews_root/$repo_slug/$head_branch/latest.txt"
```

### 6.7. Publish (only after a successful first render)

On normal paths, call `artifact-publish.sh` in every mode; local/draft mode is
the helper's no-op path. If the first render in step 6.5 failed, do not invoke
the publisher at all, even when the local-only recovery render succeeded.

Initialize publication state once:

```bash
publish_attempted=false
publish_failed=false
publish_recovery_render_failed=false
publish_exit=0
stdout=""
```

**PR mode:**

Capture any `comment_id` persisted to the artifact during this run. On a fresh
`/matthewsreview:review` this is normally empty — the seed at step 0.15 writes
`comment_id: null` unless step 0.14's recovery prompt populated
`existing_comment_id`:

```bash
if [[ "$mode" == "pr" \
      && "$render_failed" == "false" \
      && "$finalization_record_failed" == "false" ]]; then
    comment_id_from_artifact=$(artifact-read.sh \
      --path "$artifact_path" --filter '.comment_id // empty' \
      2>/dev/null || true)

    publish_args=(
        --mode pr
        --review-id "$review_id"
        --pr "$pr_number"
        --repo-slug "$repo_slug"
        --branch "$head_branch"
        --review-dir "$review_dir"
    )
    # Prefer artifact-recorded comment_id; fall back to existing_comment_id.
    # Omitting --comment-id on a fresh review intentionally POSTs.
    if [[ -n "$comment_id_from_artifact" ]]; then
        publish_args+=(--comment-id "$comment_id_from_artifact")
    elif [[ -n "$existing_comment_id" ]]; then
        publish_args+=(--comment-id "$existing_comment_id")
    fi

    publish_attempted=true
    stdout=$(artifact-publish.sh "${publish_args[@]}" \
      2>>"$trace_log_path") || publish_exit=$?

    # Persist a newly-minted id only after a successful POST/PATCH fallback.
    if [[ "$publish_exit" -eq 0 ]]; then
        new_id=$(printf '%s' "$stdout" | jq -r '.comment_id // empty')
        if [[ -n "$new_id" ]]; then
            artifact-patch.py \
              --path "$artifact_path" --set "comment_id=$new_id"
        fi
    fi
fi
```

**Local/draft mode:**

```bash
if [[ "$mode" != "pr" \
      && "$render_failed" == "false" \
      && "$finalization_record_failed" == "false" ]]; then
    publish_attempted=true
    artifact-publish.sh \
      --mode local --review-id "$review_id" --review-dir "$review_dir" \
      2>>"$trace_log_path" || publish_exit=$?
fi
```

The local invocation remains a no-op that appends one trace line. Handle a
failure from either mode once, after the publisher returns:

```bash
if [[ "$publish_attempted" == "true" && "$publish_exit" -ne 0 ]]; then
    publish_failed=true
    printf 'publish_failed\n' >> "$trace_log_path"
    if record_finalization_failure "publish" 2>>"$trace_log_path"; then
        # Local recovery only: do not retry publication.
        if render_local_report 2>>"$trace_log_path"; then
            report_ready=true
        else
            publish_recovery_render_failed=true
            report_ready=false
            printf 'publish_recovery_render_failed\n' >> "$trace_log_path"
            if ! record_finalization_failure \
              "publish-recovery-render" 2>>"$trace_log_path"; then
                finalization_record_failed=true
                printf 'finalization_failure_record_failed: publish-recovery-render\n' \
                  >> "$trace_log_path"
            fi
        fi
    else
        finalization_record_failed=true
        report_ready=false
        printf 'finalization_failure_record_failed: publish\n' \
          >> "$trace_log_path"
    fi
fi
```

The resync precedes the recovery render, so `artifact.md` contains the
degraded banner. Never retry the failed publication in this run. If its local
recovery render also fails, keep the canonical failure counters but do not
mirror an older report.

### 6.8. Mirror the rendered report to chat (all modes)

Select the report body first:

```bash
mirror_path=""
if [[ "$report_ready" == "true" ]]; then
    mirror_path="$review_dir/artifact.md"
    if [[ "$mode" == "pr" \
          && "$publish_attempted" == "true" \
          && "$publish_failed" == "false" \
          && "$publish_exit" -eq 0 \
          && -f "$review_dir/published.md" ]]; then
        mirror_path="$review_dir/published.md"
    fi
fi
```

`artifact-publish.sh` writes `published.md` atomically as the exact body
selected for GitHub. On a successful PR publication, mirror that file so an
oversized full report shows the same bounded disposition queue in chat and on
the PR. The success path therefore remains an exact chat mirror of the compact
or full body actually sent. Local/draft mode, an initial render failure, or a
publish failure uses the newly rendered full `artifact.md` with its degraded
banner.

When `$mirror_path` is non-empty, read it and output its full content directly
to chat — NOT a summary. When it is empty, both the initial/recovery render (or
the post-publish recovery render) failed; do not read a stale report and
surface the deferred failures in step 6.10 instead.

Prepend a one-line mode-aware header:

- `pr`    → `### Code review`
- `draft` → `### Code review (draft PR)`
- `local` → `### Code review (local — \`$head_branch\` vs \`$base_branch\`)`

After the selected report body, add a **Next steps** block. Do NOT use
ASK here.

Build the rows from the finalized artifact with the same selectors the
lifecycle commands use:

```bash
next_step_counts=$(jq -c '
  (.gates.fix_threshold // 60) as $fix_thr
  | (.gates.walkthrough_threshold // 60) as $walk_thr
  | def fix_disposition:
      (.disposition == "confirmed_mechanical"
       or .disposition == "partial"
       or .disposition == "regression");
    def auto_eligible:
      fix_disposition
      and (
        .human_confirmation != null
        or (
          (.impact_type == "correctness" or .impact_type == "security")
          and (.score_phase4 != null and .score_phase4 >= $fix_thr)
        )
      );
    {
      auto_eligible_count: ([.findings[]
        | select(.current_state == "open" and auto_eligible)] | length),
      walkthrough_count: ([.findings[]
        | select(.current_state == "open")
        | select(.disposition != "resolved"
                 and .disposition != "disproven"
                 and .disposition != "pending_validation"
                 and .disposition != "below_gate"
                 and .disposition != "pre_existing_report")
        | select(.human_confirmation == null)
        | select(auto_eligible | not)
        | select((.score_phase4 // .score_phase3 // -1) >= $walk_thr)
      ] | length),
      preexisting_count: ([.findings[]
        | select(.current_state == "open"
                 and .disposition == "pre_existing_report")] | length),
      internal_only: (
        (.reviewer_sources | length) > 0
        and all(.reviewer_sources[];
          . == "internal" or . == "internal-codex")
      )
    }
' "$artifact_path")
auto_eligible_count=$(printf '%s' "$next_step_counts" | jq -r '.auto_eligible_count')
walkthrough_count=$(printf '%s' "$next_step_counts" | jq -r '.walkthrough_count')
preexisting_count=$(printf '%s' "$next_step_counts" | jq -r '.preexisting_count')
internal_only=$(printf '%s' "$next_step_counts" | jq -r '.internal_only')
```

Resolve the user-facing command spelling from `harness_id` before
rendering the rows:

- `codex`: `$matthewsreview-fix`, `$matthewsreview-walkthrough`, and
  `$matthewsreview-add`
- `claude-code` or `omp`: `/matthewsreview:fix`,
  `/matthewsreview:walkthrough`, and `/matthewsreview:add`

For the work-queue row, resolve `artifact-render.py` with `command -v`
on Claude Code; otherwise use the absolute `${MRB}artifact-render.py`.
Always print the absolute `$artifact_path`. Never address `bin/`
relative to the repository being reviewed.

Then emit ONLY the rows whose counts are non-zero (plus the always
row), in this order:

```markdown
---

**Next steps**

- `<fix_command> <fix_threshold>` — applies N auto-fixable finding(s),
  re-reviews, reverts regressions, commits survivors.
  [only when auto_eligible_count > 0]
- `<walkthrough_command> <walkthrough_threshold>` — M finding(s) need
  human judgment; step through with briefings, promote the ones you want
  auto-fixed. [only when walkthrough_count > 0]
- K pre-existing issue(s) — in `pr` mode, the walkthrough files
  GitHub issues for these; in `local` or `draft` mode, it keeps them
  report-only because there is no eligible parent PR link.
  [only when preexisting_count > 0]
- Add a second opinion — use `<add_command> <paste>` to inject an
  external review. On Claude Code or OMP, re-running
  `/matthewsreview:review --ensemble` is also available.
  [only when internal_only]
- Work queue: `<artifact_render_command> --input <absolute_artifact_path>
  --format dispositions > DISPOSITIONS.md` — one row per finding with
  suggested actions. [always]
```

When every count is zero (clean review), the block collapses to the
work-queue row only.

`<fix_threshold>` / `<walkthrough_threshold>` are the resolved
`gates.*` values (default 60).

Then add (still chat-only, not in `artifact.md`):

- If PR mode: a one-line "Full artifact: `$artifact_path`" (so the user
  knows where the JSON lives).
- If local mode: "Fix commit will land locally if you run `<fix_command>`.
  It will not be pushed without `--push` (Stage 3 future flag)."

(None of these trailing lines are part of `artifact.md` itself — keeps
the PR comment clean.)

### 6.9. Pop stash (if Phase 0 took one)

If `stash_taken == true` from Phase 0 step 0.8:

```bash
git stash pop
```

If the pop conflicts, do NOT auto-resolve. Tell the user clearly: "Your
stashed changes conflict with something in the tree. Resolve manually;
your stash is preserved under `git stash list`." Leave the stash in
place (it doesn't auto-drop on conflict).

If `stash_taken == false`, skip this step.

### 6.10. Final status + surface any deferred failures

After the chat mirror (when one is available), surface every deferred failure
that occurred; do not collapse them into a generic warning:

- `orchestrator_tally_failed == true` — token telemetry could not be read.
  State that the artifact was not changed or zero-filled, any prior tally was
  retained, and the structured error is in `$trace_log_path`.
- `finalization_record_failed == true` — a finalization failure record/resync
  could not be persisted. State that render/recovery/publication was disabled
  fail-closed, no clean-looking report was mirrored, and the structured error
  is in `$trace_log_path`. Do not re-run the recorder (the phase append may
  already have succeeded); repair the log/artifact and run
  `sync-degraded.py` once.
- `render_failed == true` — the first render failed, publication was skipped,
  and the report shown (if any) is the local-only recovery render. Name
  `$trace_log_path` and tell the user to resolve the renderer error before
  manually publishing.
- `render_recovery_failed == true` — no current report could be mirrored; the
  canonical artifact still records both finalization failures.
- `publish_failed == true` — publication failed and was not retried. When its
  failure record/resync succeeded, the canonical artifact and local/chat
  `artifact.md` were rerendered with the degraded banner; tell the user to fix
  the publisher error and invoke it manually. If record/resync failed, use the
  fail-closed message above instead.
- `publish_recovery_render_failed == true` — publication failed and its local
  recovery render also failed, so no stale report was mirrored.
- A validation failure remains an immediate stop: name the validator step and
  recovery action from step 6.1.

If every flag is false and validation succeeded, nothing more is needed — the
chat mirror plus any PR comment is the deliverable.
