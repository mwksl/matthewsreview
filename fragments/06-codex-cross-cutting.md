## Phase 5 — Codex cross-cutting review (codex-review)

This fragment is the codex-review counterpart to
`fragments/06-cross-cutting.md`. The eligibility check (§5.1), apply
pattern (§5.3 step 2 onwards), and summary (§5.4) are unchanged. The
only difference is the dispatch shape:

- **Opus is replaced by ONE Codex job** that proposes cross-cutting
  groups over the confirmed deep-lane findings.
- The freeform Codex output runs through ONE **`normalizer`-role shape-fixer**
  that emits the structured `cross_cutting_groups` JSON the schema
  expects.

This phase is pure reasoning over serialized JSON — Codex doesn't need
filesystem access for it (the prompt embeds the full findings list).

Capture `phase_5_start_epoch=$(date +%s)` as the first action of this
phase — step 5.4 logs the elapsed time.

### 5.1. Check for eligibility

Identical to `fragments/06-cross-cutting.md` §5.1. Read the candidates
that qualify:

```bash
artifact-read.sh \
  --path "$artifact_path" \
  --filter '[.findings[] | select(.is_actionable == true and .validation_lane == "deep")]'
```

If the list is empty, **skip Phase 5 entirely**:

```bash
log-phase.sh \
  --review-dir "$review_dir" --phase 5 --name codex-cross-cutting \
  --elapsed 0 \
  --summary "skipped — no deep-lane actionable findings"
```

(Plus the `phases.jsonl` record with `delta="skipped"`.)

Jump to Phase 6.

Otherwise, capture the list as `xc_input_json` and proceed.

### 5.2. Dispatch the Codex cross-cutting job

After §5.1 confirms work exists, materialize the resolved role:

```bash
[[ "$role_codex_crosscut" == codex:* ]] || {
    echo "ERROR: codex_crosscut must resolve to codex:<model>:<effort>." >&2
    exit 1
}
codex_crosscut_spec="${role_codex_crosscut#codex:}"
if [[ "$codex_crosscut_spec" == *:* ]]; then
    codex_crosscut_model="${codex_crosscut_spec%%:*}"
    codex_crosscut_effort="${codex_crosscut_spec#*:}"
else
    codex_crosscut_model="$codex_crosscut_spec"
    codex_crosscut_effort=""
fi
codex_dispatch_scratch="${codex_dispatch_scratch:-${scratch_dir:-/tmp/matthews-review-$review_id}/jobs}"
mkdir -p "$codex_dispatch_scratch"
```

#### 5.2.1. Build the prompt

```bash
prompt_file="/tmp/matthews-review-codex-${review_id}-XC.md"

cat > "$prompt_file" <<'PROMPT'
You are reviewing a set of confirmed, actionable deep-lane findings to
identify cross-cutting concerns — findings whose fixes must happen
together because they share code, invariants, or root cause.

**Findings (full validation_result included):**

PROMPT

printf '```\n%s\n```\n\n' "$xc_input_json" >> "$prompt_file"

cat >> "$prompt_file" <<'PROMPT'
Look across these for:

- Parallel code paths needing matching fixes (e.g., an edit in `foo()`
  implies a matching edit in `fooAsync()`).
- Shared invariants stressed by multiple findings (e.g. multiple
  findings all depend on "user_id is always non-null" — fixing them
  piecemeal leaves the invariant in an inconsistent state).
- Fix proposals that would collide if applied independently (two
  findings editing the same function with incompatible changes).
- Findings whose root cause is shared, where fixing only one leaves
  the others broken.

**Only group when combining is actually required** — not when findings
are merely thematically related. Findings that stand alone get no
annotation.

Return JSON:

```
{
  "cross_cutting_groups": [
    {
      "id": "G1",
      "finding_ids": ["F001", "F003"],
      "combined_approach": "one paragraph explaining the unified fix"
    },
    ...
  ],
  "per_finding_annotations": [
    {"finding_id": "F001", "group_id": "G1", "note": "..."},
    ...
  ]
}
```

Group ids follow `^G[0-9]+$` (G1, G2, ...). Each group must have at
least 2 finding_ids (singleton groups serve no purpose).
`per_finding_annotations` is optional — include only when a finding
needs group-specific context beyond the combined_approach.

If no cross-cutting concerns warrant grouping, emit
`{"cross_cutting_groups": [], "per_finding_annotations": []}`.
PROMPT
```

