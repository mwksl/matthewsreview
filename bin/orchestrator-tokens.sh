#!/usr/bin/env bash
# orchestrator-tokens.sh — roll the active Claude Code session transcript's
# usage into `orchestrator_tokens` on the artifact.
#
# `subagent_tokens` (via tally-subagent-tokens.sh) captures dispatched
# sub-agents but deliberately excludes the main orchestrator session. Claude
# Code's SessionStart hook writes the exact active transcript path + session id
# into MATTHEWS_REVIEW_TRANSCRIPT_FILE / MATTHEWS_REVIEW_SESSION_ID. This helper
# reads only that file, filters its assistant turns to that session and the
# review window, sums the four `message.usage` counters, and writes the result
# through artifact-patch.py --set-json.
#
# Four counters are preserved separately — cache-read $/token is roughly an
# order of magnitude cheaper than fresh input, so collapsing them hides the
# real cost signal.
#
# Scope filter: `timestamp >= --since`, plus exact `sessionId` equality when a
# session id is available. This eliminates the old cwd-wide directory scan and
# its cross-session over-count. Unrelated chat in the same Claude session after
# review_started_at can still over-count; command-boundary attribution is not
# exposed in transcript usage records.
#
# Transcript discovery:
#   - Default: MATTHEWS_REVIEW_TRANSCRIPT_FILE and
#     MATTHEWS_REVIEW_SESSION_ID, exported by hooks/dep-check.sh through
#     CLAUDE_ENV_FILE at SessionStart.
#   - --transcript-file / --session-id override the hook environment for smoke
#     tests and manual diagnostics.
#   - Missing hook metadata skips without artifact mutation. A missing explicit
#     file is an input error. An empty or all-pre-since file writes a zero rollup.
#
# Opt-in: defaults to skip unless `MATTHEWS_REVIEW_TALLY_ORCHESTRATOR=1`
# (or true/yes/on) is set. Transcript contents are sensitive and may carry
# macOS provenance metadata, so users must explicitly enable reading them.
# Opt-out exits 0 with one stdout line and preserves any prior value.
#
# Usage:
#   orchestrator-tokens.sh --artifact <path> --since <iso-ts> \
#       [--transcript-file <path>] [--session-id <id>]
#
# Stdout (on success):
#   `orchestrator-tally: total_input=<N> output=<N> cache_read=<N> cache_creation=<N> turns=<N> sessions=<M>`
#
# Exits:
#   0   success
#   1   missing artifact/file, write failure, or artifact-patch.py rejection
#   64  usage error

set -euo pipefail

usage() {
    cat >&2 <<USAGE
Usage: $(basename "$0") --artifact <path> --since <iso-ts> [--transcript-file <path>] [--session-id <id>]

Rolls the active Claude Code session transcript into an artifact's
orchestrator_tokens field via artifact-patch.py --set-json. When no transcript
file is supplied, uses MATTHEWS_REVIEW_TRANSCRIPT_FILE and
MATTHEWS_REVIEW_SESSION_ID exported by the Claude Code SessionStart hook.
USAGE
}

die_usage() { echo "ERROR: $1" >&2; usage; exit 64; }

