#!/usr/bin/env bash
# review-root.sh — resolve the canonical matthewsreview state root.
#
# Precedence:
#   1. MATTHEWS_REVIEW_REVIEWS_ROOT
#   2. ADAMS_REVIEW_REVIEWS_ROOT (legacy env, with migration warning)
#   3. ~/.matthews-reviews when it exists
#   4. ~/.adams-reviews when it exists (with migration warning)
#   5. ~/.matthews-reviews for a new installation
#
# Prints exactly one path on stdout. Migration guidance goes to stderr so
# command substitution remains safe.
set -u

if [[ $# -ne 0 ]]; then
    echo "ERROR: review-root.sh takes no arguments" >&2
    echo "Action: set MATTHEWS_REVIEW_REVIEWS_ROOT, then run review-root.sh." >&2
    exit 64
fi

if [[ -n "${MATTHEWS_REVIEW_REVIEWS_ROOT:-}" ]]; then
    printf '%s\n' "$MATTHEWS_REVIEW_REVIEWS_ROOT"
elif [[ -n "${ADAMS_REVIEW_REVIEWS_ROOT:-}" ]]; then
    echo "migrate: rename ADAMS_REVIEW_REVIEWS_ROOT to MATTHEWS_REVIEW_REVIEWS_ROOT" >&2
    printf '%s\n' "$ADAMS_REVIEW_REVIEWS_ROOT"
elif [[ -d "$HOME/.matthews-reviews" ]]; then
    printf '%s\n' "$HOME/.matthews-reviews"
elif [[ -d "$HOME/.adams-reviews" ]]; then
    echo "migrate: mv ~/.adams-reviews ~/.matthews-reviews" >&2
    printf '%s\n' "$HOME/.adams-reviews"
else
    printf '%s\n' "$HOME/.matthews-reviews"
fi
