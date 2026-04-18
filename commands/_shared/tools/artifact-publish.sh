#!/usr/bin/env bash
# artifact-publish.sh — rendered-report publisher (DESIGN §21.6, §13.4, §8.4).
#
# PR mode: post or edit the rendered `artifact.md` on a GitHub PR.
# Local mode: no-op. (Local-mode exists so the orchestrator can call
# this unconditionally in every mode.)
#
# Usage:
#   artifact-publish.sh --mode pr --review-id <id> --pr <num> --md-path <path>
#                       [--comment-id <n>] [--review-dir <path>]
#   artifact-publish.sh --mode local --review-id <id> [--review-dir <path>]
#
# Stage-1 note: --md-path is a Stage-1 extension. DESIGN §21.6 assumes
# latest.txt resolution (Phase 0, Stage 2); in Stage 1 we pass the .md
# path explicitly so the harness doesn't need to stub
# ~/.claude/reviews/<slug>/<branch>/latest.txt. Stage 2 will make
# --md-path optional with latest.txt fallback. This does not change the
# orchestrator-facing contract — callers that want latest.txt resolution
# simply omit --md-path in Stage 2.
#
# Comment discovery (§13.4, in order):
#   1. --comment-id passed → verify + PATCH.
#   2. Marker search: list PR issue-comments, filter to current gh user
#      + body contains `<!-- adams-review-v1 -->`, take most recent → PATCH
#      + emit {"comment_id": N} to stdout (orchestrator persists via
#      artifact-patch.py --set comment_id=N).
#   3. Create: POST new comment → emit {"comment_id": N}.
#   4. PATCH-fails fallback: POST new, log failure to trace.md, emit new id.
#
# Exits: 0 success; 1 gh/network error; 64 usage.

set -euo pipefail

usage() {
    cat >&2 <<USAGE
Usage:
  $(basename "$0") --mode pr    --review-id <id> --pr <num> --md-path <path> \\
                                [--comment-id <n>] [--review-dir <path>]
  $(basename "$0") --mode local --review-id <id> [--review-dir <path>]

Modes:
  pr     Post or edit the rendered artifact.md on a GitHub PR via gh.
         Requires --pr and --md-path. Comment discovery order:
         --comment-id → marker search → create. Emits {"comment_id": N}
         to stdout when a new comment is created or an existing one is
         located via marker search.
  local  No-op. If --review-dir is given, appends a one-line entry to
         <review-dir>/trace.md so the orchestrator's trace reflects
         that publish ran.
USAGE
}

die_usage() { echo "ERROR: $1" >&2; usage; exit 64; }

MODE=""
REVIEW_ID=""
PR_NUM=""
MD_PATH=""
COMMENT_ID=""
REVIEW_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode)       MODE="${2:-}"; shift 2 ;;
        --review-id)  REVIEW_ID="${2:-}"; shift 2 ;;
        --pr)         PR_NUM="${2:-}"; shift 2 ;;
        --md-path)    MD_PATH="${2:-}"; shift 2 ;;
        --comment-id) COMMENT_ID="${2:-}"; shift 2 ;;
        --review-dir) REVIEW_DIR="${2:-}"; shift 2 ;;
        -h|--help)    usage; exit 0 ;;
        *)            die_usage "unknown arg '$1'" ;;
    esac
done

[[ -n "$MODE" ]]      || die_usage "--mode is required (pr|local)"
[[ -n "$REVIEW_ID" ]] || die_usage "--review-id is required"

case "$MODE" in
    pr|local) : ;;
    *) die_usage "invalid --mode '$MODE' (valid: pr, local)" ;;
esac

# ------------------------------------------------------------------ helpers

trace_append() {
    # $1 = line to append
    [[ -n "$REVIEW_DIR" ]] || return 0
    mkdir -p "$REVIEW_DIR"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    {
        echo "## publish ($ts)"
        echo "$1"
        echo ""
    } >> "$REVIEW_DIR/trace.md"
}

emit_comment_id() {
    # $1 = numeric comment id. Emits a one-line JSON object to stdout
    # (DESIGN §21.6: "emit the comment id to stdout as {\"comment_id\": <n>}").
    printf '{"comment_id": %s}\n' "$1"
}