#### 5.2.2. Launch + poll + fetch

Launch through the transport selected by preflight:

```bash
set +e
if [[ "$codex_launch_mode" == "companion" ]]; then
    companion_args=(node "$CODEX_COMPANION" task --background \
        --prompt-file "$prompt_file" --json)
    [[ -n "$codex_crosscut_model" ]] && companion_args+=(--model "$codex_crosscut_model")
    [[ -n "$codex_crosscut_effort" ]] && companion_args+=(--effort "$codex_crosscut_effort")
    launch_json=$("${companion_args[@]}")
    launch_rc=$?
    xc_job_id=$(printf '%s' "$launch_json" | jq -r '.jobId // empty')
else
    dispatch_args=("${MRB}agent-dispatch.sh" start --engine codex \
        --prompt-file "$prompt_file" --scratch-dir "$codex_dispatch_scratch")
    [[ -n "$codex_crosscut_model" ]] && dispatch_args+=(--model "$codex_crosscut_model")
    [[ -n "$codex_crosscut_effort" ]] && dispatch_args+=(--effort "$codex_crosscut_effort")
    launch_json=$("${dispatch_args[@]}")
    launch_rc=$?
    xc_job_id=$(printf '%s' "$launch_json" | jq -r '.job_id // empty')
fi
set -e
```

A non-zero `launch_rc` or empty id enters §5.2.3's retry path.
Cross-cutting is one pass over already validated findings, so use
compressed ceilings:

```bash
case "$codex_crosscut_effort" in
    low)    ceiling=180 ;;
    medium) ceiling=300 ;;
    high)   ceiling=480 ;;
    xhigh)  ceiling=720 ;;
    max)    ceiling=960 ;;
    ultra)  ceiling=1200 ;;
    *)      ceiling=480 ;;
esac

if [[ "$codex_launch_mode" == "companion" ]]; then
    poll=$(codex-poll.sh \
        --job "$xc_job_id" \
        --companion "$CODEX_COMPANION" \
        --stall-threshold-sec 90 \
        --wall-clock-ceiling-sec "$ceiling") || exit $?
else
    poll=$("${MRB}agent-dispatch.sh" poll \
        --job "$xc_job_id" \
        --scratch-dir "$codex_dispatch_scratch" \
        --stall-threshold-sec 90 \
        --wall-clock-ceiling-sec "$ceiling") || exit $?
fi
verdict=$(printf '%s\n' "$poll" | jq -er \
  '.verdict | select(type == "string" and length > 0)') || exit $?
```

On `completed`, capture the transport-neutral result:

```bash
xc_codex_output=$(printf '%s' "$poll" | jq -r '.raw_output // ""')
xc_codex_tokens=$(printf '%s' "$poll" | jq -r '.tokens // "null"')
```

Empty output is retryable. `failed_terminal` and terminal `cancelled`
enter §5.2.3 without another stop. Only `broker_desynced` (companion
only) or `wall_clock_exceeded` needs cancellation before retry:

