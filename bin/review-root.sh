#!/usr/bin/env bash
# review-root.sh — resolve the canonical matthewsreview state root.
#
# Precedence:
#   1. --path <absolute-path>
#   2. MATTHEWS_REVIEW_REVIEWS_ROOT
#   3. ADAMS_REVIEW_REVIEWS_ROOT (legacy env, with migration warning)
#   4. ~/.matthews-reviews when it exists
#   5. ~/.adams-reviews when it exists (with migration warning)
#   6. ~/.matthews-reviews for a new installation
#
# Prints exactly one normalized absolute path on stdout. Migration guidance
# goes to stderr so command substitution remains safe. Existing directories
# are physical-path canonicalized; nonexistent absolute roots remain valid for
# first-run creation.
set -u

usage() {
    printf '%s\n' "Usage: $(basename "$0") [--path <absolute-path>]" >&2
}

die_usage() {
    printf '%s\n' "ERROR: $1" >&2
    usage
    printf '%s\n' "Action: pass one absolute path with --path, or configure MATTHEWS_REVIEW_REVIEWS_ROOT." >&2
    exit 64
}

die_validation() {
    printf '%s\n' "ERROR: $1" >&2
    printf '%s\n' "Valid input: one absolute directory path; literal '~' and '~/' expand to HOME." >&2
    printf '%s\n' "Action: set MATTHEWS_REVIEW_REVIEWS_ROOT to an absolute path and retry." >&2
    exit 1
}

explicit_path=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --path)
            [[ $# -ge 2 && -n "${2:-}" ]] || die_usage "--path requires a value"
            explicit_path="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die_usage "unknown argument '$1'"
            ;;
    esac
done

if [[ -n "$explicit_path" ]]; then
    raw_path="$explicit_path"
elif [[ -n "${MATTHEWS_REVIEW_REVIEWS_ROOT:-}" ]]; then
    raw_path="$MATTHEWS_REVIEW_REVIEWS_ROOT"
elif [[ -n "${ADAMS_REVIEW_REVIEWS_ROOT:-}" ]]; then
    printf '%s\n' "migrate: rename ADAMS_REVIEW_REVIEWS_ROOT to MATTHEWS_REVIEW_REVIEWS_ROOT" >&2
    raw_path="$ADAMS_REVIEW_REVIEWS_ROOT"
elif [[ -d "$HOME/.matthews-reviews" ]]; then
    if [[ -d "$HOME/.adams-reviews" ]]; then
        printf '%s\n' \
            "WARNING: both ~/.matthews-reviews and ~/.adams-reviews exist; using ~/.matthews-reviews. Migrate or remove the legacy root to avoid split history." >&2
    fi
    raw_path="$HOME/.matthews-reviews"
elif [[ -d "$HOME/.adams-reviews" ]]; then
    printf '%s\n' "migrate: mv ~/.adams-reviews ~/.matthews-reviews" >&2
    raw_path="$HOME/.adams-reviews"
else
    raw_path="$HOME/.matthews-reviews"
fi

case "$raw_path" in
    *$'\n'*|*$'\r'*)
        die_validation "reviews root must be a single line"
        ;;
    "~")
        resolved_path="$HOME"
        ;;
    \~/*)
        resolved_path="$HOME/${raw_path#\~/}"
        ;;
    "~"*)
        die_validation "user-qualified tilde paths are not supported: '$raw_path'"
        ;;
    *)
        resolved_path="$raw_path"
        ;;
esac

[[ "$resolved_path" == /* ]] \
    || die_validation "reviews root must be absolute, got '$resolved_path'"

if [[ -e "$resolved_path" && ! -d "$resolved_path" ]]; then
    die_validation "reviews root exists but is not a directory: '$resolved_path'"
fi

if [[ -d "$resolved_path" ]]; then
    canonical_path=$(cd -P -- "$resolved_path" 2>/dev/null && pwd -P) \
        || die_validation "cannot access reviews root directory: '$resolved_path'"
    resolved_path="$canonical_path"
fi

printf '%s\n' "$resolved_path"