require_pr_args() {
    [[ -n "$PR_NUM" ]]   || die_usage "--pr is required when --mode=pr"
    [[ -n "$MD_PATH" ]]  || die_usage "--md-path is required when --mode=pr"
    [[ -f "$MD_PATH" ]]  || {
        echo "ERROR: --md-path file not found: $MD_PATH" >&2
        echo "Action: run artifact-render.py first to produce artifact.md." >&2
        exit 1
    }
}

gh_owner_repo() {
    # Returns "owner/name" via gh. Errors bubble up.
    gh repo view --json nameWithOwner -q .nameWithOwner
}

gh_current_user() {
    gh api user -q .login
}

# gh api with method + JSON body via stdin. $1=method, $2=path, $3=body-file.
gh_send_body() {
    local method="$1" path="$2" body_file="$3"
    gh api -X "$method" "$path" \
        -H "Accept: application/vnd.github+json" \
        --input "$body_file"
}

# ------------------------------------------------------------------ local mode

if [[ "$MODE" == "local" ]]; then
    trace_append "local mode, nothing to publish"
    exit 0
fi

# ------------------------------------------------------------------ pr mode

require_pr_args

OWNER_REPO=$(gh_owner_repo) || {
    echo "ERROR: could not resolve owner/repo via 'gh repo view'" >&2
    echo "Action: run 'gh auth login' and 'gh repo view' in this directory to verify." >&2
    exit 1
}
CURRENT_USER=$(gh_current_user) || {
    echo "ERROR: could not resolve current gh user via 'gh api user'" >&2
    echo "Action: run 'gh auth status' to verify authentication." >&2
    exit 1
}

# Build the JSON body once (GitHub comment PATCH/POST both take {"body": "..."}).
BODY_JSON=$(mktemp -t publish-body.XXXXXX)
trap 'rm -f "$BODY_JSON"' EXIT
jq -Rs '{body: .}' "$MD_PATH" > "$BODY_JSON"

patch_comment() {
    # $1 = comment id. Returns 0 on success.
    gh_send_body PATCH "repos/$OWNER_REPO/issues/comments/$1" "$BODY_JSON" > /dev/null
}

post_comment() {
    # Emits the new comment id to stdout on success.
    local new_id
    new_id=$(gh_send_body POST "repos/$OWNER_REPO/issues/$PR_NUM/comments" "$BODY_JSON" \
             | jq -r '.id')
    [[ -n "$new_id" && "$new_id" != "null" ]] || {
        echo "ERROR: POST succeeded but response had no .id field" >&2
        return 1
    }
    emit_comment_id "$new_id"
}

find_by_marker() {
    # Returns the most-recent matching comment id, or empty if none.
    # Filters: author == current gh user AND body contains the stable
    # marker line (§13.4).
    gh api --paginate "repos/$OWNER_REPO/issues/$PR_NUM/comments" \
        | jq -r --arg user "$CURRENT_USER" \
               --arg marker "<!-- adams-review-v1 -->" \
            '[.[] | select(.user.login == $user) | select(.body | contains($marker))]
             | sort_by(.created_at) | last | .id // empty'
}

# Step 1: --comment-id → PATCH directly (cheapest path, no list required).
if [[ -n "$COMMENT_ID" ]]; then
    if patch_comment "$COMMENT_ID"; then
        trace_append "patched comment_id=$COMMENT_ID (passed via --comment-id)"
        exit 0
    fi
    # PATCH fallback: comment deleted out-of-band. Fall through to create.
    trace_append "PATCH failed for comment_id=$COMMENT_ID — falling back to POST"
    if post_comment; then exit 0; fi
    echo "ERROR: PATCH failed and POST fallback also failed" >&2
    exit 1
fi

# Step 2: marker search → PATCH if found.
FOUND_ID=$(find_by_marker || true)
if [[ -n "$FOUND_ID" ]]; then
    if patch_comment "$FOUND_ID"; then
        emit_comment_id "$FOUND_ID"
        trace_append "patched comment_id=$FOUND_ID (found via marker search)"
        exit 0
    fi
    # PATCH fallback (rare: permissions, comment deleted between list and patch).
    trace_append "PATCH failed for comment_id=$FOUND_ID — falling back to POST"
fi

# Step 3: create new comment.
if post_comment; then
    trace_append "created new comment on PR #$PR_NUM"
    exit 0
fi

echo "ERROR: failed to publish comment (POST returned no id)" >&2
exit 1