```bash
stop_verdict=not_requested
if [[ "$codex_launch_mode" == "companion" ]]; then
    ( node "$CODEX_COMPANION" cancel "$xc_job_id" >/dev/null 2>&1 ) & disown
    stop_verdict=cancel_requested
else
    set +e
    stop_result=$("${MRB}agent-dispatch.sh" stop \
        --job "$xc_job_id" --scratch-dir "$codex_dispatch_scratch")
    stop_rc=$?
    set -e
    stop_verdict=$(printf '%s\n' "$stop_result" | jq -ser \
      --arg job "$xc_job_id" '
        select(length == 1)
        | .[0]
        | select(
            type == "object"
            and .job_id == $job
            and (
              (.verdict == "cancelled" and .status == "cancelled")
              or
              (.verdict == "already_finished"
               and .stop_noop == true
               and (
                 (.status == "completed" and .terminal_verdict == "completed")
                 or
                 (.status == "failed" and .terminal_verdict == "failed_terminal")
               ))
              or
              (.verdict == "stop_failed"
               and .status == "stop_failed"
               and (.reason | type == "string" and length > 0)
               and (.wrapper_alive | type == "boolean")
               and (.engine_alive | type == "boolean"))
            ))
        | .verdict
      ') || {
        printf '%s\n' \
          'ERROR: agent-dispatch.sh stop returned malformed, partial, or mismatched output.' \
          'Action: inspect the job processes; do not retry as if cancellation succeeded.' >&2
        exit 1
    }
    if [[ ( "$stop_rc" -eq 0 && "$stop_verdict" == "stop_failed" ) \
          || ( "$stop_rc" -ne 0 && "$stop_verdict" != "stop_failed" ) ]]; then
        printf 'ERROR: agent-dispatch.sh stop exited %s with verdict %s.\n' \
          "$stop_rc" "$stop_verdict" >&2
        exit 1
    fi
    case "$stop_verdict" in
        cancelled)
            : # terminal cancellation; retry policy may replace this job
            ;;
        already_finished)
            poll=$("${MRB}agent-dispatch.sh" poll \
                --job "$xc_job_id" \
                --scratch-dir "$codex_dispatch_scratch" \
                --stall-threshold-sec 90 \
                --wall-clock-ceiling-sec "$ceiling") || exit $?
            verdict=$(printf '%s\n' "$poll" | jq -er \
              '.verdict | select(. == "completed" or . == "failed_terminal" or . == "cancelled")') \
              || exit $?
            xc_codex_output=$(printf '%s' "$poll" | jq -r '.raw_output // ""')
            xc_codex_tokens=$(printf '%s' "$poll" | jq -r '.tokens // "null"')
            ;;
        stop_failed)
            printf '%s\n' \
              'ERROR: standalone Codex cancellation could not be verified.' \
              'Action: inspect the authenticated wrapper/engine; do not launch a retry.' >&2
            exit 1
            ;;
        *)
            printf 'ERROR: unknown agent-dispatch stop verdict: %s\n' \
              "$stop_verdict" >&2
            exit 1
            ;;
    esac
fi
elapsed_for_log=$(printf '%s' "$poll" | jq -r '.elapsed_sec // "null"')
printf 'phase_5_codex_watchdog: mode=%s verdict=%s stop=%s job=%s elapsed=%s\n' \
    "$codex_launch_mode" "$verdict" "$stop_verdict" "$xc_job_id" \
    "$elapsed_for_log" >> "$trace_log_path"
```

On `already_finished`, route the re-polled terminal verdict through the normal
completed/failure branch before retry decisions. `stop_failed` blocks retry
because the old engine may still be running.

#### 5.2.3. Adaptive retry-with-judgment

Apply the §3.7 retry policy:

1. On Codex job failure (non-zero exit, malformed output, or empty
   output), retry up to 3 times with the same prompt.
2. If all 3 retries fail, ASK:

   ```
   "Codex cross-cutting analysis failed after retry. Continue without
   cross_cutting_groups (the rest of the review is unaffected), or
   abort?"
   Options:
   - Continue — skip Phase 5; artifact ships without groups
   - Abort
   ```

   On Continue: log `phase_5_codex_dropped: continuing without groups`
   and proceed to Phase 6.

#### 5.2.4. `normalizer`-role shape-fixer

Dispatch ONE sub-agent with the resolved `normalizer` role to canonicalize Codex's freeform output
into the structured shape:

> You are normalizing one Codex cross-cutting analysis output into the
> matthewsreview cross_cutting_groups schema.
>
> **Codex output (freeform):**
>
> ```
> $xc_codex_output
> ```
>
> **Valid finding ids in this run:** `<comma-separated ids from xc_input_json>`
>
> Emit a JSON object:
>
> ```
> {
>   "cross_cutting_groups": [
>     {
>       "id": "G1",
>       "finding_ids": ["F001", "F003"],
>       "combined_approach": "one paragraph"
>     },
>     ...
>   ],
>   "per_finding_annotations": [
>     {"finding_id": "F001", "group_id": "G1", "note": "..."}
>   ]
> }
> ```
>
> Constraints (the schema enforces these — failing them rejects the
> whole apply):
> - Each `id` matches `^G[0-9]+$` (G1, G2, ...). Number sequentially
>   from G1.
> - Each `finding_ids` has at least 2 entries.
> - `finding_ids` ⊆ the valid finding-id list above. Drop any group
>   that references unknown ids; do not invent ids.
> - `combined_approach` is non-empty string.
>
> If Codex's output proposes no groups, emit
> `{"cross_cutting_groups": [], "per_finding_annotations": []}`.
> If Codex's output is unparseable for groups but contains relevant
> prose, emit empty arrays (skipping is safe — groups are
> observability, not correctness).