ARTIFACT=""
SINCE=""
TRANSCRIPT_FILE=""
SESSION_ID=""
TRANSCRIPT_FILE_EXPLICIT=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --artifact)
            [[ $# -ge 2 ]] || die_usage "--artifact requires a value"
            ARTIFACT="${2:-}"; shift 2 ;;
        --since)
            [[ $# -ge 2 ]] || die_usage "--since requires a value"
            SINCE="${2:-}"; shift 2 ;;
        --transcript-file)
            [[ $# -ge 2 ]] || die_usage "--transcript-file requires a value"
            TRANSCRIPT_FILE="${2:-}"; TRANSCRIPT_FILE_EXPLICIT=1; shift 2 ;;
        --session-id)
            [[ $# -ge 2 ]] || die_usage "--session-id requires a value"
            SESSION_ID="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die_usage "unknown arg '$1'" ;;
    esac
done

[[ -n "$ARTIFACT" ]] || die_usage "--artifact is required"
[[ -n "$SINCE" ]] || die_usage "--since is required"

# Use exact SessionStart metadata unless the caller selected another file.
if [[ "$TRANSCRIPT_FILE_EXPLICIT" == "0" \
      && -n "${MATTHEWS_REVIEW_TRANSCRIPT_FILE:-}" ]]; then
    TRANSCRIPT_FILE="$MATTHEWS_REVIEW_TRANSCRIPT_FILE"
    if [[ -z "$SESSION_ID" ]]; then
        SESSION_ID="${MATTHEWS_REVIEW_SESSION_ID:-}"
    fi
fi

opt_in="${MATTHEWS_REVIEW_TALLY_ORCHESTRATOR:-${ADAMS_REVIEW_TALLY_ORCHESTRATOR:-}}"
case "$opt_in" in
    1|true|TRUE|yes|YES|on|ON) ;;
    *)
        echo "orchestrator-tally: skipped (set MATTHEWS_REVIEW_TALLY_ORCHESTRATOR=1 to enable; see README §Token counts)"
        exit 0
        ;;
esac

if [[ ! -f "$ARTIFACT" ]]; then
    echo "ERROR: artifact not found at $ARTIFACT" >&2
    echo "Action: check the path — the artifact must already exist (Phase 0 inits it)." >&2
    exit 1
fi

if [[ "$TRANSCRIPT_FILE_EXPLICIT" == "0" \
      && -z "$TRANSCRIPT_FILE" && -z "$SESSION_ID" ]]; then
    echo "orchestrator-tally: skipped (no Claude SessionStart transcript metadata)"
    exit 0
fi
if [[ "$TRANSCRIPT_FILE_EXPLICIT" == "0" \
      && ( -z "$TRANSCRIPT_FILE" || -z "$SESSION_ID" ) ]]; then
    echo "orchestrator-tally: skipped (incomplete Claude SessionStart transcript/session metadata)"
    exit 0
fi
if [[ -z "$TRANSCRIPT_FILE" ]]; then
    echo "orchestrator-tally: skipped (no Claude SessionStart transcript metadata)"
    exit 0
fi
if [[ ! -f "$TRANSCRIPT_FILE" ]]; then
    if [[ "$TRANSCRIPT_FILE_EXPLICIT" == "1" ]]; then
        echo "ERROR: explicit transcript file not found: $TRANSCRIPT_FILE" >&2
        echo "Action: pass a readable Claude Code session transcript JSONL file" >&2
        exit 1
    fi
    echo "orchestrator-tally: skipped (SessionStart transcript file not found: $TRANSCRIPT_FILE)"
    exit 0
fi

# Phase 0 timestamps have second precision while transcript timestamps carry
# milliseconds. Normalize the former so lexical comparison includes turns from
# the same second.
if [[ "$SINCE" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})Z$ ]]; then
    SINCE_NORMALIZED="${BASH_REMATCH[1]}.000Z"
else
    SINCE_NORMALIZED="$SINCE"
fi

combined_stream() {
    jq -c --arg src "$TRANSCRIPT_FILE" --arg since "$SINCE_NORMALIZED" \
        --arg scoped_session_id "$SESSION_ID" '
        . as $line
        | select(
            .type == "assistant"
            and (.timestamp // "") >= $since
            and ((.sessionId // "") | type == "string")
            and (.sessionId // "") != ""
            and ($scoped_session_id == "" or (.sessionId // "") == $scoped_session_id)
          )
        | (.message.usage // empty) as $u
        | $line + {
            _transcript_path: $src,
            message: ($line.message + {usage: $u})
          }
    ' "$TRANSCRIPT_FILE" 2>/dev/null || true
}

tally_json=$(combined_stream | jq -cs '
    . as $turns
    | {
        total_input:    (([ $turns[] | .message.usage.input_tokens                // 0 ] | add) // 0),
        total_output:   (([ $turns[] | .message.usage.output_tokens               // 0 ] | add) // 0),
        cache_read:     (([ $turns[] | .message.usage.cache_read_input_tokens     // 0 ] | add) // 0),
        cache_creation: (([ $turns[] | .message.usage.cache_creation_input_tokens // 0 ] | add) // 0),
        turn_count:     ($turns | length),
        sessions: (
            $turns
            | group_by(.sessionId)
            | map({
                session_id:      .[0].sessionId,
                transcript_path: .[0]._transcript_path,
                first_seen:      ([ .[] | .timestamp // "" ] | min),
                last_seen:       ([ .[] | .timestamp // "" ] | max),
                total_input:     (([ .[] | .message.usage.input_tokens                // 0 ] | add) // 0),
                total_output:    (([ .[] | .message.usage.output_tokens               // 0 ] | add) // 0),
                cache_read:      (([ .[] | .message.usage.cache_read_input_tokens     // 0 ] | add) // 0),
                cache_creation:  (([ .[] | .message.usage.cache_creation_input_tokens // 0 ] | add) // 0),
                turn_count:      length
              })
            | sort_by(.first_seen)
        )
      }
')

# Scoped-v2 artifacts retain per-session counters. Merge prior reviewed
# sessions numerically without reopening their transcript files; replace the
# active session's prior row so repeated lifecycle tallies stay idempotent.
# Pre-v2 aggregates lack per-session counters and may contain the cwd-wide
# over-count, so the first scoped tally intentionally replaces them.
if [[ -n "$SESSION_ID" ]] && jq -e '
    (.orchestrator_tokens? // null) as $o
    | $o != null
      and ($o.sessions | type == "array")
      and ($o.sessions | all(
        has("total_input") and has("total_output")
        and has("cache_read") and has("cache_creation")
      ))
  ' "$ARTIFACT" >/dev/null 2>&1; then
    prior_json=$(jq -c '.orchestrator_tokens' "$ARTIFACT")
    tally_json=$(jq -cn \
        --argjson prior "$prior_json" \
        --argjson current "$tally_json" \
        --arg scoped_session_id "$SESSION_ID" '
        ($current.sessions | map(.session_id)) as $current_ids
        | (
            $prior.sessions
            | map(select(
                if $scoped_session_id != "" then
                    .session_id != $scoped_session_id
                else
                    .session_id as $id | ($current_ids | index($id)) == null
                end
              ))
          ) as $retained
        | (($retained + $current.sessions) | sort_by(.first_seen)) as $sessions
        | {
            total_input:    (([ $sessions[] | .total_input ] | add) // 0),
            total_output:   (([ $sessions[] | .total_output ] | add) // 0),
            cache_read:     (([ $sessions[] | .cache_read ] | add) // 0),
            cache_creation: (([ $sessions[] | .cache_creation ] | add) // 0),
            turn_count:     (([ $sessions[] | .turn_count ] | add) // 0),
            sessions:       $sessions
          }
      ')
fi

if [[ -z "$tally_json" ]]; then
    echo "ERROR: orchestrator tally produced empty output (jq failure?)" >&2
    echo "Action: inspect the selected Claude transcript JSONL for malformed lines." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -t orchestrator-tokens.XXXXXX)"
trap 'rm -f "$tmp"' EXIT
printf '%s\n' "$tally_json" > "$tmp"

"$SCRIPT_DIR/artifact-patch.py" \
    --path "$ARTIFACT" \
    --set-json "orchestrator_tokens=@$tmp" >/dev/null

total_input=$(printf '%s' "$tally_json" | jq -r '.total_input')
total_output=$(printf '%s' "$tally_json" | jq -r '.total_output')
cache_read=$(printf '%s' "$tally_json" | jq -r '.cache_read')
cache_creation=$(printf '%s' "$tally_json" | jq -r '.cache_creation')
turns=$(printf '%s' "$tally_json" | jq -r '.turn_count')
sessions=$(printf '%s' "$tally_json" | jq -r '.sessions | length')

echo "orchestrator-tally: total_input=${total_input} output=${total_output} cache_read=${cache_read} cache_creation=${cache_creation} turns=${turns} sessions=${sessions}"