Capture the shape-fixer's response as `xc_response_json`.

Log the Codex job and shape-fixer usage:

```bash
log-tokens.sh \
  --review-dir "$review_dir" --phase phase_5 \
  --agent-role codex_cross_cutting --agent-id "$xc_job_id" \
  --model "$role_codex_crosscut" --tokens "$xc_codex_tokens"
log-tokens.sh \
  --review-dir "$review_dir" --phase phase_5 \
  --agent-role cross_cutting_shape_fixer --agent-id <id> \
  --model "$role_normalizer" --tokens <N or null>
```

### 5.3. Apply the cross-cutting groups

Same pattern as `fragments/06-cross-cutting.md` §5.3 step 2 onwards.
Parse the shape-fixer's response, extract `.cross_cutting_groups`,
write to a tmpfile, apply via `artifact-patch.py --set-json`:

Mirror `fragments/06-cross-cutting.md` §5.3's pluck — accept either
the envelope (with `.cross_cutting_groups`) or a bare groups array.
The shape-fixer's prompt asks for the envelope, but a normalizer that
returns just the array shouldn't lose its work. The `// .` fallback
is the same shape :review uses; `// []` would silently zero-out a
valid bare-array response.

```bash
groups_tmp=$(mktemp -t matthews-review-ccg.XXXXXX)
cleanup_groups_tmp() { rm -f "$groups_tmp" || true; }
trap cleanup_groups_tmp EXIT HUP INT TERM
if ! jq -c '.cross_cutting_groups // .' <<<"$xc_response_json" > "$groups_tmp"; then
    printf 'phase_5_codex_groups_unparseable: shape-fixer output is invalid JSON; setting to []\n' \
        >> "$trace_log_path"
    printf '%s\n' '[]' > "$groups_tmp"
fi

# Defensive type-guard: if neither path produced an array, fall back to [].
if ! jq -e 'type == "array"' "$groups_tmp" >/dev/null; then
    printf 'phase_5_codex_groups_unparseable: shape-fixer output not an array; setting to []\n' \
        >> "$trace_log_path"
    printf '%s\n' '[]' > "$groups_tmp"
fi

artifact-patch.py \
  --path "$artifact_path" \
  --set-json "cross_cutting_groups=@$groups_tmp"
patch_rc=$?
cleanup_groups_tmp
trap - EXIT HUP INT TERM
[[ "$patch_rc" -eq 0 ]] || printf 'phase_5_codex_groups_apply_failed\n' >> "$trace_log_path"
```

If `artifact-patch.py` rejects the write (schema validation — invalid
group id, finding_ids list too short, etc.), log to `trace.md` with
tag `phase_5_apply_rejected: <stderr>` and proceed without
cross_cutting_groups. Same fallback as the original Opus path.

Clean up the Phase 5 Codex prompt + output files:

```bash
rm -f "/tmp/matthews-review-codex-${review_id}-XC.md" \
      "/tmp/matthews-review-codex-${review_id}-XC.out.json"
rm -rf -- "$codex_dispatch_scratch"
```

### 5.4. Log Phase 5 summary

Identical to `fragments/06-cross-cutting.md` §5.4:

```bash
phase_5_elapsed=$(( $(date +%s) - phase_5_start_epoch ))
group_count=$(artifact-read.sh \
  --path "$artifact_path" --filter '.cross_cutting_groups | length')

log-phase.sh \
  --review-dir "$review_dir" --phase 5 --name codex-cross-cutting \
  --elapsed "$phase_5_elapsed" \
  --summary "groups=$group_count"

log-phase.sh \
  --review-dir "$review_dir" --phase 5 --record "$(jq -nc \
    --argjson elapsed "$phase_5_elapsed" \
    --argjson groups "$group_count" \
    '{name:"codex-cross-cutting", elapsed_sec:$elapsed, counts_by_state:{}, counts_by_disposition:{}, cross_cutting_groups:$groups, delta:"\($groups) groups emitted"}')"
```
