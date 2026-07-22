#!/usr/bin/env bash
# smoke.sh — Stage 1 done-when walk-through (plan/stage-1-foundation.md §7).
#
# Exercises artifact-patch.py + artifact-render.py + every Bash helper
# against the hand-authored fixture under ./fixtures/. Each assertion
# prints `ok N: <label>` on success and `FAIL N: <label>` + the
# offending stderr on failure. Exits non-zero on first failure.
#
# Test artifacts live under /tmp/s1; trap cleans on exit unless
# SMOKE_KEEP=1 (for debugging).
#
# Usage:
#   ./test/smoke.sh                 # run from any cwd; paths are absolute
#   SMOKE_KEEP=1 ./test/smoke.sh    # keep /tmp/s1 for inspection

set -u   # intentionally no -e: we manage failures per-assertion
set -o pipefail

THIS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$THIS/.." && pwd)"
TOOLS="$REPO/bin"
FIX="$THIS/fixtures"

WORK=/tmp/s1
ART="$WORK/art.json"
MD="$WORK/art.md"

cleanup() {
    if [[ "${SMOKE_KEEP:-}" != "1" ]]; then
        rm -rf "$WORK"
    else
        echo "SMOKE_KEEP=1 → artifacts preserved under $WORK" >&2
    fi
}
trap cleanup EXIT

rm -rf "$WORK"
mkdir -p "$WORK"

# ---------------------------------------------------------------- helpers

N=0
FAIL=0

pass() { N=$((N+1)); printf 'ok %2d: %s\n' "$N" "$1"; }
fail() {
    N=$((N+1)); FAIL=1
    printf 'FAIL %2d: %s\n' "$N" "$1" >&2
    [[ -n "${2:-}" ]] && printf '       %s\n' "$2" >&2
    echo "smoke: FAIL (assertion $N)" >&2
    exit 1
}

# run command, capture exit; return the exit code as a string
rc() { ( "$@" >/dev/null 2>&1 ); printf '%s' "$?"; }

sha_of() { shasum "$1" | awk '{print $1}'; }

# ---------------------------------------------------------------- main 12

# 1. --init from seed
if "$TOOLS/artifact-patch.py" --init "@$FIX/artifact-seed.json" --path "$ART" >/dev/null; then
    pass "--init from seed produces valid artifact"
else
    fail "--init from seed" "exit=$?"
fi

# 2. --add-finding F099 (below_gate; schema-valid)
F099='{"id":"F099","sources":["detection"],"source_families":["code-review"],"impact_type":"correctness","origin":"introduced_by_pr","origin_confidence":"low","actionability":"report_only","validation_lane":"deep","current_state":"open","disposition":"below_gate","is_actionable":false,"reason":null,"confirmed_strength":null,"file":"src/misc/flake.ts","line_range":[1,1],"claim":"Minor below threshold","score_phase3":30,"score_phase4":30,"score_history":[{"phase":"phase_3","score":30},{"phase":"phase_4","score":30}],"validation_result":null,"fix_attempts":[],"introduced_in_sha":null,"suggested_follow_up":null,"related_parent_finding_id":null}'
if "$TOOLS/artifact-patch.py" --path "$ART" --add-finding "$F099" >/dev/null; then
    pass "--add-finding F099 succeeds"
else
    fail "--add-finding F099"
fi

# 2b. --add-finding F100 (disproven; schema-valid). Pairs with F099 to exercise
# both halves of render_summary's "Filtered out:" bullet (Y2 regression guard
# below for the Xilem #1791 silent-drop class). Not in the seed itself —
# AF-* assertions hardcode the seed ID list, so introducing it here keeps
# their fixtures clean.
F100='{"id":"F100","sources":["detection"],"source_families":["code-review"],"impact_type":"correctness","origin":"introduced_by_pr","origin_confidence":"medium","actionability":"report_only","validation_lane":"deep","current_state":"open","disposition":"disproven","is_actionable":false,"reason":"Phase 4 validation refuted the claim against the actual code","confirmed_strength":null,"file":"src/auth/session.ts","line_range":[10,10],"claim":"Race condition on session refresh","score_phase3":65,"score_phase4":25,"score_history":[{"phase":"phase_3","score":65},{"phase":"phase_4","score":25}],"validation_result":null,"fix_attempts":[],"introduced_in_sha":null,"suggested_follow_up":null,"related_parent_finding_id":null}'
if "$TOOLS/artifact-patch.py" --path "$ART" --add-finding "$F100" >/dev/null; then
    pass "--add-finding F100 (disproven) succeeds"
else
    fail "--add-finding F100"
fi

# 3. standalone validate
if "$TOOLS/artifact-validate.sh" --path "$ART" >/dev/null; then
    pass "artifact-validate.sh reports valid"
else
    fail "artifact-validate.sh --path $ART"
fi

# 4. open → resolved must fail with exit 2 (invalid transition)
code=$(rc "$TOOLS/artifact-patch.py" --path "$ART" --finding-id F001 --set current_state=resolved)
if [[ "$code" == "2" ]]; then
    pass "open→resolved rejected with exit 2"
else
    fail "open→resolved should exit 2, got $code"
fi

# 5. open → attempted succeeds
if "$TOOLS/artifact-patch.py" --path "$ART" --finding-id F001 --set current_state=attempted >/dev/null; then
    pass "open→attempted succeeds"
else
    fail "open→attempted"
fi

# 6. attempted → resolved alone (without disposition=resolved) must fail coupling (exit 1)
code=$(rc "$TOOLS/artifact-patch.py" --path "$ART" --finding-id F001 --set current_state=resolved)
if [[ "$code" == "1" ]]; then
    pass "attempted→resolved without disposition rejected (coupling, exit 1)"
else
    fail "attempted→resolved alone should exit 1, got $code"
fi

# 7. attempted → resolved WITH disposition=resolved in same call succeeds
if "$TOOLS/artifact-patch.py" --path "$ART" --finding-id F001 \
        --set current_state=resolved --set disposition=resolved >/dev/null; then
    pass "current_state=resolved + disposition=resolved succeeds"
else
    fail "coupled resolve"
fi

# 8. --append-fix-attempt (append; not replace)
ATT='{"run_id":"fixrun_stage1smoke","timestamp":"2026-04-17T21:30:00Z","fix_group_id":"FG-1","input_sha":"abcdef0123","output_sha":"fedcba9876","phase_9_outcome":"verified"}'
if "$TOOLS/artifact-patch.py" --path "$ART" --finding-id F001 --append-fix-attempt "$ATT" >/dev/null; then
    # verify length == 1
    len=$(jq '.findings[] | select(.id=="F001") | .fix_attempts | length' "$ART")
    if [[ "$len" == "1" ]]; then
        pass "--append-fix-attempt appended exactly one attempt to F001"
    else
        fail "fix_attempts length should be 1, got $len"
    fi
else
    fail "--append-fix-attempt"
fi

# 9. render and diff against expected.md
if "$TOOLS/artifact-render.py" --input "$ART" --output "$MD" >/dev/null; then
    if diff -u "$FIX/expected.md" "$MD" >/dev/null; then
        pass "rendered markdown matches expected.md"
    else
        diff -u "$FIX/expected.md" "$MD" >&2 || true
        fail "rendered markdown differs from expected.md (see diff above)"
    fi
else
    fail "artifact-render.py"
fi

# 10. bad disposition value — schema violation
stderr=$("$TOOLS/artifact-patch.py" --path "$ART" --finding-id F099 --set disposition=bogus 2>&1 >/dev/null); code=$?
if [[ "$code" != "0" ]] && echo "$stderr" | grep -q "schema violation"; then
    pass "bad disposition rejected with schema-violation error-as-prompt"
else
    fail "bad disposition test: exit=$code, stderr lacked 'schema violation'" "$stderr"
fi

# 11. is_actionable/disposition coupling violation
stderr=$("$TOOLS/artifact-patch.py" --path "$ART" --finding-id F099 --set is_actionable=true --set disposition=below_gate 2>&1 >/dev/null); code=$?
if [[ "$code" != "0" ]] && echo "$stderr" | grep -q "is_actionable"; then
    pass "is_actionable/disposition mismatch rejected with coupling error-as-prompt"
else
    fail "coupling test: exit=$code, stderr lacked 'is_actionable'" "$stderr"
fi

# 12. --dry-run on invalid input: non-zero AND artifact on disk unchanged
SHA_BEFORE=$(sha_of "$ART")
code=$(rc "$TOOLS/artifact-patch.py" --path "$ART" --finding-id F001 --set current_state=bogus --dry-run)
SHA_AFTER=$(sha_of "$ART")
if [[ "$code" != "0" ]] && [[ "$SHA_BEFORE" == "$SHA_AFTER" ]]; then
    pass "--dry-run on invalid exits non-zero and leaves artifact unchanged"
else
    fail "--dry-run test: exit=$code, sha_before=$SHA_BEFORE sha_after=$SHA_AFTER"
fi

# ---------------------------------------------------------------- sidecars

# A. artifact-read.sh --summary returns expected counts
expected_counts='{"findings_total":8,"by_disposition":{"below_gate":1,"confirmed_manual":1,"confirmed_mechanical":1,"disproven":1,"pre_existing_report":1,"resolved":1,"uncertain":2}}'
# NB: --add-finding F100 in step 2b below introduces the disproven case.
# AF-* assertions further down init their own copies from the same seed
# (without that step), so leaving disproven out of the seed itself keeps
# their hardcoded ID lists (F001..F006 + F1xx) accurate.
actual=$("$TOOLS/artifact-read.sh" --path "$ART" --summary \
    | jq -c '{findings_total, by_disposition: .counts_by_disposition}')
if [[ "$actual" == "$expected_counts" ]]; then
    pass "A: artifact-read.sh --summary counts match"
else
    fail "A: summary counts mismatch" "expected=$expected_counts actual=$actual"
fi

# AR-1: artifact-read.sh emits JSON-encoded backslashes that survive a
# downstream pipe under shells that interpret `\\` in echo (zsh, dash,
# bash with xpg_echo). Pre-fix the helper used `echo "$result"`, which
# collapses `\\d` → `\d` and parse-errors the next jq.
#
# Invocation note: `bash -O xpg_echo -c "$helper | jq …"` only enables
# xpg_echo on the wrapper bash; the helper's #!/usr/bin/env bash shebang
# spawns a fresh bash with default options, so the helper's internal
# `echo` never sees xpg_echo and the test passes even when broken.
# Instead, invoke the helper as `bash -O xpg_echo <script>` — that
# bypasses the shebang and runs the helper's body in the xpg_echo bash.
# Verified: pre-fix this triggers `jq: parse error: Invalid escape`;
# post-fix the value round-trips. AR-1b adds a structural pin so a
# revert from `printf` to `echo` is caught even if the runtime path
# stops triggering for environment reasons.
AR_ART="$WORK/art-ar1.json"
cp "$ART" "$AR_ART"
"$TOOLS/artifact-patch.py" --path "$AR_ART" --finding-id F001 \
    --set 'reason=use \d for digit class' >/dev/null
ar1_out=$(bash -O xpg_echo "$TOOLS/artifact-read.sh" \
    --path "$AR_ART" --finding-id F001 \
    | jq -r '.reason' 2>&1)
if [[ "$ar1_out" == 'use \d for digit class' ]]; then
    pass "AR-1: artifact-read.sh round-trips backslash content under xpg_echo bash"
else
    fail "AR-1: backslash mangled in artifact-read.sh single-finding emit" "out=$ar1_out"
fi

# AR-1b: structural regression pin — single-finding emission must use printf,
# not echo. Catches a code revert even if a future host shell stops triggering
# AR-1's runtime path (e.g., bash binary built without xpg_echo support).
if grep -qE "^[[:space:]]+printf '%s\\\\n' \"\\\$result\"" "$TOOLS/artifact-read.sh"; then
    pass "AR-1b: artifact-read.sh single-finding emits via printf (structural pin)"
else
    fail "AR-1b: artifact-read.sh single-finding emit reverted away from printf"
fi

# B. artifact-publish.sh local no-op
mkdir -p "$WORK/pub"
if "$TOOLS/artifact-publish.sh" --mode local --review-id rev_stage1smoke --review-dir "$WORK/pub" >/dev/null; then
    if grep -q "local mode, nothing to publish" "$WORK/pub/trace.md"; then
        pass "B: publish --mode local appends trace line and exits 0"
    else
        fail "B: publish --mode local did not write trace line"
    fi
else
    fail "B: publish --mode local exit non-zero"
fi

# B2. publish with bogus mode → 64
code=$(rc "$TOOLS/artifact-publish.sh" --mode bogus --review-id rev_x)
if [[ "$code" == "64" ]]; then
    pass "B2: publish --mode bogus rejected with exit 64"
else
    fail "B2: publish --mode bogus should exit 64, got $code"
fi

# B3. publish --mode pr with no md source → non-zero + "cannot resolve md path"
stderr=$("$TOOLS/artifact-publish.sh" --mode pr --review-id rev_x --pr 1 --dry-run 2>&1 >/dev/null); code=$?
if [[ "$code" != "0" ]] && echo "$stderr" | grep -q "cannot resolve md path"; then
    pass "B3: publish --mode pr with no md source rejected with resolution error"
else
    fail "B3: expected non-zero + 'cannot resolve md path', got code=$code stderr=$stderr"
fi

# B4. publish --mode pr --dry-run with latest.txt resolves + prints path
FAKE_ROOT="$WORK/reviews"
mkdir -p "$FAKE_ROOT/fake-slug/fake-branch/rev_fake"
echo "rev_fake" > "$FAKE_ROOT/fake-slug/fake-branch/latest.txt"
echo "# rendered" > "$FAKE_ROOT/fake-slug/fake-branch/rev_fake/artifact.md"
out=$(MATTHEWS_REVIEW_REVIEWS_ROOT="$FAKE_ROOT" "$TOOLS/artifact-publish.sh" \
        --mode pr --review-id rev_fake --pr 1 \
        --repo-slug fake-slug --branch fake-branch --dry-run 2>&1); code=$?
expected_path="$(cd "$FAKE_ROOT" && pwd -P)/fake-slug/fake-branch/rev_fake/artifact.md"
if [[ "$code" == "0" ]] && [[ "$out" == "$expected_path" ]]; then
    pass "B4: publish --dry-run resolves latest.txt → $expected_path"
else
    fail "B4: dry-run resolution mismatch" "code=$code out=$out expected=$expected_path"
fi

# B5. publish --mode pr with latest.txt disagreeing with --review-id → non-zero + staleness note
stderr=$(MATTHEWS_REVIEW_REVIEWS_ROOT="$FAKE_ROOT" "$TOOLS/artifact-publish.sh" \
        --mode pr --review-id rev_stale --pr 1 \
        --repo-slug fake-slug --branch fake-branch --dry-run 2>&1 >/dev/null); code=$?
if [[ "$code" != "0" ]] && echo "$stderr" | grep -q "latest.txt points to review_id='rev_fake'"; then
    pass "B5: publish rejects --review-id mismatch against latest.txt"
else
    fail "B5: expected staleness error, got code=$code stderr=$stderr"
fi

# B6. publish default root (no MATTHEWS_REVIEW_REVIEWS_ROOT override) → ~/.matthews-reviews.
# Stage 2.5.A relocated the default root outside ~/.claude/ so that Claude Code's
# hardcoded sensitive-file gate for ~/.claude/... paths doesn't fire. Assert the
# new default by triggering a latest.txt-not-found error against a slug guaranteed
# not to exist under the real home dir; the error message names the resolved path
# so we can grep for ~/.matthews-reviews without polluting actual state.
ghost_slug="matthews-review-smoke-missing-$$-$(date +%s)"
# Isolate HOME so a real ~/.adams-reviews on the machine can't trip the
# legacy-state fallback and shadow the default-root assertion.
B6_HOME="$WORK/b6home"
mkdir -p "$B6_HOME"
stderr=$(env -u MATTHEWS_REVIEW_REVIEWS_ROOT -u ADAMS_REVIEW_REVIEWS_ROOT HOME="$B6_HOME" "$TOOLS/artifact-publish.sh" \
        --mode pr --review-id rev_ghost --pr 1 \
        --repo-slug "$ghost_slug" --branch ghost-branch --dry-run 2>&1 >/dev/null); code=$?
if [[ "$code" != "0" ]] && echo "$stderr" | grep -q "\.matthews-reviews/$ghost_slug/ghost-branch/latest.txt"; then
    pass "B6: publish default reviews root resolves under ~/.matthews-reviews (Stage 2.5.A)"
else
    fail "B6: expected error naming ~/.matthews-reviews/$ghost_slug/ghost-branch/latest.txt; code=$code stderr=$stderr"
fi

# B7. publish honors legacy ADAMS_REVIEW_REVIEWS_ROOT when the new var is unset
# (backward-compat fallback; FAKE_ROOT fixture from B4 reused).
out=$(env -u MATTHEWS_REVIEW_REVIEWS_ROOT ADAMS_REVIEW_REVIEWS_ROOT="$FAKE_ROOT" "$TOOLS/artifact-publish.sh" \
        --mode pr --review-id rev_fake --pr 1 \
        --repo-slug fake-slug --branch fake-branch --dry-run 2>/dev/null); code=$?
if [[ "$code" == "0" ]] && [[ "$out" == "$expected_path" ]]; then
    pass "B7: publish falls back to ADAMS_REVIEW_REVIEWS_ROOT when MATTHEWS_REVIEW_REVIEWS_ROOT unset"
else
    fail "B7: legacy env-var fallback mismatch" "code=$code out=$out expected=$expected_path"
fi

# B8. publish falls back to legacy ~/.adams-reviews state root (with migrate
# nudge) when neither env var is set and only the legacy dir exists.
LEGACY_HOME="$WORK/legacyhome"
mkdir -p "$LEGACY_HOME/.adams-reviews/fake-slug/fake-branch/rev_fake"
echo "rev_fake" > "$LEGACY_HOME/.adams-reviews/fake-slug/fake-branch/latest.txt"
echo "# rendered" > "$LEGACY_HOME/.adams-reviews/fake-slug/fake-branch/rev_fake/artifact.md"
out=$(env -u MATTHEWS_REVIEW_REVIEWS_ROOT -u ADAMS_REVIEW_REVIEWS_ROOT HOME="$LEGACY_HOME" "$TOOLS/artifact-publish.sh" \
        --mode pr --review-id rev_fake --pr 1 \
        --repo-slug fake-slug --branch fake-branch --dry-run 2>&1); code=$?
if [[ "$code" == "0" ]] && echo "$out" | grep -q "migrate: mv" && echo "$out" | grep -q "\.adams-reviews/fake-slug/fake-branch/rev_fake/artifact.md"; then
    pass "B8: publish falls back to ~/.adams-reviews with migrate nudge when no root configured"
else
    fail "B8: legacy dir fallback mismatch" "code=$code out=$out"
fi

# B8a. review-root.sh is the single normalization boundary: existing
# directories canonicalize, literal ~/ expands, and unsafe roots fail without
# stdout so command substitutions cannot continue with split/cwd-relative state.
mkdir -p "$WORK/review-root-real"
ln -s "$WORK/review-root-real" "$WORK/review-root-link"
root_expected=$(cd "$WORK/review-root-real" && pwd -P)
root_canonical=$("$TOOLS/review-root.sh" --path "$WORK/review-root-link" 2>/dev/null)
root_tilde=$(HOME="$B6_HOME" "$TOOLS/review-root.sh" --path '~/first-run' 2>/dev/null)
root_relative=$(
    MATTHEWS_REVIEW_REVIEWS_ROOT=relative "$TOOLS/review-root.sh" \
        2>"$WORK/review-root-relative.err"
)
root_relative_rc=$?
root_multiline=$(
    MATTHEWS_REVIEW_REVIEWS_ROOT=$'bad\npath' "$TOOLS/review-root.sh" \
        2>"$WORK/review-root-multiline.err"
)
root_multiline_rc=$?
if [[ "$root_canonical" == "$root_expected" \
   && "$root_tilde" == "$B6_HOME/first-run" \
   && "$root_relative_rc" -eq 1 && -z "$root_relative" \
   && "$root_multiline_rc" -eq 1 && -z "$root_multiline" \
   && "$(cat "$WORK/review-root-relative.err")" == *"ERROR:"* \
   && "$(cat "$WORK/review-root-multiline.err")" == *"Action:"* ]]; then
    pass "B8a (F095): canonical review root expands/canonicalizes safe paths and rejects relative/multiline roots"
else
    fail "B8a: review-root normalization contract failed" \
      "canonical=$root_canonical expected=$root_expected tilde=$root_tilde relative=$root_relative_rc:$root_relative multiline=$root_multiline_rc:$root_multiline"
fi

# B8b. Publisher consumes the canonical helper rather than accepting a
# cwd-relative root through an independent fallback.
publish_relative=$(
    MATTHEWS_REVIEW_REVIEWS_ROOT=relative "$TOOLS/artifact-publish.sh" \
        --mode pr --review-id rev_fake --pr 1 \
        --repo-slug fake-slug --branch fake-branch --dry-run \
        2>"$WORK/publish-relative.err"
)
publish_relative_rc=$?
if [[ "$publish_relative_rc" -eq 1 && -z "$publish_relative" \
   && "$(cat "$WORK/publish-relative.err")" == *"must be absolute"* ]]; then
    pass "B8b (F095): publisher rejects a relative configured reviews root"
else
    fail "B8b: publisher bypassed canonical reviews-root validation" \
      "code=$publish_relative_rc out=$publish_relative err=$(cat "$WORK/publish-relative.err")"
fi

# B8c. Calibration delegates both explicit and configured roots to the same
# helper, so symlink canonicalization and unsafe-input rejection cannot diverge
# from publication.
calibration_link=$(
    "$TOOLS/calibration-report.py" "$WORK/review-root-link" \
        2>"$WORK/calibration-link.err"
)
calibration_link_rc=$?
calibration_relative=$(
    MATTHEWS_REVIEW_REVIEWS_ROOT=relative "$TOOLS/calibration-report.py" \
        2>"$WORK/calibration-relative.err"
)
calibration_relative_rc=$?
if [[ "$calibration_link_rc" -eq 1 && -z "$calibration_link" \
   && "$(cat "$WORK/calibration-link.err")" == *"no runs found under $root_expected"* \
   && "$calibration_relative_rc" -eq 1 && -z "$calibration_relative" \
   && "$(cat "$WORK/calibration-relative.err")" == *"must be absolute"* ]]; then
    pass "B8c (F095): calibration and publisher share canonical reviews-root semantics"
else
    fail "B8c: calibration bypassed canonical reviews-root validation" \
      "link=$calibration_link_rc:$calibration_link:$(cat "$WORK/calibration-link.err") relative=$calibration_relative_rc:$calibration_relative:$(cat "$WORK/calibration-relative.err")"
fi

# B9. Oversized PR reports are compacted before sending to GitHub. The full
# artifact.md remains intact; published.md records the exact body sent.
PUBLISH_STUB_BIN="$WORK/publish-stub-bin"
PUBLISH_CAPTURE="$WORK/publish-capture.md"
mkdir -p "$PUBLISH_STUB_BIN"
cat > "$PUBLISH_STUB_BIN/gh" <<'SH'
#!/usr/bin/env bash
set -eu
if [[ "${1:-}" == "repo" && "${2:-}" == "view" ]]; then
    printf 'example/repo\n'
    exit 0
fi
if [[ "${1:-}" == "api" ]]; then
    input=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --input) input="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    jq -j '.body' "$input" > "$PUBLISH_CAPTURE"
    printf '{"id":9001}\n'
    exit 0
fi
printf 'unexpected gh invocation: %s\n' "$*" >&2
exit 2
SH
chmod +x "$PUBLISH_STUB_BIN/gh"

BIG_PUB_DIR="$WORK/pub-big"
mkdir -p "$BIG_PUB_DIR"
cp "$ART" "$BIG_PUB_DIR/artifact.json"
awk 'BEGIN { for (i = 0; i < 70000; i++) printf "x"; printf "\n" }' \
    > "$BIG_PUB_DIR/artifact.md"
big_artifact_sha=$(sha_of "$BIG_PUB_DIR/artifact.md")
b9_out=$(PATH="$PUBLISH_STUB_BIN:$PATH" PUBLISH_CAPTURE="$PUBLISH_CAPTURE" \
    "$TOOLS/artifact-publish.sh" \
    --mode pr --review-id rev_stage1smoke --pr 9 \
    --review-dir "$BIG_PUB_DIR" 2>"$WORK/b9.err"); code=$?
b9_bytes=$(wc -c < "$BIG_PUB_DIR/published.md" 2>/dev/null | tr -d '[:space:]')
if [[ "$code" == "0" ]] \
    && [[ "$b9_out" == '{"comment_id": 9001}' ]] \
    && [[ -n "$b9_bytes" && "$b9_bytes" -le 65536 ]] \
    && cmp -s "$PUBLISH_CAPTURE" "$BIG_PUB_DIR/published.md" \
    && [[ "$(sha_of "$BIG_PUB_DIR/artifact.md")" == "$big_artifact_sha" ]] \
    && grep -Fq '<!-- matthews-review-v1 -->' "$BIG_PUB_DIR/published.md" \
    && grep -Fq 'Full sectioned report exceeded GitHub' "$BIG_PUB_DIR/published.md" \
    && grep -Fq 'compact_fallback' "$BIG_PUB_DIR/trace.md"; then
    pass "B9: oversized report publishes bounded compact body and preserves full artifact.md"
else
    fail "B9: oversized report fallback failed" \
        "code=$code out=$b9_out bytes=${b9_bytes:-missing} stderr=$(cat "$WORK/b9.err")"
fi

# B10. Small PR reports still publish byte-for-byte and published.md mirrors
# the exact body sent, so chat can mirror the actual PR comment.
SMALL_PUB_DIR="$WORK/pub-small"
mkdir -p "$SMALL_PUB_DIR"
printf '<!-- matthews-review-v1 -->\n\n# Small report\n' \
    > "$SMALL_PUB_DIR/artifact.md"
PUBLISH_CAPTURE="$WORK/publish-small-capture.md"
b10_out=$(PATH="$PUBLISH_STUB_BIN:$PATH" PUBLISH_CAPTURE="$PUBLISH_CAPTURE" \
    "$TOOLS/artifact-publish.sh" \
    --mode pr --review-id rev_small --pr 10 \
    --review-dir "$SMALL_PUB_DIR" 2>"$WORK/b10.err"); code=$?
if [[ "$code" == "0" ]] \
    && [[ "$b10_out" == '{"comment_id": 9001}' ]] \
    && cmp -s "$SMALL_PUB_DIR/artifact.md" "$SMALL_PUB_DIR/published.md" \
    && cmp -s "$PUBLISH_CAPTURE" "$SMALL_PUB_DIR/published.md"; then
    pass "B10: small report publishes unchanged and persists exact published.md"
else
    fail "B10: small report publication mirror mismatch" \
        "code=$code out=$b10_out stderr=$(cat "$WORK/b10.err")"
fi

# B11. The compact renderer enforces its byte budget even when not called
# through artifact-publish.sh.
B11_MD="$WORK/pr-comment-bounded.md"
if "$TOOLS/artifact-render.py" \
    --input "$ART" --format pr-comment --max-bytes 1024 \
    --output "$B11_MD" >/dev/null 2>"$WORK/b11.err"; then
    b11_bytes=$(wc -c < "$B11_MD" | tr -d '[:space:]')
    if [[ "$b11_bytes" -le 1024 ]] \
        && grep -Fq '<!-- matthews-review-v1 -->' "$B11_MD" \
        && grep -Fq 'omitted from this compact comment' "$B11_MD"; then
        pass "B11: compact PR renderer stays within byte budget and reports omissions"
    else
        fail "B11: compact PR renderer violated budget or hid omissions" \
            "bytes=$b11_bytes body=$(cat "$B11_MD")"
    fi
else
    fail "B11: compact PR renderer failed" "stderr=$(cat "$WORK/b11.err")"
fi

# B12. Review finalization and post-fix output mirror the exact successful PR
# publication body, while local/failed publication retains full artifact.md.
if grep -Fq '$review_dir/published.md' "$REPO/fragments/07-finalize.md" \
    && grep -Fq 'successful PR publication' "$REPO/fragments/07-finalize.md" \
    && grep -Fq '$review_dir/published.md' "$REPO/fragments/10-post-fix-and-commit.md" \
    && grep -Fq 'successful PR publication' "$REPO/fragments/10-post-fix-and-commit.md"; then
    pass "B12: final review and post-fix chat mirror exact successful PR publication body"
else
    fail "B12: lifecycle prompts do not mirror published.md after successful PR publication"
fi

# OC. Fresh-run-won't-overwrite (DESIGN §13.4, rev 7).
# The publisher no longer auto-discovers a prior comment by marker. Each
# command carries its own continuation intent: fresh /matthewsreview:review
# omits --comment-id (→ POST); /matthewsreview:fix and /matthewsreview:promote
# pass --comment-id read from the artifact (→ PATCH).

# OC-1: find_by_marker function is gone from the publisher.
if grep -q 'find_by_marker' "$TOOLS/artifact-publish.sh"; then
    fail "OC-1: artifact-publish.sh still references find_by_marker"
else
    pass "OC-1: artifact-publish.sh no longer contains find_by_marker"
fi

# OC-2: gh_current_user helper is gone (tier-2 was its only caller).
if grep -q 'gh_current_user' "$TOOLS/artifact-publish.sh"; then
    fail "OC-2: artifact-publish.sh still references gh_current_user"
else
    pass "OC-2: artifact-publish.sh no longer resolves current gh user"
fi

# OC-3: help text no longer lists 'marker search' as an active
# discovery step. The header's negative reference ("never auto-discovers
# ... via marker search") is fine — it's documentation of what the
# publisher deliberately doesn't do. Scope the check to the usage block.
usage_txt=$("$TOOLS/artifact-publish.sh" --help 2>&1)
if echo "$usage_txt" | grep -qi 'marker search'; then
    fail "OC-3: --help usage still documents 'marker search' tier"
else
    pass "OC-3: --help usage documents two-tier discovery only"
fi

# OC-4: --comment-id path still present (tier 1 intact).
if grep -q '\-\-comment-id' "$TOOLS/artifact-publish.sh" \
   && grep -q 'patch_comment "$COMMENT_ID"' "$TOOLS/artifact-publish.sh"; then
    pass "OC-4: artifact-publish.sh --comment-id → PATCH path preserved"
else
    fail "OC-4: --comment-id PATCH path missing"
fi

# OC-5: publisher still lints clean after the removal.
if bash -n "$TOOLS/artifact-publish.sh" 2>/dev/null; then
    pass "OC-5: artifact-publish.sh is syntactically valid after tier-2 removal"
else
    fail "OC-5: artifact-publish.sh has syntax errors"
fi

# OC-6: DESIGN §13.4 documents the new rule (fresh /matthewsreview:review POSTs).
# Path repointed to docs/archive/ after the 2026-04-19 docs-consolidation move.
if grep -q 'always .POST. a new comment' "$REPO/docs/archive/DESIGN.md"; then
    pass "OC-6: DESIGN §13.4 documents fresh-/matthewsreview:review-POSTs rule"
else
    fail "OC-6: DESIGN §13.4 missing new POST-on-fresh-review rule"
fi

# C. claude-md-paths synthetic tree: root + a/CLAUDE.md expected, root-first
mkdir -p "$WORK/cm/a/b" "$WORK/cm/a/c"
touch "$WORK/cm/CLAUDE.md" "$WORK/cm/a/CLAUDE.md" "$WORK/cm/a/b/file.ts" "$WORK/cm/a/c/file.ts"
actual=$("$TOOLS/claude-md-paths.sh" --repo-root "$WORK/cm" --files "a/b/file.ts,a/c/file.ts")
# realpath via `cd && pwd -P` — match the script's resolved form
resolved_root=$(cd "$WORK/cm" && pwd -P)
expected_cm="$resolved_root/CLAUDE.md
$resolved_root/a/CLAUDE.md"
if [[ "$actual" == "$expected_cm" ]]; then
    pass "C: claude-md-paths.sh deduped and root-first sorted"
else
    fail "C: claude-md-paths output mismatch" "expected=$expected_cm | actual=$actual"
fi

# D. staleness: safe / warn / unsafe on throwaway repo
mkdir -p "$WORK/repo"
(
    cd "$WORK/repo"
    git init -q -b main
    git config user.email smoke@example.com
    git config user.name smoke
    echo one > foo.txt
    echo one > bar.txt
    git add . && git commit -q -m c1
    SHA1=$(git rev-parse HEAD)
    # safe
    [[ "$("$TOOLS/staleness.sh" --reviewed-sha "$SHA1" --reviewed-files foo.txt,bar.txt)" == "safe" ]] || exit 10
    # warn
    echo two > bar.txt && git commit -q -am c2
    out=$("$TOOLS/staleness.sh" --reviewed-sha "$SHA1" --reviewed-files foo.txt) || exit 11
    [[ "$out" == warn:* ]] || exit 12
    # unsafe
    echo two > foo.txt && git commit -q -am c3
    err=$("$TOOLS/staleness.sh" --reviewed-sha "$SHA1" --reviewed-files foo.txt 2>&1); code=$?
    [[ "$code" != "0" ]] || exit 13
    [[ "$err" == unsafe:* && "$err" == *$'\nERROR:'* && "$err" == *$'\nAction:'* ]] || exit 14
)
subrc=$?
if [[ "$subrc" == "0" ]]; then
    pass "D: staleness safe / warn / unsafe all classified correctly"
else
    fail "D: staleness subtest failure code=$subrc"
fi

# E. log-phase.sh --record + log-tokens.sh produce valid JSONL
# Covers both numeric and string-bucket phase values (e.g. "1_5" for
# Phase 1.5 per §11 conventions).
mkdir -p "$WORK/rev"
"$TOOLS/log-phase.sh" --review-dir "$WORK/rev" --phase 6 --name detection --summary "smoke" --elapsed 5
"$TOOLS/log-phase.sh" --review-dir "$WORK/rev" --phase 6 --record '{"name":"detection","elapsed_sec":5}'
"$TOOLS/log-phase.sh" --review-dir "$WORK/rev" --phase 1_5 --record '{"name":"ensemble-adapter","elapsed_sec":7}'
"$TOOLS/log-tokens.sh" --review-dir "$WORK/rev" --phase phase_3 --agent-role validator --agent-id ag_abc --model opus --tokens 12345 --finding-id F001
# Verify both records landed; the 1_5 entry should keep phase as the
# literal string.
phase_1_5_phase=$(jq -r 'select(.name == "ensemble-adapter") | .phase' "$WORK/rev/phases.jsonl" | head -1)
phase_6_phase=$(jq -r 'select(.name == "detection") | .phase' "$WORK/rev/phases.jsonl" | head -1)
if jq -e . "$WORK/rev/phases.jsonl" >/dev/null \
        && jq -e . "$WORK/rev/tokens.jsonl" >/dev/null \
        && grep -q "## Phase 6 — detection" "$WORK/rev/trace.md" \
        && [[ "$phase_1_5_phase" == "1_5" ]] \
        && [[ "$phase_6_phase" == "6" ]]; then
    pass "E: log-phase accepts numeric + string phases; tokens/phases JSONL valid"
else
    fail "E: phase_1_5=$phase_1_5_phase phase_6=$phase_6_phase; check $WORK/rev/phases.jsonl"
fi

# E2. Phase 3 telemetry payload shape (#24 calibration): demote_rate float
# and score_phase3_histogram (10 buckets) land in phases.jsonl via --record
# pass-through. Sanity-check that log-phase.sh carries arbitrary JSON
# payloads through unchanged, so the fragments/04-scoring-gate.md wiring
# doesn't need a bespoke helper.
p3_record=$(jq -nc \
    --argjson hist '{"0-9":1,"10-19":2,"20-29":3,"30-39":2,"40-49":4,"50-59":3,"60-69":5,"70-79":4,"80-89":2,"90-100":1}' \
    '{name:"scoring-gate", elapsed_sec:42, demote_rate:0.6486486486486487, score_phase3_histogram:$hist}')
"$TOOLS/log-phase.sh" --review-dir "$WORK/rev" --phase 3 --record "$p3_record"
p3_demote=$(jq -r 'select(.name == "scoring-gate" and .phase == 3) | .demote_rate' "$WORK/rev/phases.jsonl" | head -1)
p3_hist_keys=$(jq -r 'select(.name == "scoring-gate" and .phase == 3) | .score_phase3_histogram | keys | length' "$WORK/rev/phases.jsonl" | head -1)
p3_bucket_90_100=$(jq -r 'select(.name == "scoring-gate" and .phase == 3) | .score_phase3_histogram["90-100"]' "$WORK/rev/phases.jsonl" | head -1)
if [[ "$p3_demote" == "0.6486486486486487" ]] \
        && [[ "$p3_hist_keys" == "10" ]] \
        && [[ "$p3_bucket_90_100" == "1" ]]; then
    pass "E2: Phase 3 phases.jsonl record carries demote_rate + score_phase3_histogram (#24 telemetry)"
else
    fail "E2: phase 3 telemetry shape wrong — demote_rate=$p3_demote hist_keys=$p3_hist_keys bucket_90_100=$p3_bucket_90_100"
fi

# F. Schema-invalid fixture rejected by artifact-validate.sh
stderr=$("$TOOLS/artifact-validate.sh" --path "$FIX/invalid/bad-disposition.json" 2>&1 >/dev/null); code=$?
if [[ "$code" != "0" ]] && echo "$stderr" | grep -q "bogus_disposition"; then
    pass "F: artifact-validate.sh rejects bad-disposition fixture with readable error"
else
    fail "F: validator should reject bad-disposition fixture" "exit=$code stderr=$stderr"
fi

# H. --delete-finding removes the finding
# (Make a disposable copy so we don't disturb the main $ART.)
cp "$ART" "$WORK/art-del.json"
before_count=$(jq '.findings | length' "$WORK/art-del.json")
if "$TOOLS/artifact-patch.py" --path "$WORK/art-del.json" --delete-finding F099 >/dev/null; then
    after_count=$(jq '.findings | length' "$WORK/art-del.json")
    if [[ "$after_count" == "$((before_count - 1))" ]] && \
       ! jq -e '.findings[] | select(.id == "F099")' "$WORK/art-del.json" >/dev/null 2>&1; then
        pass "H: --delete-finding F099 removes the finding"
    else
        fail "H: count before=$before_count after=$after_count; F099 still present?"
    fi
else
    fail "H: --delete-finding F099 exit non-zero"
fi

# I. --delete-finding on unknown id → non-zero with did-you-mean
stderr=$("$TOOLS/artifact-patch.py" --path "$ART" --delete-finding F999 2>&1 >/dev/null); code=$?
if [[ "$code" != "0" ]] && echo "$stderr" | grep -q "no finding with id"; then
    pass "I: --delete-finding on unknown id rejected with error-as-prompt"
else
    fail "I: expected error for unknown id; got code=$code stderr=$stderr"
fi

# J. --set-json writes an array field (sources)
cp "$ART" "$WORK/art-sj.json"
if "$TOOLS/artifact-patch.py" --path "$WORK/art-sj.json" --finding-id F001 \
        --set-json "sources=[\"detection\",\"codex\"]" >/dev/null; then
    actual=$(jq -c '.findings[] | select(.id=="F001") | .sources' "$WORK/art-sj.json")
    if [[ "$actual" == '["detection","codex"]' ]]; then
        pass "J: --set-json sources=<array> writes correctly"
    else
        fail "J: sources after --set-json = $actual"
    fi
else
    fail "J: --set-json exit non-zero"
fi

# K. --set-json with @file reads from disk
echo '["external-pr:greptile-apps[bot]"]' > "$WORK/sj.json"
if "$TOOLS/artifact-patch.py" --path "$WORK/art-sj.json" --finding-id F001 \
        --set-json "sources=@$WORK/sj.json" >/dev/null; then
    actual=$(jq -c '.findings[] | select(.id=="F001") | .sources' "$WORK/art-sj.json")
    if [[ "$actual" == '["external-pr:greptile-apps[bot]"]' ]]; then
        pass "K: --set-json @file reads JSON from disk"
    else
        fail "K: expected greptile source, got $actual"
    fi
else
    fail "K: --set-json @file exit non-zero"
fi

# L. --set-json on non-whitelisted field rejects
stderr=$("$TOOLS/artifact-patch.py" --path "$WORK/art-sj.json" --finding-id F001 \
        --set-json 'fix_attempts=[]' 2>&1 >/dev/null); code=$?
if [[ "$code" != "0" ]] && echo "$stderr" | grep -q "cannot touch"; then
    pass "L: --set-json rejects fix_attempts (append-only via --append-fix-attempt)"
else
    fail "L: expected rejection; got code=$code stderr=$stderr"
fi

# M. --set-json --top-level (no --finding-id) writes artifact-level JSON field
# Schema requires CCG id ^G[0-9]+$ and finding_ids length >= 2.
if "$TOOLS/artifact-patch.py" --path "$WORK/art-sj.json" \
        --set-json "cross_cutting_groups=[{\"id\":\"G1\",\"finding_ids\":[\"F001\",\"F002\"],\"combined_approach\":\"x\"}]" >/dev/null; then
    actual=$(jq -c '.cross_cutting_groups | length' "$WORK/art-sj.json")
    if [[ "$actual" == "1" ]]; then
        pass "M: --set-json writes top-level cross_cutting_groups"
    else
        fail "M: cross_cutting_groups length = $actual"
    fi
else
    fail "M: --set-json top-level exit non-zero"
fi

# G. external-scrape.sh fixture-replay: bot filter + deny list (no time window —
# see Stage 2.8: --since removed because code locality, not newness, is
# the right relevance axis. Both coderabbit bot comments now survive; the
# "too old" case is kept because age no longer matters at this layer).
EXT="$WORK/ext"
mkdir -p "$EXT"
cat > "$EXT/issue_comments.json" <<'JSON'
[
  {"id":1,"user":{"login":"humanuser","type":"User"},"created_at":"2026-02-01T00:00:00Z","body":"human comment"},
  {"id":2,"user":{"login":"coderabbit-ai[bot]","type":"Bot"},"created_at":"2026-02-01T00:00:00Z","body":"bot finding uses \\d at 100%"},
  {"id":3,"user":{"login":"dependabot[bot]","type":"Bot"},"created_at":"2026-02-01T00:00:00Z","body":"dep bump uses \\w at 50%"},
  {"id":5,"user":{"login":"coderabbit-ai[bot]","type":"Bot"},"created_at":"2025-01-01T00:00:00Z","body":"age no longer filtered uses \\s at 25%"}
]
JSON
echo '[]' > "$EXT/reviews.json"
echo '[]' > "$EXT/review_comments.json"
# Default config (no --config) — DEFAULT_DENY applies, allow=null.
out=$(MATTHEWS_REVIEW_FIXTURES_USER=smokeuser "$TOOLS/external-scrape.sh" \
        --fixtures-dir "$EXT")
ids=$(echo "$out" | jq -c '[.[].id] | sort')
if [[ "$ids" == "[2,5]" ]]; then
    pass "G: external-scrape fixture replay keeps both coderabbit records, drops human + dep-bump"
else
    fail "G: expected ids [2,5], got $ids" "out=$out"
fi

# Exercise the branch-added G2/G3 captured-JSON boundaries with the same shell
# option enabled by `bash -O xpg_echo`. Backslashes catch echo-based emitters;
# percent signs catch data accidentally used as a printf format string.
g_restore_xpg_echo=false
if ! shopt -q xpg_echo; then
    shopt -s xpg_echo
    g_restore_xpg_echo=true
fi
# G2. external-scrape honors legacy ADAMS_REVIEW_CONFIG_ROOT when the new var
# is unset (backward-compat fallback). A config-supplied deny list REPLACES
# DEFAULT_DENY, so denying coderabbit alone drops records 2+5 and dependabot
# (id 3) survives — [3] proves the legacy config root was read (the default
# chain would yield [2,5]).
LEGACY_CFG="$WORK/legacy-cfg"
mkdir -p "$LEGACY_CFG"
echo '{"external_reviewer_bots":{"deny":["coderabbit-ai[bot]"]}}' > "$LEGACY_CFG/review-config.json"
out=$(env -u MATTHEWS_REVIEW_CONFIG_ROOT ADAMS_REVIEW_CONFIG_ROOT="$LEGACY_CFG" \
        MATTHEWS_REVIEW_FIXTURES_USER=smokeuser "$TOOLS/external-scrape.sh" --fixtures-dir "$EXT")
ids=$(printf '%s\n' "$out" | jq -c '[.[].id] | sort')
g2_body=$(printf '%s\n' "$out" | jq -r '.[0].body')
if [[ "$ids" == "[3]" && "$g2_body" == 'dep bump uses \w at 50%' ]]; then
    pass "G2: legacy config root preserves backslash/percent JSON under xpg_echo"
else
    fail "G2: legacy config-root fallback mismatch" "ids=$ids body=$g2_body"
fi

# G3. external-scrape honors legacy ADAMS_REVIEW_FIXTURES_USER when the new
# var is unset (backward-compat fallback).
out=$(env -u MATTHEWS_REVIEW_FIXTURES_USER ADAMS_REVIEW_FIXTURES_USER=smokeuser \
        "$TOOLS/external-scrape.sh" --fixtures-dir "$EXT")
ids=$(printf '%s\n' "$out" | jq -c '[.[].id] | sort')
g3_bodies=$(printf '%s\n' "$out" | jq -r 'map(.body) | join("|")')
if [[ "$g_restore_xpg_echo" == true ]]; then
    shopt -u xpg_echo
fi
if [[ "$ids" == "[2,5]" \
      && "$g3_bodies" == 'bot finding uses \d at 100%|age no longer filtered uses \s at 25%' ]]; then
    pass "G3: legacy fixtures user preserves backslash/percent JSON under xpg_echo"
else
    fail "G3: legacy fixtures-user fallback mismatch" "ids=$ids bodies=$g3_bodies"
fi

# N. pending_validation is a valid disposition enum (R2 fix)
cp "$ART" "$WORK/art-pv.json"
if "$TOOLS/artifact-patch.py" --path "$WORK/art-pv.json" --finding-id F099 \
        --set disposition=pending_validation --set is_actionable=false >/dev/null 2>&1; then
    actual=$(jq -r '.findings[] | select(.id=="F099") | .disposition' "$WORK/art-pv.json")
    if [[ "$actual" == "pending_validation" ]]; then
        pass "N: pending_validation accepted as disposition (R2 parking state)"
    else
        fail "N: disposition after set = $actual"
    fi
else
    fail "N: --set disposition=pending_validation exit non-zero"
fi

# O. artifact-read.sh --summary emits counts_by_state (R6 rename)
if "$TOOLS/artifact-read.sh" --path "$ART" --summary | jq -e '.counts_by_state' >/dev/null; then
    # Also confirm the deprecated key is gone
    if "$TOOLS/artifact-read.sh" --path "$ART" --summary | jq -e '.counts_by_current_state' >/dev/null 2>&1; then
        fail "O: counts_by_current_state still present; rename incomplete"
    else
        pass "O: --summary emits counts_by_state (DESIGN §12.1 naming)"
    fi
else
    fail "O: --summary does not emit counts_by_state"
fi

# P. empty-string list → [] via jq -Rn inputs|select(length>0) (R4 fix pattern)
# (Exercises the exact jq expression used in 00-preflight.md:306-307.)
empty_out=$(printf '%s' "" | jq -Rn '[inputs | select(length>0)]')
if [[ "$empty_out" == "[]" ]]; then
    pass "P: jq -Rn 'inputs|select(length>0)' returns [] on empty input (R4)"
else
    fail "P: expected [] got $empty_out"
fi

# Q. --set disposition=pending_validation + is_actionable=true → coupling reject
# (pending_validation is not in ACTIONABLE_DISPOSITIONS.)
stderr=$("$TOOLS/artifact-patch.py" --path "$WORK/art-pv.json" --finding-id F099 \
        --set disposition=pending_validation --set is_actionable=true 2>&1 >/dev/null); code=$?
if [[ "$code" != "0" ]] && echo "$stderr" | grep -q "is_actionable"; then
    pass "Q: pending_validation + is_actionable=true rejected (coupling invariant)"
else
    fail "Q: expected coupling error; got code=$code stderr=$stderr"
fi

# R. pending_validation → confirmed_mechanical Phase-4 transition works (R2 flow)
# F099 starts at below_gate; move through pending_validation → confirmed_mechanical
# (with is_actionable=true, confirmed_strength) simulating Phase 3→4.
cp "$ART" "$WORK/art-p34.json"
"$TOOLS/artifact-patch.py" --path "$WORK/art-p34.json" --finding-id F099 \
    --set disposition=pending_validation --set is_actionable=false >/dev/null
if "$TOOLS/artifact-patch.py" --path "$WORK/art-p34.json" --finding-id F099 \
        --set disposition=confirmed_mechanical \
        --set is_actionable=true \
        --set confirmed_strength=strong \
        --set "score_phase4=85" >/dev/null; then
    disp=$(jq -r '.findings[] | select(.id=="F099") | .disposition' "$WORK/art-p34.json")
    if [[ "$disp" == "confirmed_mechanical" ]]; then
        pass "R: pending_validation → confirmed_mechanical Phase-4 transition succeeds"
    else
        fail "R: final disposition = $disp"
    fi
else
    fail "R: Phase-4 transition exit non-zero"
fi

# S. Schema-valid validation_result via --set-json @file (R3 write path)
VR=$(cat <<'JSON'
{
  "evidence": ["src/foo.ts:42 — null deref"],
  "blast_radius": {
    "writers": ["src/foo.ts:40"],
    "consumers": ["src/bar.ts:88"],
    "parallel_paths": [],
    "invariants_at_stake": ["user_id is non-null"]
  },
  "fix_proposal": {
    "approach": "Add null-check + fallback path",
    "files_to_modify": [
      {"file":"src/foo.ts","what":"guard null","why":"prevents NPE"}
    ]
  },
  "verification_context": {
    "how_to_verify_fix": ["grep 'user_id' src/"],
    "edge_cases_to_preserve": ["empty string"],
    "what_would_break_if_incomplete": ["API returns 500 on unauth"]
  }
}
JSON
)
echo "$VR" > "$WORK/vr.json"
if "$TOOLS/artifact-patch.py" --path "$WORK/art-p34.json" --finding-id F099 \
        --set-json "validation_result=@$WORK/vr.json" >/dev/null; then
    actual=$(jq -r '.findings[] | select(.id=="F099") | .validation_result.fix_proposal.approach' "$WORK/art-p34.json")
    if [[ "$actual" == "Add null-check + fallback path" ]]; then
        pass "S: --set-json validation_result=@file writes schema-valid object (R3)"
    else
        fail "S: fix_proposal.approach readback = $actual"
    fi
else
    fail "S: --set-json validation_result @file exit non-zero"
fi

# T. --set-json reviewer_sources=@file at top level (Phase 6.3a recompute path)
echo '["internal","codex"]' > "$WORK/rs.json"
if "$TOOLS/artifact-patch.py" --path "$WORK/art-p34.json" \
        --set-json "reviewer_sources=@$WORK/rs.json" >/dev/null; then
    actual=$(jq -c '.reviewer_sources' "$WORK/art-p34.json")
    if [[ "$actual" == '["internal","codex"]' ]]; then
        pass "T: --set-json reviewer_sources at top-level (Phase 6.3a path)"
    else
        fail "T: reviewer_sources readback = $actual"
    fi
else
    fail "T: --set-json reviewer_sources exit non-zero"
fi

# U. reviewer_sources Phase-6.3a regex correctly classifies lens tags.
# Simulates the jq expression in 07-finalize.md step 6.3a against a
# synthetic sources[] union.
U_OUT=$(echo '["L1-diff-local","L3-claude-md","L7-holistic","codex","external-pr:greptile-apps[bot]","random-tag"]' \
    | jq -c 'map(
        if test("^L[0-9]+-") then "internal"
        elif . == "codex" then .
        elif startswith("external-pr:") then .
        else empty end
      ) | unique')
if [[ "$U_OUT" == '["codex","external-pr:greptile-apps[bot]","internal"]' ]]; then
    pass "U: reviewer_sources regex classifies L1..L7 lens tags, codex, external-pr: correctly"
else
    fail "U: reviewer_sources output = $U_OUT"
fi

# Ubis. Strict L7-only variant — guards the post-Stage-2.9 forward-
# compat regex specifically. With the old buggy regex ^L[1-6]- and only
# L7 tags in sources[], the union would collapse to [] (L7 classified as
# `empty`, dropped). With the fixed ^L[0-9]+-, the union is ["internal"].
# U alone doesn't distinguish the two regexes when L1..L6 are also present
# — this test does.
U_OUT_STRICT=$(echo '["L7-holistic"]' \
    | jq -c 'map(
        if test("^L[0-9]+-") then "internal"
        elif . == "codex" then .
        elif startswith("external-pr:") then .
        else empty end
      ) | unique')
if [[ "$U_OUT_STRICT" == '["internal"]' ]]; then
    pass "Ubis: L7-holistic alone classifies as 'internal' (forward-compat regex guard)"
else
    fail "Ubis: expected [\"internal\"]; got $U_OUT_STRICT"
fi

# Vbis. review_id fallback format matches ^rev_[A-Za-z0-9]+$.
# Regression test for real-repo round-5 red: the 0.15 fallback used
# `rev_${date}_${random}` with an underscore separator; the regex
# rejects underscores after the `rev_` prefix.
fallback_id="rev_$(date -u +%Y%m%dT%H%M%SZ)$(openssl rand -hex 3)"
if [[ "$fallback_id" =~ ^rev_[A-Za-z0-9]+$ ]]; then
    pass "Vbis: review_id fallback '$fallback_id' matches schema regex"
else
    fail "Vbis: fallback id '$fallback_id' does not match ^rev_[A-Za-z0-9]+$"
fi

# V. pr_state=OPEN (uppercase from gh) would fail schema — the 00-preflight
# transform at step 0.4 must lowercase it. This asserts the schema rejects
# uppercase directly, so the transform has something to protect.
BAD_SEED=$(jq '.pr_state = "OPEN"' "$FIX/artifact-seed.json")
stderr=$("$TOOLS/artifact-patch.py" --init "$BAD_SEED" --path "$WORK/art-badstate.json" 2>&1 >/dev/null); code=$?
if [[ "$code" != "0" ]] && echo "$stderr" | grep -q "pr_state"; then
    pass "V: schema rejects pr_state='OPEN' (uppercase — protects 00-preflight transform)"
else
    fail "V: schema should reject uppercase pr_state; code=$code stderr=$stderr"
fi

# W. --apply-decisions: mixed batch routes via §13.1 and writes validation_result
# only for the confirmed band (Stage 2.5.B). Build a seed with 3 findings in
# pending_validation, run one --apply-decisions call with a confirmed_mechanical +
# uncertain + disproven tuple set, and check each finding's post-state.
APPLY_DIR="$WORK/apply-decisions"
mkdir -p "$APPLY_DIR"

PV_SEED=$(jq '.review_id = "rev_applydecisions" | .findings = [
  {"id":"F101","sources":["L1-diff-local"],"source_families":["structural-family"],
   "impact_type":"correctness","origin":"introduced_by_pr","origin_confidence":"high",
   "actionability":"auto_fixable","validation_lane":"deep",
   "current_state":"open","disposition":"pending_validation","is_actionable":false,
   "reason":null,"confirmed_strength":null,
   "file":"src/a.ts","line_range":[10,20],"claim":"confirmed-band candidate",
   "score_phase3":55,"score_phase4":null,
   "score_history":[{"phase":"phase_3","score":55}],
   "validation_result":null,"fix_attempts":[],
   "introduced_in_sha":null,"suggested_follow_up":null,"related_parent_finding_id":null},
  {"id":"F102","sources":["L2-structural"],"source_families":["structural-family"],
   "impact_type":"correctness","origin":"introduced_by_pr","origin_confidence":"medium",
   "actionability":"auto_fixable","validation_lane":"deep",
   "current_state":"open","disposition":"pending_validation","is_actionable":false,
   "reason":null,"confirmed_strength":null,
   "file":"src/b.ts","line_range":[30,40],"claim":"uncertain-band candidate",
   "score_phase3":50,"score_phase4":null,
   "score_history":[{"phase":"phase_3","score":50}],
   "validation_result":null,"fix_attempts":[],
   "introduced_in_sha":null,"suggested_follow_up":null,"related_parent_finding_id":null},
  {"id":"F103","sources":["L3-claude-md"],"source_families":["code-review"],
   "impact_type":"policy","origin":"introduced_by_pr","origin_confidence":"low",
   "actionability":"manual","validation_lane":"light",
   "current_state":"open","disposition":"pending_validation","is_actionable":false,
   "reason":null,"confirmed_strength":null,
   "file":"src/c.ts","line_range":[1,5],"claim":"disproven-band candidate",
   "score_phase3":45,"score_phase4":null,
   "score_history":[{"phase":"phase_3","score":45}],
   "validation_result":null,"fix_attempts":[],
   "introduced_in_sha":null,"suggested_follow_up":null,"related_parent_finding_id":null}
]' "$FIX/artifact-seed.json")

"$TOOLS/artifact-patch.py" --init "$PV_SEED" --path "$APPLY_DIR/art.json" >/dev/null

VR_JSON='{
  "evidence":["src/a.ts:12 calls .user.id without null check"],
  "blast_radius":{"writers":["src/a.ts:12"],"consumers":["src/b.ts:40"],
                  "parallel_paths":[],"invariants_at_stake":["user non-null after login"]},
  "fix_proposal":{"approach":"guard before deref",
    "files_to_modify":[{"file":"src/a.ts","what":"add null check","why":"prevents crash"}]},
  "verification_context":{"how_to_verify_fix":["run unit tests"],
                          "edge_cases_to_preserve":["guest auth flow"],
                          "what_would_break_if_incomplete":["crash on cold cache"]}
}'

BATCH=$(jq -n --argjson vr "$VR_JSON" '[
  {id:"F101",score_phase4:80,decision:"confirmed",actionability:"auto_fixable",validation_result:$vr},
  {id:"F102",score_phase4:50,decision:"uncertain",actionability:null},
  {id:"F103",score_phase4:30,decision:"disproven",actionability:null,reason:"Phase 4: not reproducible"}
]')

out=$("$TOOLS/artifact-patch.py" --apply-decisions "$BATCH" --path "$APPLY_DIR/art.json" 2>&1); code=$?

F101_DISP=$(jq -r '.findings[] | select(.id=="F101") | .disposition' "$APPLY_DIR/art.json")
F101_IA=$(jq -r '.findings[] | select(.id=="F101") | .is_actionable' "$APPLY_DIR/art.json")
F101_CS=$(jq -r '.findings[] | select(.id=="F101") | .confirmed_strength' "$APPLY_DIR/art.json")
F101_VR=$(jq -r '.findings[] | select(.id=="F101") | if .validation_result == null then "null" else "object" end' "$APPLY_DIR/art.json")
F102_DISP=$(jq -r '.findings[] | select(.id=="F102") | .disposition' "$APPLY_DIR/art.json")
F102_VR=$(jq -r '.findings[] | select(.id=="F102") | .validation_result' "$APPLY_DIR/art.json")
F103_DISP=$(jq -r '.findings[] | select(.id=="F103") | .disposition' "$APPLY_DIR/art.json")
F103_VR=$(jq -r '.findings[] | select(.id=="F103") | .validation_result' "$APPLY_DIR/art.json")
F103_REASON=$(jq -r '.findings[] | select(.id=="F103") | .reason' "$APPLY_DIR/art.json")

if [[ "$code" == "0" ]] \
    && [[ "$F101_DISP" == "confirmed_mechanical" && "$F101_IA" == "true" && "$F101_CS" == "strong" && "$F101_VR" == "object" ]] \
    && [[ "$F102_DISP" == "uncertain" && "$F102_VR" == "null" ]] \
    && [[ "$F103_DISP" == "disproven" && "$F103_VR" == "null" && "$F103_REASON" == "Phase 4: not reproducible" ]] \
    && echo "$out" | grep -q "applied 3 decisions"; then
    pass "W: --apply-decisions batch routes per §13.1; validation_result only for confirmed band (Stage 2.5.B)"
else
    fail "W: apply-decisions state mismatch" "code=$code F101=($F101_DISP,$F101_IA,$F101_CS,$F101_VR) F102=($F102_DISP,$F102_VR) F103=($F103_DISP,$F103_VR,$F103_REASON) out=$out"
fi

# W2. Legacy artifacts may have no persisted disposition. A Phase-4 decision
# supplies the derived disposition and actionability in one atomic pair set;
# coupling must validate the proposed pair, not the missing stored value.
jq '(.findings[] | select(.id == "F101")) |=
      (del(.disposition) | .is_actionable = false | .score_phase4 = null)' \
  "$APPLY_DIR/art.json" > "$APPLY_DIR/legacy-no-disposition.json"
legacy_batch=$(jq -n --argjson vr "$VR_JSON" \
  '[{id:"F101",score_phase4:80,decision:"confirmed",actionability:"auto_fixable",validation_result:$vr}]')
legacy_out=$("$TOOLS/artifact-patch.py" \
  --apply-decisions "$legacy_batch" \
  --path "$APPLY_DIR/legacy-no-disposition.json" 2>&1); legacy_code=$?
legacy_state=$(jq -r '.findings[] | select(.id=="F101") | "\(.disposition)|\(.is_actionable)"' \
  "$APPLY_DIR/legacy-no-disposition.json" 2>/dev/null || true)
if [[ $legacy_code -eq 0 && "$legacy_state" == "confirmed_mechanical|true" ]]; then
    pass "W2: --apply-decisions validates derived coupling for legacy disposition-null findings"
else
    fail "W2: legacy disposition-null decision rejected" "code=$legacy_code state=$legacy_state out=$legacy_out"
fi

# Y. Light-lane uncertain findings render in both summary and table (Stage 2.5.D).
# Regression guard for a real data-loss bug: artifact-render.py's light-lane
# iteration tuples omitted "uncertain" — C13 on ray-finance had 3 light-lane
# uncertain findings (F021/F022/F032) present in artifact.json but silently
# missing from the rendered PR comment. Fixture seed now includes F006 as a
# light-lane uncertain finding; this assertion is belt-and-suspenders next to
# the existing expected.md byte-diff (step 9) so a future tuple-literal drop
# surfaces with a clear "light uncertain dropped" signal rather than a generic
# rendering diff.
if grep -q "^| F006 | 48 | architecture |" "$MD" \
    && grep -q "1 auto-fixable, 1 uncertain" "$MD"; then
    pass "Y: Light-lane uncertain finding renders in table + summary (Stage 2.5.D)"
else
    fail "Y: expected F006 row + '1 auto-fixable, 1 uncertain' in $MD" "$(cat "$MD")"
fi

# Y2. Same data-loss pattern, second class: disproven + below_gate findings used
# to count toward "Found N findings" but had no breakdown bullet — Xilem
# #1791 showed "Found 9 findings" with only 2 explained, leaving 7 silently
# unaccounted. Steps 2 and 2b add F099 (below_gate) and F100 (disproven) to
# this artifact; this assertion + the expected.md byte-diff (step 9)
# belt-and-suspenders the headline-vs-bullet identity so a future
# allow-list omission surfaces here.
if grep -q "^Found 8 findings across all lanes:" "$MD" \
    && grep -q "Filtered out: 1 disproven, 1 below score gate (<45)" "$MD"; then
    pass "Y2: disproven + below_gate counted in 'Filtered out' summary bullet (regression guard for Xilem #1791 silent-drop)"
else
    fail "Y2: expected 'Found 8 findings' headline + 'Filtered out: 1 disproven, 1 below score gate (<45)' bullet in $MD" "$(cat "$MD")"
fi

# X. --apply-decisions rejects a confirmed-band tuple that omits actionability.
# Error-as-prompt names the failing tuple id so the caller can re-invoke with
# the remainder. Reset state first: re-init so the earlier W writes don't
# color this assertion's "nothing changed" guarantee.
"$TOOLS/artifact-patch.py" --init "$PV_SEED" --path "$APPLY_DIR/art.json" >/dev/null
BEFORE_SHA=$(sha_of "$APPLY_DIR/art.json")
BAD_BATCH='[{"id":"F101","score_phase4":70}]'
stderr=$("$TOOLS/artifact-patch.py" --apply-decisions "$BAD_BATCH" --path "$APPLY_DIR/art.json" 2>&1 >/dev/null); code=$?
AFTER_SHA=$(sha_of "$APPLY_DIR/art.json")
if [[ "$code" == "1" ]] \
    && echo "$stderr" | grep -q "F101" \
    && echo "$stderr" | grep -q "actionability" \
    && [[ "$BEFORE_SHA" == "$AFTER_SHA" ]]; then
    pass "X: --apply-decisions rejects confirmed-band tuple without actionability; leaves artifact unchanged"
else
    fail "X: expected EXIT_VALIDATION + stderr naming F101+actionability + unchanged file; code=$code sha_eq=$([[ "$BEFORE_SHA" == "$AFTER_SHA" ]] && echo Y || echo N) stderr=$stderr"
fi

# BD-1. --apply-decisions --expected N rejects under-sized batches (Phase 4
# structural guard from plans/phase-3-and-4-batching.md). The caller passes
# the count of candidates it dispatched in this wave (deep + light); if the
# orchestrator collapsed multiple candidates into a single Opus call OR a
# light-lane chunk-agent dropped findings from its returned array, fewer
# tuples arrive than expected and the helper must fail loudly with
# EXIT_EXPECTED_MISMATCH (exit 6) so the orchestrator re-dispatches.
# Stderr names BOTH lane recoveries — the helper is lane-agnostic.
"$TOOLS/artifact-patch.py" --init "$PV_SEED" --path "$APPLY_DIR/art.json" >/dev/null
BEFORE_SHA=$(sha_of "$APPLY_DIR/art.json")
SHORT_BATCH='[{"id":"F101","score_phase4":80,"decision":"confirmed","actionability":"auto_fixable"}]'
stderr=$("$TOOLS/artifact-patch.py" --apply-decisions "$SHORT_BATCH" --expected 5 --path "$APPLY_DIR/art.json" 2>&1 >/dev/null); code=$?
AFTER_SHA=$(sha_of "$APPLY_DIR/art.json")
if [[ "$code" == "6" ]] \
    && echo "$stderr" | grep -q "expected 5 tuple" \
    && echo "$stderr" | grep -q "received 1" \
    && echo "$stderr" | grep -q "deep lane" \
    && echo "$stderr" | grep -q "chunk-agent" \
    && [[ "$BEFORE_SHA" == "$AFTER_SHA" ]]; then
    pass "BD-1: --expected N rejects under-sized batch with exit 6; stderr names both deep-lane and chunk-agent recoveries; artifact unchanged"
else
    fail "BD-1: expected EXIT_EXPECTED_MISMATCH (6) + count-mismatch stderr (deep-lane + chunk-agent) + unchanged file" "code=$code sha_eq=$([[ "$BEFORE_SHA" == "$AFTER_SHA" ]] && echo Y || echo N) stderr=$stderr"
fi

# BD-2. --apply-decisions --expected N accepts a matching-count batch — proves
# the guard is structural, not punitive. Reuses W's BATCH (the 3-tuple set built
# from VR_JSON above) with --expected 3 to assert the success path still routes
# per §13.1 when the count check is in play.
"$TOOLS/artifact-patch.py" --init "$PV_SEED" --path "$APPLY_DIR/art.json" >/dev/null
out=$("$TOOLS/artifact-patch.py" --apply-decisions "$BATCH" --expected 3 --path "$APPLY_DIR/art.json" 2>&1); code=$?
F101_DISP_BD=$(jq -r '.findings[] | select(.id=="F101") | .disposition' "$APPLY_DIR/art.json")
if [[ "$code" == "0" ]] \
    && [[ "$F101_DISP_BD" == "confirmed_mechanical" ]] \
    && echo "$out" | grep -q "applied 3 decisions"; then
    pass "BD-2: --expected N matching count accepts the batch and routes per §13.1"
else
    fail "BD-2: expected exit 0 + 'applied 3 decisions' + F101=confirmed_mechanical" "code=$code F101=$F101_DISP_BD out=$out"
fi

# BD-3. --apply-decisions --expected N rejects over-sized batches (the
# count-direction tightening from F003). A chunk-agent that returns extra
# hallucinated ids (or the orchestrator that recomposes from a malformed
# multi-chunk response) would emit MORE tuples than dispatched. The helper
# must reject with the same EXIT_EXPECTED_MISMATCH (exit 6) and the same
# recovery prose so the orchestrator strips the extras before re-invoking.
"$TOOLS/artifact-patch.py" --init "$PV_SEED" --path "$APPLY_DIR/art.json" >/dev/null
BEFORE_SHA=$(sha_of "$APPLY_DIR/art.json")
LONG_BATCH=$(jq -n --argjson vr "$VR_JSON" '[
  {id:"F101",score_phase4:80,decision:"confirmed",actionability:"auto_fixable",validation_result:$vr},
  {id:"F102",score_phase4:50,decision:"uncertain",actionability:null},
  {id:"F103",score_phase4:30,decision:"disproven",actionability:null}
]')
stderr=$("$TOOLS/artifact-patch.py" --apply-decisions "$LONG_BATCH" --expected 2 --path "$APPLY_DIR/art.json" 2>&1 >/dev/null); code=$?
AFTER_SHA=$(sha_of "$APPLY_DIR/art.json")
if [[ "$code" == "6" ]] \
    && echo "$stderr" | grep -q "expected 2 tuple" \
    && echo "$stderr" | grep -q "received 3" \
    && [[ "$BEFORE_SHA" == "$AFTER_SHA" ]]; then
    pass "BD-3 (F003): --apply-decisions rejects over-sized batch with exit 6; artifact unchanged"
else
    fail "BD-3: expected EXIT_EXPECTED_MISMATCH (6) + over-sized stderr + unchanged file" "code=$code sha_eq=$([[ "$BEFORE_SHA" == "$AFTER_SHA" ]] && echo Y || echo N) stderr=$stderr"
fi

# BD-4. --apply-decisions rejects duplicate finding ids in the same batch
# (F003). Independent of --expected — duplicates always re-apply the
# decision and re-append score_history for the same finding. EXIT_VALIDATION
# (exit 1) because this is a different validation failure class than count
# mismatch: the recovery is "strip the duplicate", not "re-dispatch the
# missing/extra".
"$TOOLS/artifact-patch.py" --init "$PV_SEED" --path "$APPLY_DIR/art.json" >/dev/null
BEFORE_SHA=$(sha_of "$APPLY_DIR/art.json")
DUP_BATCH=$(jq -n --argjson vr "$VR_JSON" '[
  {id:"F101",score_phase4:80,decision:"confirmed",actionability:"auto_fixable",validation_result:$vr},
  {id:"F101",score_phase4:50,decision:"uncertain",actionability:null}
]')
stderr=$("$TOOLS/artifact-patch.py" --apply-decisions "$DUP_BATCH" --path "$APPLY_DIR/art.json" 2>&1 >/dev/null); code=$?
AFTER_SHA=$(sha_of "$APPLY_DIR/art.json")
if [[ "$code" == "1" ]] \
    && echo "$stderr" | grep -q "duplicate finding id" \
    && echo "$stderr" | grep -q "F101" \
    && [[ "$BEFORE_SHA" == "$AFTER_SHA" ]]; then
    pass "BD-4 (F003): --apply-decisions rejects duplicate ids with exit 1; artifact unchanged"
else
    fail "BD-4: expected EXIT_VALIDATION (1) + duplicate-id stderr + unchanged file" "code=$code sha_eq=$([[ "$BEFORE_SHA" == "$AFTER_SHA" ]] && echo Y || echo N) stderr=$stderr"
fi

# ------------------------------------------------------------------ Stage 2.6.A
# Base-branch freshness gate (§13.10). Exercises the non-interactive pieces of
# 00-preflight.md step 0.2a against scratch git repos — the AskUserQuestion
# branching is orchestrator-level and untestable in Bash, but the fetch +
# behind-count math + per-option ref resolution + offline fallback are pure
# git plumbing and are covered here.

FRESH_DIR="$WORK/freshness"
mkdir -p "$FRESH_DIR"

# Build a bare "remote" repo + a local clone that's one commit behind.
ORIGIN_BARE="$FRESH_DIR/origin.git"
LOCAL="$FRESH_DIR/local"

git init --bare --initial-branch=main "$ORIGIN_BARE" >/dev/null 2>&1 || \
    git init --bare "$ORIGIN_BARE" >/dev/null 2>&1

# Seed the remote via a throwaway clone.
SEED="$FRESH_DIR/seed"
git clone "$ORIGIN_BARE" "$SEED" >/dev/null 2>&1
(
    cd "$SEED"
    git checkout -b main >/dev/null 2>&1 || git checkout main >/dev/null 2>&1
    git config user.email "smoke@example.com"
    git config user.name "smoke"
    echo "v1" > README.md
    git add README.md
    git commit -q -m "initial"
    git push -q -u origin main
)

# Clone locally — local main == origin main at this point.
git clone "$ORIGIN_BARE" "$LOCAL" >/dev/null 2>&1
(
    cd "$LOCAL"
    git config user.email "smoke@example.com"
    git config user.name "smoke"
)

# Advance origin main by one commit (local is now 1 behind).
(
    cd "$SEED"
    echo "v2" >> README.md
    git commit -q -am "upstream advance"
    git push -q origin main
)

# Fetch so origin/main is visible locally (step 0.2a step 2 equivalent).
(
    cd "$LOCAL"
    git fetch origin main --quiet
)

# Create feat/smoke based on origin/main — this is the realistic post-
# rebase/merge state: the feature has the upstream commit already integrated,
# but *local* main is still at v1 (stale). Reviewing against stale local main
# would inflate the diff by including the upstream commit; reviewing against
# origin/main correctly sees only the feature commit.
(
    cd "$LOCAL"
    git checkout -q -b feat/smoke origin/main
    echo "feature" > feature.txt
    git add feature.txt
    git commit -q -m "feature change"
)

# Assertion FR-1: behind_count computed correctly.
behind_count=$(cd "$LOCAL" && git rev-list --count main..origin/main)
if [[ "$behind_count" == "1" ]]; then
    pass "FR-1 (§13.10): behind_count correctly reports local main 1 commit behind origin/main"
else
    fail "FR-1: expected behind_count=1, got $behind_count"
fi

# Assertion FR-2: option (b) used_remote_ref — comparison against origin/main
# sees ONLY the feature commit (the correct, post-§13.10 behavior).
count_via_remote=$(cd "$LOCAL" && git rev-list --count "origin/main..HEAD")
if [[ "$count_via_remote" == "1" ]]; then
    pass "FR-2 (§13.10): option (b) comparison_ref=origin/main sees 1 commit (feature only) — correct diff surface"
else
    fail "FR-2: expected 1 commit via origin/main..HEAD, got $count_via_remote"
fi

# Assertion FR-3: option (c) proceeded_stale — comparison against stale local
# main sees BOTH the feature commit AND the upstream commit. This is the
# inflated diff the freshness gate exists to defend against. Documenting the
# pre-§13.10 bug class as a positive assertion.
count_via_local=$(cd "$LOCAL" && git rev-list --count "main..HEAD")
if [[ "$count_via_local" == "2" ]]; then
    pass "FR-3 (§13.10): option (c) comparison_ref=main sees 2 commits (feature + inflated upstream) — reproduces pre-gate data loss"
else
    fail "FR-3: expected 2 commits via main..HEAD (inflated), got $count_via_local"
fi

# Assertion FR-4: option (a) fast-forward via `git fetch origin main:main` —
# refuses non-FF. On this scratch repo local main is strictly behind origin,
# so FF succeeds and behind_count drops to 0.
(
    cd "$LOCAL"
    # Must run from a checkout that is NOT main (currently feat/smoke). Git
    # refuses to update a checked-out branch via this form.
    git fetch origin main:main --quiet
)
ff_behind=$(cd "$LOCAL" && git rev-list --count main..origin/main)
if [[ "$ff_behind" == "0" ]]; then
    pass "FR-4 (§13.10): option (a) 'git fetch origin main:main' fast-forwards local main (behind_count now 0)"
else
    fail "FR-4: expected behind_count=0 post-FF, got $ff_behind"
fi

# Assertion FR-5: schema accepts base_context with each freshness enum value.
# One synthetic artifact per freshness variant, validate each via artifact-validate.
FR5_PASS=1
for freshness in fresh fast_forwarded used_remote_ref proceeded_stale no_fetch no_remote; do
    case "$freshness" in
        no_fetch|no_remote) remote_sha=null; behind=null ;;
        *) remote_sha='"abc1234"'; behind=0 ;;
    esac
    # proceeded_stale / used_remote_ref / fast_forwarded can also have null
    # behind, but the non-null form is the common one so we test that.
    if [[ "$freshness" == "fresh" ]]; then
        behind=0
    fi
    SEED_JSON=$(jq --arg f "$freshness" \
                  --argjson rs "$remote_sha" \
                  --argjson bc "$behind" \
                  '.base_context = {freshness: $f, comparison_ref: "main", remote_sha: $rs, behind_count: $bc}' \
                  "$FIX/artifact-seed.json" | jq --arg f "$freshness" '.review_id = ("rev_" + ($f | gsub("_"; "")))')
    if ! "$TOOLS/artifact-patch.py" --init "$SEED_JSON" --path "$FRESH_DIR/art-$freshness.json" >/dev/null 2>&1; then
        FR5_PASS=0
        echo "  freshness=$freshness FAILED init" >&2
        break
    fi
done
if [[ "$FR5_PASS" == "1" ]]; then
    pass "FR-5 (§13.10): schema accepts base_context for every freshness enum value (fresh, fast_forwarded, used_remote_ref, proceeded_stale, no_fetch, no_remote)"
else
    fail "FR-5: schema rejected at least one freshness variant"
fi

# Assertion FR-6: schema rejects an invalid freshness enum value (guards the
# enum against typos).
BAD=$(jq '.base_context = {freshness: "stale", comparison_ref: "main", remote_sha: null, behind_count: null}' "$FIX/artifact-seed.json")
stderr=$("$TOOLS/artifact-patch.py" --init "$BAD" --path "$FRESH_DIR/art-bad.json" 2>&1 >/dev/null); code=$?
if [[ "$code" != "0" ]] && echo "$stderr" | grep -q "freshness"; then
    pass "FR-6 (§13.10): schema rejects invalid freshness enum value with error-as-prompt"
else
    fail "FR-6: expected rejection of freshness='stale'; code=$code stderr=$stderr"
fi

# Assertion FR-7: offline fallback — fetch against a bogus remote URL fails
# (non-zero rc) in under 30s. This is the guarded path that must degrade to
# base_freshness="no_fetch" rather than hard-abort.
OFFLINE="$FRESH_DIR/offline"
mkdir -p "$OFFLINE"
(
    cd "$OFFLINE"
    git init --quiet
    git remote add origin /nonexistent/path/to/nowhere.git
)
fetch_rc=0
(cd "$OFFLINE" && git fetch origin main --quiet 2>/dev/null) || fetch_rc=$?
if [[ "$fetch_rc" != "0" ]]; then
    pass "FR-7 (§13.10): fetch against unreachable remote fails (rc=$fetch_rc) — exercises no_fetch degradation path"
else
    fail "FR-7: expected non-zero fetch rc against bogus remote, got 0"
fi

# ------------------------------------------------------------------ Stage 2.6.B
# Origin cross-check (§13.11). Deterministic blame-based classifier —
# origin-crosscheck.sh takes a candidate JSON array and corrects
# {origin, origin_confidence} based on whether every implicated commit
# is reachable from $comparison_ref.

OC_DIR="$WORK/origin-crosscheck"
mkdir -p "$OC_DIR/repo"
(
    cd "$OC_DIR/repo"
    git init --quiet --initial-branch=main 2>/dev/null || git init --quiet
    git config user.email "smoke@example.com"
    git config user.name "smoke"
    # Rename default branch to main if init didn't honor --initial-branch.
    git symbolic-ref HEAD refs/heads/main 2>/dev/null || true
    cat > file_a.py <<PY
def a():
    return 1
def b():
    return 2
PY
    git add file_a.py
    git commit --quiet -m "initial main"
    git checkout --quiet -b feat
    # Add a new file (trivially PR-introduced).
    cat > file_b.py <<PY
def new_feature():
    return 'hi'
PY
    # Modify one line of file_a.py (line 4: "return 2" → "return 3").
    sed -i.bak 's/return 2/return 3/' file_a.py
    rm -f file_a.py.bak
    git add file_a.py file_b.py
    git commit --quiet -m "feature"
)

# Assertion OC-1: pre-existing range (lines 1-2 of file_a.py — untouched).
# Lens default (introduced_by_pr/high) should be DOWNGRADED to pre_existing/
# medium so the §13.1 override does NOT fire — Phase 3 + Phase 4 decide.
# Covers two failure modes that look identical at this layer: (a) lens cited
# the wrong line range (claim is real, cited lines aren't); (b) the bug is
# an "exposure" finding where this PR added new code elsewhere that makes
# old code wrong. Either way, force-routing to the report-only footnote
# would skip validation; keep the finding flowing through the pipeline.
out=$(cd "$OC_DIR/repo" && "$TOOLS/origin-crosscheck.sh" \
    --comparison-ref main \
    --candidates '[{"id":"C1","file":"file_a.py","line_range":[1,2],"origin":"introduced_by_pr","origin_confidence":"high"}]' 2> "$OC_DIR/c1.err")
origin=$(echo "$out" | jq -r '.[0].origin')
conf=$(echo "$out" | jq -r '.[0].origin_confidence')
if [[ "$origin" == "pre_existing" && "$conf" == "medium" ]] \
    && grep -q 'action=downgraded' "$OC_DIR/c1.err" \
    && grep -q 'reason=lens-introduced-by-pr-but-all-blame-ancestor' "$OC_DIR/c1.err"; then
    pass "OC-1 (§13.11): lens=introduced_by_pr + all-blame-ancestor → pre_existing/medium (action=downgraded; §13.1 does not fire)"
else
    fail "OC-1: expected pre_existing/medium + action=downgraded + reason=lens-introduced-by-pr-but-all-blame-ancestor; got origin=$origin conf=$conf stderr=$(cat "$OC_DIR/c1.err")"
fi

# Assertion OC-12: lens AGREES with blame (lens already pre_existing/high
# AND every blame SHA is ancestor of comparison_ref). The respect/no-op
# path on the main branch — separate assertion from OC-1 because their
# input directions are now opposite, and a future drift in either branch
# of the if/else should fail loudly. Reason should be `blame-confirms-
# preexisting`, not the downgrade reason.
out=$(cd "$OC_DIR/repo" && "$TOOLS/origin-crosscheck.sh" \
    --comparison-ref main \
    --candidates '[{"id":"C12","file":"file_a.py","line_range":[1,2],"origin":"pre_existing","origin_confidence":"high"}]' 2> "$OC_DIR/c12.err")
origin=$(echo "$out" | jq -r '.[0].origin')
conf=$(echo "$out" | jq -r '.[0].origin_confidence')
if [[ "$origin" == "pre_existing" && "$conf" == "high" ]] \
    && grep -q 'action=respected' "$OC_DIR/c12.err" \
    && grep -q 'reason=blame-confirms-preexisting' "$OC_DIR/c12.err"; then
    pass "OC-12 (§13.11): lens=pre_existing/high + all-blame-ancestor → respected (no-op, reason=blame-confirms-preexisting)"
else
    fail "OC-12: expected pre_existing/high + action=respected + reason=blame-confirms-preexisting; got origin=$origin conf=$conf stderr=$(cat "$OC_DIR/c12.err")"
fi

# Assertion OC-2: PR-modified range (line 4 of file_a.py — the sed change).
# Lens value (introduced_by_pr/high) should be RESPECTED.
out=$(cd "$OC_DIR/repo" && "$TOOLS/origin-crosscheck.sh" \
    --comparison-ref main \
    --candidates '[{"id":"C2","file":"file_a.py","line_range":[4,4],"origin":"introduced_by_pr","origin_confidence":"high"}]' 2>/dev/null)
origin=$(echo "$out" | jq -r '.[0].origin')
conf=$(echo "$out" | jq -r '.[0].origin_confidence')
if [[ "$origin" == "introduced_by_pr" && "$conf" == "high" ]]; then
    pass "OC-2 (§13.11): PR-modified line respects lens (introduced_by_pr/high)"
else
    fail "OC-2: expected origin=introduced_by_pr,conf=high; got origin=$origin conf=$conf"
fi

# Assertion OC-3: new file (file_b.py). Whole file is PR-introduced.
# Lens value should be RESPECTED with reason=new-file.
out=$(cd "$OC_DIR/repo" && "$TOOLS/origin-crosscheck.sh" \
    --comparison-ref main \
    --candidates '[{"id":"C3","file":"file_b.py","line_range":[1,2],"origin":"introduced_by_pr","origin_confidence":"high"}]' 2> "$OC_DIR/c3.err")
origin=$(echo "$out" | jq -r '.[0].origin')
conf=$(echo "$out" | jq -r '.[0].origin_confidence')
if [[ "$origin" == "introduced_by_pr" && "$conf" == "high" ]] \
    && grep -q "action=respected" "$OC_DIR/c3.err" \
    && grep -q "reason=new-file" "$OC_DIR/c3.err"; then
    pass "OC-3 (§13.11): new-file candidate respects lens with reason=new-file"
else
    fail "OC-3: expected origin=introduced_by_pr,conf=high + new-file reason; got origin=$origin conf=$conf; stderr=$(cat "$OC_DIR/c3.err")"
fi

# Assertion OC-4: mixed range (file_a.py lines 1-4 — spans pre-existing AND
# the sed'd line). Conservative policy: RESPECT lens (don't auto-override).
out=$(cd "$OC_DIR/repo" && "$TOOLS/origin-crosscheck.sh" \
    --comparison-ref main \
    --candidates '[{"id":"C4","file":"file_a.py","line_range":[1,4],"origin":"introduced_by_pr","origin_confidence":"high"}]' 2>/dev/null)
origin=$(echo "$out" | jq -r '.[0].origin')
conf=$(echo "$out" | jq -r '.[0].origin_confidence')
if [[ "$origin" == "introduced_by_pr" && "$conf" == "high" ]]; then
    pass "OC-4 (§13.11): mixed PR+pre-existing range respects lens (conservative policy)"
else
    fail "OC-4: expected origin=introduced_by_pr,conf=high (mixed range); got origin=$origin conf=$conf"
fi

# Assertion OC-5: lens says pre_existing/high but blame disagrees.
# DOWNGRADE confidence to medium so §13.1 override does not fire.
out=$(cd "$OC_DIR/repo" && "$TOOLS/origin-crosscheck.sh" \
    --comparison-ref main \
    --candidates '[{"id":"C5","file":"file_a.py","line_range":[4,4],"origin":"pre_existing","origin_confidence":"high"}]' 2> "$OC_DIR/c5.err")
origin=$(echo "$out" | jq -r '.[0].origin')
conf=$(echo "$out" | jq -r '.[0].origin_confidence')
if [[ "$origin" == "pre_existing" && "$conf" == "medium" ]] \
    && grep -q "action=downgraded" "$OC_DIR/c5.err"; then
    pass "OC-5 (§13.11): lens=pre_existing/high + blame-disagrees → confidence downgraded to medium"
else
    fail "OC-5: expected origin=pre_existing,conf=medium + action=downgraded; got origin=$origin conf=$conf stderr=$(cat "$OC_DIR/c5.err")"
fi

# Assertion OC-6: unknown --comparison-ref surfaces error-as-prompt with
# suggestions (git rev-parse --symbolic --branches). Exits EXIT_VALIDATION=1.
stderr=$(cd "$OC_DIR/repo" && "$TOOLS/origin-crosscheck.sh" \
    --comparison-ref nonexistent-ref \
    --candidates '[{"id":"C6","file":"file_a.py","line_range":[1,1],"origin":"introduced_by_pr","origin_confidence":"high"}]' 2>&1 >/dev/null); code=$?
if [[ "$code" == "1" ]] \
    && echo "$stderr" | grep -q "did not resolve" \
    && echo "$stderr" | grep -q "Did you mean"; then
    pass "OC-6 (§13.11): unknown --comparison-ref rejected with error-as-prompt + suggestions (exit 1)"
else
    fail "OC-6: expected exit 1 + error-as-prompt; got code=$code stderr=$stderr"
fi

# Assertion OC-7: malformed JSON rejected. Exits EXIT_VALIDATION=1.
stderr=$(cd "$OC_DIR/repo" && "$TOOLS/origin-crosscheck.sh" \
    --comparison-ref main --candidates 'not-json' 2>&1 >/dev/null); code=$?
if [[ "$code" == "1" ]] && echo "$stderr" | grep -q "JSON array"; then
    pass "OC-7 (§13.11): malformed --candidates JSON rejected with exit 1"
else
    fail "OC-7: expected exit 1; got code=$code stderr=$stderr"
fi

# Assertion OC-8: blame failure captures stderr into the audit reason so
# rc=128 cases are diagnosable in trace.md instead of opaque. Force the
# failure by requesting a line range that overshoots file_a.py (4 lines).
out=$(cd "$OC_DIR/repo" && "$TOOLS/origin-crosscheck.sh" \
    --comparison-ref main \
    --candidates '[{"id":"C8","file":"file_a.py","line_range":[99,100],"origin":"introduced_by_pr","origin_confidence":"high"}]' \
    2> "$OC_DIR/c8.err")
if grep -qE 'reason=blame-failed rc=[0-9]+; .+' "$OC_DIR/c8.err" \
    && grep -q 'action=skipped' "$OC_DIR/c8.err"; then
    pass "OC-8 (§13.11): blame failure records rc and captured stderr suffix in reason"
else
    fail "OC-8: expected 'reason=blame-failed rc=<N>; <stderr>' + action=skipped; got: $(cat "$OC_DIR/c8.err")"
fi

# ------------------------------------------------------------------ Stage 2.6.B (rename-follow)
# Rename- and extraction-follow (§13.11, Project G). `git cat-file -e
# $ref:$file` fails for any PR-added file — the old helper exited with
# reason=new-file and respected the lens, missing F038-class cases
# where the "new" file is actually an extraction from a pre-PR
# predecessor. origin-crosscheck.sh now walks `git log --follow` to
# reach the pre-rename ancestor and re-checks reachability.

OC_RN_DIR="$WORK/origin-crosscheck-rename"
mkdir -p "$OC_RN_DIR/extract-repo"
(
    cd "$OC_RN_DIR/extract-repo"
    git init --quiet --initial-branch=main 2>/dev/null || git init --quiet
    git config user.email "smoke@example.com"
    git config user.name "smoke"
    git symbolic-ref HEAD refs/heads/main 2>/dev/null || true
    # main: monolith with a bug inside recategorize().
    cat > monolith.ts <<'TS'
export function helper() { return 1; }
export function recategorize(x: unknown) {
    // BUG: missing null check
    return (x as any).kind;
}
export function other() { return 2; }
TS
    git add monolith.ts
    git commit --quiet -m "initial main with bug in monolith"
    git checkout --quiet -b pr
    # PR extracts recategorize into its own file, preserving content.
    cat > monolith.ts <<'TS'
export function helper() { return 1; }
export function other() { return 2; }
export { recategorize } from "./recategorization";
TS
    cat > recategorization.ts <<'TS'
export function recategorize(x: unknown) {
    // BUG: missing null check
    return (x as any).kind;
}
TS
    git add monolith.ts recategorization.ts
    git commit --quiet -m "extract recategorize into its own file"
    # A follow-up PR commit adds a genuinely-new line to the extracted file.
    cat >> recategorization.ts <<'TS'
export const NEW_BUG_CONST = null as any;
TS
    git add recategorization.ts
    git commit --quiet -m "add new buggy constant in PR"
)

# Assertion OC-9: happy path. Lines 1-3 of recategorization.ts came
# across the extraction boundary from monolith.ts (pre-PR). `git log
# --follow` reaches a commit on main; blame points to the file-add
# commit. Override lens → pre_existing/high.
out=$(cd "$OC_RN_DIR/extract-repo" && "$TOOLS/origin-crosscheck.sh" \
    --comparison-ref main \
    --candidates '[{"id":"RF1","file":"recategorization.ts","line_range":[1,3],"origin":"introduced_by_pr","origin_confidence":"high"}]' \
    2> "$OC_RN_DIR/rf1.err")
origin=$(echo "$out" | jq -r '.[0].origin')
conf=$(echo "$out" | jq -r '.[0].origin_confidence')
if [[ "$origin" == "pre_existing" && "$conf" == "high" ]] \
    && grep -q 'action=overridden' "$OC_RN_DIR/rf1.err" \
    && grep -q 'reason=rename-followed-to-preexisting' "$OC_RN_DIR/rf1.err"; then
    pass "OC-9 (§13.11, Project G): extracted lines of PR-added file traced via git log --follow to pre-PR ancestor → override to pre_existing/high"
else
    fail "OC-9: expected overridden to pre_existing/high with reason=rename-followed-to-preexisting; got origin=$origin conf=$conf stderr=$(cat "$OC_RN_DIR/rf1.err")"
fi

# Assertion OC-10: regression guard. A brand-new file with no rename
# history must still exit via reason=new-file and respect the lens.
mkdir -p "$OC_RN_DIR/genuine-repo"
(
    cd "$OC_RN_DIR/genuine-repo"
    git init --quiet --initial-branch=main 2>/dev/null || git init --quiet
    git config user.email "smoke@example.com"
    git config user.name "smoke"
    git symbolic-ref HEAD refs/heads/main 2>/dev/null || true
    echo "baseline" > existing.txt
    git add existing.txt
    git commit --quiet -m "initial main"
    git checkout --quiet -b pr
    cat > brand-new.ts <<'TS'
export function foo() { return 1; }
export function bug() { return (null as any).x; }
TS
    git add brand-new.ts
    git commit --quiet -m "add brand-new.ts"
)
out=$(cd "$OC_RN_DIR/genuine-repo" && "$TOOLS/origin-crosscheck.sh" \
    --comparison-ref main \
    --candidates '[{"id":"RF2","file":"brand-new.ts","line_range":[1,2],"origin":"introduced_by_pr","origin_confidence":"high"}]' \
    2> "$OC_RN_DIR/rf2.err")
origin=$(echo "$out" | jq -r '.[0].origin')
conf=$(echo "$out" | jq -r '.[0].origin_confidence')
if [[ "$origin" == "introduced_by_pr" && "$conf" == "high" ]] \
    && grep -q 'action=respected' "$OC_RN_DIR/rf2.err" \
    && grep -q 'reason=new-file' "$OC_RN_DIR/rf2.err"; then
    pass "OC-10 (§13.11, Project G): genuinely-new PR file (no rename/extraction ancestor) still respects lens with reason=new-file"
else
    fail "OC-10: expected introduced_by_pr/high + reason=new-file; got origin=$origin conf=$conf stderr=$(cat "$OC_RN_DIR/rf2.err")"
fi

# Assertion OC-11: extraction-with-PR-additions. When an extracted file
# also gets new lines added in a later PR commit, blame on those new
# lines points to a non-ancestor, non-add-commit SHA. The override
# must NOT fire — respect the lens with an audit reason that signals
# why (so a reviewer reading trace.md can distinguish "extracted"
# from "mixed-extracted-plus-new" findings).
out=$(cd "$OC_RN_DIR/extract-repo" && "$TOOLS/origin-crosscheck.sh" \
    --comparison-ref main \
    --candidates '[{"id":"RF3","file":"recategorization.ts","line_range":[5,5],"origin":"introduced_by_pr","origin_confidence":"high"}]' \
    2> "$OC_RN_DIR/rf3.err")
origin=$(echo "$out" | jq -r '.[0].origin')
conf=$(echo "$out" | jq -r '.[0].origin_confidence')
if [[ "$origin" == "introduced_by_pr" && "$conf" == "high" ]] \
    && grep -q 'action=respected' "$OC_RN_DIR/rf3.err" \
    && grep -q 'reason=rename-follow-but-lines-modified-in-pr' "$OC_RN_DIR/rf3.err"; then
    pass "OC-11 (§13.11, Project G): PR-added lines in an extracted file are NOT overridden (blame SHA not in ancestor nor file-add set) — lens respected"
else
    fail "OC-11: expected introduced_by_pr/high + reason=rename-follow-but-lines-modified-in-pr; got origin=$origin conf=$conf stderr=$(cat "$OC_RN_DIR/rf3.err")"
fi

# Assertion OC-13: prompt-rule fixture. The shared lens-prompt invariants
# (extracted per plans/codex-review.md §4.1 from 01-detection.md §1.2.1
# into fragments/lens-prompts/_shared-invariants.md so :review and
# :codex-review consume the same source) must carry the exposure-aware
# origin rule ("reverting this PR would not close the finding"). This
# is a cheap regression guard — the rule is what stops lenses from
# labeling exposure findings (PR adds new code that makes old code stale)
# as pre_existing in the first place. Removing the wording would
# re-create the bug origin-crosscheck's main-path downgrade was added
# to mitigate.
SHARED_INVARIANTS="$REPO/fragments/lens-prompts/_shared-invariants.md"
if grep -q 'reverting this PR would not close the finding' "$SHARED_INVARIANTS"; then
    pass "OC-13 (§13.11/lens-prompts/_shared-invariants.md): shared lens-prompt block carries the exposure-aware origin rule"
else
    fail "OC-13: expected $SHARED_INVARIANTS to contain the exposure-aware origin sentence ('reverting this PR would not close the finding')"
fi

# Assertion OC-13b: position guard for the §1.2.1 origin rule. The
# original blockquote-position guard checked the sentence sat on a
# `>`-prefixed line inside the dispatched blockquote. Post-extraction
# the file IS the dispatched body (no `>` prefix needed), so the new
# guard just asserts the rule comes BEFORE the closing "introduced_by_pr"
# default fallback paragraph (i.e. inside the rule statement, not in
# trailing commentary that would be stripped). Mirrors the original
# intent: lens sub-agents only ever see the file's content.
quote_line=$(grep -nE 'reverting this PR would not close the finding' \
    "$SHARED_INVARIANTS" | head -1 | cut -d: -f1)
end_line=$(wc -l <"$SHARED_INVARIANTS")
if [ -n "$quote_line" ] && [ "$quote_line" -lt "$end_line" ]; then
    pass "OC-13b (§13.11/lens-prompts/_shared-invariants.md): exposure-aware origin rule present in body (line $quote_line of $end_line)"
else
    fail "OC-13b: expected exposure-aware sentence inside _shared-invariants.md body; quote_line=$quote_line end_line=$end_line"
fi

# Assertion OC-13c: 01-detection.md §1.2.1 must reference the extracted
# _shared-invariants.md file (Read directive). Guards against an edit
# that drops the directive and reverts to inline content (which would
# diverge from codex-review's prompt source).
if grep -qF 'fragments/lens-prompts/_shared-invariants.md' "$REPO/fragments/01-detection.md"; then
    pass "OC-13c: 01-detection.md §1.2.1 references lens-prompts/_shared-invariants.md (extracted shared block)"
else
    fail "OC-13c: 01-detection.md missing Read directive for lens-prompts/_shared-invariants.md"
fi

# Assertions DD-1 through DD-5: Phase 2 dedup origin_confidence
# reconciliation (fragments/03-dedup.md §2.3). For pre_existing-origin
# keepers the rule is order-independent and two-stage:
#
#   C1 — same-origin lowest: lowest origin_confidence across all
#        pre_existing-origin members of the group. Any corrective-medium
#        from origin-crosscheck.sh's main path A2 downgrade binds the
#        whole group regardless of which member became keeper.
#
#   C2 — cross-origin cap: if C1's lowest is still high AND any group
#        member has a non-pre_existing origin, cap max_conf at medium.
#        Cross-origin disagreement (one lens classified the finding as
#        PR-caused, another as pre-existing — same underlying bug) is
#        itself signal of group-level origin uncertainty, independent
#        of individual confidence levels.
#
# Together C1 + C2 make the pre_existing branch fully order-independent:
# §13.1 cannot fire on any dedup group containing same-origin medium
# evidence OR cross-origin disagreement, regardless of which member
# became keeper. DD-1 (medium-keeper, same-origin) and DD-3 (high-keeper,
# same-origin) cover C1's symmetry; DD-4 (high-keeper + cross-origin/high
# sibling) and DD-5 (high-keeper + cross-origin/medium sibling) cover
# C2's cap. DD-2 covers the unchanged introduced_by_pr keeper path.
# Fixtures paste-mirror the fragment's jq snippet against synthetic
# group_json so any drift between prose rule, snippet, or downstream
# consumers fails loudly.

# Assertion DD-1: pre_existing/medium keeper + pre_existing/high sibling
# → max_conf=medium (C1: same-origin lowest binds group)
group_json='[
  {"id":"K","origin":"pre_existing","origin_confidence":"medium"},
  {"id":"D1","origin":"pre_existing","origin_confidence":"high"}
]'
keeper_origin=$(jq -r --arg kid "K" '.[] | select(.id==$kid) | .origin' <<<"$group_json")
if [ "$keeper_origin" = "pre_existing" ]; then
    max_conf=$(jq -r '
      [.[] | select(.origin == "pre_existing") | .origin_confidence]
      | sort_by({"low":1, "medium":2, "high":3}[.]) | first
    ' <<<"$group_json")
    if [ "$max_conf" = "high" ]; then
        has_cross_origin=$(jq -r 'any(.[].origin; . != "pre_existing")' <<<"$group_json")
        if [ "$has_cross_origin" = "true" ]; then
            max_conf="medium"
        fi
    fi
else
    max_conf=$(jq -r '
      [.[].origin_confidence]
      | sort_by({"low":1, "medium":2, "high":3}[.]) | last
    ' <<<"$group_json")
fi
if [ "$max_conf" = "medium" ]; then
    pass "DD-1 (§03-dedup §2.3): pre_existing/medium keeper + pre_existing/high sibling → max_conf=medium (C1 same-origin lowest binds group; §13.1 does NOT fire)"
else
    fail "DD-1: expected max_conf=medium for pre_existing keeper; got $max_conf"
fi

# Assertion DD-2: introduced_by_pr keeper + mixed-confidence group still
# picks the HIGHEST — regression-checks that the pre_existing branch's
# C1+C2 rule didn't accidentally break corroboration-raises-confidence
# for the introduced_by_pr branch.
group_json='[
  {"id":"K","origin":"introduced_by_pr","origin_confidence":"medium"},
  {"id":"D1","origin":"introduced_by_pr","origin_confidence":"high"}
]'
keeper_origin=$(jq -r --arg kid "K" '.[] | select(.id==$kid) | .origin' <<<"$group_json")
if [ "$keeper_origin" = "pre_existing" ]; then
    max_conf=$(jq -r '
      [.[] | select(.origin == "pre_existing") | .origin_confidence]
      | sort_by({"low":1, "medium":2, "high":3}[.]) | first
    ' <<<"$group_json")
    if [ "$max_conf" = "high" ]; then
        has_cross_origin=$(jq -r 'any(.[].origin; . != "pre_existing")' <<<"$group_json")
        if [ "$has_cross_origin" = "true" ]; then
            max_conf="medium"
        fi
    fi
else
    max_conf=$(jq -r '
      [.[].origin_confidence]
      | sort_by({"low":1, "medium":2, "high":3}[.]) | last
    ' <<<"$group_json")
fi
if [ "$max_conf" = "high" ]; then
    pass "DD-2 (§03-dedup §2.3): introduced_by_pr keeper + mixed-confidence group → max_conf=high (corroboration-raises-confidence path unchanged)"
else
    fail "DD-2: expected max_conf=high for introduced_by_pr keeper; got $max_conf"
fi

# Assertion DD-3: pre_existing/HIGH keeper + pre_existing/medium sibling
# → max_conf=medium. DD-1 covered medium-keeper-first; DD-3 covers
# high-keeper-first. Both yield medium under C1's same-origin-lowest
# rule; symmetry confirms order-independence within same-origin groups.
# Trade-off: a legitimate rename-follow override-to-high keeper
# (F038-class extraction) gets demoted to medium when grouped with any
# pre_existing/medium sibling, and routes through Phase 3 + Phase 4
# instead of the §13.1 footnote — Phase 4 re-validates and the
# extraction trace typically re-confirms.
group_json='[
  {"id":"K","origin":"pre_existing","origin_confidence":"high"},
  {"id":"D1","origin":"pre_existing","origin_confidence":"medium"}
]'
keeper_origin=$(jq -r --arg kid "K" '.[] | select(.id==$kid) | .origin' <<<"$group_json")
if [ "$keeper_origin" = "pre_existing" ]; then
    max_conf=$(jq -r '
      [.[] | select(.origin == "pre_existing") | .origin_confidence]
      | sort_by({"low":1, "medium":2, "high":3}[.]) | first
    ' <<<"$group_json")
    if [ "$max_conf" = "high" ]; then
        has_cross_origin=$(jq -r 'any(.[].origin; . != "pre_existing")' <<<"$group_json")
        if [ "$has_cross_origin" = "true" ]; then
            max_conf="medium"
        fi
    fi
else
    max_conf=$(jq -r '
      [.[].origin_confidence]
      | sort_by({"low":1, "medium":2, "high":3}[.]) | last
    ' <<<"$group_json")
fi
if [ "$max_conf" = "medium" ]; then
    pass "DD-3 (§03-dedup §2.3): pre_existing/high keeper + pre_existing/medium sibling → max_conf=medium (C1 order-independence: high-keeper order matches DD-1's medium-keeper order)"
else
    fail "DD-3: expected max_conf=medium for pre_existing/high keeper with sibling-medium; got $max_conf"
fi

# Assertion DD-4: pre_existing/high keeper + introduced_by_pr/high
# sibling → max_conf=medium (C2 cross-origin cap). The exact scenario
# Codex round-2 surfaced: C1 alone filters to pre_existing-only members
# (just the keeper, max_conf=high), and the unchanged "leave origin on
# keeper" rule keeps keeper.origin=pre_existing — §13.1 still fires
# under C1 alone. C2 caps to medium when cross-origin disagreement
# exists, breaking the third order-dependent disguise of the original
# Mode 2 bug.
group_json='[
  {"id":"K","origin":"pre_existing","origin_confidence":"high"},
  {"id":"D1","origin":"introduced_by_pr","origin_confidence":"high"}
]'
keeper_origin=$(jq -r --arg kid "K" '.[] | select(.id==$kid) | .origin' <<<"$group_json")
if [ "$keeper_origin" = "pre_existing" ]; then
    max_conf=$(jq -r '
      [.[] | select(.origin == "pre_existing") | .origin_confidence]
      | sort_by({"low":1, "medium":2, "high":3}[.]) | first
    ' <<<"$group_json")
    if [ "$max_conf" = "high" ]; then
        has_cross_origin=$(jq -r 'any(.[].origin; . != "pre_existing")' <<<"$group_json")
        if [ "$has_cross_origin" = "true" ]; then
            max_conf="medium"
        fi
    fi
else
    max_conf=$(jq -r '
      [.[].origin_confidence]
      | sort_by({"low":1, "medium":2, "high":3}[.]) | last
    ' <<<"$group_json")
fi
if [ "$max_conf" = "medium" ]; then
    pass "DD-4 (§03-dedup §2.3): pre_existing/high keeper + introduced_by_pr/high sibling → max_conf=medium (C2 cross-origin cap; §13.1 does NOT fire)"
else
    fail "DD-4: expected max_conf=medium under C2 cross-origin cap; got $max_conf"
fi

# Assertion DD-5: pre_existing/high keeper + introduced_by_pr/medium
# sibling → max_conf=medium. Same as DD-4 with sibling at lower
# confidence — the cross-origin cap is independent of the sibling's
# own confidence level. C1 filters to pre_existing-only (keeper alone,
# max_conf=high), then C2 caps to medium because has_cross_origin is
# true regardless of sibling confidence.
group_json='[
  {"id":"K","origin":"pre_existing","origin_confidence":"high"},
  {"id":"D1","origin":"introduced_by_pr","origin_confidence":"medium"}
]'
keeper_origin=$(jq -r --arg kid "K" '.[] | select(.id==$kid) | .origin' <<<"$group_json")
if [ "$keeper_origin" = "pre_existing" ]; then
    max_conf=$(jq -r '
      [.[] | select(.origin == "pre_existing") | .origin_confidence]
      | sort_by({"low":1, "medium":2, "high":3}[.]) | first
    ' <<<"$group_json")
    if [ "$max_conf" = "high" ]; then
        has_cross_origin=$(jq -r 'any(.[].origin; . != "pre_existing")' <<<"$group_json")
        if [ "$has_cross_origin" = "true" ]; then
            max_conf="medium"
        fi
    fi
else
    max_conf=$(jq -r '
      [.[].origin_confidence]
      | sort_by({"low":1, "medium":2, "high":3}[.]) | last
    ' <<<"$group_json")
fi
if [ "$max_conf" = "medium" ]; then
    pass "DD-5 (§03-dedup §2.3): pre_existing/high keeper + introduced_by_pr/medium sibling → max_conf=medium (C2 cross-origin cap independent of sibling confidence)"
else
    fail "DD-5: expected max_conf=medium under C2 cross-origin cap; got $max_conf"
fi

# ------------------------------------------------------------------ Stage 2.6.C
# Renderer surfaces §13.10 freshness state in the header when non-default.

RH_DIR="$WORK/render-header"
mkdir -p "$RH_DIR"

# Helper: build an artifact with a given base_context and render it. Returns
# the rendered markdown's header block.
render_with_freshness() {
    local freshness="$1"
    local behind="$2"
    local remote_sha_arg
    if [[ "$freshness" == "no_fetch" || "$freshness" == "no_remote" ]]; then
        remote_sha_arg=null
    else
        remote_sha_arg='"abc1234"'
    fi
    local id="rev_$(echo "$freshness" | tr -d '_')"
    local seed
    seed=$(jq --arg f "$freshness" \
              --arg id "$id" \
              --argjson rs "$remote_sha_arg" \
              --argjson bc "$behind" \
              '.review_id = $id
               | .base_context = {freshness: $f, comparison_ref: "main", remote_sha: $rs, behind_count: $bc}' \
              "$FIX/artifact-seed.json")
    "$TOOLS/artifact-patch.py" --init "$seed" --path "$RH_DIR/art-$freshness.json" >/dev/null
    "$TOOLS/artifact-render.py" --input "$RH_DIR/art-$freshness.json"
}

# Assertion RH-1: freshness=fresh → NO "Base freshness:" line (happy path
# stays quiet so the header isn't cluttered for 99% of runs).
md=$(render_with_freshness fresh 0)
if ! echo "$md" | grep -q "Base freshness:"; then
    pass "RH-1 (§13.10/§7): freshness=fresh renders WITHOUT a Base freshness line"
else
    fail "RH-1: fresh should render quietly; saw: $(echo "$md" | grep 'Base freshness')"
fi

# Assertion RH-2: fast_forwarded → single ⚠-free line noting the prior behind count.
md=$(render_with_freshness fast_forwarded 12)
if echo "$md" | grep -q "Base freshness:" \
    && echo "$md" | grep -q "fast-forwarded before review" \
    && echo "$md" | grep -q "12 commits behind"; then
    pass "RH-2 (§13.10/§7): fast_forwarded renders prior behind-count with fast-forwarded note"
else
    fail "RH-2: expected fast_forwarded header; saw: $md"
fi

# Assertion RH-3: used_remote_ref → single ⚠ with the review-used-remote phrasing.
md=$(render_with_freshness used_remote_ref 12)
if echo "$md" | grep -q "Base freshness:" \
    && echo "$md" | grep -q "compared against" \
    && echo "$md" | grep -q 'origin/main' \
    && echo "$md" | grep -q "⚠"; then
    pass "RH-3 (§13.10/§7): used_remote_ref renders ⚠ + 'compared against origin/main'"
else
    fail "RH-3: expected used_remote_ref header with ⚠; saw: $md"
fi

# Assertion RH-4: proceeded_stale → ⚠⚠ with explicit data-loss warning.
md=$(render_with_freshness proceeded_stale 12)
if echo "$md" | grep -q "⚠⚠" \
    && echo "$md" | grep -q "stale local" \
    && echo "$md" | grep -q "git pull"; then
    pass "RH-4 (§13.10/§7): proceeded_stale renders ⚠⚠ + explicit stale warning + git pull hint"
else
    fail "RH-4: expected proceeded_stale header with ⚠⚠; saw: $md"
fi

# Assertion RH-5: no_fetch → offline note. No ⚠ (offline is a soft degradation).
md=$(render_with_freshness no_fetch 0)
if echo "$md" | grep -q "could not fetch" \
    && echo "$md" | grep -q "offline"; then
    pass "RH-5 (§13.10/§7): no_fetch renders 'could not fetch (offline?)' note"
else
    fail "RH-5: expected no_fetch header; saw: $md"
fi

# Assertion RH-6: no_remote → no line rendered (local-only repo is normal,
# not a warning-worthy state).
md=$(render_with_freshness no_remote 0)
if ! echo "$md" | grep -q "Base freshness:"; then
    pass "RH-6 (§13.10/§7): no_remote renders silently (no warning for local-only repos)"
else
    fail "RH-6: no_remote should render quietly; saw: $(echo "$md" | grep 'Base freshness')"
fi

# Assertion RH-7: artifacts without base_context (pre-§13.10) render without
# any freshness line — backward compat.
md=$("$TOOLS/artifact-render.py" --input "$ART")
if ! echo "$md" | grep -q "Base freshness:"; then
    pass "RH-7 (§13.10/§7): pre-§13.10 artifact (no base_context) renders without freshness line"
else
    fail "RH-7: pre-§13.10 artifact should not render freshness; saw: $(echo "$md" | grep 'Base freshness')"
fi

# --- OTR-* : orchestrator-tokens render line shape (post-plugin-improvements
# Project A). The header line used to display four counters (cache-read /
# output / cache-creation / fresh input) which buried the signal; the four
# values stay in the artifact for cost analysis, but the rendered line now
# shows only the user-facing levers (output / input across N turns). See
# CLAUDE.md §"Pipeline shape" for the rationale.

OTR_DIR="$WORK/render-orch"
mkdir -p "$OTR_DIR"
"$TOOLS/artifact-patch.py" --init "@$FIX/artifact-seed.json" --path "$OTR_DIR/art.json" >/dev/null
"$TOOLS/artifact-patch.py" --path "$OTR_DIR/art.json" --set-json \
    'orchestrator_tokens={"total_input":484,"total_output":566990,"cache_read":53046666,"cache_creation":2134808,"turn_count":324,"sessions":[]}' \
    >/dev/null
md=$("$TOOLS/artifact-render.py" --input "$OTR_DIR/art.json")

# Assertion OTR-1: rendered line is the simplified `<output> output /
# <input> input across <N> turns` shape. Exact, because this string is the
# whole point of the display-cleanup — regressions silently re-bury signal.
expected_line='**Orchestrator tokens:** 566,990 output / 484 input across 324 turns'
if echo "$md" | grep -qxF "$expected_line"; then
    pass "OTR-1 (post-plugin-improvements A): rendered orchestrator-tokens line is '<output> output / <input> input across <N> turns'"
else
    fail "OTR-1: expected '$expected_line'; saw: $(echo "$md" | grep -F 'Orchestrator tokens:' || echo '(no Orchestrator tokens line)')"
fi

# Assertion OTR-2: cache-read and cache-creation must NOT appear on the
# rendered header. The artifact still carries them (see schema-v1.json and
# OT-* helper assertions below) — they just stay machine-facing.
if echo "$md" | grep -F 'Orchestrator tokens:' | grep -Eq 'cache-read|cache-creation|fresh input'; then
    fail "OTR-2: rendered header still leaks cache-read/cache-creation/'fresh input'; saw: $(echo "$md" | grep -F 'Orchestrator tokens:')"
else
    pass "OTR-2 (post-plugin-improvements A): cache-read/cache-creation/'fresh input' dropped from rendered header (still in artifact)"
fi

# Assertion OTR-3: all four counters still present in the stored artifact
# — schema-v1.json still requires them; narrowing the display must not
# collapse the internal capture.
stored=$(jq -c '.orchestrator_tokens | {total_input, total_output, cache_read, cache_creation, turn_count}' "$OTR_DIR/art.json")
expected_stored='{"total_input":484,"total_output":566990,"cache_read":53046666,"cache_creation":2134808,"turn_count":324}'
if [[ "$stored" == "$expected_stored" ]]; then
    pass "OTR-3 (post-plugin-improvements A): all four counters preserved in artifact.orchestrator_tokens after narrowed render"
else
    fail "OTR-3: artifact counters drifted after narrowed render; got $stored, expected $expected_stored"
fi

# Assertion OTR-4: render still guards on missing orchestrator_tokens
# (pre-feature artifacts, interrupted runs) — the seed.json has no
# orchestrator_tokens object, so the base $ART render from earlier
# assertions shouldn't carry an Orchestrator line at all.
md_base=$("$TOOLS/artifact-render.py" --input "$ART")
if echo "$md_base" | grep -qF 'Orchestrator tokens:'; then
    fail "OTR-4: pre-feature artifact (no orchestrator_tokens) should not render header line"
else
    pass "OTR-4 (post-plugin-improvements A): missing orchestrator_tokens still omits header line (backward compat)"
fi

# Assertion OTR-5: zero-turn orchestrator_tokens (legacy artifacts that
# carried the dropped Phase-0 zero seed, or opted-in runs whose time
# window matched no turns) must also suppress the rendered line —
# "0 output / 0 input across 0 turns" is content-free noise. Guards the
# stronger `if turn_count:` predicate against accidental relaxation
# back to `is not None` (which would re-render zero-turn lines).
OTR5_DIR="$WORK/render-orch-zero"
mkdir -p "$OTR5_DIR"
"$TOOLS/artifact-patch.py" --init "@$FIX/artifact-seed.json" --path "$OTR5_DIR/art.json" >/dev/null
"$TOOLS/artifact-patch.py" --path "$OTR5_DIR/art.json" --set-json \
    'orchestrator_tokens={"total_input":0,"total_output":0,"cache_read":0,"cache_creation":0,"turn_count":0,"sessions":[]}' \
    >/dev/null
md_zero=$("$TOOLS/artifact-render.py" --input "$OTR5_DIR/art.json")
if echo "$md_zero" | grep -qF 'Orchestrator tokens:'; then
    fail "OTR-5: zero-turn orchestrator_tokens should suppress rendered line; saw: $(echo "$md_zero" | grep -F 'Orchestrator tokens:')"
else
    pass "OTR-5: zero-turn orchestrator_tokens suppressed (legacy zero seed + empty time-window opted-in runs)"
fi

# ------------------------------------------------------------------ Stage 2.7
# assign-finding-ids.sh (§13.12) — deterministic source-priority sort +
# monotonic F### assignment over pooled internal + external candidates.
# Stage 2.7 hoists id assignment to a single join point after Phase 1 +
# Phase 1.5 dispatch so the two phases can fan out concurrently without
# racing a shared id counter.

AI_TOOL="$TOOLS/assign-finding-ids.sh"

# Assertion AI-1: internal-only pool — 3 L1 + 2 L2 + 1 L3. Expect
# F001..F006 in source-priority order (L1 → L2 → L3) with input order
# preserved within each source bucket.
in='[{"sources":["L1-diff-local"],"file":"a.ts"},{"sources":["L1-diff-local"],"file":"b.ts"},{"sources":["L1-diff-local"],"file":"c.ts"},{"sources":["L2-structural"],"file":"d.ts"},{"sources":["L2-structural"],"file":"e.ts"},{"sources":["L3-claude-md"],"file":"f.ts"}]'
out=$(echo "$in" | "$AI_TOOL")
line=$(echo "$out" | jq -r '[.[] | "\(.id):\(.sources[0]):\(.file)"] | join(",")')
expected="F001:L1-diff-local:a.ts,F002:L1-diff-local:b.ts,F003:L1-diff-local:c.ts,F004:L2-structural:d.ts,F005:L2-structural:e.ts,F006:L3-claude-md:f.ts"
if [[ "$line" == "$expected" ]]; then
    pass "AI-1 (§13.12): internal-only pool assigns F001..F006 in L1→L2→L3 source order"
else
    fail "AI-1: expected '$expected', got '$line'"
fi

# Assertion AI-2: ensemble-mixed pool — 1 L1 + 1 L6 + 1 external-pr +
# 1 codex. Expect L1 → L6 → external-pr → codex.
in='[{"sources":["L1-diff-local"],"file":"a.ts"},{"sources":["L6-security"],"file":"b.ts"},{"sources":["external-pr:greptile[bot]"],"file":"c.ts"},{"sources":["codex"],"file":"d.ts"}]'
out=$(echo "$in" | "$AI_TOOL")
line=$(echo "$out" | jq -r '[.[] | "\(.id):\(.sources[0])"] | join(",")')
expected="F001:L1-diff-local,F002:L6-security,F003:external-pr:greptile[bot],F004:codex"
if [[ "$line" == "$expected" ]]; then
    pass "AI-2 (§13.12): ensemble-mixed pool orders L1 → L6 → external-pr → codex"
else
    fail "AI-2: expected '$expected', got '$line'"
fi

# Assertion AI-3: stable within source. 4 L1 candidates in input order
# A,B,C,D should emerge in the same order — jq sort_by is stable and
# our secondary key on input index preserves it across identical priorities.
in='[{"sources":["L1-diff-local"],"file":"A"},{"sources":["L1-diff-local"],"file":"B"},{"sources":["L1-diff-local"],"file":"C"},{"sources":["L1-diff-local"],"file":"D"}]'
out=$(echo "$in" | "$AI_TOOL")
line=$(echo "$out" | jq -r '[.[] | "\(.id):\(.file)"] | join(",")')
expected="F001:A,F002:B,F003:C,F004:D"
if [[ "$line" == "$expected" ]]; then
    pass "AI-3 (§13.12): same-source candidates preserve input order (stable sort)"
else
    fail "AI-3: expected '$expected', got '$line'"
fi

# Assertion AI-4: empty pool. `[]` in, `[]` out, exit 0. Non-ensemble
# runs with zero Phase 1 findings exercise this path.
out=$(echo '[]' | "$AI_TOOL"); code=$?
if [[ "$code" == "0" && "$out" == "[]" ]]; then
    pass "AI-4 (§13.12): empty pool returns '[]' with exit 0"
else
    fail "AI-4: expected empty-array passthrough; got code=$code out='$out'"
fi

# Assertion AI-5: malformed stdin → exit 1 with error-as-prompt.
stderr=$(echo 'not-json' | "$AI_TOOL" 2>&1 >/dev/null); code=$?
if [[ "$code" == "1" ]] \
    && echo "$stderr" | grep -q "not a JSON array" \
    && echo "$stderr" | grep -q "Did you mean" \
    && echo "$stderr" | grep -q "Action:"; then
    pass "AI-5 (§13.12): malformed stdin rejected with exit 1 + error-as-prompt"
else
    fail "AI-5: expected exit 1 + full error-as-prompt; got code=$code stderr='$stderr'"
fi

# Assertion AI-6: non-array stdin (JSON object) → same error path.
stderr=$(echo '{}' | "$AI_TOOL" 2>&1 >/dev/null); code=$?
if [[ "$code" == "1" ]] && echo "$stderr" | grep -q "not a JSON array"; then
    pass "AI-6 (§13.12): non-array JSON stdin rejected with exit 1"
else
    fail "AI-6: expected exit 1 for non-array JSON; got code=$code stderr='$stderr'"
fi

# Assertion AI-7: unknown source falls to priority 99 (sorted last) but
# still gets an id. Forward-compat for future source-family additions
# (e.g. a hypothetical 'semgrep' CLI reviewer) that ship before the
# helper is updated — the id assignment must not drop the candidate.
in='[{"sources":["mystery-source"],"file":"unknown.ts"},{"sources":["L1-diff-local"],"file":"known.ts"}]'
out=$(echo "$in" | "$AI_TOOL")
line=$(echo "$out" | jq -r '[.[] | "\(.id):\(.sources[0]):\(.file)"] | join(",")')
expected="F001:L1-diff-local:known.ts,F002:mystery-source:unknown.ts"
if [[ "$line" == "$expected" ]]; then
    pass "AI-7 (§13.12): unknown source falls to priority 99 (sorted last), id still assigned"
else
    fail "AI-7: expected '$expected', got '$line'"
fi

# ------------------------------------------------------------------ Stage 3
#
# Stage 3 introduces `/matthewsreview:fix`. These assertions cover the helper
# contracts it depends on — `group-fixes.py` (§21.5) fix-group union-find
# and `artifact-patch.py` batched fix-outcome modes. Fragment-level prose
# (Phase 7/8/9 orchestration) is not machine-tested here; real-repo runs
# are the first integration signal, same posture as Stage 2.5.B / 2.7.

GF_TOOL="$TOOLS/group-fixes.py"
GF_ART="$WORK/gf-art.json"

# Rebuild artifact from the fix-group fixture. Independent of the Stage 1/2
# state above; validator in --init guards schema shape.
if "$TOOLS/artifact-patch.py" --init "@$FIX/fix-group-seed.json" --path "$GF_ART" >/dev/null; then
    pass "FX-init: fix-group fixture loads into valid artifact"
else
    fail "FX-init: fix-group-seed.json --init failed"
fi

# Assertion FX-GF-1: single-finding eligible list → single FG with one id.
# F007 is standalone on src/e.ts — the happy path.
out=$("$GF_TOOL" --artifact "$GF_ART" --eligible-finding-ids "F007")
line=$(echo "$out" | jq -c '.')
expected='[{"id":"FG-1","finding_ids":["F007"],"files_planned":["src/e.ts"]}]'
if [[ "$line" == "$expected" ]]; then
    pass "FX-GF-1 (§21.5): single eligible finding produces single FG group"
else
    fail "FX-GF-1: expected '$expected', got '$line'"
fi

# Assertion FX-GF-2: two findings in the same cross_cutting_group merge.
# F004+F005 are on disjoint files (c.ts / d.ts) but linked by G1. The
# cross-cutting seed in §21.5 step 2 must fire before file-union step 3
# decides they're disjoint.
out=$("$GF_TOOL" --artifact "$GF_ART" --eligible-finding-ids "F004,F005")
line=$(echo "$out" | jq -c '.')
expected='[{"id":"FG-1","finding_ids":["F004","F005"],"files_planned":["src/c.ts","src/d.ts"]}]'
if [[ "$line" == "$expected" ]]; then
    pass "FX-GF-2 (§21.5): cross_cutting_groups merge eligible members (disjoint files)"
else
    fail "FX-GF-2: expected '$expected', got '$line'"
fi

# Assertion FX-GF-3: two findings sharing a planned file merge. F001 and
# F002 both plan src/a.ts — no cross-cutting link, the file-overlap step
# alone must catch this.
out=$("$GF_TOOL" --artifact "$GF_ART" --eligible-finding-ids "F001,F002")
line=$(echo "$out" | jq -c '.')
expected='[{"id":"FG-1","finding_ids":["F001","F002"],"files_planned":["src/a.ts"]}]'
if [[ "$line" == "$expected" ]]; then
    pass "FX-GF-3 (§21.5): findings sharing a planned file merge into one group"
else
    fail "FX-GF-3: expected '$expected', got '$line'"
fi

# Assertion FX-GF-4: transitive closure. F004+F005 linked by CCG; F004+F006
# share src/c.ts. All three must collapse to one group — tests that the
# union-find picks up the transitive relation (F005 → F004 → F006).
out=$("$GF_TOOL" --artifact "$GF_ART" --eligible-finding-ids "F004,F005,F006")
line=$(echo "$out" | jq -c '.')
expected='[{"id":"FG-1","finding_ids":["F004","F005","F006"],"files_planned":["src/c.ts","src/d.ts"]}]'
if [[ "$line" == "$expected" ]]; then
    pass "FX-GF-4 (§21.5): transitive closure (CCG + file-share) merges all three"
else
    fail "FX-GF-4: expected '$expected', got '$line'"
fi

# Assertion FX-GF-5: disjoint singletons stay singletons. F003 on b.ts,
# F007 on e.ts, no CCG — two separate FGs, numbered by minimum-id rule.
out=$("$GF_TOOL" --artifact "$GF_ART" --eligible-finding-ids "F003,F007")
line=$(echo "$out" | jq -c '.')
expected='[{"id":"FG-1","finding_ids":["F003"],"files_planned":["src/b.ts"]},{"id":"FG-2","finding_ids":["F007"],"files_planned":["src/e.ts"]}]'
if [[ "$line" == "$expected" ]]; then
    pass "FX-GF-5 (§21.5): disjoint singletons produce two FGs, numbered by minimum id"
else
    fail "FX-GF-5: expected '$expected', got '$line'"
fi

# Assertion FX-GF-6: empty eligible list → empty JSON array, exit 0.
# Orchestrator path: threshold filter excluded every finding; no fix
# groups to form, but the helper must not error.
out=$("$GF_TOOL" --artifact "$GF_ART" --eligible-finding-ids ""); code=$?
if [[ "$code" == "0" && "$out" == "[]" ]]; then
    pass "FX-GF-6 (§21.5): empty eligible list returns '[]' with exit 0"
else
    fail "FX-GF-6: expected '[]' + exit 0, got code=$code out='$out'"
fi

# Assertion FX-GF-7: unknown finding id → EXIT_VALIDATION (1) + error-as-prompt
# naming the bad id AND listing valid ids.
stderr=$("$GF_TOOL" --artifact "$GF_ART" --eligible-finding-ids "F999" 2>&1 >/dev/null); code=$?
if [[ "$code" == "1" ]] \
    && echo "$stderr" | grep -q "unknown id" \
    && echo "$stderr" | grep -q "F999" \
    && echo "$stderr" | grep -q "existing ids" \
    && echo "$stderr" | grep -q "Action:"; then
    pass "FX-GF-7 (§21.5): unknown eligible id rejected with exit 1 + error-as-prompt"
else
    fail "FX-GF-7: expected exit 1 + error-as-prompt; got code=$code stderr='$stderr'"
fi

# Assertion FX-GF-8: eligible finding with null validation_result is
# rejected. The orchestrator must not hand trivial-mode or below-gate
# findings to the grouper — the helper confirms it via error-as-prompt
# rather than silently dropping them. Rebuild a fresh artifact from the
# Stage-1 seed (whose F001 has validation_result=null per its fixture
# design) so this test is independent of whatever $ART is after the
# earlier Stage 1/2 assertions mutated it.
NULL_VR_ART="$WORK/gf-null-vr.json"
"$TOOLS/artifact-patch.py" --init "@$FIX/artifact-seed.json" --path "$NULL_VR_ART" >/dev/null
stderr=$("$GF_TOOL" --artifact "$NULL_VR_ART" --eligible-finding-ids "F001" 2>&1 >/dev/null); code=$?
if [[ "$code" == "1" ]] && echo "$stderr" | grep -q "validation_result is required"; then
    pass "FX-GF-8 (§21.5): eligible finding missing validation_result rejected"
else
    fail "FX-GF-8: expected exit 1 + validation_result message; got code=$code stderr='$stderr'"
fi

# Assertion FX-GF-9: a PROMOTED finding with null validation_result is accepted
# by the grouper — the human_confirmation override (§27) bypasses the
# fix_proposal requirement. files_planned falls back to [finding.file].
# Covers the §27 light-lane end-to-end path: promote → Phase 8 grouping →
# fix-group dispatch. Without this fallback, group-fixes.py would hard-error
# before Phase 8 ever sees the finding, nullifying the --fix-hint steering.
GF_PROMOTED_ART="$WORK/gf-promoted.json"
"$TOOLS/artifact-patch.py" --init "@$FIX/artifact-seed.json" --path "$GF_PROMOTED_ART" >/dev/null
GF_PROMOTE_HC=$(jq -nc '{
    reviewer: "tester@example.com",
    reason:   "promote light-lane for fix",
    ts:       "2026-04-19T12:00:00Z",
    promoted_from: {disposition:"uncertain", actionability:"report_only", score_phase4:null},
    fix_hint: "Update the docstring to match the code; do not modify the code."
}')
"$TOOLS/artifact-patch.py" --path "$GF_PROMOTED_ART" --finding-id F001 \
    --set disposition=confirmed_mechanical \
    --set current_state=open \
    --set actionability=auto_fixable \
    --set-json "human_confirmation=$GF_PROMOTE_HC" >/dev/null 2>&1 \
    || fail "FX-GF-9 setup: promote patch failed"
gf9_out=$("$GF_TOOL" --artifact "$GF_PROMOTED_ART" --eligible-finding-ids "F001" 2>"$WORK/gf9.err"); gf9_code=$?
gf9_files=$(echo "$gf9_out" | jq -c '.[0].files_planned' 2>/dev/null)
if [[ "$gf9_code" == "0" ]] && [[ "$gf9_files" == '["src/auth/session.ts"]' ]]; then
    pass "FX-GF-9 (§21.5, §27): promoted finding with null validation_result groups with files_planned=[finding.file]"
else
    fail "FX-GF-9: expected exit 0 + files_planned=[src/auth/session.ts]; got code=$gf9_code files=$gf9_files stderr=$(cat "$WORK/gf9.err")"
fi

# ------------------------------------------------------------------ Stage 3 — apply-fix-* modes
#
# --apply-fix-start collapses Phase 8 step 8.4 (bulk open→attempted) to a
# single call. --apply-fix-outcomes collapses Phase 9d (per-finding state
# transition + fix_attempt append) to a single call. Both follow the
# Stage-2.5.B --apply-decisions pattern: per-tuple atomic writes, first
# failure halts, one summary line on success.

AF_ART="$WORK/af-art.json"

# Build a fresh artifact for apply-fix-* assertions. Avoid reusing the
# gf-art state (which has been mutated by earlier GF assertions in theory,
# though in practice group-fixes.py is read-only — still, independence
# matters for test isolation).
if "$TOOLS/artifact-patch.py" --init "@$FIX/fix-group-seed.json" --path "$AF_ART" >/dev/null; then
    pass "FX-AF-init: rebuilt artifact for apply-fix-* tests"
else
    fail "FX-AF-init: --init failed"
fi

# Assertion FX-AF-1: --apply-fix-start bulk transition open→attempted.
# Three eligible findings; post-call all three have current_state=attempted.
"$TOOLS/artifact-patch.py" --path "$AF_ART" --apply-fix-start \
  '[{"id":"F001","run_id":"fixrun_smoke1"},{"id":"F002","run_id":"fixrun_smoke1"},{"id":"F003","run_id":"fixrun_smoke1"}]' \
  >/dev/null 2>&1
states=$(jq -r '.findings[0:3] | [.[].current_state] | join(",")' "$AF_ART")
if [[ "$states" == "attempted,attempted,attempted" ]]; then
    pass "FX-AF-1 (§21.2/§4 Phase 8): --apply-fix-start bulk open→attempted"
else
    fail "FX-AF-1: expected all three attempted, got '$states'"
fi

# Assertion FX-AF-2: --apply-fix-start halts loudly when a tuple's finding
# is not current_state=open. Re-running start on F001 (already attempted
# from AF-1) tests the Phase-7-gate-bypass guard: the Phase-7 leftover-
# attempted hard abort is supposed to catch stale state; --apply-fix-start
# refuses to silently no-op on same→same.
stderr=$("$TOOLS/artifact-patch.py" --path "$AF_ART" --apply-fix-start \
  '[{"id":"F001","run_id":"fixrun_smoke2"}]' 2>&1 >/dev/null); code=$?
if [[ "$code" == "2" ]] \
    && echo "$stderr" | grep -q "current_state='attempted' is not 'open'"; then
    pass "FX-AF-2 (§4 Phase 8): --apply-fix-start rejects non-open finding (exit 2)"
else
    fail "FX-AF-2: expected exit 2 + non-open guard, got code=$code stderr='$stderr'"
fi

# Assertion FX-AF-3: --apply-fix-outcomes verified outcome transitions
# attempted→resolved, disposition=resolved, reason=null, fix_attempt
# appended with output_sha.
"$TOOLS/artifact-patch.py" --path "$AF_ART" --apply-fix-outcomes \
  '[{"id":"F001","run_id":"fixrun_smoke1","fix_group_id":"FG-1","input_sha":"aaaa111","output_sha":"bbbb222","phase_9_outcome":"verified","timestamp":"2026-04-18T13:00:00Z"}]' \
  >/dev/null 2>&1
f1=$(jq -c '.findings[] | select(.id=="F001") | {current_state,disposition,reason,attempts:(.fix_attempts|length),last_outcome:(.fix_attempts[-1].phase_9_outcome),last_sha:(.fix_attempts[-1].output_sha)}' "$AF_ART")
expected='{"current_state":"resolved","disposition":"resolved","reason":null,"attempts":1,"last_outcome":"verified","last_sha":"bbbb222"}'
if [[ "$f1" == "$expected" ]]; then
    pass "FX-AF-3 (§13.1 Phase 9): verified → resolved+resolved, fix_attempt with output_sha"
else
    fail "FX-AF-3: expected '$expected', got '$f1'"
fi

# Assertion FX-AF-4: partial outcome → attempted→open, disposition=partial,
# reason prose includes phase_9_finding, fix_attempt captures the diagnostic.
"$TOOLS/artifact-patch.py" --path "$AF_ART" --apply-fix-outcomes \
  '[{"id":"F002","run_id":"fixrun_smoke1","fix_group_id":"FG-1","input_sha":"aaaa111","output_sha":"bbbb222","phase_9_outcome":"partial","timestamp":"2026-04-18T13:00:00Z","phase_9_finding":"missed x.ts:10"}]' \
  >/dev/null 2>&1
f2=$(jq -c '.findings[] | select(.id=="F002") | {current_state,disposition,reason,last_finding:(.fix_attempts[-1].phase_9_finding)}' "$AF_ART")
expected='{"current_state":"open","disposition":"partial","reason":"fix partial: missed x.ts:10","last_finding":"missed x.ts:10"}'
if [[ "$f2" == "$expected" ]]; then
    pass "FX-AF-4 (§13.1 Phase 9): partial → open+partial, reason prose + phase_9_finding"
else
    fail "FX-AF-4: expected '$expected', got '$f2'"
fi

# Assertion FX-AF-5: regression outcome → attempted→open, disposition=regression,
# output_sha on the fix_attempt MUST be null (group was reverted).
"$TOOLS/artifact-patch.py" --path "$AF_ART" --apply-fix-outcomes \
  '[{"id":"F003","run_id":"fixrun_smoke1","fix_group_id":"FG-2","input_sha":"aaaa111","output_sha":null,"phase_9_outcome":"regression","timestamp":"2026-04-18T13:00:00Z","phase_9_finding":"new 401 in y.ts:22"}]' \
  >/dev/null 2>&1
f3=$(jq -c '.findings[] | select(.id=="F003") | {current_state,disposition,reason,last_sha:(.fix_attempts[-1].output_sha),last_outcome:(.fix_attempts[-1].phase_9_outcome)}' "$AF_ART")
expected='{"current_state":"open","disposition":"regression","reason":"fix regressed: new 401 in y.ts:22","last_sha":null,"last_outcome":"regression"}'
if [[ "$f3" == "$expected" ]]; then
    pass "FX-AF-5 (§13.1 Phase 9 / §6): regression → open+regression, output_sha=null preserved"
else
    fail "FX-AF-5: expected '$expected', got '$f3'"
fi

# Assertion FX-AF-6: overlap-abort (phase_9_outcome=null). current_state
# MUST stay at attempted — this is what triggers the next run's
# leftover-attempted hard abort for deterministic recovery. fix_attempt is
# still appended for audit.
OA_ART="$WORK/af-oa.json"
"$TOOLS/artifact-patch.py" --init "@$FIX/fix-group-seed.json" --path "$OA_ART" >/dev/null
"$TOOLS/artifact-patch.py" --path "$OA_ART" --apply-fix-start '[{"id":"F004","run_id":"fixrun_oa"}]' >/dev/null
"$TOOLS/artifact-patch.py" --path "$OA_ART" --apply-fix-outcomes \
  '[{"id":"F004","run_id":"fixrun_oa","fix_group_id":"FG-1","input_sha":"aaaa111","output_sha":null,"phase_9_outcome":null,"timestamp":"2026-04-18T13:00:00Z","phase_9_finding":"run aborted: overlap on src/c.ts"}]' \
  >/dev/null 2>&1
f4=$(jq -c '.findings[] | select(.id=="F004") | {current_state,disposition,attempts:(.fix_attempts|length),last_sha:(.fix_attempts[-1].output_sha),last_outcome:(.fix_attempts[-1].phase_9_outcome),last_finding:(.fix_attempts[-1].phase_9_finding)}' "$OA_ART")
expected='{"current_state":"attempted","disposition":"confirmed_mechanical","attempts":1,"last_sha":null,"last_outcome":null,"last_finding":"run aborted: overlap on src/c.ts"}'
if [[ "$f4" == "$expected" ]]; then
    pass "FX-AF-6 (§4 Phase 9.pre): overlap-abort preserves current_state=attempted, appends audit fix_attempt"
else
    fail "FX-AF-6: expected '$expected', got '$f4'"
fi

# Assertion FX-AF-7: regression with non-null output_sha rejected. The
# helper enforces the §13.1 invariant that regressions have no commit.
"$TOOLS/artifact-patch.py" --init "@$FIX/fix-group-seed.json" --path "$WORK/af-rej.json" >/dev/null
"$TOOLS/artifact-patch.py" --path "$WORK/af-rej.json" --apply-fix-start '[{"id":"F001","run_id":"fixrun_rej"}]' >/dev/null
stderr=$("$TOOLS/artifact-patch.py" --path "$WORK/af-rej.json" --apply-fix-outcomes \
  '[{"id":"F001","run_id":"fixrun_rej","fix_group_id":"FG-1","input_sha":"aaaa111","output_sha":"ffff999","phase_9_outcome":"regression","timestamp":"2026-04-18T13:00:00Z","phase_9_finding":"x"}]' \
  2>&1 >/dev/null); code=$?
if [[ "$code" == "1" ]] && echo "$stderr" | grep -q "regression outcome requires output_sha=null"; then
    pass "FX-AF-7 (§13.1): regression with non-null output_sha rejected (exit 1)"
else
    fail "FX-AF-7: expected exit 1 + regression-null message; got code=$code stderr='$stderr'"
fi

# Assertion FX-AF-8: --apply-fix-outcomes tuple missing required key rejected.
stderr=$("$TOOLS/artifact-patch.py" --path "$WORK/af-rej.json" --apply-fix-outcomes \
  '[{"id":"F001","run_id":"fixrun_rej","phase_9_outcome":"verified"}]' \
  2>&1 >/dev/null); code=$?
if [[ "$code" == "1" ]] \
    && echo "$stderr" | grep -q "missing required key" \
    && echo "$stderr" | grep -q "fix_group_id"; then
    pass "FX-AF-8 (§21.2): --apply-fix-outcomes rejects tuple missing required key(s)"
else
    fail "FX-AF-8: expected exit 1 + missing-key message; got code=$code stderr='$stderr'"
fi

# Assertion FX-AF-9: unknown phase_9_outcome rejected. Defense against
# sub-agent response-parsing drift (e.g., a validator returns "verifed"
# instead of "verified" — a close typo where difflib's did-you-mean fires).
stderr=$("$TOOLS/artifact-patch.py" --path "$WORK/af-rej.json" --apply-fix-outcomes \
  '[{"id":"F001","run_id":"fixrun_rej","fix_group_id":"FG-1","input_sha":"aaaa111","output_sha":null,"phase_9_outcome":"verifed","timestamp":"2026-04-18T13:00:00Z"}]' \
  2>&1 >/dev/null); code=$?
if [[ "$code" == "1" ]] \
    && echo "$stderr" | grep -q "unknown phase_9_outcome" \
    && echo "$stderr" | grep -q "Did you mean 'verified'"; then
    pass "FX-AF-9 (§13.1 Phase 9): unknown phase_9_outcome rejected with did-you-mean"
else
    fail "FX-AF-9: expected exit 1 + unknown outcome + suggestion; got code=$code stderr='$stderr'"
fi

# Assertion FX-OUT-DUP (F003): --apply-fix-outcomes rejects duplicate
# finding ids in the same batch. Two tuples for the same finding would
# cause two fix_attempt appends and two state transitions in one call —
# audit-trail pollution at best, schema invariant violation at worst.
# The dup guard mirrors the one in --apply-decisions (BD-4) — same
# parallel path, same EXIT_VALIDATION (exit 1).
"$TOOLS/artifact-patch.py" --init "@$FIX/fix-group-seed.json" --path "$WORK/af-out-dup.json" >/dev/null
"$TOOLS/artifact-patch.py" --path "$WORK/af-out-dup.json" --apply-fix-start \
  '[{"id":"F001","run_id":"fixrun_dup"}]' >/dev/null
BEFORE_SHA=$(sha_of "$WORK/af-out-dup.json")
stderr=$("$TOOLS/artifact-patch.py" --path "$WORK/af-out-dup.json" --apply-fix-outcomes \
  '[{"id":"F001","run_id":"fixrun_dup","fix_group_id":"FG-1","input_sha":"aaaa111","output_sha":"bbbb222","phase_9_outcome":"verified","timestamp":"2026-04-18T13:00:00Z"},
    {"id":"F001","run_id":"fixrun_dup","fix_group_id":"FG-1","input_sha":"aaaa111","output_sha":null,"phase_9_outcome":"partial","timestamp":"2026-04-18T13:00:00Z","phase_9_finding":"x"}]' \
  2>&1 >/dev/null); code=$?
AFTER_SHA=$(sha_of "$WORK/af-out-dup.json")
if [[ "$code" == "1" ]] \
    && echo "$stderr" | grep -q "duplicate finding id" \
    && echo "$stderr" | grep -q "F001" \
    && [[ "$BEFORE_SHA" == "$AFTER_SHA" ]]; then
    pass "FX-OUT-DUP (F003): --apply-fix-outcomes rejects duplicate ids with exit 1; artifact unchanged"
else
    fail "FX-OUT-DUP: expected EXIT_VALIDATION (1) + duplicate-id stderr + unchanged file" "code=$code sha_eq=$([[ "$BEFORE_SHA" == "$AFTER_SHA" ]] && echo Y || echo N) stderr=$stderr"
fi

# ------------------------------------------------------------------ Reconcile-on-overlap (plans/reconcile-on-overlap.md)
#
# Assertions FX-RECON-*: the 9.pre.offer + 9.pre.reconcile + FG-RECON
# synthetic-group wiring in 10-post-fix-and-commit.md. Grep-level over the
# fragment text for the structural contracts (options, preservation
# snapshot, merge-agent prompt core, delete-leak ordering), plus one
# fixture-level check that --apply-fix-outcomes still accepts the
# ORIGINAL FG-N as fix_group_id on a reconciled run (FG-RECON is
# in-memory only; schema-valid FG-N lands on disk).

FRAG="$REPO/fragments/10-post-fix-and-commit.md"

# FX-RECON-1: fragment offers a three-way ASK on overlap,
# with Abort as the default (recommended) choice.
if grep -q "9.pre.offer" "$FRAG" \
   && grep -q "ASK with three options" "$FRAG" \
   && grep -q "Abort (recommended)" "$FRAG" \
   && grep -q "Reconcile — dispatch one merge agent" "$FRAG" \
   && grep -q "Inspect — leave tree as-is" "$FRAG"; then
    pass "FX-RECON-1: 9.pre.offer presents three-way ASK with Abort as default"
else
    fail "FX-RECON-1: fragment missing one of {9.pre.offer, ASK with three options, Abort/Reconcile/Inspect options}"
fi

# FX-RECON-2: reconcile branch collapses fix_groups to a synthetic
# FG-RECON entry AND snapshots the original per-finding fix_group_id
# (original_fix_group_by_finding) for 9d schema compat.
if grep -q 'id: "FG-RECON"' "$FRAG" \
   && grep -q "original_fix_group_by_finding" "$FRAG" \
   && grep -q "reconciled_flag=true" "$FRAG"; then
    pass "FX-RECON-2: fragment collapses fix_groups to FG-RECON and snapshots original per-finding group"
else
    fail "FX-RECON-2: fragment missing FG-RECON collapse or original-group snapshot"
fi

# FX-RECON-3: merge-agent prompt carries the core contract (unresolved
# conflicts escape hatch, delete/rename prohibition, per-group tracking).
if grep -q "unresolved_conflicts" "$FRAG" \
   && grep -q "DO NOT delete or rename files" "$FRAG" \
   && grep -q "reconciled_from_groups" "$FRAG" \
   && grep -q "Phase 9 reconciliation agent" "$FRAG"; then
    pass "FX-RECON-3: merge-agent prompt carries core contract (unresolved_conflicts + delete prohibition + group tracking)"
else
    fail "FX-RECON-3: merge-agent prompt missing one of the core contract pieces"
fi

# FX-RECON-4: on a reconciled run, apply-fix-outcomes tuples MUST use
# each finding's original FG-N (schema rejects FG-RECON). This is a
# smoke-level guard that the schema still validates when the
# reconciled run's fix_attempts preserve FG-1/FG-2 rather than
# FG-RECON — i.e., that 9d's fix_group_id override actually prevents
# the schema violation we'd otherwise hit.
stderr=$("$TOOLS/artifact-patch.py" --init "@$FIX/fix-group-seed.json" --path "$WORK/recon-ok.json" 2>&1); code=$?
[[ "$code" != "0" ]] && fail "FX-RECON-4 setup: --init failed (code=$code stderr=$stderr)"
"$TOOLS/artifact-patch.py" --path "$WORK/recon-ok.json" --apply-fix-start \
  '[{"id":"F001","run_id":"fixrun_rc"},{"id":"F002","run_id":"fixrun_rc"}]' >/dev/null 2>&1
# F001 and F002 originally belonged to different groups (FG-1, FG-2);
# on a reconciled run, both commit under a single commit_sha but each
# preserves its ORIGINAL fix_group_id.
"$TOOLS/artifact-patch.py" --path "$WORK/recon-ok.json" --apply-fix-outcomes \
  '[{"id":"F001","run_id":"fixrun_rc","fix_group_id":"FG-1","input_sha":"aaaa111","output_sha":"cccc333","phase_9_outcome":"verified","timestamp":"2026-04-21T10:00:00Z"},
    {"id":"F002","run_id":"fixrun_rc","fix_group_id":"FG-2","input_sha":"aaaa111","output_sha":"cccc333","phase_9_outcome":"verified","timestamp":"2026-04-21T10:00:00Z"}]' \
  >/dev/null 2>&1
recon_ids=$(jq -r '[.findings[] | select(.id=="F001" or .id=="F002") | .fix_attempts[-1].fix_group_id] | join(",")' "$WORK/recon-ok.json")
if [[ "$recon_ids" == "FG-1,FG-2" ]]; then
    pass "FX-RECON-4: reconciled run preserves original per-finding fix_group_id (schema-valid FG-N, not FG-RECON)"
else
    fail "FX-RECON-4: expected 'FG-1,FG-2', got '$recon_ids'"
fi

# FX-RECON-5: delete-leak path still short-circuits to abort WITHOUT
# showing the offer. The fragment ordering must place the deleted_paths
# branch above 9.pre.offer.
deleted_line=$(grep -n 'deleted_paths=.*git status' "$FRAG" | head -1 | cut -d: -f1)
offer_line=$(grep -n '^#### 9.pre.offer' "$FRAG" | head -1 | cut -d: -f1)
if [[ -n "$deleted_line" && -n "$offer_line" && "$deleted_line" -lt "$offer_line" ]]; then
    pass "FX-RECON-5: delete-leak detection precedes 9.pre.offer (delete-leak never sees the reconcile offer)"
else
    fail "FX-RECON-5: expected deleted_paths detection BEFORE 9.pre.offer (got deleted_line=$deleted_line offer_line=$offer_line)"
fi

# ------------------------------------------------------------------ Stage 3 — render fix_runs
#
# artifact-render.py gained a richer `## Fix runs` section plus the
# retry-eligible partial/regression sections. These assertions pin the
# header shape, the outcome labels (including the overlap-abort label
# for phase_9_outcome=null), and the oldest-first ordering invariant
# (runs flow top-to-bottom chronologically, matching how GitHub renders
# the enclosing PR comment).
# expected.md already exercises the single-verified-run case at
# assertion 9 above; these tests focus on the edge cases not covered
# there.

RF_ART="$WORK/rf-art.json"

# Build a fresh artifact with F001 open/confirmed_mechanical and exercise the
# full fix cycle to produce a verified+partial+regression multi-outcome
# run.
"$TOOLS/artifact-patch.py" --init "@$FIX/fix-group-seed.json" --path "$RF_ART" >/dev/null
"$TOOLS/artifact-patch.py" --path "$RF_ART" --apply-fix-start \
  '[{"id":"F001","run_id":"fixrun_rf"},{"id":"F002","run_id":"fixrun_rf"},{"id":"F003","run_id":"fixrun_rf"}]' >/dev/null 2>&1
"$TOOLS/artifact-patch.py" --path "$RF_ART" --apply-fix-outcomes \
  '[{"id":"F001","run_id":"fixrun_rf","fix_group_id":"FG-1","input_sha":"aaaa111","output_sha":"bbbb222","phase_9_outcome":"verified","timestamp":"2026-04-18T14:00:00Z"},
    {"id":"F002","run_id":"fixrun_rf","fix_group_id":"FG-1","input_sha":"aaaa111","output_sha":"bbbb222","phase_9_outcome":"partial","timestamp":"2026-04-18T14:00:00Z","phase_9_finding":"missed q.ts:5"},
    {"id":"F003","run_id":"fixrun_rf","fix_group_id":"FG-2","input_sha":"aaaa111","output_sha":null,"phase_9_outcome":"regression","timestamp":"2026-04-18T14:00:00Z","phase_9_finding":"new 401 in z.ts"}]' >/dev/null 2>&1

"$TOOLS/artifact-render.py" --input "$RF_ART" --output "$WORK/rf.md" >/dev/null

# Assertion FX-RF-1: Fix runs section header + per-run sub-header present.
if grep -q '^## Fix runs$' "$WORK/rf.md" && grep -q '^### Run `fixrun_rf` — 2026-04-18T14:00:00Z$' "$WORK/rf.md"; then
    pass "FX-RF-1 (§7): Fix runs section with per-run ### sub-header and timestamp"
else
    fail "FX-RF-1: expected ## Fix runs + ### Run header; $WORK/rf.md"
fi

# Assertion FX-RF-2: outcome summary line captures all three labels.
if grep -Fq '1 fixed and verified, 1 partial, 1 regression' "$WORK/rf.md"; then
    pass "FX-RF-2 (§7): outcome summary shows verified + partial + regression counts"
else
    fail "FX-RF-2: expected mixed-outcome summary line, got:
$(grep -A1 'Outcomes:' "$WORK/rf.md")"
fi

# Assertion FX-RF-3: per-finding table renders each outcome label correctly
# (✓ fixed and verified / ⚠ partial / ✗ regression) plus the phase_9_finding text.
if grep -Fq '| F001 | FG-1 | ✓ fixed and verified |' "$WORK/rf.md" \
    && grep -Fq '| F002 | FG-1 | ⚠ partial | missed q.ts:5 |' "$WORK/rf.md" \
    && grep -Fq '| F003 | FG-2 | ✗ regression (reverted) | new 401 in z.ts |' "$WORK/rf.md"; then
    pass "FX-RF-3 (§7): per-finding table renders verified/partial/regression with phase_9_finding"
else
    fail "FX-RF-3: per-finding table row(s) missing or mis-rendered; $WORK/rf.md"
fi

# Assertion FX-RF-4: Fix runs section absent when no fix_attempts exist.
"$TOOLS/artifact-patch.py" --init "@$FIX/fix-group-seed.json" --path "$WORK/rf-fresh.json" >/dev/null
"$TOOLS/artifact-render.py" --input "$WORK/rf-fresh.json" --output "$WORK/rf-fresh.md" >/dev/null
if ! grep -q '^## Fix runs$' "$WORK/rf-fresh.md"; then
    pass "FX-RF-4 (§7): Fix runs section ABSENT on artifacts with no fix_attempts"
else
    fail "FX-RF-4: Fix runs section rendered on an artifact with zero fix_attempts"
fi

# Assertion FX-RF-5: overlap-abort (phase_9_outcome=null) renders as
# '⚠ overlap-abort' in the per-finding table rather than raw 'None' or
# disappearing. Tests the §4 Phase 9.pre audit-trail visibility.
"$TOOLS/artifact-patch.py" --init "@$FIX/fix-group-seed.json" --path "$WORK/rf-oa.json" >/dev/null
"$TOOLS/artifact-patch.py" --path "$WORK/rf-oa.json" --apply-fix-start \
  '[{"id":"F004","run_id":"fixrun_oa"}]' >/dev/null 2>&1
"$TOOLS/artifact-patch.py" --path "$WORK/rf-oa.json" --apply-fix-outcomes \
  '[{"id":"F004","run_id":"fixrun_oa","fix_group_id":"FG-1","input_sha":"aaaa111","output_sha":null,"phase_9_outcome":null,"timestamp":"2026-04-18T15:00:00Z","phase_9_finding":"run aborted: overlap on src/a.ts"}]' >/dev/null 2>&1
"$TOOLS/artifact-render.py" --input "$WORK/rf-oa.json" --output "$WORK/rf-oa.md" >/dev/null
if grep -Fq '| F004 | FG-1 | ⚠ overlap-abort | run aborted: overlap on src/a.ts |' "$WORK/rf-oa.md" \
    && grep -Fq '1 overlap-abort' "$WORK/rf-oa.md"; then
    pass "FX-RF-5 (§4 Phase 9.pre / §7): overlap-abort renders distinctly in per-finding table + outcome summary"
else
    fail "FX-RF-5: expected overlap-abort label; got:
$(grep -A3 'Fix runs' "$WORK/rf-oa.md")"
fi

# Assertion FX-RF-6: oldest-first ordering. Two runs on the same artifact,
# different timestamps; expect the older run's ### header to appear first
# so the Fix runs section flows chronologically top-to-bottom like the
# enclosing PR comment thread.
"$TOOLS/artifact-patch.py" --init "@$FIX/fix-group-seed.json" --path "$WORK/rf-two.json" >/dev/null
# Run A at 13:00
"$TOOLS/artifact-patch.py" --path "$WORK/rf-two.json" --apply-fix-start '[{"id":"F007","run_id":"fixrun_old"}]' >/dev/null 2>&1
"$TOOLS/artifact-patch.py" --path "$WORK/rf-two.json" --apply-fix-outcomes \
  '[{"id":"F007","run_id":"fixrun_old","fix_group_id":"FG-1","input_sha":"aaaa111","output_sha":"cccc333","phase_9_outcome":"verified","timestamp":"2026-04-18T13:00:00Z"}]' >/dev/null 2>&1
# F007 is now resolved — to run a second fix, we need a fresh open finding.
# Use F005 (currently open/confirmed_mechanical) for run B at 16:00.
"$TOOLS/artifact-patch.py" --path "$WORK/rf-two.json" --apply-fix-start '[{"id":"F005","run_id":"fixrun_new"}]' >/dev/null 2>&1
"$TOOLS/artifact-patch.py" --path "$WORK/rf-two.json" --apply-fix-outcomes \
  '[{"id":"F005","run_id":"fixrun_new","fix_group_id":"FG-1","input_sha":"bbbb222","output_sha":"dddd444","phase_9_outcome":"verified","timestamp":"2026-04-18T16:00:00Z"}]' >/dev/null 2>&1

"$TOOLS/artifact-render.py" --input "$WORK/rf-two.json" --output "$WORK/rf-two.md" >/dev/null
# Extract line numbers of the two ### Run sub-headers; older (fixrun_old) must come first.
line_new=$(grep -n '^### Run `fixrun_new`' "$WORK/rf-two.md" | cut -d: -f1)
line_old=$(grep -n '^### Run `fixrun_old`' "$WORK/rf-two.md" | cut -d: -f1)
if [[ -n "$line_new" && -n "$line_old" && "$line_old" -lt "$line_new" ]]; then
    pass "FX-RF-6 (§7): Fix runs ordered oldest-first (line $line_old before $line_new)"
else
    fail "FX-RF-6: expected fixrun_old before fixrun_new, got old=$line_old new=$line_new"
fi

# ------------------------------------------------------------------ Stage 2.8
# PR comment freshness filter (§21.10, §13.13). Replaces the Stage-2
# `--since` time filter with a per-record code-locality check.
#
# Scratch 2-commit repo: C1 creates a.txt + b.txt; C2 modifies a.txt.
# Review comments pinned to C1 are fresh if their path wasn't touched in
# C1..HEAD, stale otherwise. Review submissions (no path) intersect the
# C1..HEAD diff with --reviewed-files. Issue comments (no commit_id) use
# a fixture pr_commits.json with known committer.date values.

CF_DIR="$WORK/comment-freshness"
mkdir -p "$CF_DIR/repo" "$CF_DIR/fixtures"
(
    cd "$CF_DIR/repo"
    git init --quiet --initial-branch=main 2>/dev/null || git init --quiet
    git config user.email "smoke@example.com"
    git config user.name "smoke"
    git symbolic-ref HEAD refs/heads/main 2>/dev/null || true
    echo "alpha" > a.txt
    echo "beta"  > b.txt
    git add a.txt b.txt
    git commit --quiet -m "c1: add a + b"
    echo "alpha-modified" > a.txt
    git add a.txt
    git commit --quiet -m "c2: modify a"
)
CF_C1=$(cd "$CF_DIR/repo" && git rev-parse HEAD~1)
CF_C2=$(cd "$CF_DIR/repo" && git rev-parse HEAD)

# Fixture pr_commits.json mimics pulls/<pr>/commits shape — an array of
# records with .commit.committer.date. Latest date = 2026-04-18T12:00:00Z.
cat > "$CF_DIR/fixtures/pr_commits.json" <<JSON
[
  {"sha":"aaa111","commit":{"committer":{"date":"2026-04-18T10:00:00Z"}}},
  {"sha":"bbb222","commit":{"committer":{"date":"2026-04-18T12:00:00Z"}}}
]
JSON

# Assertion CF-1: review_comment pinned to C1, path b.txt (untouched in
# C1..HEAD). Freshness helper includes it; audit action=fresh.
in_json=$(jq -nc --arg sha "$CF_C1" \
    '[{id:1,author_login:"bot[bot]",author_type:"Bot",created_at:"2026-04-18T15:00:00Z",body:"x",kind:"review_comment",path:"b.txt",line:1,commit_id:$sha}]')
out=$(cd "$CF_DIR/repo" && echo "$in_json" \
    | "$TOOLS/comment-freshness.sh" --fixtures-dir "$CF_DIR/fixtures" \
        --reviewed-files "a.txt,b.txt" 2>"$CF_DIR/cf1.err")
len=$(echo "$out" | jq 'length')
if [[ "$len" == "1" ]] && grep -q "action=fresh" "$CF_DIR/cf1.err" \
    && grep -q "reason=path-unchanged" "$CF_DIR/cf1.err"; then
    pass "CF-1 (§21.10): review_comment on unchanged path is included (action=fresh)"
else
    fail "CF-1: expected include + action=fresh; got len=$len stderr=$(cat "$CF_DIR/cf1.err")"
fi

# Assertion CF-2: review_comment pinned to C1, path a.txt (touched in
# C1..HEAD). Freshness helper excludes it; audit action=stale.
in_json=$(jq -nc --arg sha "$CF_C1" \
    '[{id:2,author_login:"bot[bot]",author_type:"Bot",created_at:"2026-04-18T15:00:00Z",body:"x",kind:"review_comment",path:"a.txt",line:1,commit_id:$sha}]')
out=$(cd "$CF_DIR/repo" && echo "$in_json" \
    | "$TOOLS/comment-freshness.sh" --fixtures-dir "$CF_DIR/fixtures" \
        --reviewed-files "a.txt,b.txt" 2>"$CF_DIR/cf2.err")
len=$(echo "$out" | jq 'length')
if [[ "$len" == "0" ]] && grep -q "action=stale" "$CF_DIR/cf2.err" \
    && grep -q "reason=path-touched" "$CF_DIR/cf2.err"; then
    pass "CF-2 (§21.10): review_comment on touched path is excluded (action=stale)"
else
    fail "CF-2: expected exclude + action=stale; got len=$len stderr=$(cat "$CF_DIR/cf2.err")"
fi

# Assertion CF-3: review submission (no path) pinned to C1, reviewed_files
# includes only b.txt. Diff C1..HEAD touches a.txt but not b.txt → empty
# intersection → include.
in_json=$(jq -nc --arg sha "$CF_C1" \
    '[{id:3,author_login:"bot[bot]",author_type:"Bot",created_at:"2026-04-18T15:00:00Z",body:"x",kind:"review",path:null,line:null,commit_id:$sha}]')
out=$(cd "$CF_DIR/repo" && echo "$in_json" \
    | "$TOOLS/comment-freshness.sh" --fixtures-dir "$CF_DIR/fixtures" \
        --reviewed-files "b.txt" 2>"$CF_DIR/cf3.err")
len=$(echo "$out" | jq 'length')
if [[ "$len" == "1" ]] && grep -q "action=fresh" "$CF_DIR/cf3.err"; then
    pass "CF-3 (§21.10): review submission with no reviewed-file touched is included"
else
    fail "CF-3: expected include; got len=$len stderr=$(cat "$CF_DIR/cf3.err")"
fi

# Assertion CF-4: review submission pinned to C1, reviewed_files includes
# a.txt. Diff C1..HEAD touches a.txt → non-empty intersection → exclude.
in_json=$(jq -nc --arg sha "$CF_C1" \
    '[{id:4,author_login:"bot[bot]",author_type:"Bot",created_at:"2026-04-18T15:00:00Z",body:"x",kind:"review",path:null,line:null,commit_id:$sha}]')
out=$(cd "$CF_DIR/repo" && echo "$in_json" \
    | "$TOOLS/comment-freshness.sh" --fixtures-dir "$CF_DIR/fixtures" \
        --reviewed-files "a.txt,b.txt" 2>"$CF_DIR/cf4.err")
len=$(echo "$out" | jq 'length')
if [[ "$len" == "0" ]] && grep -q "action=stale" "$CF_DIR/cf4.err" \
    && grep -q "reason=reviewed-file-touched" "$CF_DIR/cf4.err"; then
    pass "CF-4 (§21.10): review submission with touched reviewed-file is excluded"
else
    fail "CF-4: expected exclude; got len=$len stderr=$(cat "$CF_DIR/cf4.err")"
fi

# Assertion CF-5: issue_comment (no commit_id) with created_at newer than
# the latest committer.date in the fixture → included (action=fresh-summary).
# Fixture latest = 2026-04-18T12:00:00Z.
in_json='[{"id":5,"author_login":"greptile[bot]","author_type":"Bot","created_at":"2026-04-18T13:00:00Z","body":"nits","kind":"issue_comment","path":null,"line":null,"commit_id":null}]'
out=$(cd "$CF_DIR/repo" && echo "$in_json" \
    | "$TOOLS/comment-freshness.sh" --fixtures-dir "$CF_DIR/fixtures" \
        --reviewed-files "a.txt,b.txt" 2>"$CF_DIR/cf5.err")
len=$(echo "$out" | jq 'length')
if [[ "$len" == "1" ]] && grep -q "action=fresh-summary" "$CF_DIR/cf5.err" \
    && grep -q "reason=newer-than-latest-commit" "$CF_DIR/cf5.err"; then
    pass "CF-5 (§21.10): issue_comment posted after latest commit is included (C2 policy)"
else
    fail "CF-5: expected fresh-summary + include; got len=$len stderr=$(cat "$CF_DIR/cf5.err")"
fi

# Assertion CF-6: issue_comment with created_at older than the latest
# committer.date → excluded (action=stale-summary).
in_json='[{"id":6,"author_login":"greptile[bot]","author_type":"Bot","created_at":"2026-04-18T08:00:00Z","body":"old","kind":"issue_comment","path":null,"line":null,"commit_id":null}]'
out=$(cd "$CF_DIR/repo" && echo "$in_json" \
    | "$TOOLS/comment-freshness.sh" --fixtures-dir "$CF_DIR/fixtures" \
        --reviewed-files "a.txt,b.txt" 2>"$CF_DIR/cf6.err")
len=$(echo "$out" | jq 'length')
if [[ "$len" == "0" ]] && grep -q "action=stale-summary" "$CF_DIR/cf6.err" \
    && grep -q "reason=latest-commit-newer" "$CF_DIR/cf6.err"; then
    pass "CF-6 (§21.10): issue_comment posted before latest commit is excluded (C2 policy)"
else
    fail "CF-6: expected stale-summary + exclude; got len=$len stderr=$(cat "$CF_DIR/cf6.err")"
fi

# Assertion CF-7: review_comment pinned to a commit_id that doesn't exist
# in the scratch repo (simulates force-push / shallow clone). Fetch fallback
# is skipped in --fixtures-dir mode, so the helper excludes with
# action=unreachable.
in_json='[{"id":7,"author_login":"bot[bot]","author_type":"Bot","created_at":"2026-04-18T15:00:00Z","body":"x","kind":"review_comment","path":"a.txt","line":1,"commit_id":"deadbeef00000000000000000000000000000000"}]'
out=$(cd "$CF_DIR/repo" && echo "$in_json" \
    | "$TOOLS/comment-freshness.sh" --fixtures-dir "$CF_DIR/fixtures" \
        --reviewed-files "a.txt,b.txt" 2>"$CF_DIR/cf7.err")
len=$(echo "$out" | jq 'length')
if [[ "$len" == "0" ]] && grep -q "action=unreachable" "$CF_DIR/cf7.err" \
    && grep -q "reason=commit_id-not-in-history" "$CF_DIR/cf7.err"; then
    pass "CF-7 (§21.10): unreachable commit_id excluded with action=unreachable"
else
    fail "CF-7: expected unreachable; got len=$len stderr=$(cat "$CF_DIR/cf7.err")"
fi

# CF-8: missing-dep guard — a dep-less PATH fails at entry with exit 5
# (error-as-prompt), per the AGENTS.md rule-3 contract (a function named
# die_missing_dep must return EXIT_MISSING_DEP, not the validation code).
# Run via /bin/bash so the empty PATH only affects the script's own
# lookups, not the `#!/usr/bin/env bash` shebang. Only bash builtins run
# pre-guard, so the git guard (the first of the three) fires.
mkdir -p "$CF_DIR/cf8-emptybin"
cf8_rc=0
cf8_err=$(PATH="$CF_DIR/cf8-emptybin" /bin/bash "$TOOLS/comment-freshness.sh" \
    --fixtures-dir "$CF_DIR/fixtures" --reviewed-files "a.txt" \
    2>&1 >/dev/null) || cf8_rc=$?
if [[ "$cf8_rc" == "5" ]] \
    && echo "$cf8_err" | grep -q 'git not found' \
    && echo "$cf8_err" | grep -q '^Action:'; then
    pass "CF-8: missing-dep guard — dep-less PATH exits 5 with error-as-prompt at entry"
else
    fail "CF-8: expected rc=5 + 'git not found' + 'Action:'; got rc=$cf8_rc err='$cf8_err'"
fi

# ------------------------------------------------------------------ Stage 2.8.B guards
# These two assertions confirm --since is actually gone (not just ignored).
# CF-ES-1 also exercises the fixture-replay happy path without --since — was
# previously a usage error before Stage 2.8 because --since was required.

# CF-ES-1: external-scrape.sh --fixtures-dir succeeds without --since.
es_out=$(MATTHEWS_REVIEW_FIXTURES_USER=smokeuser "$TOOLS/external-scrape.sh" \
            --fixtures-dir "$EXT" 2>"$CF_DIR/es1.err")
es_rc=$?
es_type=$(echo "$es_out" | jq -r 'type' 2>/dev/null)
if [[ "$es_rc" == "0" && "$es_type" == "array" ]]; then
    pass "CF-ES-1 (§21.8): external-scrape.sh succeeds without --since (post-2.8 default)"
else
    fail "CF-ES-1: expected rc=0 + array; got rc=$es_rc type=$es_type stderr=$(cat "$CF_DIR/es1.err")"
fi

# CF-ES-2: external-scrape.sh --since <iso> is rejected (unknown-arg usage error).
es_stderr=$("$TOOLS/external-scrape.sh" --since 2026-01-01T00:00:00Z \
              --fixtures-dir "$EXT" 2>&1 >/dev/null); es_code=$?
if [[ "$es_code" == "64" ]] && echo "$es_stderr" | grep -q "unknown arg '--since'"; then
    pass "CF-ES-2 (§21.8): external-scrape.sh --since is rejected with exit 64 + unknown-arg"
else
    fail "CF-ES-2: expected exit 64 + unknown-arg; got code=$es_code stderr=$es_stderr"
fi

# ------------------------------------------------------------------ MP-* /matthewsreview:promote (§27)
#
# Covers the human_confirmation field, Phase 8 eligibility bypass
# (§5.2.1, §13.1, §13.2), and the renderer's (human-confirmed) tag.
# Fixture's F006 is architecture/light-lane/score=48/uncertain — the
# canonical "would never be Phase-8-eligible without a human override"
# case, so perfect for the eligibility-bypass assertions.

MP_ART="$WORK/art-promote.json"
cp "$ART" "$MP_ART"  # reuse the fully-populated post-stage-1 artifact

# MP-1: --set-json human_confirmation=null succeeds (schema accepts null).
if "$TOOLS/artifact-patch.py" --path "$MP_ART" --finding-id F006 \
        --set-json human_confirmation=null >/dev/null 2>&1; then
    pass "MP-1 (§27.3): --set-json human_confirmation=null accepted"
else
    fail "MP-1: --set-json human_confirmation=null should succeed"
fi

# MP-2: --set-json human_confirmation=<valid object> succeeds.
MP_HC_VALID=$(jq -nc '{
    reviewer: "tester@example.com",
    reason:   "smoke test promotion",
    ts:       "2026-04-18T12:00:00Z",
    promoted_from: {disposition:"uncertain", actionability:"report_only", score_phase4:48}
}')
if "$TOOLS/artifact-patch.py" --path "$MP_ART" --finding-id F006 \
        --set-json "human_confirmation=$MP_HC_VALID" >/dev/null 2>&1; then
    pass "MP-2 (§27.3): --set-json human_confirmation=<valid object> accepted"
else
    fail "MP-2: --set-json with valid human_confirmation object should succeed"
fi

# MP-3: incomplete human_confirmation (missing promoted_from) rejected.
# Top-level schema is anyOf: [null, <object-with-required-fields>]; jsonschema
# reports "is not valid under any of the given schemas" with the field path
# ($findings[N].human_confirmation) rather than naming the specific missing
# sub-field. Grep on the field path — specific enough to prove the rejection
# is about this field and not, say, a typo elsewhere.
MP_HC_BAD=$(jq -nc '{reviewer: "x", reason: "y", ts: "2026-04-18T12:00:00Z"}')
mp3_stderr=$("$TOOLS/artifact-patch.py" --path "$MP_ART" --finding-id F006 \
        --set-json "human_confirmation=$MP_HC_BAD" 2>&1 >/dev/null); mp3_code=$?
if [[ "$mp3_code" != "0" ]] && echo "$mp3_stderr" | grep -q "human_confirmation"; then
    pass "MP-3 (§27.3): incomplete human_confirmation (missing promoted_from) rejected"
else
    fail "MP-3: expected non-zero + 'human_confirmation' in stderr; code=$mp3_code stderr=$mp3_stderr"
fi

# MP-4: F006 is NOT in Phase 8 eligible set at baseline — architecture impact_type
# fails the lane filter, score 48 fails the 60-threshold, and no human_confirmation
# to bypass. Asserts the unpromoted path (the failure case the bypass is designed
# to rescue). Uses the same jq as 09-fix-execution.md step 8.1.
MP_BASELINE="$WORK/art-promote-baseline.json"
cp "$ART" "$MP_BASELINE"  # fresh copy, no MP-2 mutation
mp4_ids=$(jq -r --argjson thr 60 '
    [.findings[]
     | select(.current_state == "open")
     | select(.disposition == "confirmed_mechanical" or .disposition == "partial" or .disposition == "regression")
     | select(
         (.human_confirmation != null)
         or (
           (.impact_type == "correctness" or .impact_type == "security")
           and (.score_phase4 != null and .score_phase4 >= $thr)
         )
       )
     | .id
    ] | join(",")
' "$MP_BASELINE")
if [[ ",$mp4_ids," != *,F006,* ]]; then
    pass "MP-4 (§5.2.1, §13.1): unpromoted F006 (architecture, score=48, uncertain) is NOT Phase-8-eligible"
else
    fail "MP-4: F006 should be ineligible without human_confirmation; got ids=$mp4_ids"
fi

# MP-5: after promoting F006 (disposition=confirmed_mechanical + actionability=auto_fixable +
# human_confirmation set), the same Phase 8 selector DOES include it. Tests the bypass.
MP_PROMOTED="$WORK/art-promote-done.json"
cp "$ART" "$MP_PROMOTED"
"$TOOLS/artifact-patch.py" --path "$MP_PROMOTED" --finding-id F006 \
    --set disposition=confirmed_mechanical \
    --set actionability=auto_fixable \
    --set-json "human_confirmation=$MP_HC_VALID" >/dev/null 2>&1 \
    || fail "MP-5 setup: promote patch failed"
mp5_ids=$(jq -r --argjson thr 60 '
    [.findings[]
     | select(.current_state == "open")
     | select(.disposition == "confirmed_mechanical" or .disposition == "partial" or .disposition == "regression")
     | select(
         (.human_confirmation != null)
         or (
           (.impact_type == "correctness" or .impact_type == "security")
           and (.score_phase4 != null and .score_phase4 >= $thr)
         )
       )
     | .id
    ] | join(",")
' "$MP_PROMOTED")
if [[ ",$mp5_ids," == *,F006,* ]]; then
    pass "MP-5 (§5.2.1, §13.1, §27.6): promoted F006 IS Phase-8-eligible (bypass works)"
else
    fail "MP-5: F006 should be eligible after promotion; got ids=$mp5_ids"
fi

# MP-6: renderer output contains "(human-confirmed)" somewhere after promotion.
# F006 is light-lane so it lands in render_light_lane; the helper inserts the tag
# in both deep and light lane tables, so this also exercises _claim_with_promotion.
MP_MD="$WORK/art-promote-done.md"
"$TOOLS/artifact-render.py" --input "$MP_PROMOTED" --output "$MP_MD" \
    || fail "MP-6 setup: render failed"
if grep -q "(human-confirmed)" "$MP_MD"; then
    pass "MP-6 (§7, §27.7): rendered artifact.md shows (human-confirmed) tag on promoted finding"
else
    fail "MP-6: '(human-confirmed)' tag missing from rendered output"
fi

# MP-7: schema accepts human_confirmation with non-empty fix_hint string. Covers
# the §27.3 / schema rev-adding-fix_hint path — this is the on-disk shape
# /matthewsreview:promote --fix-hint "..." produces after step 5's jq build.
MP_HC_WITH_HINT=$(jq -nc '{
    reviewer: "tester@example.com",
    reason:   "promote with steering",
    ts:       "2026-04-19T12:00:00Z",
    promoted_from: {disposition:"uncertain", actionability:"report_only", score_phase4:48},
    fix_hint: "Update the docstring to match the code; do not modify the code."
}')
MP_ART_HINT="$WORK/art-promote-hint.json"
cp "$ART" "$MP_ART_HINT"
if "$TOOLS/artifact-patch.py" --path "$MP_ART_HINT" --finding-id F006 \
        --set disposition=confirmed_mechanical \
        --set actionability=auto_fixable \
        --set-json "human_confirmation=$MP_HC_WITH_HINT" >/dev/null 2>&1; then
    pass "MP-7 (§27.3, schema): human_confirmation with non-empty fix_hint accepted"
else
    fail "MP-7: human_confirmation with fix_hint should succeed"
fi

# MP-8: empty-string fix_hint rejected (schema minLength: 1 on the non-null branch).
# Null or absent are both fine; empty-string is not. Guards the invariant that
# "absent == no hint" — callers should omit the key, not pass "".
MP_HC_EMPTY_HINT=$(jq -nc '{
    reviewer: "tester@example.com",
    reason:   "x",
    ts:       "2026-04-19T12:00:00Z",
    promoted_from: {disposition:"uncertain", actionability:"report_only", score_phase4:48},
    fix_hint: ""
}')
mp8_stderr=$("$TOOLS/artifact-patch.py" --path "$MP_ART" --finding-id F006 \
        --set-json "human_confirmation=$MP_HC_EMPTY_HINT" 2>&1 >/dev/null); mp8_code=$?
if [[ "$mp8_code" != "0" ]] && echo "$mp8_stderr" | grep -q "human_confirmation"; then
    pass "MP-8 (§27.3, schema): empty-string fix_hint rejected (minLength: 1)"
else
    fail "MP-8: expected non-zero + 'human_confirmation' in stderr; code=$mp8_code stderr=$mp8_stderr"
fi

# MP-9: renderer emits "**Fix direction:**" when fix_hint is set. Uses the same
# rendering path MP-6 exercises; this catches the new _finding_detail branch.
MP_MD_HINT="$WORK/art-promote-hint.md"
"$TOOLS/artifact-render.py" --input "$MP_ART_HINT" --output "$MP_MD_HINT" \
    || fail "MP-9 setup: render failed"
if grep -q "Fix direction:.*Update the docstring" "$MP_MD_HINT"; then
    pass "MP-9 (§7, §27.7): rendered artifact.md shows Fix direction line when fix_hint is set"
else
    fail "MP-9: '**Fix direction:**' line missing from rendered output with fix_hint"
fi

# MP-10: renderer does NOT emit "**Fix direction:**" when fix_hint is absent.
# Reuses MP-6's MP_MD (rendered from MP_PROMOTED, whose human_confirmation has
# no fix_hint). Guards against an accidental unconditional emit.
if ! grep -q "Fix direction:" "$MP_MD"; then
    pass "MP-10 (§7, §27.7): rendered artifact.md omits Fix direction line when fix_hint is absent"
else
    fail "MP-10: 'Fix direction:' should NOT appear when fix_hint is absent"
fi

# ------------------------------------------------------------------ AFH-* auto-fix-hint (more-auto.md)
#
# Covers the auto_fix_hint field, the two new artifact-patch.py modes
# (--apply-auto-fix-hints / --apply-auto-rec-promotions), and the
# renderer's Auto-recommendation block.
#
# Targets F004 (light-lane, confirmed_mechanical, score=60, open) for
# the happy path: it stays open through every prior assertion (only F001
# sees state mutations earlier in the suite), and post-AFH-4 promotion
# its human_confirmation routes it through render_light_lane → promoted
# details → _finding_detail, exercising the new Auto-recommendation
# render branch.

AFH_ART="$WORK/art-afh.json"
cp "$ART" "$AFH_ART"  # reuse the post-stage-1 artifact

# AFH-1: --apply-auto-fix-hints with valid input → exit 0; finding gains
# auto_fix_hint with the right shape (hint, confidence, second_opinion, ts).
afh1_input=$(jq -nc '[{
    id: "F004",
    hint: "Add a loading spinner during the destructive request to prevent double-click",
    confidence: "high",
    second_opinion: "concurs"
}]')
afh1_stdout=$("$TOOLS/artifact-patch.py" --path "$AFH_ART" \
        --apply-auto-fix-hints "$afh1_input" 2>/dev/null); afh1_code=$?
afh1_hint=$(jq -r '.findings[] | select(.id=="F004") | .auto_fix_hint.hint // empty' "$AFH_ART")
afh1_conf=$(jq -r '.findings[] | select(.id=="F004") | .auto_fix_hint.confidence // empty' "$AFH_ART")
afh1_so=$(jq -r '.findings[] | select(.id=="F004") | .auto_fix_hint.second_opinion // empty' "$AFH_ART")
afh1_ts=$(jq -r '.findings[] | select(.id=="F004") | .auto_fix_hint.ts // empty' "$AFH_ART")
if [[ "$afh1_code" == "0" ]] \
   && [[ "$afh1_hint" == "Add a loading spinner during the destructive request to prevent double-click" ]] \
   && [[ "$afh1_conf" == "high" ]] \
   && [[ "$afh1_so" == "concurs" ]] \
   && [[ -n "$afh1_ts" ]]; then
    pass "AFH-1 (more-auto.md Stage 1): --apply-auto-fix-hints valid input → exit 0, auto_fix_hint set with hint/confidence/second_opinion/ts"
else
    fail "AFH-1: code=$afh1_code hint='$afh1_hint' conf='$afh1_conf' so='$afh1_so' ts='$afh1_ts' stdout='$afh1_stdout'"
fi

# AFH-2: --apply-auto-fix-hints with invalid input (missing required `hint`)
# → exit 7 (all rejected) with error-as-prompt. Schema rejection is a
# per-entry continue-on-error, but a single-entry batch where every entry
# is rejected lands on EXIT_ALL_REJECTED.
AFH_ART_BAD="$WORK/art-afh-bad.json"
cp "$ART" "$AFH_ART_BAD"
afh2_input=$(jq -nc '[{id: "F004", confidence: "high", second_opinion: "concurs"}]')  # missing hint
afh2_err=$("$TOOLS/artifact-patch.py" --path "$AFH_ART_BAD" \
        --apply-auto-fix-hints "$afh2_input" 2>&1 >/dev/null); afh2_code=$?
if [[ "$afh2_code" == "7" ]] \
   && echo "$afh2_err" | grep -q "auto-fix-hints-rejected:" \
   && echo "$afh2_err" | grep -q "ERROR: --apply-auto-fix-hints: every input was rejected" \
   && echo "$afh2_err" | grep -q "Action:"; then
    pass "AFH-2 (more-auto.md Stage 1): --apply-auto-fix-hints rejects entry missing 'hint' → exit 7 with error-as-prompt + per-entry rejection line"
else
    fail "AFH-2: expected exit 7 + auto-fix-hints-rejected + ERROR: + Action:; code=$afh2_code stderr=$afh2_err"
fi

# AFH-3: when finding already has auto_fix_hint, --apply-auto-fix-hints
# without --overwrite rejects the entry → exit 7 (single-entry batch, all
# rejected). Pre-condition: AFH-1 set F004's auto_fix_hint, so AFH_ART
# already carries one.
afh3_input=$(jq -nc '[{
    id: "F004",
    hint: "different hint that should not land",
    confidence: "low",
    second_opinion: "concerns",
    concerns: ["this would clobber AFH-1"]
}]')
afh3_err=$("$TOOLS/artifact-patch.py" --path "$AFH_ART" \
        --apply-auto-fix-hints "$afh3_input" 2>&1 >/dev/null); afh3_code=$?
afh3_hint_after=$(jq -r '.findings[] | select(.id=="F004") | .auto_fix_hint.hint' "$AFH_ART")
if [[ "$afh3_code" == "7" ]] \
   && echo "$afh3_err" | grep -q "reason=already_set" \
   && [[ "$afh3_hint_after" == "Add a loading spinner during the destructive request to prevent double-click" ]]; then
    pass "AFH-3 (more-auto.md Stage 1): --apply-auto-fix-hints rejects already-set finding without --overwrite → exit 7, original hint preserved"
else
    fail "AFH-3: expected exit 7 + reason=already_set + AFH-1 hint preserved; code=$afh3_code stderr=$afh3_err hint_after='$afh3_hint_after'"
fi

# AFH-4: --apply-auto-rec-promotions with valid input → exit 0. Promotes
# F004 (which now carries an auto_fix_hint from AFH-1). Validates:
#   - exit 0
#   - finding now has human_confirmation populated
#   - human_confirmation.fix_hint == auto_fix_hint.hint (sourced server-side)
#   - human_confirmation.reviewer matches the input
afh4_input=$(jq -nc '[{
    id: "F004",
    reviewer: "auto-rec/tester@example.com",
    reason: "AFH-4 batch promote"
}]')
afh4_stdout=$("$TOOLS/artifact-patch.py" --path "$AFH_ART" \
        --apply-auto-rec-promotions "$afh4_input" 2>/dev/null); afh4_code=$?
afh4_hc_reviewer=$(jq -r '.findings[] | select(.id=="F004") | .human_confirmation.reviewer // empty' "$AFH_ART")
afh4_hc_fix_hint=$(jq -r '.findings[] | select(.id=="F004") | .human_confirmation.fix_hint // empty' "$AFH_ART")
afh4_afh_hint=$(jq -r '.findings[] | select(.id=="F004") | .auto_fix_hint.hint // empty' "$AFH_ART")
if [[ "$afh4_code" == "0" ]] \
   && [[ "$afh4_hc_reviewer" == "auto-rec/tester@example.com" ]] \
   && [[ -n "$afh4_hc_fix_hint" ]] \
   && [[ "$afh4_hc_fix_hint" == "$afh4_afh_hint" ]]; then
    pass "AFH-4 (more-auto.md Stage 1): --apply-auto-rec-promotions valid input → exit 0, human_confirmation.fix_hint sourced from auto_fix_hint.hint, reviewer recorded"
else
    fail "AFH-4: code=$afh4_code reviewer='$afh4_hc_reviewer' hc_fix_hint='$afh4_hc_fix_hint' afh_hint='$afh4_afh_hint' stdout='$afh4_stdout'"
fi

# AFH-5: --apply-auto-rec-promotions on a finding that already has
# human_confirmation → first-fail-halt (exit 1). Pre-condition: AFH-4
# already promoted F004, so re-running with the same id should bail.
afh5_input=$(jq -nc '[{
    id: "F004",
    reviewer: "auto-rec/tester@example.com",
    reason: "AFH-5 second promote attempt"
}]')
afh5_err=$("$TOOLS/artifact-patch.py" --path "$AFH_ART" \
        --apply-auto-rec-promotions "$afh5_input" 2>&1 >/dev/null); afh5_code=$?
if [[ "$afh5_code" == "1" ]] \
   && echo "$afh5_err" | grep -q "already has human_confirmation"; then
    pass "AFH-5 (more-auto.md Stage 1): --apply-auto-rec-promotions on already-promoted finding → exit 1 (first-fail-halt) with descriptive error-as-prompt"
else
    fail "AFH-5: expected exit 1 + 'already has human_confirmation'; code=$afh5_code stderr=$afh5_err"
fi

# AFH-6: hint text reaches the reader via SOME rendering path when
# auto_fix_hint is set. Two scenarios are covered by separate assertions:
#   - AFH-7 covers "auto_fix_hint set, NOT promoted" → '### Auto-recommendations' section
#   - AFH-8 covers "auto_fix_hint set, promoted with SAME hint" → suppressed inline, shown via 'Fix direction:'
#   - AFH-9 covers "auto_fix_hint set, promoted with EDITED hint" → both 'Fix direction:' and inline appear
# AFH-6 stays as a coarse end-to-end check: AFH_ART (post-AFH-4) renders
# the hint text via the human_confirmation path, and the baseline ART
# (no hint anywhere) renders neither path.
AFH_MD="$WORK/art-afh.md"
"$TOOLS/artifact-render.py" --input "$AFH_ART" --output "$AFH_MD" \
    || fail "AFH-6 setup: render of AFH_ART failed"
AFH_BASELINE_MD="$WORK/art-afh-baseline.md"
"$TOOLS/artifact-render.py" --input "$ART" --output "$AFH_BASELINE_MD" \
    || fail "AFH-6 setup: render of baseline ART failed"
if grep -q "Add a loading spinner during the destructive request" "$AFH_MD" \
   && grep -q "Fix direction:" "$AFH_MD" \
   && ! grep -q "Add a loading spinner during the destructive request" "$AFH_BASELINE_MD" \
   && ! grep -q "Auto-recommendation" "$AFH_BASELINE_MD"; then
    pass "AFH-6 (more-auto.md Stage 1+4): renderer surfaces auto_fix_hint text via human_confirmation 'Fix direction' line after batch-accept promotion; omits all hint paths when no hint exists"
else
    fail "AFH-6: rendered output mismatch — AFH_MD must contain hint text + 'Fix direction:'; baseline must omit hint and 'Auto-recommendation'" "AFH_MD has hint=$(grep -c 'loading spinner' "$AFH_MD" || true) fix-direction=$(grep -c 'Fix direction:' "$AFH_MD" || true); baseline has hint=$(grep -c 'loading spinner' "$AFH_BASELINE_MD" || true) auto-rec=$(grep -c 'Auto-recommendation' "$AFH_BASELINE_MD" || true)"
fi

# AFH-7: renderer emits a top-level "Auto-recommendations" SECTION (not just
# the per-finding inline block) when at least one finding has auto_fix_hint
# AND has not been promoted (human_confirmation == null). Pre-AFH-4 state on
# F004 satisfies this; rebuild a fresh fixture rather than rewinding AFH_ART.
AFH7_ART="$WORK/art-afh7.json"
cp "$ART" "$AFH7_ART"
AFH7_HINTS="$WORK/afh7-hints.json"
cat > "$AFH7_HINTS" <<'EOF'
[{"id":"F004","hint":"Add a loading spinner during the destructive request and disable the button until the response returns","confidence":"high","second_opinion":"concurs"}]
EOF
"$TOOLS/artifact-patch.py" --path "$AFH7_ART" --apply-auto-fix-hints "@$AFH7_HINTS" >/dev/null \
    || fail "AFH-7 setup: --apply-auto-fix-hints failed"
AFH7_MD="$WORK/art-afh7.md"
"$TOOLS/artifact-render.py" --input "$AFH7_ART" --output "$AFH7_MD" \
    || fail "AFH-7 setup: render of AFH7_ART failed"
if grep -q "^### Auto-recommendations (1)" "$AFH7_MD" \
   && grep -q "Add a loading spinner during the destructive request" "$AFH7_MD" \
   && ! grep -q "^### Auto-recommendations" "$AFH_BASELINE_MD" \
   && ! grep -q "^### Auto-recommendations" "$AFH_MD"; then
    pass "AFH-7 (more-auto.md Stage 1.5): renderer emits dedicated 'Auto-recommendations (N)' overlay section for unpromoted hint-bearing findings; omits when none qualify (baseline + post-promote)"
else
    fail "AFH-7: section visibility mismatch — AFH7_MD must contain '### Auto-recommendations (1)' + hint text; baseline + AFH_MD must NOT contain '### Auto-recommendations'" "AFH7_MD: $(grep -c '^### Auto-recommendations' "$AFH7_MD" || true); AFH_MD: $(grep -c '^### Auto-recommendations' "$AFH_MD" || true); baseline: $(grep -c '^### Auto-recommendations' "$AFH_BASELINE_MD" || true)"
fi

# AFH-8: when a finding has both auto_fix_hint AND human_confirmation with
# the SAME fix_hint (i.e. promoted via :fix Phase 7.5 / :walkthrough Step 4.5
# Apply-all path, helper sourcing fix_hint from auto_fix_hint.hint), the
# renderer must suppress the **Auto-recommendation block in _finding_detail**
# to avoid double-displaying the same hint text. The finding still appears
# elsewhere via its disposition section's _finding_detail call; only the
# inline block is suppressed. AFH_ART (post-AFH-4) satisfies this:
# F004.auto_fix_hint.hint == F004.human_confirmation.fix_hint == AFH-1's hint.
# The previously-rendered AFH_MD already exists from AFH-6.
afh8_inline_count=$(grep -c "^\*\*Auto-recommendation (high):\*\*" "$AFH_MD" || true)
if [[ "$afh8_inline_count" == "0" ]]; then
    pass "AFH-8 (more-auto.md Stage 4): renderer suppresses inline Auto-recommendation block in _finding_detail when auto_fix_hint.hint == human_confirmation.fix_hint (no double-display after batch-accept promotion)"
else
    fail "AFH-8: expected 0 inline '**Auto-recommendation (high):**' lines in AFH_MD (F004 promoted with same hint); got $afh8_inline_count"
fi

# AFH-9: edited-hint case — when human_confirmation.fix_hint DIFFERS from
# auto_fix_hint.hint (user took the auto-rec then edited at promote time, or
# walkthrough's edit-hint flow set a custom hint), the renderer keeps the
# inline auto_fix_hint block as the audit trail of the original
# recommendation alongside the user's revised fix_hint.
AFH9_ART="$WORK/art-afh9.json"
# Direct jq mutation: --set rejects `human_confirmation.*` (immutable-by-helper);
# this scenario simulates the walkthrough edit-hint flow which sets the override
# via promote-core, not the auto-rec batch helper. For smoke we just want a
# fixture with diverging fix_hints to exercise the renderer's audit-trail path.
jq '(.findings[] | select(.id=="F004") | .human_confirmation.fix_hint) = "Reviewer rewrite — different wording than the auto-rec"' \
    "$AFH_ART" > "$AFH9_ART" \
    || fail "AFH-9 setup: jq mutation of human_confirmation.fix_hint failed"
AFH9_MD="$WORK/art-afh9.md"
"$TOOLS/artifact-render.py" --input "$AFH9_ART" --output "$AFH9_MD" \
    || fail "AFH-9 setup: render of AFH9_ART failed"
afh9_inline_count=$(grep -c "^\*\*Auto-recommendation (high):\*\*" "$AFH9_MD" || true)
if [[ "$afh9_inline_count" -ge "1" ]]; then
    pass "AFH-9 (more-auto.md Stage 4): renderer keeps inline Auto-recommendation block when human_confirmation.fix_hint diverges from auto_fix_hint.hint (edit-hint audit trail preserved)"
else
    fail "AFH-9: expected ≥1 inline '**Auto-recommendation (high):**' lines in AFH9_MD (F004 promoted with edited hint); got $afh9_inline_count"
fi

# AFH-10: integration wiring grep checks. These catch accidental drops of
# the auto_fix_hint plumbing during future refactors. They're not behavior
# tests — they assert that the cross-file references stay in place.
afh10_ok=true
grep -q '06b-auto-fix-hint.md' "$REPO/commands/review.md" || afh10_ok=false
grep -q '06b-auto-fix-hint.md' "$REPO/commands/codex-review.md" || afh10_ok=false
grep -q '06b-auto-fix-hint.md' "$REPO/commands/add.md" || afh10_ok=false
grep -q 'apply-auto-fix-hints' "$REPO/fragments/06b-auto-fix-hint.md" || afh10_ok=false
grep -q 'Phase 7.5' "$REPO/fragments/08-fix-loader.md" || afh10_ok=false
grep -q 'apply-auto-rec-promotions' "$REPO/fragments/08-fix-loader.md" || afh10_ok=false
grep -q '4.5' "$REPO/commands/walkthrough.md" || afh10_ok=false
grep -q 'auto_fix_hint' "$REPO/commands/walkthrough.md" || afh10_ok=false
grep -q 'apply-auto-rec-promotions' "$REPO/commands/walkthrough.md" || afh10_ok=false
if $afh10_ok; then
    pass "AFH-10 (more-auto.md Stage 4): cross-file integration wiring intact — review/codex-review/add include 06b; 06b calls apply-auto-fix-hints; 08-fix-loader has Phase 7.5 + apply-auto-rec-promotions; walkthrough has Step 4.5 + auto_fix_hint references + apply-auto-rec-promotions"
else
    fail "AFH-10: integration wiring missing — re-grep the assertion to find the dropped reference"
fi

# AFH-11: Phase 5.5 eligibility predicate covers confirmed_mechanical
# regardless of lane (v0.4.2 widening). Runs the exact jq filter from
# fragments/06b-auto-fix-hint.md against a synthetic 9-finding artifact
# and asserts the selected set matches the predicate's intent.
#
# Why: dedup's "deep wins over light" rule produces findings with
# lane=deep + impact_type=ux when two lenses with different lanes
# collide on the same root cause. Pre-v0.4.2 these fell through both
# Phase 8 (impact_type filter excludes ux) and Phase 5.5 (lane filter
# excluded deep+mechanical). Real-world hit: F031 on
# user-research-invite PR #267, surfaced 2026-05-11.
#
# Expected selected ids: F-DM, F-LM, F-MAN, F-REP (4 of 9).
afh11_synth=$(jq -nc '{
    findings: [
        {id:"F-DM",  disposition:"confirmed_mechanical", validation_lane:"deep",  score_phase4:70, current_state:"open",     human_confirmation:null, auto_fix_hint:null},
        {id:"F-LM",  disposition:"confirmed_mechanical", validation_lane:"light", score_phase4:70, current_state:"open",     human_confirmation:null, auto_fix_hint:null},
        {id:"F-MAN", disposition:"confirmed_manual",     validation_lane:"deep",  score_phase4:80, current_state:"open",     human_confirmation:null, auto_fix_hint:null},
        {id:"F-REP", disposition:"confirmed_report",     validation_lane:"light", score_phase4:65, current_state:"open",     human_confirmation:null, auto_fix_hint:null},
        {id:"F-LO",  disposition:"confirmed_mechanical", validation_lane:"light", score_phase4:50, current_state:"open",     human_confirmation:null, auto_fix_hint:null},
        {id:"F-PRE", disposition:"pre_existing_report",  validation_lane:"deep",  score_phase4:80, current_state:"open",     human_confirmation:null, auto_fix_hint:null},
        {id:"F-RES", disposition:"confirmed_mechanical", validation_lane:"deep",  score_phase4:80, current_state:"resolved", human_confirmation:null, auto_fix_hint:null},
        {id:"F-HC",  disposition:"confirmed_mechanical", validation_lane:"light", score_phase4:70, current_state:"open",     human_confirmation:{reviewer:"x",ts:"t",reason:"r"}, auto_fix_hint:null},
        {id:"F-AFH", disposition:"confirmed_mechanical", validation_lane:"deep",  score_phase4:70, current_state:"open",     human_confirmation:null, auto_fix_hint:{hint:"h",confidence:"high",second_opinion:"concurs",ts:"t"}}
    ]
}')

# Exact predicate copied from fragments/06b-auto-fix-hint.md §5.5.0.
afh11_selected=$(printf '%s' "$afh11_synth" | jq -r '
    [.findings[]
       | select(.current_state == "open")
       | select(.human_confirmation == null)
       | select(.auto_fix_hint == null)
       | select(.disposition != "pre_existing_report")
       | select(
           (.disposition == "confirmed_manual")
           or (.disposition == "confirmed_report")
           or (.disposition == "confirmed_mechanical")
         )
       | select(.score_phase4 != null and .score_phase4 >= 60)
       | .id]
    | sort | join(",")
')

if [[ "$afh11_selected" == "F-DM,F-LM,F-MAN,F-REP" ]]; then
    pass "AFH-11 (v0.4.2): Phase 5.5 predicate selects confirmed_mechanical regardless of lane (covers dedup-induced deep+ux gap, F031-style); correctly excludes below-gate, pre_existing_report, resolved, already-promoted, already-hinted"
else
    fail "AFH-11: predicate mismatch — expected 'F-DM,F-LM,F-MAN,F-REP'; got '$afh11_selected'" "the predicate in fragments/06b-auto-fix-hint.md may have drifted from the v0.4.2 widening — re-check §5.5.0"
fi

# AFH-12: fragment source must not re-introduce the lane gate on
# confirmed_mechanical (regression guard for v0.4.2). Pairs with AFH-11
# and AFH-13:
# - AFH-11 checks the predicate's runtime behavior via the inline copy.
# - AFH-13 checks the predicate's runtime behavior via the canonical
#   fragment block (extracted between fence markers and executed).
# - AFH-12 catches textual revert forms that AFH-13 might still pass
#   (e.g., a syntactically reordered predicate that semantically
#   re-narrows the lane gate but happens to evaluate identically on the
#   AFH-11/AFH-13 synthetic). The patterns below catch the original
#   form, clause-order swaps, separate-select reformulations, and
#   single-quoted variants.
afh12_frag="$REPO/fragments/06b-auto-fix-hint.md"
# Strip whitespace inside the fragment for tolerant matching of
# multi-line reformulations. Bash 3.2 portable: tr -d '[:space:]'.
afh12_compact=$(tr -d '[:space:]' < "$afh12_frag")
afh12_hit=0
# Pattern A: confirmed_mechanical adjacent to a validation_lane=="light"
# clause in either order (catches "and" / "&&" / separate select() with
# the two clauses textually adjacent after whitespace stripping).
if printf '%s' "$afh12_compact" \
   | grep -qE '"confirmed_mechanical"[^|}]{0,80}\.validation_lane=="light"'; then
    afh12_hit=1
fi
if printf '%s' "$afh12_compact" \
   | grep -qE '\.validation_lane=="light"[^|}]{0,80}"confirmed_mechanical"'; then
    afh12_hit=1
fi
# Pattern B: single-quoted variants (jq embedded in a different bash
# quoting context).
if printf '%s' "$afh12_compact" \
   | grep -qE "'confirmed_mechanical'[^|}]{0,80}\.validation_lane=='light'"; then
    afh12_hit=1
fi
if printf '%s' "$afh12_compact" \
   | grep -qE "\.validation_lane=='light'[^|}]{0,80}'confirmed_mechanical'"; then
    afh12_hit=1
fi
if [[ "$afh12_hit" -eq 1 ]]; then
    fail "AFH-12: fragments/06b-auto-fix-hint.md re-introduces the light-lane gate on confirmed_mechanical — see v0.4.2 release notes / F031 incident"
else
    pass "AFH-12 (v0.4.2 regression guard): fragments/06b-auto-fix-hint.md predicate has no light-lane gate on confirmed_mechanical (clause-swap / separate-select / single-quote variants all checked)"
fi

# AFH-13: behavioral check on the canonical fragment block.
# AFH-11 exercises an inline COPY of the predicate; if the fragment
# drifts (e.g., '>= 60' becomes '>= 75', a select() clause is dropped,
# the lane gate is re-added under a different syntax), AFH-11 stays
# green because it tests the copy, not the source. AFH-13 closes that
# gap: extract the bash block between the fence markers in §5.5.0,
# rewrite the artifact-read.sh call so it reads from the AFH-11
# synthetic via plain jq, and assert the selected IDs still match the
# v0.4.2-widened expectation. Any non-trivial predicate drift breaks
# this assertion.
afh13_frag="$REPO/fragments/06b-auto-fix-hint.md"
# Extract the bash block between the fence markers. The fences are
# HTML comments wrapping the ```bash ... ``` block; awk prints lines
# strictly between START and END markers.
afh13_block=$(awk '
    /<!-- AFH-PREDICATE-START -->/ { inblock = 1; next }
    /<!-- AFH-PREDICATE-END -->/   { inblock = 0 }
    inblock { print }
' "$afh13_frag")
if [[ -z "$afh13_block" ]]; then
    fail "AFH-13: could not extract canonical predicate block from $afh13_frag — fence markers AFH-PREDICATE-START / AFH-PREDICATE-END missing or out of order"
fi
# Extract just the jq filter body from inside the artifact-read.sh
# --filter '...' single-quoted argument. The filter spans from the
# first line after "--filter '" up to (but not including) the closing
# "  ')" line. The result is a self-contained jq expression operating
# on the artifact root {findings: [...]}.
afh13_filter=$(printf '%s\n' "$afh13_block" | awk '
    /--filter / { capture = 1; next }
    capture && /^[[:space:]]*'"'"'\)$/ { capture = 0 }
    capture { print }
')
if [[ -z "$afh13_filter" ]]; then
    fail "AFH-13: extracted block did not contain an artifact-read.sh --filter '...' jq body — block shape changed?"
fi
# Execute the canonical filter against the AFH-11 synthetic and
# extract the .id of each selected element, sorted. Append the sort +
# join to the extracted filter (which itself ends with a "| ... ]"
# array constructor).
afh13_selected=$(printf '%s' "$afh11_synth" \
    | MATTHEWS_REVIEW_CONFIRM_THRESHOLD=60 \
      jq -r "$afh13_filter"' | map(.id) | sort | join(",")')
if [[ "$afh13_selected" == "F-DM,F-LM,F-MAN,F-REP" ]]; then
    pass "AFH-13 (v0.4.2 fragment behavior): canonical predicate extracted from fragments/06b-auto-fix-hint.md §5.5.0 selects expected ids on AFH-11 synthetic (drift catches: score threshold, lane gate re-add, missing select clause)"
else
    fail "AFH-13: canonical fragment predicate selected '$afh13_selected'; expected 'F-DM,F-LM,F-MAN,F-REP' — fragments/06b-auto-fix-hint.md §5.5.0 has drifted from the v0.4.2 contract"
fi

# ---------------------------------------------------------------- walkthrough
#
# WT-* cover the /matthewsreview:walkthrough command surface. WT-1..WT-4 exercise
# the scope-filter jq (the inverse of 09-fix-execution.md step 8.1); WT-5 is a
# structural check on /matthewsreview:promote's --defer-publish + shared-fragment
# wiring. The scope jq MUST stay in sync with Phase 8 eligibility — any drift
# surfaces here.

PROMOTE_MD="$REPO/commands/promote.md"
PROMOTE_CORE_MD="$REPO/fragments/promote-core.md"

# WT-0: promote-core precondition PROCEEDS (not no-op) for confirmed_mechanical +
# curr_hc == null. Pre-existing-bug guard: a blanket no-op on that row silently
# broke promoting light-lane findings and deep-lane below-threshold findings
# (§27.2, §27.6). If a future edit re-adds the no-op language, this surfaces.
# Checks: (a) the precondition table contains a **Proceed.** verdict on the
# confirmed_mechanical + curr_hc == null row, (b) it does NOT contain the old
# "already confirmed_mechanical by validator" no-op text.
if grep -q '`confirmed_mechanical` | `curr_hc == null` | \*\*Proceed' "$PROMOTE_CORE_MD" \
   && ! grep -q "already confirmed_mechanical by validator.*no-op" "$PROMOTE_CORE_MD"; then
    pass "WT-0 (§27.2, §27.6): promote-core precondition proceeds for confirmed_mechanical + no human_confirmation"
else
    fail "WT-0: promote-core.md missing 'Proceed' verdict or still has blanket no-op for confirmed_mechanical + no hc"
fi

# The walkthrough scope-filter jq — must stay in sync with the expression in
# commands/walkthrough.md §3. Held as a shell variable so the
# assertions below can exercise it against different fixtures without drift.
# NOTE: pre_existing_report findings are excluded from scope_full_ids — they
# are routed exclusively to §6.5 issue filing, never walked for promotion.
WT_SCOPE_JQ='
[.findings[]
 | select(.current_state == "open")
 | select(.disposition != "resolved")
 | select(.disposition != "disproven")
 | select(.disposition != "pending_validation")
 | select(.disposition != "pre_existing_report")
 | select(.human_confirmation == null)
 | select(
     (
       (.disposition == "confirmed_mechanical" or .disposition == "partial" or .disposition == "regression")
       and (
         (.impact_type == "correctness" or .impact_type == "security")
         and (.score_phase4 != null and .score_phase4 >= $thr)
       )
     ) | not
   )
 | select((.score_phase4 // .score_phase3 // -1) >= $thr)
 | .id
] | join(",")
'

# WT fixture builder. Accepts a findings[] JSON array on stdin; emits a minimal
# artifact stub that passes just enough of the schema's top-level requirements
# for the jq filter to run against. Only .findings is queried, so we don't need
# a full schema-valid seed.
wt_build_fixture() {
    local findings_json="$1"
    jq -nc --argjson findings "$findings_json" '{findings: $findings}'
}

# Shared finding templates — varying only the fields the scope filter inspects.
# All other fields stubbed with plausible defaults; the scope jq ignores them.
# score_phase3 is optional (8th arg, default "null") — lets tests exercise the
# COALESCE(phase4, phase3, -1) score floor for below_gate findings, which
# legitimately carry a phase3 score but no phase4 score.
wt_finding() {
    # args: id impact_type validation_lane disposition score_phase4 current_state human_confirmation [score_phase3]
    jq -nc \
        --arg id "$1" \
        --arg impact "$2" \
        --arg lane "$3" \
        --arg disp "$4" \
        --arg score "$5" \
        --arg state "$6" \
        --arg hc "$7" \
        --arg score3 "${8:-null}" \
        '{
            id: $id,
            impact_type: $impact,
            validation_lane: $lane,
            disposition: $disp,
            score_phase4: (if $score == "null" then null else ($score | tonumber) end),
            score_phase3: (if $score3 == "null" then null else ($score3 | tonumber) end),
            current_state: $state,
            human_confirmation: (if $hc == "null" then null else ($hc | fromjson) end)
        }'
}

WT_HC='{"reviewer":"x","reason":"y","ts":"2026-04-19T00:00:00Z","promoted_from":{"disposition":"uncertain","actionability":"manual","score_phase4":null}}'

# WT-1: resolved / disproven / pending_validation findings are excluded.
# Fixture includes one of each terminal/unused disposition plus one in-scope
# finding (uncertain) to prove the filter isn't dropping everything.
wt1_findings=$(jq -nc \
    --argjson a "$(wt_finding W001 correctness deep resolved 80 resolved null)" \
    --argjson b "$(wt_finding W002 correctness deep disproven 70 open null)" \
    --argjson c "$(wt_finding W003 correctness deep pending_validation null open null)" \
    --argjson d "$(wt_finding W004 correctness deep uncertain 70 open null)" \
    '[$a,$b,$c,$d]')
wt1_fx=$(wt_build_fixture "$wt1_findings")
wt1_ids=$(echo "$wt1_fx" | jq -r --argjson thr 60 "$WT_SCOPE_JQ")
if [[ "$wt1_ids" == "W004" ]]; then
    pass "WT-1 (§28, plans/walkthrough-mode.md §3.5): scope excludes resolved/disproven/pending_validation"
else
    fail "WT-1: expected W004 only; got '$wt1_ids'"
fi

# WT-2: already-promoted findings (human_confirmation != null) are excluded
# so a partially-walked session resumes cleanly without re-surfacing them.
wt2_findings=$(jq -nc \
    --argjson a "$(wt_finding W010 architecture light uncertain 70 open "$WT_HC")" \
    --argjson b "$(wt_finding W011 architecture light uncertain 70 open null)" \
    '[$a,$b]')
wt2_fx=$(wt_build_fixture "$wt2_findings")
wt2_ids=$(echo "$wt2_fx" | jq -r --argjson thr 60 "$WT_SCOPE_JQ")
if [[ "$wt2_ids" == "W011" ]]; then
    pass "WT-2 (§28, §27.6): scope excludes already-promoted findings (human_confirmation set)"
else
    fail "WT-2: expected W011 only; got '$wt2_ids'"
fi

# WT-3: findings the Phase 8 gate would ALREADY pass (correctness/security +
# score >= threshold + confirmed_mechanical/partial/regression) are excluded — the
# walkthrough's purpose is to surface what fix SKIPS. Fixture: deep/correctness
# confirmed_mechanical at score=80 should NOT appear.
wt3_findings=$(jq -nc \
    --argjson a "$(wt_finding W020 correctness deep confirmed_mechanical 80 open null)" \
    --argjson b "$(wt_finding W021 correctness deep confirmed_manual 80 open null)" \
    '[$a,$b]')
wt3_fx=$(wt_build_fixture "$wt3_findings")
wt3_ids=$(echo "$wt3_fx" | jq -r --argjson thr 60 "$WT_SCOPE_JQ")
if [[ "$wt3_ids" == "W021" ]]; then
    pass "WT-3 (§28, §13.1): scope excludes fix-eligible findings (correctness confirmed_mechanical >= threshold)"
else
    fail "WT-3: expected W021 only; got '$wt3_ids'"
fi

# WT-4: light-lane confirmed_mechanical findings (which fail the impact_type gate)
# ARE included IF they score at/above the walkthrough floor — the primary gap
# the walkthrough exists to close, but now with a score-floor filter so
# low-signal findings don't pad the session. Fixture: ux confirmed_mechanical
# at score 80 (in-scope, above floor), policy confirmed_mechanical at score 50
# (in-scope by lane-mismatch but excluded by the score floor), and correctness/deep
# confirmed_mechanical at score 40 (below both the Phase 8 fix gate AND the
# walkthrough floor). Only W030 should survive.
wt4_findings=$(jq -nc \
    --argjson a "$(wt_finding W030 ux light confirmed_mechanical 80 open null)" \
    --argjson b "$(wt_finding W031 policy light confirmed_mechanical 50 open null)" \
    --argjson c "$(wt_finding W032 correctness deep confirmed_mechanical 40 open null)" \
    '[$a,$b,$c]')
wt4_fx=$(wt_build_fixture "$wt4_findings")
wt4_ids=$(echo "$wt4_fx" | jq -r --argjson thr 60 "$WT_SCOPE_JQ")
if [[ "$wt4_ids" == "W030" ]]; then
    pass "WT-4 (§28, §13.2): scope includes light-lane confirmed_mechanical at/above score floor; below-floor items excluded regardless of lane"
else
    fail "WT-4: expected W030 only (score floor 60 excludes W031@50 and W032@40); got '$wt4_ids'"
fi

# WT-6: /matthewsreview:walkthrough decisions-log template contains the required
# structural markers. Since the markdown is rendered inline by Claude at
# runtime (the command file is a prompt, not a shell script), this is a
# template-integrity check — guards against accidental removal of any
# section so the posted PR comment stays auditable.
WALK_MD="$REPO/commands/walkthrough.md"
if grep -q 'matthews-review-walkthrough-v1' "$WALK_MD" \
   && grep -q '### Walkthrough decisions' "$WALK_MD" \
   && grep -q '#### Promoted' "$WALK_MD" \
   && grep -q '#### Skipped' "$WALK_MD" \
   && grep -q '#### Stopped' "$WALK_MD" \
   && grep -q 'human_confirmation.* bypass' "$WALK_MD"; then
    pass "WT-6 (§28.7): walkthrough decisions-log template has marker + Promoted/Skipped/Stopped sections"
else
    fail "WT-6: walkthrough decisions-log template missing required sections in $WALK_MD"
fi

# WT-5: /matthewsreview:promote wires --defer-publish and includes promote-core.md.
# Structural check guarding against accidental removal of either piece (plans/
# walkthrough-mode.md §5, §6). If a future refactor merges the shared fragment
# back inline or drops the --defer-publish flag, this assertion surfaces it
# before the walkthrough command breaks.
if grep -q -- '--defer-publish' "$PROMOTE_MD" \
   && grep -q 'defer_publish.*true' "$PROMOTE_MD" \
   && grep -q 'promote-core.md' "$PROMOTE_MD"; then
    pass "WT-5 (§27, §28): promote command wires --defer-publish guards + includes promote-core fragment"
else
    fail "WT-5: --defer-publish or promote-core include missing from $PROMOTE_MD"
fi

# WT-7: the "Qualifying" scope jq (step 3 of walkthrough) must additionally
# exclude below_gate (which the full scope keeps for the reviewer who wants
# to audit Phase-3-demoted findings). BOTH the full and qualifying scopes
# exclude pre_existing_report — those are routed only to §6.5 issue filing
# and are never walked for promotion. Mirrors the second jq in
# commands/walkthrough.md; keep in sync when that file changes.
WT_QUALIFYING_JQ='
[.findings[]
 | select(.current_state == "open")
 | select(.disposition != "resolved")
 | select(.disposition != "disproven")
 | select(.disposition != "pending_validation")
 | select(.disposition != "below_gate")
 | select(.disposition != "pre_existing_report")
 | select(.human_confirmation == null)
 | select(
     (
       (.disposition == "confirmed_mechanical" or .disposition == "partial" or .disposition == "regression")
       and (
         (.impact_type == "correctness" or .impact_type == "security")
         and (.score_phase4 != null and .score_phase4 >= $thr)
       )
     ) | not
   )
 | select((.score_phase4 // .score_phase3 // -1) >= $thr)
 | .id
] | join(",")
'
wt7_findings=$(jq -nc \
    --argjson a "$(wt_finding W050 correctness deep below_gate null open null 30)" \
    --argjson b "$(wt_finding W051 correctness deep pre_existing_report null open null)" \
    --argjson c "$(wt_finding W052 ux light confirmed_mechanical 80 open null)" \
    --argjson d "$(wt_finding W053 correctness deep uncertain 55 open null)" \
    '[$a,$b,$c,$d]')
wt7_fx=$(wt_build_fixture "$wt7_findings")
# Run at threshold=25 so the score floor doesn't swallow below_gate (W050
# has phase3=30) or uncertain (W053 has phase4=55) — the test's purpose is
# to prove the Full-vs-Qualifying distinction on below_gate. WT-12 covers
# the score-floor mechanics at default threshold=60.
wt7_full=$(echo "$wt7_fx" | jq -r --argjson thr 25 "$WT_SCOPE_JQ")
wt7_qual=$(echo "$wt7_fx" | jq -r --argjson thr 25 "$WT_QUALIFYING_JQ")
# Full scope includes below_gate (W050) but excludes pre_existing_report (W051)
# — pre-existing is routed only to §6.5. Qualifying additionally excludes
# below_gate (W050).
if [[ ",$wt7_full," == *,W050,* && ",$wt7_full," != *,W051,* && ",$wt7_full," == *,W052,* && ",$wt7_full," == *,W053,* ]] \
   && [[ ",$wt7_qual," != *,W050,* && ",$wt7_qual," != *,W051,* ]] \
   && [[ ",$wt7_qual," == *,W052,* && ",$wt7_qual," == *,W053,* ]]; then
    pass "WT-7 (§28 §3): full scope excludes pre_existing_report but keeps below_gate; qualifying excludes both"
else
    fail "WT-7: full='$wt7_full' qual='$wt7_qual' (expected full=W050,W052,W053; qual=W052,W053)"
fi

# WT-8: the pre-existing isolation jq (step 3, third expression) must
# select only open, non-promoted pre_existing_report findings.
WT_PREEXISTING_JQ='
[.findings[]
 | select(.current_state == "open")
 | select(.disposition == "pre_existing_report")
 | select(.human_confirmation == null)
 | .id
] | join(",")
'
wt8_findings=$(jq -nc \
    --argjson a "$(wt_finding W060 correctness deep pre_existing_report null open null)" \
    --argjson b "$(wt_finding W061 correctness deep pre_existing_report null open "$WT_HC")" \
    --argjson c "$(wt_finding W062 correctness deep below_gate null open null)" \
    '[$a,$b,$c]')
wt8_fx=$(wt_build_fixture "$wt8_findings")
wt8_ids=$(echo "$wt8_fx" | jq -r "$WT_PREEXISTING_JQ")
if [[ "$wt8_ids" == "W060" ]]; then
    pass "WT-8 (§28 §3): pre-existing scope isolates only open, non-promoted pre_existing_report findings"
else
    fail "WT-8: expected W060 only; got '$wt8_ids'"
fi

# WT-9: preflight (§4) presents the three-tier AskUserQuestion and the
# terminology preamble naming all three gates. Template-integrity check.
if grep -q 'Qualifying only' "$WALK_MD" \
   && grep -q 'Full skip set' "$WALK_MD" \
   && grep -q 'Cancel' "$WALK_MD" \
   && grep -q 'Phase 3 scoring gate' "$WALK_MD" \
   && grep -q 'Phase 4 confirmation cutoffs' "$WALK_MD" \
   && grep -q 'Phase 8 fix gate' "$WALK_MD" \
   && grep -q 'scope_qualifying_ids' "$WALK_MD" \
   && grep -q 'scope_full_ids' "$WALK_MD" \
   && grep -q 'scope_preexisting_ids' "$WALK_MD"; then
    pass "WT-9 (§28 §4): preflight has three-tier choice + gate-terminology preamble + three scope variables"
else
    fail "WT-9: preflight tier options or gate preamble missing from $WALK_MD"
fi

# WT-10: pre-existing issue filing (§6.5) + decisions-log subsection are
# wired. Template-integrity check.
if grep -q '### 6.5' "$WALK_MD" \
   && grep -q 'gh issue create' "$WALK_MD" \
   && grep -q 'issues_filed' "$WALK_MD" \
   && grep -q '#### Pre-existing issues filed' "$WALK_MD" \
   && grep -q 'pre_existing_issue_draft' "$WALK_MD"; then
    pass "WT-10 (§28 §6.5, §7.1): pre-existing issue filing + decisions-log subsection wired"
else
    fail "WT-10: step 6.5 or decisions-log 'Pre-existing issues filed' subsection missing from $WALK_MD"
fi

# WT-11: briefer prompt (§5.2) tells the agent to propose best-effort
# hints for confirmed_manual/confirmed_report. Template-integrity check.
if grep -q 'confirmed_manual.*confirmed_report' "$WALK_MD" \
   || grep -q 'confirmed_manual` and `confirmed_report' "$WALK_MD"; then
    pass "WT-11 (§28 §5.2): briefer prompt addresses confirmed_manual + confirmed_report findings"
else
    fail "WT-11: briefer prompt missing confirmed_manual/confirmed_report clause in $WALK_MD"
fi

# WT-12: the walkthrough `$threshold` argument is a score floor — findings
# scoring below it are dropped from scope so the session stays focused on
# high-signal items. Fixture exercises three cases at threshold=60: a
# lane-mismatched finding above the floor (kept), a lane-mismatched finding
# below the floor (dropped by the floor), and a below_gate finding whose
# phase3 score falls back via COALESCE and is also below the floor (dropped).
# Second assertion lowers the threshold to 25 to prove the same fixture
# admits all three — proves the floor is the gating constraint, not some
# other filter, and that score_phase3 fallback works for null-phase4 findings.
wt12_findings=$(jq -nc \
    --argjson a "$(wt_finding W070 ux light confirmed_mechanical 80 open null)" \
    --argjson b "$(wt_finding W071 ux light confirmed_mechanical 55 open null)" \
    --argjson c "$(wt_finding W072 correctness deep below_gate null open null 30)" \
    '[$a,$b,$c]')
wt12_fx=$(wt_build_fixture "$wt12_findings")
wt12_at60=$(echo "$wt12_fx" | jq -r --argjson thr 60 "$WT_SCOPE_JQ")
if [[ "$wt12_at60" == "W070" ]]; then
    pass "WT-12a (§28 §3): score floor at default threshold=60 excludes below-floor findings (lane-mismatch + null-phase4 below_gate)"
else
    fail "WT-12a: expected W070 only (floor=60 drops W071@55, W072@phase3=30); got '$wt12_at60'"
fi
wt12_at25=$(echo "$wt12_fx" | jq -r --argjson thr 25 "$WT_SCOPE_JQ")
if [[ ",$wt12_at25," == *,W070,* && ",$wt12_at25," == *,W071,* && ",$wt12_at25," == *,W072,* ]] \
   && [[ $(echo "$wt12_at25" | awk -F, '{print NF}') == "3" ]]; then
    pass "WT-12b (§28 §3): score floor at threshold=25 admits below-default findings via score_phase3 fallback for below_gate"
else
    fail "WT-12b: expected W070,W071,W072 (any order) at threshold=25; got '$wt12_at25'"
fi

# ------------------------------------------------------------------ Stage 2.6.D
# Line-range sanity filter at Phase 1 join. line-range-check.sh rejects
# candidates whose line_range[1] overshoots the file's actual length at
# $reviewed_sha, catches missing-file references, and passes through the
# Phase 1.5 "(unknown)" sentinel. Addresses the L5-ux hallucination
# observed on the ray-finance 2026-04-19 run (ranges 1815-1826 in a
# 1042-line file).
#
# Reuses the OC_DIR git fixture so file_a.py (4 lines) + file_b.py
# (2 lines) provide concrete upper bounds to overshoot.

# LR-1: valid in-range candidate is passed through unchanged.
out=$(cd "$OC_DIR/repo" && "$TOOLS/line-range-check.sh" \
    --reviewed-sha HEAD \
    < <(echo '[{"sources":["L1-diff-local"],"file":"file_a.py","line_range":[1,4]}]') \
    2> "$WORK/lr1.err")
kept=$(echo "$out" | jq 'length')
if [[ "$kept" == "1" ]] && [[ ! -s "$WORK/lr1.err" ]]; then
    pass "LR-1: in-range candidate passes through unchanged (no audit stderr)"
else
    fail "LR-1: expected 1 kept and empty stderr; got kept=$kept stderr=$(cat "$WORK/lr1.err")"
fi

# LR-2: hallucinated range (99-100 on 4-line file_a.py) is dropped with
# the lens_hallucinated_line_range trace tag on stderr.
out=$(cd "$OC_DIR/repo" && "$TOOLS/line-range-check.sh" \
    --reviewed-sha HEAD \
    < <(echo '[{"sources":["L5-ux"],"file":"file_a.py","line_range":[99,100]}]') \
    2> "$WORK/lr2.err")
kept=$(echo "$out" | jq 'length')
if [[ "$kept" == "0" ]] \
    && grep -q 'lens_hallucinated_line_range:' "$WORK/lr2.err" \
    && grep -q 'source=L5-ux' "$WORK/lr2.err" \
    && grep -q 'actual_lines=4' "$WORK/lr2.err"; then
    pass "LR-2: overshot range dropped with lens_hallucinated_line_range + source + actual_lines"
else
    fail "LR-2: expected 0 kept + hallucinated-range trace; got kept=$kept stderr=$(cat "$WORK/lr2.err")"
fi

# LR-3: file=="(unknown)" (Phase 1.5 external-scrape sentinel) passes
# through without any audit stderr.
out=$(cd "$OC_DIR/repo" && "$TOOLS/line-range-check.sh" \
    --reviewed-sha HEAD \
    < <(echo '[{"sources":["external-pr:coderabbitai"],"file":"(unknown)","line_range":[1,1]}]') \
    2> "$WORK/lr3.err")
kept=$(echo "$out" | jq 'length')
if [[ "$kept" == "1" ]] && [[ ! -s "$WORK/lr3.err" ]]; then
    pass "LR-3: file=='(unknown)' sentinel passes through with no audit stderr"
else
    fail "LR-3: expected 1 kept and empty stderr; got kept=$kept stderr=$(cat "$WORK/lr3.err")"
fi

# LR-5: a file without a trailing newline must NOT produce false-
# positive drops at its last visible line. The helper counts records
# via `awk 'END{print NR}'` (not `wc -l`, which counts newlines and
# would undercount by 1 on no-EOL files).
(
    cd "$OC_DIR/repo"
    printf 'line1\nline2\nline3' > file_no_nl.py   # 3 lines, NO trailing newline
    git add file_no_nl.py
    git commit --quiet -m "add no-trailing-newline fixture"
)
out=$(cd "$OC_DIR/repo" && "$TOOLS/line-range-check.sh" \
    --reviewed-sha HEAD \
    < <(echo '[{"sources":["L1-diff-local"],"file":"file_no_nl.py","line_range":[1,3]}]') \
    2> "$WORK/lr5.err")
kept=$(echo "$out" | jq 'length')
if [[ "$kept" == "1" ]] && [[ ! -s "$WORK/lr5.err" ]]; then
    pass "LR-5: no-trailing-newline file — range to last line passes through (awk NR counts records, not newlines)"
else
    fail "LR-5: expected 1 kept + empty stderr for no-EOL file range [1,3]; got kept=$kept stderr=$(cat "$WORK/lr5.err")"
fi

# LR-4: file missing at $reviewed_sha is dropped with the
# lens_referenced_missing_file trace tag.
out=$(cd "$OC_DIR/repo" && "$TOOLS/line-range-check.sh" \
    --reviewed-sha HEAD \
    < <(echo '[{"sources":["L5-ux"],"file":"does_not_exist.py","line_range":[1,1]}]') \
    2> "$WORK/lr4.err")
kept=$(echo "$out" | jq 'length')
if [[ "$kept" == "0" ]] \
    && grep -q 'lens_referenced_missing_file:' "$WORK/lr4.err" \
    && grep -q 'file=does_not_exist.py' "$WORK/lr4.err"; then
    pass "LR-4: missing file dropped with lens_referenced_missing_file trace tag"
else
    fail "LR-4: expected 0 kept + missing-file trace; got kept=$kept stderr=$(cat "$WORK/lr4.err")"
fi

# LR-6: lens-prompts/_shared-invariants.md (extracted from 01-detection.md
# §1.2.1 per plans/codex-review.md §4.1) carries the file-absolute +
# in-bounds + hunk-header prohibition for `line_range`. Prompt-level
# guard against the L5-ux classification from GH #2 (P3) where lenses
# copied hunk-header numbers verbatim and produced out-of-bounds ranges.
# The invariant lives in the shared file (dispatched to every lens
# sub-agent), not lens-specific.
DETECT_MD_LR6="$REPO/fragments/lens-prompts/_shared-invariants.md"
lr6_missing=()
for phrase in \
    '`line_range` must be file-absolute' \
    "the file's total line count" \
    'Do not copy the numbers inside unified-' \
    '@@ -a,b +c,d @@'; do
    if ! grep -qF "$phrase" "$DETECT_MD_LR6"; then
        lr6_missing+=("$phrase")
    fi
done
if [[ ${#lr6_missing[@]} -eq 0 ]]; then
    pass "LR-6: §1.2.1 line_range invariant requires file-absolute + hunk-header prohibition (P3, GH #2)"
else
    fail "LR-6: missing §1.2.1 invariant phrases: ${lr6_missing[*]}"
fi

# ------------------------------------------------------------------ Stage 2.6.E
# Polish / below-gate cluster renderer section. Dense runs of below_gate
# findings in one area are hidden by default (Phase 3 parks them so the
# report stays skimmable), but ≥3 within a 100-line window is its own
# signal — surface them in a dedicated section with a cluster label so
# a reviewer can spot what the pipeline filtered out.

PC_DIR="$WORK/polish-clusters"
mkdir -p "$PC_DIR"

# Template for a below_gate finding; overrides via jq at call site.
PC_TMPL='{"id":"F101","sources":["L5-ux"],"source_families":["ux-family"],"impact_type":"ux","origin":"introduced_by_pr","origin_confidence":"low","actionability":"manual","validation_lane":"light","current_state":"open","disposition":"below_gate","is_actionable":false,"reason":null,"confirmed_strength":null,"file":"src/cli/commands.ts","line_range":[920,920],"claim":"Net worth formatting mismatch","score_phase3":30,"score_phase4":null,"score_history":[{"phase":"phase_3","score":30}],"validation_result":null,"fix_attempts":[],"introduced_in_sha":null,"suggested_follow_up":null,"related_parent_finding_id":null}'

jq '.findings = []' "$FIX/artifact-seed.json" > "$PC_DIR/base.json"

# PC-1: 3 below_gate findings in one file, spanning 97 lines
# (920, 960, 1017). ≤ 100 → cluster → section emitted.
f1=$(echo "$PC_TMPL" | jq '.id="F101"|.line_range=[920,920]|.claim="nit-a"')
f2=$(echo "$PC_TMPL" | jq '.id="F102"|.line_range=[960,960]|.claim="nit-b"')
f3=$(echo "$PC_TMPL" | jq '.id="F103"|.line_range=[1017,1017]|.claim="nit-c"')
jq --argjson a "$f1" --argjson b "$f2" --argjson c "$f3" \
    '.findings=[$a,$b,$c]|.review_id="rev_pc1"' "$PC_DIR/base.json" > "$PC_DIR/pc1.json"
"$TOOLS/artifact-render.py" --input "$PC_DIR/pc1.json" --output "$PC_DIR/pc1.md" >/dev/null
if grep -q '## Polish — below threshold, clustered' "$PC_DIR/pc1.md" \
    && grep -q '| F101 |' "$PC_DIR/pc1.md" \
    && grep -q '| F102 |' "$PC_DIR/pc1.md" \
    && grep -q '| F103 |' "$PC_DIR/pc1.md"; then
    pass "PC-1 (§7): polish-cluster section emitted for 3+ below_gate in 100-line window"
else
    fail "PC-1: expected polish-cluster section with F101/F102/F103; got:\n$(cat "$PC_DIR/pc1.md")"
fi

# PC-2: 3 below_gate findings in same file but spanning > 100 lines.
# No sliding window of size ≥3 fits → no cluster → no section.
f1=$(echo "$PC_TMPL" | jq '.id="F201"|.line_range=[100,100]')
f2=$(echo "$PC_TMPL" | jq '.id="F202"|.line_range=[250,250]')
f3=$(echo "$PC_TMPL" | jq '.id="F203"|.line_range=[500,500]')
jq --argjson a "$f1" --argjson b "$f2" --argjson c "$f3" \
    '.findings=[$a,$b,$c]|.review_id="rev_pc2"' "$PC_DIR/base.json" > "$PC_DIR/pc2.json"
"$TOOLS/artifact-render.py" --input "$PC_DIR/pc2.json" --output "$PC_DIR/pc2.md" >/dev/null
if ! grep -q 'Polish — below threshold' "$PC_DIR/pc2.md"; then
    pass "PC-2 (§7): polish-cluster section omitted when 3 findings span > 100 lines in same file"
else
    fail "PC-2: section should be absent; got:\n$(cat "$PC_DIR/pc2.md")"
fi

# PC-3: only 2 below_gate findings, densely clustered. < 3 → no section.
f1=$(echo "$PC_TMPL" | jq '.id="F301"|.line_range=[100,100]')
f2=$(echo "$PC_TMPL" | jq '.id="F302"|.line_range=[110,110]')
jq --argjson a "$f1" --argjson b "$f2" \
    '.findings=[$a,$b]|.review_id="rev_pc3"' "$PC_DIR/base.json" > "$PC_DIR/pc3.json"
"$TOOLS/artifact-render.py" --input "$PC_DIR/pc3.json" --output "$PC_DIR/pc3.md" >/dev/null
if ! grep -q 'Polish — below threshold' "$PC_DIR/pc3.md"; then
    pass "PC-3 (§7): polish-cluster section omitted when fewer than 3 below_gate findings (even dense)"
else
    fail "PC-3: section should be absent; got:\n$(cat "$PC_DIR/pc3.md")"
fi

# ------------------------------------------------------------------ Phase 4 validator hardening
# VR-* assertions cover the read-only preamble + fix-scope cross-check + post-wave
# tree-cleanliness sweep added to 05-validation.md after the ray-finance 2026-04-19
# run surfaced a validator that edited the working tree (F027) and two class-of-bug
# misses whose prior fixes had scoped only to the obvious site (F032 ← F011,
# F034 ← F037).
VALIDATION_MD="$REPO/fragments/05-validation.md"

# VR-1: Phase 4a + 4b validator prompts contain a read-only preamble forbidding
# Edit/Write. Prevents a repeat of the F027 incident where an Opus validator
# modified src/cli/commands.ts and the orchestrator had to inline-revert with
# no formal guardrail.
if grep -qF '**Read-only.**' "$VALIDATION_MD" \
    && grep -qF 'Do not use `Edit` or `Write`' "$VALIDATION_MD" \
    && [[ "$(grep -cF '**Read-only.**' "$VALIDATION_MD")" -ge 2 ]]; then
    pass "VR-1 (§19.5/§19.6): Phase 4a + 4b validator prompts contain read-only preamble"
else
    fail "VR-1: read-only preamble missing from one or both validator prompts in $VALIDATION_MD"
fi

# VR-2: Phase 4a validator prompt step 4 requires cross-checking
# blast_radius.parallel_paths + grepping for in-repo precedent before
# finalizing fix_proposal. Addresses the class-vs-instance gap.
if grep -qF 'blast_radius.parallel_paths' "$VALIDATION_MD" \
    && grep -qF 'in-repo precedent' "$VALIDATION_MD" \
    && grep -qF 'the full class' "$VALIDATION_MD"; then
    pass "VR-2 (§19.5): validator prompt step 4 requires parallel-path cross-check + precedent grep"
else
    fail "VR-2: class-not-instance fix-scope rule missing from $VALIDATION_MD"
fi

# VR-3: Post-wave tree-cleanliness sweep present as belt-and-braces for VR-1.
# If a validator ignores the read-only preamble, the sweep reverts the tree
# before Phase 5 and logs the incident to trace.md under phase_4_tree_dirty_reverted.
if grep -qF 'phase_4_tree_dirty_reverted' "$VALIDATION_MD" \
    && grep -qF 'status --porcelain' "$VALIDATION_MD"; then
    pass "VR-3 (§4.4.5): post-wave tree-cleanliness sweep present with phase_4_tree_dirty_reverted trace tag"
else
    fail "VR-3: tree-cleanliness sweep missing from $VALIDATION_MD"
fi

# ------------------------------------------------------------------ Phase 9a post-fix hardening
# PF-* assertions cover the premise audit + convention-drift sweep added to
# 10-post-fix-and-commit.md after the ray-finance feat/import-apple 2026-04-20
# ultrareview surfaced two bugs Phase 9a missed: a wrong COALESCE direction
# justified by a false inline comment (bug_007, F021) and a new scoring loop
# whose bound drifted from every sibling scoring path in the codebase
# (bug_001, F023).
POSTFIX_MD="$REPO/fragments/10-post-fix-and-commit.md"

# PF-1: Phase 9a prompt step 5a — adjacent-regression sweep kept as the local
# ±20-lines same-file check. Split from the old combined step 5 so step 5b can
# own the cross-file convention drift case.
if grep -qF 'Adjacent-regression sweep (local)' "$POSTFIX_MD"; then
    pass "PF-1 (§19.9): Phase 9a prompt retains adjacent-regression sweep as step 5a"
else
    fail "PF-1: adjacent-regression sweep missing from $POSTFIX_MD"
fi

# PF-2: Phase 9a prompt step 5b(i) — validator-identified parallels cross-check.
# Uses blast_radius.parallel_paths and explicitly names the COALESCE-direction
# example from bug_007 so the check surface stays narrow and scannable.
if grep -qF 'Convention-drift sweep (cross-file)' "$POSTFIX_MD" \
    && grep -qF 'blast_radius.parallel_paths' "$POSTFIX_MD" \
    && grep -qF 'COALESCE(a, b)' "$POSTFIX_MD"; then
    pass "PF-2 (§19.9): Phase 9a prompt step 5b(i) cross-checks blast_radius.parallel_paths"
else
    fail "PF-2: convention-drift sweep (validator parallels) missing from $POSTFIX_MD"
fi

# PF-3: Phase 9a prompt step 5b(ii) — fix-introduced-siblings instruction.
# The *bug*/*fix* distinction is load-bearing: Phase 4 computes parallel_paths
# on the bug pattern, so new code the fix introduces needs independent sibling
# search. This closes the gap that let bug_001 (cleanupDerivedAfterRemove loop
# bound drifted from calculateDailyScore callers) past Phase 9a.
if grep -qF 'parallel_paths` was computed on the *bug*' "$POSTFIX_MD" \
    && grep -qF 'new parallels the validator didn' "$POSTFIX_MD"; then
    pass "PF-3 (§19.9): Phase 9a prompt step 5b(ii) flags fix-introduced new siblings"
else
    fail "PF-3: fix-introduced-siblings instruction missing from $POSTFIX_MD"
fi

# PF-4: Phase 9a prompt step 6 — premise audit of added inline comments.
# A wrong comment is worse than no comment because it propagates to future
# readers. Scoped to comments in the same hunk as a logic change so pre-existing
# comments are out of scope. This is what catches bug_007's false
# `// fresh INSERT leaves label NULL` justification.
if grep -qF 'Premise audit of added inline comments' "$POSTFIX_MD" \
    && grep -qF 'falsifiable claim' "$POSTFIX_MD" \
    && grep -qF 'same hunk as a logic change' "$POSTFIX_MD"; then
    pass "PF-4 (§19.9): Phase 9a prompt step 6 audits added inline-comment premises"
else
    fail "PF-4: premise audit missing from $POSTFIX_MD"
fi

# ------------------------------------------------------------------ assign-finding-ids --start-from
# AS-* assertions cover the --start-from flag added for /matthewsreview:add (so
# new findings injected into an existing artifact continue the id sequence
# instead of colliding from F001). The default-no-flag behavior must remain
# F001..F0NN to keep Phase 1's pooled-candidate join unchanged.

# AS-1: default behavior preserved (no flag → F001..).
out=$(echo '[{"sources":["L1-diff-local"],"claim":"a"},{"sources":["L1-diff-local"],"claim":"b"}]' \
        | "$TOOLS/assign-finding-ids.sh" | jq -r '[.[].id] | join(",")')
if [[ "$out" == "F001,F002" ]]; then
    pass "AS-1: assign-finding-ids.sh default start emits F001,F002 (regression check)"
else
    fail "AS-1: expected F001,F002, got $out"
fi

# AS-2: --start-from F037 emits F037..
out=$(echo '[{"sources":["L1-diff-local"],"claim":"a"},{"sources":["L1-diff-local"],"claim":"b"},{"sources":["L1-diff-local"],"claim":"c"}]' \
        | "$TOOLS/assign-finding-ids.sh" --start-from F037 | jq -r '[.[].id] | join(",")')
if [[ "$out" == "F037,F038,F039" ]]; then
    pass "AS-2: --start-from F037 emits F037,F038,F039"
else
    fail "AS-2: expected F037,F038,F039, got $out"
fi

# AS-3: --start-from with bad value rejected with exit 64.
code=$(rc "$TOOLS/assign-finding-ids.sh" --start-from notF)
if [[ "$code" == "64" ]]; then
    pass "AS-3: --start-from with non-F<NNN> value rejected (exit 64)"
else
    fail "AS-3: expected exit 64, got $code"
fi

# ------------------------------------------------------------------ /matthewsreview:add command
# RA-* assertions cover the structural shape of the new top-level command
# (commands/add.md). The command is a prose markdown file
# that Claude Code interprets — these assertions verify the load-bearing
# pieces are present, mirroring the VR-* / PF-* pattern for prompts that
# only an LLM can execute.
ADD_MD="$REPO/commands/add.md"

# RA-1: command file exists.
if [[ -f "$ADD_MD" ]]; then
    pass "RA-1: commands/add.md exists"
else
    fail "RA-1: commands/add.md missing"
fi

# RA-2: leftover-attempted hard abort present (mirrors Phase 7 step 4).
# Re-uses the same "attempted" detection + recovery message shape so a
# /matthewsreview:fix run in flight cannot be silently extended by an add.
if grep -qF 'select(.current_state == "attempted")' "$ADD_MD" \
    && grep -qF 'leftover_ids' "$ADD_MD"; then
    pass "RA-2: leftover-attempted hard abort present (mirrors Phase 7)"
else
    fail "RA-2: leftover-attempted gate missing from $ADD_MD"
fi

# RA-3: --start-from wired through assign-finding-ids.sh so new findings
# continue past the highest existing F-id (the AS-2 helper assertion is
# the helper-side proof; this is the wiring proof).
if grep -qF 'assign-finding-ids.sh --start-from' "$ADD_MD"; then
    pass "RA-3: assign-finding-ids.sh --start-from wired into ID assignment"
else
    fail "RA-3: --start-from invocation missing from $ADD_MD"
fi

# RA-4: paste-mode normalizer Sonnet prompt present. Returns the
# standard candidate-array shape with origin_confidence: low and
# external-add-family family.
if grep -qF 'normalizing an externally-sourced code-review note' "$ADD_MD" \
    && grep -qF 'external-add-family' "$ADD_MD" \
    && grep -qF '"origin_confidence": "low"' "$ADD_MD"; then
    pass "RA-4: paste-normalizer prompt present (origin_confidence=low, external-add-family)"
else
    fail "RA-4: paste-normalizer prompt missing or malformed in $ADD_MD"
fi

# RA-5: one-direction dedup Sonnet prompt present. Each new candidate
# matches AT MOST ONE existing finding; existing findings are NOT
# compared against each other.
if grep -qF 'deduplicating new bug candidates' "$ADD_MD" \
    && grep -qF 'matches AT MOST ONE existing finding' "$ADD_MD" \
    && grep -qF 'NOT compared against each other' "$ADD_MD"; then
    pass "RA-5: dedup prompt present with one-direction matching constraint"
else
    fail "RA-5: dedup prompt missing or malformed in $ADD_MD"
fi

# RA-6: structured one-shot mode (--file/--line/--claim) builds a
# candidate inline without invoking the normalizer.
if grep -qF '"external-add:cli"' "$ADD_MD" \
    && grep -qF 'external-add-family' "$ADD_MD" \
    && grep -qF 'cli_file' "$ADD_MD" \
    && grep -qF 'cli_claim' "$ADD_MD"; then
    pass "RA-6: structured one-shot mode builds inline candidate (cli sources)"
else
    fail "RA-6: structured one-shot mode missing from $ADD_MD"
fi

# RA-7: re-render + re-publish to existing comment_id (so the new
# findings appear in the same PR comment, not a duplicate).
if grep -qF 'artifact-render.py' "$ADD_MD" \
    && grep -qF 'artifact-publish.sh' "$ADD_MD" \
    && grep -qF -e '--comment-id "$comment_id"' "$ADD_MD"; then
    pass "RA-7: re-render + re-publish to existing comment_id wired"
else
    fail "RA-7: render/publish flow missing from $ADD_MD"
fi

# RA-8: Phase 4 validation lane-aware with NO Wave 2 chain retry.
# Verifies the deep + light dispatch is present AND that the no-Wave-2
# constraint is documented in the deep validator prompt.
if grep -qF 'no Wave 2' "$ADD_MD" \
    && grep -qF 'deep validator' "$ADD_MD" \
    && grep -qF 'light confirmation validator' "$ADD_MD" \
    && grep -qF 'apply-decisions' "$ADD_MD"; then
    pass "RA-8: Phase 4 validation lane-aware, no Wave 2, --apply-decisions wired"
else
    fail "RA-8: Phase 4 dispatch incomplete in $ADD_MD"
fi

# PL-1: scripts/dev-run.sh exists and is executable. The old
# install.sh/uninstall.sh symlink flow is obsolete under the plugin
# runtime — Claude Code discovers commands from the plugin package
# directly. dev-run.sh is the plugin-author iteration wrapper.
if [[ -x "$REPO/scripts/dev-run.sh" ]]; then
    pass "PL-1: scripts/dev-run.sh exists and is executable"
else
    fail "PL-1: scripts/dev-run.sh missing or not executable"
fi

# PL-2: .claude-plugin/plugin.json is present and valid JSON. Required
# by the Claude Code plugin runtime; a malformed file silently prevents
# plugin load.
if [[ -f "$REPO/.claude-plugin/plugin.json" ]] \
    && jq empty "$REPO/.claude-plugin/plugin.json" >/dev/null 2>&1; then
    pass "PL-2: .claude-plugin/plugin.json present and valid JSON"
else
    fail "PL-2: .claude-plugin/plugin.json missing or invalid JSON"
fi

# RA-10: allowed-tools front-matter grants every Bash binary the command
# actually invokes. Catches the permissions-vs-usage drift class — e.g.
# a step using mktemp without a Bash(mktemp:*) grant would prompt the
# user mid-run instead of running cleanly. The check below pins the
# subset of binaries this command literally invokes; common shell
# builtins (echo, paste) are deliberately omitted to match the
# established pattern of relying on the user's global allowlist for
# those (see promote/walkthrough). timeout/sleep/kill are pinned for
# §3a's bounded fetch (GNU-timeout branch + background+watchdog fallback).
front=$(awk '/^---$/{c++; next} c==1{print}' "$ADD_MD")
missing=()
for tool in mktemp jq git awk grep mkdir rm tr cat printf date timeout sleep kill; do
    if ! echo "$front" | grep -qF "Bash($tool:"; then
        missing+=("$tool")
    fi
done
if [[ ${#missing[@]} -eq 0 ]]; then
    pass "RA-10: allowed-tools grants every Bash binary the command invokes"
else
    fail "RA-10: missing Bash grants for: ${missing[*]}"
fi

# RA-11: step 6's finding builder honors trivial_mode when deriving
# validation_lane, matching Phase 1's detection builder
# (01-detection.md §1.10). Without this, new findings added to a
# trivial-mode artifact would be stored as validation_lane=deep for
# correctness/security while the rest of the artifact is all-light,
# and artifact-render.py's lane-section filter would misplace them.
if grep -qF 'trivial_mode=$(artifact-read.sh' "$ADD_MD" \
    && grep -qF -- "--path \"\$artifact_path\" --filter '.trivial_mode'" "$ADD_MD" \
    && grep -qF -e '--argjson trivial "$trivial_mode"' "$ADD_MD" \
    && grep -qF 'if $trivial then "light"' "$ADD_MD"; then
    pass "RA-11: step 6 validation_lane honors trivial_mode (Phase 1 parity)"
else
    fail "RA-11: step 6 validation_lane missing trivial_mode branch in $ADD_MD"
fi

# RA-12: step 7.5 tree-cleanliness sweep is GATED on pre_validator_clean
# so the sweep does not clobber the user's own uncommitted work.
# /matthewsreview:add has no clean-tree gate (§3.8 design decision) — if
# the user had dirty state going in, the sweep would revert it. The
# gate + skip-branch + distinct trace tag together prove the guard is
# wired correctly.
if grep -qF 'pre_validator_clean=true' "$ADD_MD" \
    && grep -qF 'pre_validator_clean=false' "$ADD_MD" \
    && grep -qF '"$pre_validator_clean" == "true"' "$ADD_MD" \
    && grep -qF 'add_tree_dirty_sweep_skipped' "$ADD_MD"; then
    pass "RA-12: step 7.5 sweep is gated on pre_validator_clean (preserves user work)"
else
    fail "RA-12: step 7.5 sweep guard missing or malformed in $ADD_MD"
fi

# RA-13: step 5 dedup guards against the sub-agent hallucinating a
# match_id that doesn't exist. The existing_ids_csv extraction + the
# hallucinated-trace-tag + the count/drop jq's membership check
# (.matches | IN($known[])) prevent a crash in the sources-merge
# pipeline when match_id is unknown.
if grep -qF 'existing_ids_csv=' "$ADD_MD" \
    && grep -qF 'add_dedup_hallucinated' "$ADD_MD" \
    && grep -qF '.matches | IN($known[])' "$ADD_MD"; then
    pass "RA-13: step 5 dedup has hallucinated-match_id guard"
else
    fail "RA-13: step 5 dedup hallucination guard missing from $ADD_MD"
fi

# RA-14: fix.md grants the three Bash binaries §7.6a's active-fetch
# block invokes inline (timeout, sleep, kill). Mirrors RA-10's
# permissions-vs-usage discipline; tighter scope because fix.md is a
# larger command and full-coverage enumeration is out-of-scope here.
FIX_MD="$REPO/commands/fix.md"
front_fix=$(awk '/^---$/{c++; next} c==1{print}' "$FIX_MD")
missing_fix=()
for tool in timeout sleep kill; do
    if ! echo "$front_fix" | grep -qF "Bash($tool:"; then
        missing_fix+=("$tool")
    fi
done
if [[ ${#missing_fix[@]} -eq 0 ]]; then
    pass "RA-14: commands/fix.md grants §7.6a fetch-block binaries (timeout, sleep, kill)"
else
    fail "RA-14: commands/fix.md missing Bash grants for: ${missing_fix[*]}"
fi

# ------------------------------------------------------------------ Stage 2.9
# prior-fix-diff.sh (§13.11b) — deterministic prior-fix suspect scan that
# feeds L2's prompt. Construct scratch repos, exercise every branch.
# Prefix is PFD-* (not PF-*) to avoid collision with the Post-Fix block
# above.

PFD_DIR="$WORK/prior-fix-diff"

# PFD-1: Empty prior-fix history. feat branch changes a line; no prior
# commit has fix-intent wording. Expect: empty output array.
mkdir -p "$PFD_DIR/r1"
(
    cd "$PFD_DIR/r1"
    git init --quiet --initial-branch=main 2>/dev/null || git init --quiet
    git symbolic-ref HEAD refs/heads/main 2>/dev/null || true
    git config user.email smoke@example.com
    git config user.name smoke
    printf 'a\nb\nc\nd\n' > f.txt
    git add f.txt && git commit --quiet -m "initial"
    git checkout --quiet -b feat
    printf 'a\nb\nCHANGED\nd\n' > f.txt
    git add f.txt && git commit --quiet -m "change line 3"
)
out=$(cd "$PFD_DIR/r1" && "$TOOLS/prior-fix-diff.sh" \
    --comparison-ref main --reviewed-files f.txt 2>/dev/null)
len=$(echo "$out" | jq 'length')
if [[ "$len" == "0" ]]; then
    pass "PFD-1 (§13.11b): no fix-intent commits in history → empty suspects array"
else
    fail "PFD-1: expected empty array; got length=$len out=$out"
fi

# PFD-2: Prior commit touches same lines but lacks fix-intent keywords.
mkdir -p "$PFD_DIR/r2"
(
    cd "$PFD_DIR/r2"
    git init --quiet --initial-branch=main 2>/dev/null || git init --quiet
    git symbolic-ref HEAD refs/heads/main 2>/dev/null || true
    git config user.email smoke@example.com
    git config user.name smoke
    printf 'a\nb\nc\nd\n' > f.txt
    git add f.txt && git commit --quiet -m "initial"
    printf 'a\nb\nc-refactored\nd\n' > f.txt
    git add f.txt && git commit --quiet -m "refactor: tidy up phrasing"
    git checkout --quiet -b feat
    printf 'a\nb\nc-broadened\nd\n' > f.txt
    git add f.txt && git commit --quiet -m "broaden line 3"
)
out=$(cd "$PFD_DIR/r2" && "$TOOLS/prior-fix-diff.sh" \
    --comparison-ref main --reviewed-files f.txt 2>/dev/null)
len=$(echo "$out" | jq 'length')
if [[ "$len" == "0" ]]; then
    pass "PFD-2 (§13.11b): prior commit with non-fix-intent message filtered out"
else
    fail "PFD-2: expected empty array; got length=$len out=$out"
fi

# PFD-3: The P1.1 pattern — prior "Fix ..." commit at overlapping lines,
# current diff reverts the narrow fix. Expect one suspect naming the fix.
mkdir -p "$PFD_DIR/r3"
(
    cd "$PFD_DIR/r3"
    git init --quiet --initial-branch=main 2>/dev/null || git init --quiet
    git symbolic-ref HEAD refs/heads/main 2>/dev/null || true
    git config user.email smoke@example.com
    git config user.name smoke
    printf 'a\nb\nc\nd\n' > f.txt
    git add f.txt && git commit --quiet -m "initial"
    printf 'a\nb\nc // narrowly scoped\nd\n' > f.txt
    git add f.txt && git commit --quiet -m "Fix manual-accounts label regression"
    printf 'a\nb\nc // narrowly scoped\nd\n# trailing\n' > f.txt
    git add f.txt && git commit --quiet -m "add trailing note"
    git checkout --quiet -b feat
    printf 'a\nb\nc\nd\n# trailing\n' > f.txt
    git add f.txt && git commit --quiet -m "SQL refactor"
)
out=$(cd "$PFD_DIR/r3" && "$TOOLS/prior-fix-diff.sh" \
    --comparison-ref main --reviewed-files f.txt 2>/dev/null)
len=$(echo "$out" | jq 'length')
subject=$(echo "$out" | jq -r '.[0].prior_fix_commit_message_subject // ""')
if [[ "$len" == "1" ]] && [[ "$subject" == "Fix manual-accounts label regression" ]]; then
    pass "PFD-3 (§13.11b): overlapping fix-intent commit surfaces as one suspect"
else
    fail "PFD-3: expected one suspect naming the Fix commit; got length=$len subject='$subject' out=$out"
fi

# PFD-4: Fix-intent commit exists but touches different lines than the PR.
# git log -L should not select it; expect empty.
mkdir -p "$PFD_DIR/r4"
(
    cd "$PFD_DIR/r4"
    git init --quiet --initial-branch=main 2>/dev/null || git init --quiet
    git symbolic-ref HEAD refs/heads/main 2>/dev/null || true
    git config user.email smoke@example.com
    git config user.name smoke
    printf 'line1\nline2\nline3\nline4\nline5\nline6\nline7\nline8\nline9\nline10\n' > f.txt
    git add f.txt && git commit --quiet -m "initial"
    # Fix at line 2 — different from where feat will change.
    sed -i.bak 's/line2/line2-fixed/' f.txt && rm -f f.txt.bak
    git add f.txt && git commit --quiet -m "Fix bug at line 2"
    git checkout --quiet -b feat
    # feat change at line 8 (no overlap with the fix at line 2).
    sed -i.bak 's/line8/line8-changed/' f.txt && rm -f f.txt.bak
    git add f.txt && git commit --quiet -m "change line 8"
)
out=$(cd "$PFD_DIR/r4" && "$TOOLS/prior-fix-diff.sh" \
    --comparison-ref main --reviewed-files f.txt 2>/dev/null)
len=$(echo "$out" | jq 'length')
if [[ "$len" == "0" ]]; then
    pass "PFD-4 (§13.11b): fix-intent commit with no line overlap filtered out"
else
    fail "PFD-4: expected empty array; got length=$len out=$out"
fi

# PFD-5: PR-internal fix commits filtered by --is-ancestor check.
# feat branch has its own "Fix" commit that must NOT be surfaced as a
# suspect (it isn't reachable from main).
mkdir -p "$PFD_DIR/r5"
(
    cd "$PFD_DIR/r5"
    git init --quiet --initial-branch=main 2>/dev/null || git init --quiet
    git symbolic-ref HEAD refs/heads/main 2>/dev/null || true
    git config user.email smoke@example.com
    git config user.name smoke
    printf 'a\nb\nc\nd\n' > f.txt
    git add f.txt && git commit --quiet -m "initial"
    git checkout --quiet -b feat
    # Feat commit 1: intentionally introduce a bug at line 3
    printf 'a\nb\nBROKEN\nd\n' > f.txt
    git add f.txt && git commit --quiet -m "feat work (introduces bug)"
    # Feat commit 2: self-fix at line 3 ("Fix...") — PR-INTERNAL
    printf 'a\nb\nFIXED\nd\n' > f.txt
    git add f.txt && git commit --quiet -m "Fix bug introduced above"
    # Feat commit 3: further change at line 3
    printf 'a\nb\nFINAL\nd\n' > f.txt
    git add f.txt && git commit --quiet -m "finalize line 3"
)
out=$(cd "$PFD_DIR/r5" && "$TOOLS/prior-fix-diff.sh" \
    --comparison-ref main --reviewed-files f.txt 2>/dev/null)
len=$(echo "$out" | jq 'length')
if [[ "$len" == "0" ]]; then
    pass "PFD-5 (§13.11b): PR-internal fix commits filtered by --is-ancestor"
else
    fail "PFD-5: expected empty array (feat's own fixes excluded); got length=$len out=$out"
fi

# PFD-6: Usage errors — missing --comparison-ref → exit 64; unknown
# ref → exit 1 with error-as-prompt suggestions.
mkdir -p "$PFD_DIR/r6"
(
    cd "$PFD_DIR/r6"
    git init --quiet --initial-branch=main 2>/dev/null || git init --quiet
    git symbolic-ref HEAD refs/heads/main 2>/dev/null || true
    git config user.email smoke@example.com
    git config user.name smoke
    printf 'a\n' > f.txt && git add f.txt && git commit --quiet -m "seed"
)
rc_missing=$(cd "$PFD_DIR/r6" && ("$TOOLS/prior-fix-diff.sh" --reviewed-files f.txt >/dev/null 2>&1); echo $?)
rc_badref=$(cd "$PFD_DIR/r6" && ("$TOOLS/prior-fix-diff.sh" --comparison-ref no-such-ref --reviewed-files f.txt >/dev/null 2>&1); echo $?)
if [[ "$rc_missing" == "64" && "$rc_badref" == "1" ]]; then
    pass "PFD-6 (§13.11b): usage errors surface correct exit codes (64 missing / 1 bad-ref)"
else
    fail "PFD-6: expected 64/1; got missing=$rc_missing badref=$rc_badref"
fi

# L7-1..L7-4 guard the holistic-lens plumbing (Stage 2.9.D). L7 runs
# only under --ensemble; these tests exercise the wiring that happens
# on every run (source-priority slot, origin-crosscheck, fragment
# presence) without the LLM dispatch itself.

# L7-1: fragment presence — 01-detection.md step 1.1 table has L7 row,
# step 1.3 has a dispatch block with the L7 header, and step 1.4's
# lens-tag list names L7-holistic.
if grep -qE '^\| L7 — holistic review' "$REPO/fragments/01-detection.md" \
    && grep -qF '#### L7 — holistic review (Opus' "$REPO/fragments/01-detection.md" \
    && grep -qF 'L7-holistic' "$REPO/fragments/01-detection.md"; then
    pass "L7-1 (§2.9.D): 01-detection.md fragment has L7 table row, dispatch block, and lens-tag"
else
    fail "L7-1: L7 fragment wiring incomplete"
fi

# L7-2: assign-finding-ids.sh slots L7-holistic between L6-security and
# external-pr. Synthetic pool of one L6 + one L7 + one external-pr.
in='[{"sources":["L7-holistic"],"file":"h.ts"},{"sources":["external-pr:bot"],"file":"e.ts"},{"sources":["L6-security"],"file":"s.ts"}]'
out=$(echo "$in" | "$TOOLS/assign-finding-ids.sh")
line=$(echo "$out" | jq -r '[.[] | "\(.id):\(.sources[0])"] | join(",")')
expected="F001:L6-security,F002:L7-holistic,F003:external-pr:bot"
if [[ "$line" == "$expected" ]]; then
    pass "L7-2 (§2.9.D): assign-finding-ids.sh slots L7-holistic between L6 and external-pr"
else
    fail "L7-2: expected '$expected'; got '$line'"
fi

# L7-3: origin-crosscheck on a synthetic L7 candidate whose line range
# is entirely ancestor of $comparison_ref gets DOWNGRADED to
# pre_existing/medium — same behavior as L1..L6 (source-family-agnostic).
# Mirrors the OC-1 expectation (post-Option-A): no main-path override to
# /high; downgrade to /medium so §13.1 doesn't fire and Phase 3 + Phase 4
# decide. Reuse the OC scratch repo if it still exists from OC-*.
out=$(cd "$OC_DIR/repo" && "$TOOLS/origin-crosscheck.sh" \
    --comparison-ref main \
    --candidates '[{"id":"L7C1","sources":["L7-holistic"],"source_family":"holistic-family","file":"file_a.py","line_range":[1,2],"origin":"introduced_by_pr","origin_confidence":"high"}]' 2>/dev/null)
origin=$(echo "$out" | jq -r '.[0].origin')
conf=$(echo "$out" | jq -r '.[0].origin_confidence')
if [[ "$origin" == "pre_existing" && "$conf" == "medium" ]]; then
    pass "L7-3 (§2.9.D): origin-crosscheck downgrades L7-holistic candidate (ancestor range) to pre_existing/medium (source-family-agnostic)"
else
    fail "L7-3: expected pre_existing/medium on ancestor L7 range; got origin=$origin conf=$conf"
fi

# L7-4: AGENTS.md pipeline-shape narrative reflects the 6-vs-7 lens
# count. A sanity guard so this meta-doc doesn't silently drift from
# the fragment. (Moved from CLAUDE.md when AGENTS.md became canonical.)
if grep -qF '7 under --ensemble' "$REPO/AGENTS.md" \
    && grep -qF 'holistic Opus safety net' "$REPO/AGENTS.md"; then
    pass "L7-4 (§2.9.D): AGENTS.md pipeline-shape narrative mentions L7 under --ensemble"
else
    fail "L7-4: AGENTS.md pipeline-shape block missing L7 / --ensemble update"
fi

# L7-5: artifact-patch.py --add-finding accepts source_families:
# ["holistic-family"] (new source_family value). schema-v1.json has
# source_families items as {type:string, minLength:1} with no enum,
# so the addition should pass — but we verify rather than assume.
L7_ART="$WORK/l7-schema.json"
"$TOOLS/artifact-patch.py" --init "@$FIX/artifact-seed.json" --path "$L7_ART" >/dev/null
F_L7='{"id":"F901","sources":["L7-holistic"],"source_families":["holistic-family"],"impact_type":"correctness","origin":"introduced_by_pr","origin_confidence":"high","actionability":"auto_fixable","validation_lane":"deep","current_state":"open","disposition":"confirmed_mechanical","is_actionable":true,"reason":"test","confirmed_strength":"moderate","file":"src/holistic/test.ts","line_range":[10,12],"claim":"L7 schema smoke","score_phase3":65,"score_phase4":70,"score_history":[{"phase":"phase_3","score":65},{"phase":"phase_4","score":70}],"validation_result":null,"fix_attempts":[],"introduced_in_sha":null,"suggested_follow_up":null,"related_parent_finding_id":null}'
if "$TOOLS/artifact-patch.py" --path "$L7_ART" --add-finding "$F_L7" >/dev/null 2>&1 \
    && "$TOOLS/artifact-validate.sh" --path "$L7_ART" >/dev/null 2>&1; then
    pass "L7-5 (§2.9.D): holistic-family source_family passes schema validation"
else
    fail "L7-5: schema rejected L7-holistic finding or validator failed"
fi

# UXT-1 guards the L5-ux diagnostic-message-quality addition (Stage
# 2.9.B). Content lives in lens-ux-reference.md, which L5's dispatch
# Reads and embeds into its sub-agent prompt (Stage 4.C lazy load —
# fetched only when L5 is in the lens-selection set), so grep the
# reference file directly.
if grep -qF 'Diagnostic message quality' "$REPO/fragments/lens-ux-reference.md" \
    && grep -qF 'parseDate' "$REPO/fragments/lens-ux-reference.md" \
    && grep -qF 'empty-buffer' "$REPO/fragments/lens-ux-reference.md"; then
    pass "UXT-1 (§2.9.B): lens-ux-reference.md includes diagnostic-message-quality section"
else
    fail "UXT-1: diagnostic-message-quality content missing from lens-ux-reference.md"
fi

# LP-LENS-REF-1 (formerly FR-LENS-REF-INLINE-1): the L5 and L6 lens
# prompts (now extracted to fragments/lens-prompts/L5.md and L6.md per
# plans/codex-review.md §4.1) must still contain the canonical lens-
# reference content verbatim. The orchestrator Reads these files into
# the dispatched sub-agent prompt. A regression that truncates either
# file would silently degrade L5/L6 coverage.
L5_PROMPT="$REPO/fragments/lens-prompts/L5.md"
L6_PROMPT="$REPO/fragments/lens-prompts/L6.md"
if grep -qF 'empty-buffer or mid-flush failure' "$L5_PROMPT" \
    && grep -qF 'Input validation & injection' "$L6_PROMPT"; then
    pass "LP-LENS-REF-1: lens-prompts/L5.md and L6.md contain canonical UX/security checklist content"
else
    fail "LP-LENS-REF-1: canonical lens content missing from $L5_PROMPT or $L6_PROMPT"
fi

# LT-1..LT-3 guard the L2 prompt tune (Stage 2.9.A). Stage-2.9 closes
# several P1/P2 misses by adding named prompt sections; silent removal
# would regress detection without failing any helper-level test.

L2_PROMPT="$REPO/fragments/lens-prompts/L2.md"

# LT-1: Outer-pass contains the consumer-surface value trace bullet.
if grep -qF 'Consumer-surface value trace' "$L2_PROMPT" \
    && grep -qF '"0% APR"' "$L2_PROMPT"; then
    pass "LT-1 (§2.9.A): L2 outer pass includes consumer-surface value trace"
else
    fail "LT-1: consumer-surface bullet missing from $L2_PROMPT"
fi

# LT-2: Outer-pass contains the cross-provider / domain-scope bullet.
if grep -qF 'Cross-provider / domain-scope check' "$L2_PROMPT" \
    && grep -qF 'recategorization pass triggered by Apple-import' "$L2_PROMPT"; then
    pass "LT-2 (§2.9.A): L2 outer pass includes cross-provider / domain-scope check"
else
    fail "LT-2: cross-provider bullet missing from $L2_PROMPT"
fi

# LT-3: Inner-pass item 5 is SQL-JOIN-vs-UNIQUE and item 6 is Same-
# block adjacency (renumbered). Both anchors must be present in the
# expected order.
if grep -qF '5. **SQL JOIN join-key vs. target-table UNIQUE-constraint' "$L2_PROMPT" \
    && grep -qF '6. **Same-block adjacency.**' "$L2_PROMPT"; then
    pass "LT-3 (§2.9.A): inner-pass item 5=SQL-JOIN-vs-UNIQUE, item 6=Same-block adjacency"
else
    fail "LT-3: inner-pass renumbering / JOIN item missing from $L2_PROMPT"
fi

# LP-1: All 7 lens-prompts files exist and are non-trivially sized.
# Plan §4.1 extracts the L1–L7 prompt blockquotes from 01-detection.md
# into fragments/lens-prompts/L{1..7}.md so commands/codex-review.md
# can consume the same source-of-truth as commands/review.md. Each
# file must be at least 100 bytes — guards against an accidental
# truncation that would silently degrade lens coverage.
lp_missing=""
for n in 1 2 3 4 5 6 7; do
    f="$REPO/fragments/lens-prompts/L${n}.md"
    if [[ ! -s "$f" ]] || [[ "$(wc -c <"$f")" -lt 100 ]]; then
        lp_missing="$lp_missing L${n}"
    fi
done
if [[ -z "$lp_missing" ]]; then
    pass "LP-1 (codex-review §4.1): all lens-prompts/L{1..7}.md files exist and are >= 100 bytes"
else
    fail "LP-1: lens-prompts files missing or truncated:$lp_missing"
fi

# LP-2: 01-detection.md §1.3 dispatches now reference the lens-prompts/
# files via Read directives — verifies the extraction was completed (no
# stray inline blockquote left behind that would cause prompt drift
# between the file content and what the orchestrator actually
# dispatches).
DETECT_MD_LP2="$REPO/fragments/01-detection.md"
lp2_missing=""
for n in 1 2 3 4 5 6 7; do
    if ! grep -qF "fragments/lens-prompts/L${n}.md" "$DETECT_MD_LP2"; then
        lp2_missing="$lp2_missing L${n}"
    fi
done
if [[ -z "$lp2_missing" ]]; then
    pass "LP-2 (codex-review §4.1): 01-detection.md §1.3 references all 7 lens-prompts files via Read directive"
else
    fail "LP-2: 01-detection.md missing Read directive for:$lp2_missing"
fi

# PFD-8: 01-detection.md contains the step 1.2b wiring block. Guards
# against silent removal — smoke passes for the helper even if the
# wiring is deleted, so add an explicit presence check.
DETECTION_MD="$REPO/fragments/01-detection.md"
if grep -qF '### 1.2b. Prior-fix suspect scan' "$DETECTION_MD" \
    && grep -qF 'prior-fix-diff.sh' "$DETECTION_MD" \
    && grep -qF 'prior_fix_suspects=' "$DETECTION_MD"; then
    pass "PFD-8 (§13.11b): 01-detection.md step 1.2b wires prior-fix-diff.sh"
else
    fail "PFD-8: step 1.2b wiring missing from $DETECTION_MD"
fi

# PFD-9: L2 prompt contains the prior-fix reversion addendum. Guards
# against the wiring existing but L2's prompt never consuming it.
# Post codex-review §4.1: the L2 prompt body now lives in
# fragments/lens-prompts/L2.md; the substitution directive lives in
# 01-detection.md §1.3 L2 dispatch. Both anchors must be present.
# Post parallel-dispatch imperative-fix (v0.3.2): L2 sub-section is
# declarative spec form ("Per-lens substitution: `$prior_fix_suspects`
# → ..."); prior wording was "Substitute `$prior_fix_suspects` ...".
# The new phrase wraps across lines in the fragment (70-char prose
# wrap places "Per-lens" and "substitution: `$prior_fix_suspects`" on
# adjacent lines), so flatten newlines before grep -qF.
detection_flat=$(tr '\n' ' ' < "$DETECTION_MD")
if grep -qF 'Prior-fix reversion check' "$L2_PROMPT" \
    && grep -qF '$prior_fix_suspects' "$L2_PROMPT" \
    && printf '%s' "$detection_flat" | grep -qF 'Per-lens substitution: `$prior_fix_suspects`'; then
    pass "PFD-9 (§13.11b): L2 prompt consumes \$prior_fix_suspects (body in lens-prompts/L2.md, dispatch directive in 01-detection.md)"
else
    fail "PFD-9: L2 prior-fix addendum missing from $L2_PROMPT or substitution directive missing from $DETECTION_MD"
fi

# PFD-7: Lookback cap — prior fix committed before the --lookback-days
# window is filtered out of git log --since output, so no suspect.
mkdir -p "$PFD_DIR/r7"
(
    cd "$PFD_DIR/r7"
    git init --quiet --initial-branch=main 2>/dev/null || git init --quiet
    git symbolic-ref HEAD refs/heads/main 2>/dev/null || true
    git config user.email smoke@example.com
    git config user.name smoke
    printf 'a\nb\nc\nd\n' > f.txt
    GIT_AUTHOR_DATE="2022-01-01T00:00:00Z" GIT_COMMITTER_DATE="2022-01-01T00:00:00Z" \
        git add f.txt && \
        GIT_AUTHOR_DATE="2022-01-01T00:00:00Z" GIT_COMMITTER_DATE="2022-01-01T00:00:00Z" \
        git commit --quiet -m "initial (2022)"
    # Fix committed ~3 years ago.
    sed -i.bak 's/c$/c-fixed/' f.txt && rm -f f.txt.bak
    GIT_AUTHOR_DATE="2022-06-01T00:00:00Z" GIT_COMMITTER_DATE="2022-06-01T00:00:00Z" \
        git add f.txt && \
        GIT_AUTHOR_DATE="2022-06-01T00:00:00Z" GIT_COMMITTER_DATE="2022-06-01T00:00:00Z" \
        git commit --quiet -m "Fix stale-c regression"
    # Tail commit with fresh date so main has recent activity.
    echo "# tail" >> f.txt
    git add f.txt && git commit --quiet -m "tail"
    git checkout --quiet -b feat
    sed -i.bak 's/c-fixed/c/' f.txt && rm -f f.txt.bak
    git add f.txt && git commit --quiet -m "revert c-fixed"
)
# With default lookback (365 days), the 2022 fix is outside the window.
out=$(cd "$PFD_DIR/r7" && "$TOOLS/prior-fix-diff.sh" \
    --comparison-ref main --reviewed-files f.txt 2>/dev/null)
len=$(echo "$out" | jq 'length')
# With a wide lookback (2000 days ≈ 5.5 years), the fix should appear.
out_wide=$(cd "$PFD_DIR/r7" && "$TOOLS/prior-fix-diff.sh" \
    --comparison-ref main --reviewed-files f.txt --lookback-days 2000 2>/dev/null)
len_wide=$(echo "$out_wide" | jq 'length')
if [[ "$len" == "0" && "$len_wide" == "1" ]]; then
    pass "PFD-7 (§13.11b): --lookback-days bounds git-log --since window"
else
    fail "PFD-7: expected default=0 / wide=1; got default=$len wide=$len_wide"
fi

# ------------------------------------------------------------------ tally-subagent-tokens.sh

TK_DIR="$WORK/tk"
mkdir -p "$TK_DIR"
cp "$FIX/artifact-seed.json" "$TK_DIR/artifact.json"
: > "$TK_DIR/tokens.jsonl"

# TK-1: empty tokens.jsonl → zero rollup that schema-validates.
"$TOOLS/tally-subagent-tokens.sh" \
    --tokens-log "$TK_DIR/tokens.jsonl" \
    --artifact   "$TK_DIR/artifact.json" \
    >/dev/null 2>&1 || fail "TK-1: helper exit non-zero on empty log"
tk1_total=$(jq -r '.subagent_tokens.total' "$TK_DIR/artifact.json")
tk1_invs=$(jq -r '.subagent_tokens.invocations' "$TK_DIR/artifact.json")
tk1_by_phase=$(jq -c '.subagent_tokens.by_phase' "$TK_DIR/artifact.json")
if [[ "$tk1_total" == "0" && "$tk1_invs" == "0" && "$tk1_by_phase" == "{}" ]] \
   && "$TOOLS/artifact-validate.sh" --path "$TK_DIR/artifact.json" >/dev/null 2>&1; then
    pass "TK-1: empty log → zero rollup; schema-validates"
else
    fail "TK-1: expected zeros; got total=$tk1_total invs=$tk1_invs by_phase=$tk1_by_phase"
fi

# TK-2: 4-line log with a tokens:null entry → correct totals, null coerced to 0.
cat > "$TK_DIR/tokens.jsonl" <<'JSONL'
{"phase":"phase_1","agent_role":"lens_security","agent_id":"a1","model":"sonnet","tokens":1000,"ts":"2026-04-21T10:00:00Z"}
{"phase":"phase_1","agent_role":"lens_ux","agent_id":"a2","model":"sonnet","tokens":2000,"ts":"2026-04-21T10:00:05Z"}
{"phase":"phase_4a","agent_role":"validator","agent_id":"a3","model":"opus","tokens":null,"ts":"2026-04-21T10:01:00Z","finding_id":"F001"}
{"phase":"phase_4a","agent_role":"validator","agent_id":"a4","model":"opus","tokens":5000,"ts":"2026-04-21T10:01:10Z","finding_id":"F002"}
JSONL
"$TOOLS/tally-subagent-tokens.sh" \
    --tokens-log "$TK_DIR/tokens.jsonl" \
    --artifact   "$TK_DIR/artifact.json" \
    >/dev/null 2>&1 || fail "TK-2: helper exit non-zero on populated log"
tk2_total=$(jq -r '.subagent_tokens.total' "$TK_DIR/artifact.json")
tk2_invs=$(jq -r '.subagent_tokens.invocations' "$TK_DIR/artifact.json")
tk2_lens_sec=$(jq -r '.subagent_tokens.by_lens.lens_security' "$TK_DIR/artifact.json")
tk2_p4_f001=$(jq -r '.subagent_tokens.by_finding_phase4.F001' "$TK_DIR/artifact.json")
if [[ "$tk2_total" == "8000" && "$tk2_invs" == "4" \
      && "$tk2_lens_sec" == "1000" && "$tk2_p4_f001" == "0" ]]; then
    pass "TK-2: 4-line log with tokens:null → total=8000 invs=4, null coerced to 0"
else
    fail "TK-2: expected total=8000 invs=4 lens_security=1000 F001=0; got total=$tk2_total invs=$tk2_invs lens_security=$tk2_lens_sec F001=$tk2_p4_f001"
fi

# TK-3: re-invocation is idempotent (bit-for-bit subagent_tokens).
tk3_before=$(jq -cS '.subagent_tokens' "$TK_DIR/artifact.json")
"$TOOLS/tally-subagent-tokens.sh" \
    --tokens-log "$TK_DIR/tokens.jsonl" \
    --artifact   "$TK_DIR/artifact.json" \
    >/dev/null 2>&1 || fail "TK-3: helper exit non-zero on re-run"
tk3_after=$(jq -cS '.subagent_tokens' "$TK_DIR/artifact.json")
if [[ "$tk3_before" == "$tk3_after" ]]; then
    pass "TK-3: idempotent re-invocation on unchanged log"
else
    fail "TK-3: subagent_tokens diverged on re-run" "before=$tk3_before after=$tk3_after"
fi

# TK-4: append new lines → total strictly grows by the appended sum (the
# cumulative-growth invariant that the lifecycle wiring relies on).
printf '{"phase":"phase_9","agent_role":"post_fix_reviewer","agent_id":"a5","model":"opus","tokens":3500,"ts":"2026-04-21T11:00:00Z"}\n' >> "$TK_DIR/tokens.jsonl"
printf '{"phase":"phase_9","agent_role":"fix_group","agent_id":"a6","model":"opus","tokens":1500,"ts":"2026-04-21T11:00:30Z"}\n' >> "$TK_DIR/tokens.jsonl"
"$TOOLS/tally-subagent-tokens.sh" \
    --tokens-log "$TK_DIR/tokens.jsonl" \
    --artifact   "$TK_DIR/artifact.json" \
    >/dev/null 2>&1 || fail "TK-4: helper exit non-zero after append"
tk4_total=$(jq -r '.subagent_tokens.total' "$TK_DIR/artifact.json")
tk4_invs=$(jq -r '.subagent_tokens.invocations' "$TK_DIR/artifact.json")
tk4_p9=$(jq -r '.subagent_tokens.by_phase.phase_9' "$TK_DIR/artifact.json")
if [[ "$tk4_total" == "13000" && "$tk4_invs" == "6" && "$tk4_p9" == "5000" ]]; then
    pass "TK-4: cumulative growth — total=8000→13000 (+5000), phase_9=5000"
else
    fail "TK-4: expected total=13000 invs=6 phase_9=5000; got total=$tk4_total invs=$tk4_invs phase_9=$tk4_p9"
fi

# TK-5: the chat-summary jq -r filter used by matthewsreview:add step 10 and
# matthewsreview:walkthrough step 9. Must produce a clean (unquoted) line on
# a populated artifact and empty stdout when subagent_tokens is absent.
token_filter='if (.subagent_tokens.total // null) != null and (.subagent_tokens.invocations // null) != null
    then "Cumulative sub-agent spend: \(.subagent_tokens.total) tokens across \(.subagent_tokens.invocations) invocations."
    else empty end'
tk5_line=$(jq -r "$token_filter" "$TK_DIR/artifact.json")
tk5_expected="Cumulative sub-agent spend: 13000 tokens across 6 invocations."
if [[ "$tk5_line" == "$tk5_expected" ]]; then
    pass "TK-5: chat-summary jq -r filter produces clean line on populated artifact"
else
    fail "TK-5: filter output mismatch" "expected=[$tk5_expected] got=[$tk5_line]"
fi

jq 'del(.subagent_tokens)' "$TK_DIR/artifact.json" > "$TK_DIR/art-no-st.json"
tk5_missing=$(jq -r "$token_filter" "$TK_DIR/art-no-st.json")
if [[ -z "$tk5_missing" ]]; then
    pass "TK-6: chat-summary filter omits line when subagent_tokens absent"
else
    fail "TK-6: expected empty output; got [$tk5_missing]"
fi

# TK-7: phase_4b chunk-agent rows (light-lane, chunked-batch — see
# fragments/05-validation.md §4.3) log without finding_id. Without the
# tally's null-key filter, jq's `from_entries` would error on them.
# This assertion appends one such row, re-tallies, and confirms:
#   (a) the helper exits 0 (doesn't crash on a missing-finding_id row),
#   (b) total / phase_4b in by_phase reflect the new tokens,
#   (c) by_finding_phase4 still keys only on real finding ids
#       (the chunk-agent's tokens roll up only into total/by_phase/by_model).
printf '{"phase":"phase_4b","agent_role":"validator","agent_id":"a7","model":"sonnet","tokens":2400,"ts":"2026-04-24T12:00:00Z"}\n' >> "$TK_DIR/tokens.jsonl"
"$TOOLS/tally-subagent-tokens.sh" \
    --tokens-log "$TK_DIR/tokens.jsonl" \
    --artifact   "$TK_DIR/artifact.json" \
    >/dev/null 2>&1 || fail "TK-7: helper exit non-zero on chunked phase_4b row (null-key from_entries regression)"
tk7_total=$(jq -r '.subagent_tokens.total' "$TK_DIR/artifact.json")
tk7_p4b=$(jq -r '.subagent_tokens.by_phase.phase_4b // 0' "$TK_DIR/artifact.json")
tk7_by_finding_keys=$(jq -r '.subagent_tokens.by_finding_phase4 | keys | join(",")' "$TK_DIR/artifact.json")
if [[ "$tk7_total" == "15400" && "$tk7_p4b" == "2400" \
      && "$tk7_by_finding_keys" == "F001,F002" ]]; then
    pass "TK-7: phase_4b chunk-agent row (no finding_id) tallies cleanly; by_finding_phase4 keeps only real ids"
else
    fail "TK-7: expected total=15400 phase_4b=2400 by_finding_phase4_keys=F001,F002; got total=$tk7_total p4b=$tk7_p4b keys=$tk7_by_finding_keys"
fi

# ------------------------------------------------------------------ orchestrator-tokens.sh

# OT-1 through OT-7 exercise the populated tally path; the helper now
# defaults to skip unless MATTHEWS_REVIEW_TALLY_ORCHESTRATOR is set, so
# scope-export it here. OT-8 (added below) covers the opt-out skip path
# explicitly via `env -u` so test ordering doesn't matter. The trailing
# `unset` keeps the export from leaking into downstream test blocks.
export MATTHEWS_REVIEW_TALLY_ORCHESTRATOR=1

OT_DIR="$WORK/ot"
mkdir -p "$OT_DIR"
cp "$FIX/artifact-seed.json" "$OT_DIR/artifact.json"

# OT-1: without SessionStart metadata, the helper skips instead of deriving a
# cwd slug and scanning every transcript in that project directory. Seed a
# plausible legacy directory to ensure no implicit fallback can count it.
OT1_HOME="$OT_DIR/t1-home"
mkdir -p "$OT_DIR/art1" "$OT1_HOME/.claude/projects/legacy"
cp "$FIX/artifact-seed.json" "$OT_DIR/art1/artifact.json"
cat > "$OT1_HOME/.claude/projects/legacy/unrelated.jsonl" <<'JSONL'
{"type":"assistant","timestamp":"2026-04-21T10:00:00.000Z","sessionId":"unrelated","message":{"usage":{"input_tokens":999,"output_tokens":999,"cache_read_input_tokens":999,"cache_creation_input_tokens":999}}}
JSONL
ot1_stdout=$(env -u MATTHEWS_REVIEW_TRANSCRIPT_FILE -u MATTHEWS_REVIEW_SESSION_ID \
    HOME="$OT1_HOME" "$TOOLS/orchestrator-tokens.sh" \
      --artifact "$OT_DIR/art1/artifact.json" \
      --since "2026-04-21T00:00:00.000Z" 2>&1)
ot1_field=$(jq -r '.orchestrator_tokens // "absent"' "$OT_DIR/art1/artifact.json")
if [[ "$ot1_stdout" == *"no Claude SessionStart transcript metadata"* \
      && "$ot1_field" == "absent" ]]; then
    pass "OT-1: missing SessionStart metadata skips without cwd-wide transcript scan"
else
    fail "OT-1: helper retained an implicit directory scan" "stdout=$ot1_stdout field=$ot1_field"
fi

# OT-2: a missing explicit transcript file is a caller error and may not write
# a misleading zero rollup.
ot2_explicit=$("$TOOLS/orchestrator-tokens.sh" \
    --artifact "$OT_DIR/artifact.json" \
    --since "2026-04-21T00:00:00.000Z" \
    --transcript-file "$OT_DIR/does-not-exist.jsonl" 2>&1)
ot2_explicit_code=$?
ot2_field=$(jq -r '.orchestrator_tokens // "absent"' "$OT_DIR/artifact.json")
if [[ $ot2_explicit_code -eq 1 \
      && "$ot2_explicit" == *"explicit transcript file not found"* \
      && "$ot2_explicit" == *"Action:"* \
      && "$ot2_field" == "absent" ]] \
   && "$TOOLS/artifact-validate.sh" --path "$OT_DIR/artifact.json" >/dev/null 2>&1; then
    pass "OT-2: explicit missing transcript file fails; artifact stays absent"
else
    fail "OT-2: explicit transcript guard mismatch" \
      "explicit=$ot2_explicit_code:$ot2_explicit field=$ot2_field"
fi

# OT-3: one synthetic transcript, 3 in-window assistant turns with known
# usage counts. Verify all four counters, turn_count, and session audit row.
OT3_DIR="$OT_DIR/t3"
mkdir -p "$OT_DIR/art3" "$OT3_DIR"
cp "$FIX/artifact-seed.json" "$OT_DIR/art3/artifact.json"
cat > "$OT3_DIR/sess-a.jsonl" <<'JSONL'
{"type":"assistant","timestamp":"2026-04-21T10:00:00.000Z","sessionId":"sess-a","message":{"usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":30,"cache_creation_input_tokens":40}}}
{"type":"assistant","timestamp":"2026-04-21T10:01:00.000Z","sessionId":"sess-a","message":{"usage":{"input_tokens":5,"output_tokens":15,"cache_read_input_tokens":25,"cache_creation_input_tokens":35}}}
{"type":"assistant","timestamp":"2026-04-21T10:02:00.000Z","sessionId":"sess-a","message":{"usage":{"input_tokens":1,"output_tokens":2,"cache_read_input_tokens":3,"cache_creation_input_tokens":4}}}
JSONL
"$TOOLS/orchestrator-tokens.sh" \
    --artifact "$OT_DIR/art3/artifact.json" \
    --since "2026-04-21T00:00:00.000Z" \
    --transcript-file "$OT3_DIR/sess-a.jsonl" \
    >/dev/null 2>&1 || fail "OT-3: helper exit non-zero on populated transcript"
ot3_in=$(jq -r '.orchestrator_tokens.total_input' "$OT_DIR/art3/artifact.json")
ot3_out=$(jq -r '.orchestrator_tokens.total_output' "$OT_DIR/art3/artifact.json")
ot3_cr=$(jq -r '.orchestrator_tokens.cache_read' "$OT_DIR/art3/artifact.json")
ot3_cc=$(jq -r '.orchestrator_tokens.cache_creation' "$OT_DIR/art3/artifact.json")
ot3_turns=$(jq -r '.orchestrator_tokens.turn_count' "$OT_DIR/art3/artifact.json")
ot3_sid=$(jq -r '.orchestrator_tokens.sessions[0].session_id' "$OT_DIR/art3/artifact.json")
ot3_slen=$(jq -r '.orchestrator_tokens.sessions | length' "$OT_DIR/art3/artifact.json")
if [[ "$ot3_in" == "16" && "$ot3_out" == "37" && "$ot3_cr" == "58" && "$ot3_cc" == "79" \
   && "$ot3_turns" == "3" && "$ot3_sid" == "sess-a" && "$ot3_slen" == "1" ]]; then
    pass "OT-3: 3-turn transcript → correct four-counter sums + sessions[] entry"
else
    fail "OT-3: sum mismatch" "in=$ot3_in out=$ot3_out cr=$ot3_cr cc=$ot3_cc turns=$ot3_turns sid=$ot3_sid slen=$ot3_slen"
fi

# OT-4: a malformed concatenated file can carry two session ids. Without an
# explicit session filter, audit rows remain grouped and sorted deterministically.
cat >> "$OT3_DIR/sess-a.jsonl" <<'JSONL'
{"type":"assistant","timestamp":"2026-04-21T09:00:00.000Z","sessionId":"sess-b","message":{"usage":{"input_tokens":100,"output_tokens":200,"cache_read_input_tokens":300,"cache_creation_input_tokens":400}}}
JSONL
"$TOOLS/orchestrator-tokens.sh" \
    --artifact "$OT_DIR/art3/artifact.json" \
    --since "2026-04-21T00:00:00.000Z" \
    --transcript-file "$OT3_DIR/sess-a.jsonl" \
    >/dev/null 2>&1 || fail "OT-4: helper exit non-zero on multi-session transcript"
ot4_turns=$(jq -r '.orchestrator_tokens.turn_count' "$OT_DIR/art3/artifact.json")
ot4_in=$(jq -r '.orchestrator_tokens.total_input' "$OT_DIR/art3/artifact.json")
ot4_slen=$(jq -r '.orchestrator_tokens.sessions | length' "$OT_DIR/art3/artifact.json")
ot4_first=$(jq -r '.orchestrator_tokens.sessions[0].session_id' "$OT_DIR/art3/artifact.json")
ot4_second=$(jq -r '.orchestrator_tokens.sessions[1].session_id' "$OT_DIR/art3/artifact.json")
if [[ "$ot4_turns" == "4" && "$ot4_in" == "116" && "$ot4_slen" == "2" \
   && "$ot4_first" == "sess-b" && "$ot4_second" == "sess-a" ]]; then
    pass "OT-4: multi-session file → totals sum; sessions[] sorted by first_seen"
else
    fail "OT-4: grouping mismatch" "turns=$ot4_turns in=$ot4_in slen=$ot4_slen first=$ot4_first second=$ot4_second"
fi

# OT-5: time-window filter excludes all future-window turns and keeps only the
# two sess-a turns after a mid-window cutoff.
"$TOOLS/orchestrator-tokens.sh" \
    --artifact "$OT_DIR/art3/artifact.json" \
    --since "2099-01-01T00:00:00.000Z" \
    --transcript-file "$OT3_DIR/sess-a.jsonl" \
    >/dev/null 2>&1 || fail "OT-5: helper exit non-zero on future --since"
ot5_turns=$(jq -r '.orchestrator_tokens.turn_count' "$OT_DIR/art3/artifact.json")
ot5_slen=$(jq -r '.orchestrator_tokens.sessions | length' "$OT_DIR/art3/artifact.json")
"$TOOLS/orchestrator-tokens.sh" \
    --artifact "$OT_DIR/art3/artifact.json" \
    --since "2026-04-21T10:00:30.000Z" \
    --transcript-file "$OT3_DIR/sess-a.jsonl" \
    >/dev/null 2>&1 || fail "OT-5: helper exit non-zero on partial window"
ot5p_turns=$(jq -r '.orchestrator_tokens.turn_count' "$OT_DIR/art3/artifact.json")
ot5p_in=$(jq -r '.orchestrator_tokens.total_input' "$OT_DIR/art3/artifact.json")
if [[ "$ot5_turns" == "0" && "$ot5_slen" == "0" && "$ot5p_turns" == "2" && "$ot5p_in" == "6" ]]; then
    pass "OT-5: --since filter — future excludes all; partial window keeps only post-since turns"
else
    fail "OT-5: window filter mismatch" "future_turns=$ot5_turns future_slen=$ot5_slen partial_turns=$ot5p_turns partial_in=$ot5p_in"
fi

# OT-7: second-precision --since includes same-second millisecond turns.
OT7_DIR="$OT_DIR/t7"
mkdir -p "$OT_DIR/art7" "$OT7_DIR"
cp "$FIX/artifact-seed.json" "$OT_DIR/art7/artifact.json"
cat > "$OT7_DIR/sess.jsonl" <<'JSONL'
{"type":"assistant","timestamp":"2026-04-21T10:00:00.500Z","sessionId":"sess-d","message":{"usage":{"input_tokens":100,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
{"type":"assistant","timestamp":"2026-04-21T10:00:01.000Z","sessionId":"sess-d","message":{"usage":{"input_tokens":100,"output_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
JSONL
"$TOOLS/orchestrator-tokens.sh" \
    --artifact "$OT_DIR/art7/artifact.json" \
    --since "2026-04-21T10:00:00Z" \
    --transcript-file "$OT7_DIR/sess.jsonl" \
    >/dev/null 2>&1 || fail "OT-7: helper exit non-zero on second-precision since"
ot7_turns=$(jq -r '.orchestrator_tokens.turn_count' "$OT_DIR/art7/artifact.json")
ot7_in=$(jq -r '.orchestrator_tokens.total_input' "$OT_DIR/art7/artifact.json")
if [[ "$ot7_turns" == "2" && "$ot7_in" == "200" ]]; then
    pass "OT-7: second-precision --since includes same-second ms-precision turns (normalized to .000Z)"
else
    fail "OT-7: expected turns=2 in=200 (normalization works); got turns=$ot7_turns in=$ot7_in"
fi

# OT-6: non-assistant lines are ignored.
OT6_DIR="$OT_DIR/t6"
mkdir -p "$OT_DIR/art6" "$OT6_DIR"
cp "$FIX/artifact-seed.json" "$OT_DIR/art6/artifact.json"
cat > "$OT6_DIR/mix.jsonl" <<'JSONL'
{"type":"user","timestamp":"2026-04-21T10:00:00.000Z","message":{"content":"hi"}}
{"type":"system","timestamp":"2026-04-21T10:00:01.000Z","message":"boot"}
{"type":"worktree-state","timestamp":"2026-04-21T10:00:02.000Z"}
{"type":"assistant","timestamp":"2026-04-21T10:00:03.000Z","sessionId":"sess-c","message":{"usage":{"input_tokens":7,"output_tokens":8,"cache_read_input_tokens":9,"cache_creation_input_tokens":10}}}
{"type":"attachment","timestamp":"2026-04-21T10:00:04.000Z"}
JSONL
"$TOOLS/orchestrator-tokens.sh" \
    --artifact "$OT_DIR/art6/artifact.json" \
    --since "2026-04-21T00:00:00.000Z" \
    --transcript-file "$OT6_DIR/mix.jsonl" \
    >/dev/null 2>&1 || fail "OT-6: helper exit non-zero on mixed-types transcript"
ot6_turns=$(jq -r '.orchestrator_tokens.turn_count' "$OT_DIR/art6/artifact.json")
ot6_in=$(jq -r '.orchestrator_tokens.total_input' "$OT_DIR/art6/artifact.json")
ot6_out=$(jq -r '.orchestrator_tokens.total_output' "$OT_DIR/art6/artifact.json")
if [[ "$ot6_turns" == "1" && "$ot6_in" == "7" && "$ot6_out" == "8" ]]; then
    pass "OT-6: non-assistant line types (user/system/worktree-state/attachment) ignored"
else
    fail "OT-6: filter let non-assistant lines through" "turns=$ot6_turns in=$ot6_in out=$ot6_out"
fi

# OT-8: opt-out skips and leaves the optional field absent.
OT8_DIR="$OT_DIR/t8"
mkdir -p "$OT_DIR/art8" "$OT8_DIR"
cp "$FIX/artifact-seed.json" "$OT_DIR/art8/artifact.json"
: > "$OT8_DIR/empty.jsonl"
ot8_stdout=$(env -u MATTHEWS_REVIEW_TALLY_ORCHESTRATOR \
    "$TOOLS/orchestrator-tokens.sh" \
      --artifact "$OT_DIR/art8/artifact.json" \
      --since "2026-04-21T00:00:00.000Z" \
      --transcript-file "$OT8_DIR/empty.jsonl" 2>&1)
ot8_exit=$?
ot8_field=$(jq -r '.orchestrator_tokens // "absent"' "$OT_DIR/art8/artifact.json")
if [[ $ot8_exit -eq 0 && "$ot8_stdout" == *"skipped"* \
      && "$ot8_stdout" == *"MATTHEWS_REVIEW_TALLY_ORCHESTRATOR"* \
      && "$ot8_field" == "absent" ]] \
   && "$TOOLS/artifact-validate.sh" --path "$OT_DIR/art8/artifact.json" >/dev/null 2>&1; then
    pass "OT-8: opt-out (env unset) skips tally — exit 0, 'skipped' stdout, no artifact mutation, schema-valid"
else
    fail "OT-8: opt-out skip mismatch" "exit=$ot8_exit field=$ot8_field stdout=$ot8_stdout"
fi

# OT-9: legacy ADAMS_REVIEW_TALLY_ORCHESTRATOR=1 opt-in still runs.
OT9_DIR="$OT_DIR/t9"
mkdir -p "$OT_DIR/art9" "$OT9_DIR"
cp "$FIX/artifact-seed.json" "$OT_DIR/art9/artifact.json"
: > "$OT9_DIR/empty.jsonl"
ot9_stdout=$(env -u MATTHEWS_REVIEW_TALLY_ORCHESTRATOR ADAMS_REVIEW_TALLY_ORCHESTRATOR=1 \
    "$TOOLS/orchestrator-tokens.sh" \
      --artifact "$OT_DIR/art9/artifact.json" \
      --since "2026-04-21T00:00:00.000Z" \
      --transcript-file "$OT9_DIR/empty.jsonl" 2>&1)
ot9_exit=$?
if [[ $ot9_exit -eq 0 && "$ot9_stdout" != *"skipped"* ]]; then
    pass "OT-9: legacy ADAMS_REVIEW_TALLY_ORCHESTRATOR=1 opt-in runs the tally (no skip)"
else
    fail "OT-9: legacy opt-in fallback mismatch" "exit=$ot9_exit stdout=$ot9_stdout"
fi

# OT-10: an explicit transcript file plus session id scopes the tally to the
# active Claude Code session. Even if the file contains a stray assistant line
# from another session, it must not be counted; sibling transcript files in the
# same directory are never opened.
OT10_DIR="$OT_DIR/t10"
mkdir -p "$OT_DIR/art10" "$OT10_DIR"
cp "$FIX/artifact-seed.json" "$OT_DIR/art10/artifact.json"
cat > "$OT10_DIR/current.jsonl" <<'JSONL'
{"type":"assistant","timestamp":"2026-04-21T10:00:00.000Z","sessionId":"current-session","message":{"usage":{"input_tokens":11,"output_tokens":12,"cache_read_input_tokens":13,"cache_creation_input_tokens":14}}}
{"type":"assistant","timestamp":"2026-04-21T10:00:01.000Z","sessionId":"other-session","message":{"usage":{"input_tokens":100,"output_tokens":200,"cache_read_input_tokens":300,"cache_creation_input_tokens":400}}}
JSONL
cat > "$OT10_DIR/sibling.jsonl" <<'JSONL'
{"type":"assistant","timestamp":"2026-04-21T10:00:02.000Z","sessionId":"sibling-session","message":{"usage":{"input_tokens":1000,"output_tokens":2000,"cache_read_input_tokens":3000,"cache_creation_input_tokens":4000}}}
JSONL
"$TOOLS/orchestrator-tokens.sh" \
    --artifact "$OT_DIR/art10/artifact.json" \
    --since "2026-04-21T00:00:00.000Z" \
    --transcript-file "$OT10_DIR/current.jsonl" \
    --session-id "current-session" \
    >/dev/null 2>&1 || fail "OT-10: helper exit non-zero on session-scoped transcript"
cp "$FIX/artifact-seed.json" "$OT_DIR/art10/artifact-env.json"
env MATTHEWS_REVIEW_TRANSCRIPT_FILE="$OT10_DIR/current.jsonl" \
    MATTHEWS_REVIEW_SESSION_ID="current-session" \
    "$TOOLS/orchestrator-tokens.sh" \
      --artifact "$OT_DIR/art10/artifact-env.json" \
      --since "2026-04-21T00:00:00.000Z" \
      >/dev/null 2>&1 || fail "OT-10: helper exit non-zero on SessionStart environment scope"
ot10_env_in=$(jq -r '.orchestrator_tokens.total_input' "$OT_DIR/art10/artifact-env.json")
ot10_in=$(jq -r '.orchestrator_tokens.total_input' "$OT_DIR/art10/artifact.json")
ot10_out=$(jq -r '.orchestrator_tokens.total_output' "$OT_DIR/art10/artifact.json")
ot10_turns=$(jq -r '.orchestrator_tokens.turn_count' "$OT_DIR/art10/artifact.json")
ot10_sids=$(jq -r '.orchestrator_tokens.sessions | map(.session_id) | join(",")' "$OT_DIR/art10/artifact.json")
if [[ "$ot10_in" == "11" && "$ot10_out" == "12" && "$ot10_turns" == "1" \
      && "$ot10_sids" == "current-session" && "$ot10_env_in" == "11" ]]; then
    pass "OT-10: explicit transcript + session id excludes sibling files and foreign-session lines"
else
    fail "OT-10: session-scoped tally mismatch" \
      "in=$ot10_in out=$ot10_out turns=$ot10_turns sessions=$ot10_sids env_in=$ot10_env_in"
fi

# OT-11: Claude Code's SessionStart hook persists the exact current session id
# and transcript path into CLAUDE_ENV_FILE. Values with spaces must round-trip
# through the shell environment file without corruption.
OT11_ENV="$OT_DIR/t11-env"
: > "$OT11_ENV"
printf '%s\n' \
  '{"session_id":"session with spaces","transcript_path":"/tmp/transcript path/current.jsonl","cwd":"/tmp/work tree","hook_event_name":"SessionStart"}' \
  | env CLAUDE_ENV_FILE="$OT11_ENV" "$REPO/hooks/dep-check.sh" \
      >/dev/null 2>&1
ot11_values=$(bash -c \
  'source "$1"; printf "%s|%s" "$MATTHEWS_REVIEW_SESSION_ID" "$MATTHEWS_REVIEW_TRANSCRIPT_FILE"' \
  _ "$OT11_ENV")
if [[ "$ot11_values" == "session with spaces|/tmp/transcript path/current.jsonl" ]]; then
    pass "OT-11: SessionStart hook exports current Claude session metadata safely"
else
    fail "OT-11: SessionStart metadata export mismatch" "$ot11_values"
fi

# OT-12: lifecycle commands may run in later Claude sessions. Retain the
# already-recorded session totals without reopening old transcripts, and
# replace (rather than add) a session when its growing transcript is retallied.
OT12_DIR="$OT_DIR/t12"
mkdir -p "$OT_DIR/art12" "$OT12_DIR"
cp "$FIX/artifact-seed.json" "$OT_DIR/art12/artifact.json"
cat > "$OT12_DIR/a.jsonl" <<'JSONL'
{"type":"assistant","timestamp":"2026-04-21T10:00:00.000Z","sessionId":"lifecycle-a","message":{"usage":{"input_tokens":10,"output_tokens":1,"cache_read_input_tokens":2,"cache_creation_input_tokens":3}}}
JSONL
cat > "$OT12_DIR/b.jsonl" <<'JSONL'
{"type":"assistant","timestamp":"2026-04-21T11:00:00.000Z","sessionId":"lifecycle-b","message":{"usage":{"input_tokens":20,"output_tokens":4,"cache_read_input_tokens":5,"cache_creation_input_tokens":6}}}
JSONL
"$TOOLS/orchestrator-tokens.sh" \
    --artifact "$OT_DIR/art12/artifact.json" \
    --since "2026-04-21T00:00:00.000Z" \
    --transcript-file "$OT12_DIR/a.jsonl" \
    --session-id "lifecycle-a" >/dev/null 2>&1 \
    || fail "OT-12: first lifecycle session tally failed"
"$TOOLS/orchestrator-tokens.sh" \
    --artifact "$OT_DIR/art12/artifact.json" \
    --since "2026-04-21T00:00:00.000Z" \
    --transcript-file "$OT12_DIR/b.jsonl" \
    --session-id "lifecycle-b" >/dev/null 2>&1 \
    || fail "OT-12: second lifecycle session tally failed"
cat >> "$OT12_DIR/a.jsonl" <<'JSONL'
{"type":"assistant","timestamp":"2026-04-21T12:00:00.000Z","sessionId":"lifecycle-a","message":{"usage":{"input_tokens":5,"output_tokens":7,"cache_read_input_tokens":8,"cache_creation_input_tokens":9}}}
JSONL
"$TOOLS/orchestrator-tokens.sh" \
    --artifact "$OT_DIR/art12/artifact.json" \
    --since "2026-04-21T00:00:00.000Z" \
    --transcript-file "$OT12_DIR/a.jsonl" \
    --session-id "lifecycle-a" >/dev/null 2>&1 \
    || fail "OT-12: repeated lifecycle session tally failed"
ot12_summary=$(jq -r '
  [
    .orchestrator_tokens.total_input,
    .orchestrator_tokens.total_output,
    .orchestrator_tokens.cache_read,
    .orchestrator_tokens.cache_creation,
    .orchestrator_tokens.turn_count,
    (.orchestrator_tokens.sessions | length),
    .orchestrator_tokens.sessions[0].total_input,
    .orchestrator_tokens.sessions[1].total_input
  ] | map(tostring) | join("|")
' "$OT_DIR/art12/artifact.json")
if [[ "$ot12_summary" == "35|12|15|18|3|2|15|20" ]] \
   && "$TOOLS/artifact-validate.sh" --path "$OT_DIR/art12/artifact.json" >/dev/null 2>&1; then
    pass "OT-12: cross-session totals accumulate; repeated session tally replaces prior counters"
else
    fail "OT-12: lifecycle session accumulation mismatch" "$ot12_summary"
fi

# OT-13: hook-derived operation requires both metadata fields. A transcript
# path without its session id must skip rather than silently broadening to every
# sessionId present in that file.
OT13_DIR="$OT_DIR/t13"
mkdir -p "$OT_DIR/art13" "$OT13_DIR"
cp "$FIX/artifact-seed.json" "$OT_DIR/art13/artifact.json"
cat > "$OT13_DIR/current.jsonl" <<'JSONL'
{"type":"assistant","timestamp":"2026-04-21T10:00:00.000Z","sessionId":"unscoped-session","message":{"usage":{"input_tokens":99,"output_tokens":99,"cache_read_input_tokens":99,"cache_creation_input_tokens":99}}}
JSONL
ot13_stdout=$(env -u MATTHEWS_REVIEW_SESSION_ID \
    MATTHEWS_REVIEW_TRANSCRIPT_FILE="$OT13_DIR/current.jsonl" \
    "$TOOLS/orchestrator-tokens.sh" \
      --artifact "$OT_DIR/art13/artifact.json" \
      --since "2026-04-21T00:00:00.000Z" 2>&1)
ot13_exit=$?
ot13_field=$(jq -r '.orchestrator_tokens // "absent"' "$OT_DIR/art13/artifact.json")
if [[ $ot13_exit -eq 0 && "$ot13_stdout" == *"incomplete Claude SessionStart"* \
      && "$ot13_field" == "absent" ]]; then
    pass "OT-13: incomplete hook metadata skips instead of widening the session filter"
else
    fail "OT-13: incomplete hook metadata guard mismatch" \
      "exit=$ot13_exit field=$ot13_field stdout=$ot13_stdout"
fi

unset MATTHEWS_REVIEW_TALLY_ORCHESTRATOR

# ------------------------------------------------------------------
# RC: review-config.sh — model-plan resolver (precedence, grammar, matrix)
# Isolated HOME + repo so user/repo configs are fully controlled.
RC_HOME="$WORK/rc-home"
RC_REPO="$WORK/rc-repo"
mkdir -p "$RC_HOME/.matthews-reviews" "$RC_REPO"
cat > "$RC_HOME/.matthews-reviews/config.json" <<'EOF'
{"tiers":{"utility":"claude:haiku"},"roles":{"scoring":"codex::medium"},"gates":{"phase3_gate":55},"profiles":{"max":{"tiers":{"light":"claude:opus"}}}}
EOF
cat > "$RC_REPO/.matthewsreview.json" <<'EOF'
{"tiers":{"light":"claude:haiku"},"roles":{"scoring":"claude:sonnet"}}
EOF
git -C "$RC_REPO" init -q
git -C "$RC_REPO" add .matthewsreview.json
git -C "$RC_REPO" -c user.name=Smoke -c user.email=smoke@example.invalid \
    -c commit.gpgsign=false commit --no-gpg-sign -qm "trusted repo config"
RC_TRUSTED_REF=$(git -C "$RC_REPO" rev-parse HEAD)
RC_BASE_BRANCH=$(git -C "$RC_REPO" symbolic-ref --short HEAD)
git -C "$RC_REPO" checkout -qb worktree
printf '%s\n' '{"roles":{"scoring":"claude:opus"}}' \
    > "$RC_REPO/.matthewsreview.json"
git -C "$RC_REPO" add .matthewsreview.json
git -C "$RC_REPO" -c user.name=Smoke -c user.email=smoke@example.invalid \
    -c commit.gpgsign=false commit --no-gpg-sign -qm "branch named worktree"
git -C "$RC_REPO" checkout -q "$RC_BASE_BRANCH"
RC_WORKTREE_CONFIG='{"roles":{"scoring":"claude:haiku"}}'
printf '%s\n' "$RC_WORKTREE_CONFIG" > "$RC_REPO/.matthewsreview.json"
rc_run() {
    env -u MATTHEWS_REVIEW_REVIEWS_ROOT HOME="$RC_HOME" \
        "$TOOLS/review-config.sh" --repo-root "$RC_REPO" \
        --repo-config-ref "$RC_TRUSTED_REF" "$@"
}
rc_run_worktree() {
    env -u MATTHEWS_REVIEW_REVIEWS_ROOT HOME="$RC_HOME" \
        "$TOOLS/review-config.sh" --repo-root "$RC_REPO" \
        --repo-config-worktree "$@"
}

# RC-1: defaults — deep role inherits claude:opus from default tier, gates default 45
# (empty HOME → no user config; repo config moved aside → pure defaults)
RC_EMPTY="$WORK/rc-empty"
mkdir -p "$RC_EMPTY"
mv "$RC_REPO/.matthewsreview.json" "$RC_REPO/.matthewsreview.json.hold"
rc_out=$(env -u MATTHEWS_REVIEW_REVIEWS_ROOT HOME="$RC_EMPTY" "$TOOLS/review-config.sh" --repo-root "$RC_REPO" --orchestrator claude-code); code=$?
mv "$RC_REPO/.matthewsreview.json.hold" "$RC_REPO/.matthewsreview.json"
rc_deep=$(printf '%s' "$rc_out" | jq -r '.roles.deep_validate | "\(.engine):\(.model)|\(.source)"')
rc_gate=$(printf '%s' "$rc_out" | jq -r '.gates.phase3_gate')
if [[ $code -eq 0 && "$rc_deep" == "claude:opus|default (tier:deep)" && "$rc_gate" == "45" ]]; then
    pass "RC-1: defaults resolve (deep=claude:opus via default tier; phase3_gate=45)"
else
    fail "RC-1: default resolution mismatch" "code=$code deep=$rc_deep gate=$rc_gate"
fi

# RC-2: user config + repo config precedence (repo wins role scoring; user wins tier utility)
rc_out=$(rc_run --orchestrator claude-code)
rc_scoring=$(printf '%s' "$rc_out" | jq -r '.roles.scoring | "\(.engine):\(.model)|\(.source)"')
rc_util=$(printf '%s' "$rc_out" | jq -r '.roles.dedup | "\(.engine):\(.model)|\(.source)"')
rc_gate=$(printf '%s' "$rc_out" | jq -r '.gates.phase3_gate')
if [[ "$rc_scoring" == "claude:sonnet|repo-config" && "$rc_util" == "claude:haiku|user-config (tier:utility)" && "$rc_gate" == "55" ]]; then
    pass "RC-2: user < repo precedence (role from repo, tier from user, gate merged)"
else
    fail "RC-2: precedence mismatch" "scoring=$rc_scoring util=$rc_util gate=$rc_gate"
fi

# RCT-1: a repo config is executable policy, so normal resolution reads only
# the selected trusted commit. A Git branch literally named "worktree" remains
# an ordinary ref, while the dirty file is available solely through the
# separate diagnostic flag. Omission, bad refs, and selector conflicts emit no
# plan.
rct_trusted_out=$(rc_run --orchestrator claude-code)
rct_trusted_scoring=$(printf '%s' "$rct_trusted_out" | jq -r \
    '.roles.scoring | "\(.engine):\(.model)|\(.source)"')
rct_branch_out=$(env -u MATTHEWS_REVIEW_REVIEWS_ROOT HOME="$RC_HOME" \
    "$TOOLS/review-config.sh" --repo-root "$RC_REPO" \
    --repo-config-ref worktree --orchestrator claude-code)
rct_branch_code=$?
rct_branch_scoring=$(printf '%s' "$rct_branch_out" | jq -r \
    '.roles.scoring | "\(.engine):\(.model)|\(.source)"')
rct_worktree_out=$(rc_run_worktree --orchestrator claude-code)
rct_worktree_scoring=$(printf '%s' "$rct_worktree_out" | jq -r \
    '.roles.scoring | "\(.engine):\(.model)|\(.source)"')
rct_omit_out=$(env -u MATTHEWS_REVIEW_REVIEWS_ROOT HOME="$RC_HOME" \
    "$TOOLS/review-config.sh" --repo-root "$RC_REPO" \
    --orchestrator claude-code 2>"$WORK/rct-omit.err")
rct_omit_code=$?
rct_bad_out=$(env -u MATTHEWS_REVIEW_REVIEWS_ROOT HOME="$RC_HOME" \
    "$TOOLS/review-config.sh" --repo-root "$RC_REPO" \
    --repo-config-ref refs/heads/does-not-exist \
    --orchestrator claude-code 2>"$WORK/rct-bad.err")
rct_bad_code=$?
rct_mutex_out=$(env -u MATTHEWS_REVIEW_REVIEWS_ROOT HOME="$RC_HOME" \
    "$TOOLS/review-config.sh" --repo-root "$RC_REPO" \
    --repo-config-ref "$RC_TRUSTED_REF" --repo-config-worktree \
    --orchestrator claude-code 2>"$WORK/rct-mutex.err")
rct_mutex_code=$?
if [[ "$rct_trusted_scoring" == "claude:sonnet|repo-config" \
   && $rct_branch_code -eq 0 \
   && "$rct_branch_scoring" == "claude:opus|repo-config" \
   && "$rct_worktree_scoring" == "claude:haiku|repo-config" \
   && $rct_omit_code -eq 1 && -z "$rct_omit_out" \
   && "$(cat "$WORK/rct-omit.err")" == *"no trusted repo config source was selected"* \
   && "$(cat "$WORK/rct-omit.err")" == *"Action: pass --repo-config-ref"* \
   && $rct_bad_code -eq 1 && -z "$rct_bad_out" \
   && "$(cat "$WORK/rct-bad.err")" == *"does not resolve to a commit"* \
   && $rct_mutex_code -eq 64 && -z "$rct_mutex_out" \
   && "$(cat "$WORK/rct-mutex.err")" == *"cannot combine with --repo-config-worktree"* ]]; then
    pass "RCT-1: base ref/branch/diagnostic worktree are distinct; omission/bad ref/conflict emit no plan"
else
    fail "RCT-1: repo-config trust boundary mismatch" \
      "trusted=$rct_trusted_scoring branch=$rct_branch_code:$rct_branch_scoring worktree=$rct_worktree_scoring omit=$rct_omit_code:$rct_omit_out:$(cat "$WORK/rct-omit.err") bad=$rct_bad_code:$rct_bad_out:$(cat "$WORK/rct-bad.err") mutex=$rct_mutex_code:$rct_mutex_out:$(cat "$WORK/rct-mutex.err")"
fi

# RC-3: --models CLI beats repo config; tier override flows to inheriting roles
rc_out=$(rc_run --orchestrator claude-code --models "scoring=claude:haiku,utility=claude:opus")
rc_scoring=$(printf '%s' "$rc_out" | jq -r '.roles.scoring | "\(.engine):\(.model)|\(.source)"')
rc_util=$(printf '%s' "$rc_out" | jq -r '.roles.dedup | "\(.engine):\(.model)|\(.source)"')
if [[ "$rc_scoring" == "claude:haiku|cli" && "$rc_util" == "claude:opus|cli (tier:utility)" ]]; then
    pass "RC-3: --models CLI override wins (role + tier)"
else
    fail "RC-3: CLI override mismatch" "scoring=$rc_scoring util=$rc_util"
fi

# RC-4: a selected user profile beats the conflicting trusted-repo base tier;
# --models still beats that selected profile.
rc_out=$(rc_run --orchestrator claude-code --profile max)
rc_light=$(printf '%s' "$rc_out" | jq -r '.roles.light_lens | "\(.engine):\(.model)|\(.source)"')
rc_out2=$(rc_run --orchestrator claude-code --profile max --models "light=claude:sonnet")
rc_light2=$(printf '%s' "$rc_out2" | jq -r '.roles.light_lens | "\(.engine):\(.model)|\(.source)"')
if [[ "$rc_light" == "claude:opus|profile(max) (tier:light)" \
   && "$rc_light2" == "claude:sonnet|cli (tier:light)" ]]; then
    pass "RC-4: selected user profile beats trusted repo base; CLI beats profile"
else
    fail "RC-4: profile/CLI precedence mismatch" "light=$rc_light light2=$rc_light2"
fi

# RCT-3: pin the complete precedence ladder with distinct values/sources.
rct_default_deep=$(printf '%s' "$rct_trusted_out" | jq -r \
    '.roles.deep_validate | "\(.engine):\(.model)|\(.source)"')
rct_repo_light=$(printf '%s' "$rct_trusted_out" | jq -r \
    '.roles.light_lens | "\(.engine):\(.model)|\(.source)"')
rct_user_utility=$(printf '%s' "$rct_trusted_out" | jq -r \
    '.roles.dedup | "\(.engine):\(.model)|\(.source)"')
if [[ "$rct_default_deep" == "claude:opus|default (tier:deep)" \
   && "$rct_user_utility" == "claude:haiku|user-config (tier:utility)" \
   && "$rct_trusted_scoring" == "claude:sonnet|repo-config" \
   && "$rct_repo_light" == "claude:haiku|repo-config (tier:light)" \
   && "$rc_light" == "claude:opus|profile(max) (tier:light)" \
   && "$rc_light2" == "claude:sonnet|cli (tier:light)" ]]; then
    pass "RCT-3: precedence is CLI > selected profile > trusted repo > user base > defaults"
else
    fail "RCT-3: config precedence ladder drifted" \
      "default=$rct_default_deep user=$rct_user_utility repo-role=$rct_trusted_scoring repo-tier=$rct_repo_light profile=$rc_light cli=$rc_light2"
fi

# RC-5: unknown --models key → exit 1 with valid-key list
rc_err=$(rc_run --orchestrator claude-code --models "bogus=claude:opus" 2>&1); code=$?
if [[ $code -eq 1 && "$rc_err" == *"unknown --models key 'bogus'"* && "$rc_err" == *"Valid keys:"* ]]; then
    pass "RC-5: unknown --models key rejected with valid-key list"
else
    fail "RC-5: unknown-key rejection mismatch" "code=$code err=$rc_err"
fi

# RC-6: Claude role strings reject every non-empty third segment.
rc_err=$(rc_run --orchestrator claude-code --models "deep=claude:opus:high" 2>&1); code=$?
if [[ $code -eq 1 && "$rc_err" == *"Claude roles do not accept a third segment"* ]]; then
    pass "RC-6: third segment rejected on claude: role string"
else
    fail "RC-6: Claude third-segment rejection mismatch" "code=$code err=$rc_err"
fi

# RC-7: omp: role on claude-code orchestrator → exit 1 (matrix)
rc_err=$(rc_run --orchestrator claude-code --models "deep=omp:openai/gpt-5.3-codex" 2>&1); code=$?
if [[ $code -eq 1 && "$rc_err" == *"wants omp:... but the orchestrator is Claude Code"* ]]; then
    pass "RC-7: omp: engine rejected on claude-code orchestrator"
else
    fail "RC-7: matrix rejection mismatch" "code=$code err=$rc_err"
fi

# RC-8: omp orchestrator accepts omp: engine; codex effort validates
rc_out=$(rc_run --orchestrator omp --models "deep=omp:openai/gpt-5.3-codex,ensemble_detect=codex::ultra")
rc_deep=$(printf '%s' "$rc_out" | jq -r '.roles.deep_validate | "\(.engine):\(.model)"')
rc_ens=$(printf '%s' "$rc_out" | jq -r '.roles.ensemble_detect.effort')
if [[ "$rc_deep" == "omp:openai/gpt-5.3-codex" && "$rc_ens" == "ultra" ]]; then
    pass "RC-8: omp orchestrator accepts omp: engine; codex effort=ultra validates"
else
    fail "RC-8: omp orchestrator resolution mismatch" "deep=$rc_deep ens=$rc_ens"
fi

# RC-9: missing profile → exit 1
rc_err=$(rc_run --orchestrator claude-code --profile nope 2>&1); code=$?
if [[ $code -eq 1 && "$rc_err" == *"profile 'nope' not found"* ]]; then
    pass "RC-9: missing profile rejected with define-it action"
else
    fail "RC-9: missing-profile rejection mismatch" "code=$code err=$rc_err"
fi

# RC-10: malformed worktree config is visible only in explicit diagnostics.
echo '{broken' > "$RC_REPO/.matthewsreview.json"
rc_err=$(rc_run_worktree --orchestrator claude-code 2>&1); code=$?
if [[ $code -eq 1 && "$rc_err" == *"not valid JSON"* && "$rc_err" == *".matthewsreview.json"* ]]; then
    pass "RC-10: diagnostic worktree config rejects malformed JSON and names the file"
else
    fail "RC-10: malformed diagnostic config mismatch" "code=$code err=$rc_err"
fi
printf '%s\n' "$RC_WORKTREE_CONFIG" > "$RC_REPO/.matthewsreview.json"

# RC-11: every value-taking option rejects a dangling flag cleanly. This
# guards `shift 2` under set -u from surfacing an unstructured shell error.
rc11_problems=""
for rc11_flag in --repo-root --repo-config-ref --orchestrator --profile --models; do
    rc11_err=$(rc_run "$rc11_flag" 2>&1); rc11_code=$?
    if [[ $rc11_code -ne 64 || "$rc11_err" != *"requires a value"* ]]; then
        rc11_problems="$rc11_problems $rc11_flag=$rc11_code:$rc11_err"
    fi
done
if [[ -z "$rc11_problems" ]]; then
    pass "RC-11: dangling value-taking options exit 64 with structured usage errors"
else
    fail "RC-11: dangling option handling mismatch" "$rc11_problems"
fi

# RCT-2: argument validation precedes dependency probing, while a valid
# invocation in a jq-less environment fails with the dependency exit code and
# a structured recovery action (never an unstructured command-not-found).
RC_NOJQ_BIN="$WORK/rc-nojq-bin"
mkdir -p "$RC_NOJQ_BIN"
ln -s /bin/bash "$RC_NOJQ_BIN/bash"
ln -s /usr/bin/dirname "$RC_NOJQ_BIN/dirname"
rct_nojq_out=$(PATH="$RC_NOJQ_BIN" HOME="$RC_HOME" \
    "$TOOLS/review-config.sh" --repo-root "$RC_REPO" \
    --repo-config-ref "$RC_TRUSTED_REF" --orchestrator claude-code \
    2>"$WORK/rct-nojq.err")
rct_nojq_code=$?
rct_usage_out=$(PATH="$RC_NOJQ_BIN" HOME="$RC_HOME" \
    "$TOOLS/review-config.sh" --repo-root "$RC_REPO" \
    --repo-config-ref "$RC_TRUSTED_REF" --orchestrator \
    2>"$WORK/rct-usage.err")
rct_usage_code=$?
if [[ $rct_nojq_code -eq 5 && -z "$rct_nojq_out" \
   && "$(cat "$WORK/rct-nojq.err")" == *"ERROR: required dependency 'jq' is not available"* \
   && "$(cat "$WORK/rct-nojq.err")" == *"Action: install jq, then rerun review-config.sh"* \
   && "$(cat "$WORK/rct-nojq.err")" != *"command not found"* \
   && $rct_usage_code -eq 64 && -z "$rct_usage_out" \
   && "$(cat "$WORK/rct-usage.err")" == *"--orchestrator requires a value"* \
   && "$(cat "$WORK/rct-usage.err")" != *"required dependency 'jq'"* ]]; then
    pass "RCT-2: usage validates before jq probing; valid jq-less invocation exits 5 with ERROR/Action and no plan"
else
    fail "RCT-2: jq dependency/usage ordering mismatch" \
      "dependency=$rct_nojq_code:$rct_nojq_out:$(cat "$WORK/rct-nojq.err") usage=$rct_usage_code:$rct_usage_out:$(cat "$WORK/rct-usage.err")"
fi

# RC-12: doctor validates config semantics, not only JSON syntax.
RC_DOCTOR_HOME="$WORK/doctor-config"
mkdir -p "$RC_DOCTOR_HOME/.matthews-reviews"
cat > "$RC_DOCTOR_HOME/.matthews-reviews/config.json" <<'EOF'
{"roles":{"deep_validate":"unknown-engine:model"}}
EOF
rc12_out=$(HOME="$RC_DOCTOR_HOME" "$TOOLS/doctor.sh" --quiet 2>&1)
rc12_code=$?
if [[ $rc12_code -eq 5 && "$rc12_out" == *"semantic validation failed"* ]]; then
    pass "RC-12: doctor rejects semantically invalid model config"
else
    fail "RC-12: doctor accepted invalid role semantics" "code=$rc12_code out=$rc12_out"
fi

# RC-12b: an omp-native model string is not "available" merely because the
# config resolver accepts its syntax. Doctor must compare every resolved omp
# selector with the live `omp models --json` registry.
RC27_HOME="$WORK/doctor-omp-registry"
RC27_BIN="$RC27_HOME/bin"
mkdir -p "$RC27_HOME/.matthews-reviews" "$RC27_BIN"
cat > "$RC27_HOME/.matthews-reviews/config.json" <<'EOF'
{"roles":{"deep_validate":"omp:vendor/missing-model:max"}}
EOF
cat > "$RC27_BIN/omp" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "models" && "${2:-}" == "--json" ]]; then
    printf '%s\n' '{"models":[{"selector":"vendor/available-model"}]}'
    exit 0
fi
exit 0
EOF
chmod +x "$RC27_BIN/omp"
rc12b_out=$(HOME="$RC27_HOME" PATH="$RC27_BIN:$PATH" \
    "$TOOLS/doctor.sh" --quiet 2>&1)
rc12b_code=$?
if [[ $rc12b_code -eq 0 && "$rc12b_out" == *"vendor/missing-model"* \
      && "$rc12b_out" == *"not present in \`omp models\`"* ]]; then
    pass "RC-12b: doctor warns when a resolved omp model is absent from the live registry"
else
    fail "RC-12b: doctor treated a nonexistent omp model as available" \
      "code=$rc12b_code out=$rc12b_out"
fi

# AS-1: the optional v1.0 artifact extensions validate at their real shape.
AS_DIR="$WORK/artifact-schema"
mkdir -p "$AS_DIR"
as_plan=$(rc_run --orchestrator claude-code)
jq --argjson plan "$as_plan" \
    '.model_plan=$plan | .gates=$plan.gates
     | .degraded={"lens_dispatch_failures":2,"candidate_drop_failures":1,"finalization_failures":1}' \
    "$FIX/artifact-seed.json" > "$AS_DIR/valid.json"
if "$TOOLS/artifact-validate.sh" --path "$AS_DIR/valid.json" >/dev/null 2>&1; then
    pass "AS-1: resolved model_plan + gates + complete degraded extension shape is schema-valid"
else
    fail "AS-1: valid artifact extensions rejected"
fi

# AS-2: extension objects are closed and a degraded object must contain at
# least one positive failure count.
jq '.model_plan.roles.deep_lens.typo=true' "$AS_DIR/valid.json" > "$AS_DIR/extra.json"
jq '.degraded={"lens_dispatch_failures":0,"candidate_drop_failures":0,"finalization_failures":0}' \
    "$AS_DIR/valid.json" > "$AS_DIR/degraded-zero.json"
as_extra_code=$(rc "$TOOLS/artifact-validate.sh" --path "$AS_DIR/extra.json")
as_zero_code=$(rc "$TOOLS/artifact-validate.sh" --path "$AS_DIR/degraded-zero.json")
if [[ "$as_extra_code" == "1" && "$as_zero_code" == "1" ]]; then
    pass "AS-2: schema rejects unknown model-role fields and all-zero degraded counts"
else
    fail "AS-2: extension schema accepted malformed state" "extra=$as_extra_code degraded_zero=$as_zero_code"
fi

# AS-3: degraded coverage remains backward compatible with old lens-only
# artifacts while allowing candidate-loss and finalization-only failures.
jq '.degraded={"lens_dispatch_failures":2}' "$AS_DIR/valid.json" > "$AS_DIR/degraded-lens.json"
jq '.degraded={"candidate_drop_failures":2}' "$AS_DIR/valid.json" > "$AS_DIR/degraded-candidate.json"
jq '.degraded={"finalization_failures":2}' "$AS_DIR/valid.json" > "$AS_DIR/degraded-finalize.json"
as_lens_code=$(rc "$TOOLS/artifact-validate.sh" --path "$AS_DIR/degraded-lens.json")
as_candidate_code=$(rc "$TOOLS/artifact-validate.sh" --path "$AS_DIR/degraded-candidate.json")
as_finalize_code=$(rc "$TOOLS/artifact-validate.sh" --path "$AS_DIR/degraded-finalize.json")
if [[ "$as_lens_code" == "0" && "$as_candidate_code" == "0" && "$as_finalize_code" == "0" ]]; then
    pass "AS-3: degraded schema accepts lens, candidate-loss, and finalization failure classes independently"
else
    fail "AS-3: degraded failure classes rejected" \
      "lens=$as_lens_code candidate=$as_candidate_code finalize=$as_finalize_code"
fi

# AS-4: unknown source lines stay null rather than becoming a fabricated
# line 1 citation. The renderer must omit a range when location is unknown.
jq '(.findings[] | select(.id=="F001") | .line_range)=null' \
    "$FIX/artifact-seed.json" > "$AS_DIR/unknown-line.json"
as_unknown_code=$(rc "$TOOLS/artifact-validate.sh" --path "$AS_DIR/unknown-line.json")
"$TOOLS/artifact-render.py" --input "$AS_DIR/unknown-line.json" \
    --output "$AS_DIR/unknown-line.md" >/dev/null 2>&1
if [[ "$as_unknown_code" == "0" ]] \
   && grep -qF '`src/auth/session.ts`' "$AS_DIR/unknown-line.md" \
   && ! grep -qF '`src/auth/session.ts:1`' "$AS_DIR/unknown-line.md"; then
    pass "AS-4: unknown line range validates and renders without a fabricated :1 citation"
else
    fail "AS-4: unknown line range was rejected or rendered as line 1" \
      "code=$as_unknown_code"
fi

# AS-5: current_state is authoritative for completed work. A resolved
# finding whose historical disposition remains partial renders done and
# cannot inflate the engage queue.
jq '(.findings[] | select(.id=="F001")) |=
      (.current_state="resolved" | .disposition="partial")' \
    "$FIX/artifact-seed.json" > "$AS_DIR/resolved-partial.json"
as_resolved=$("$TOOLS/artifact-render.py" \
    --input "$AS_DIR/resolved-partial.json" --format dispositions)
as_resolved_row=$(printf '%s\n' "$as_resolved" | grep '^| F001 |')
if [[ "$as_resolved_row" == *"| resolved | done |"* ]]; then
    pass "AS-5: resolved state overrides stale partial disposition in work-queue routing"
else
    fail "AS-5: resolved finding remained actionable" "$as_resolved_row"
fi

# AS-6: provenance arrays are non-empty/unique, and an inclusive source
# range cannot run backwards.
jq '(.findings[] | select(.id=="F001") | .sources)=[]' \
    "$FIX/artifact-seed.json" > "$AS_DIR/empty-sources.json"
jq '(.findings[] | select(.id=="F001") | .source_families)=["code-review","code-review"]' \
    "$FIX/artifact-seed.json" > "$AS_DIR/duplicate-families.json"
jq '(.findings[] | select(.id=="F001") | .line_range)=[20,10]' \
    "$FIX/artifact-seed.json" > "$AS_DIR/reversed-range.json"
as_empty_code=$(rc "$TOOLS/artifact-validate.sh" --path "$AS_DIR/empty-sources.json")
as_duplicate_code=$(rc "$TOOLS/artifact-validate.sh" --path "$AS_DIR/duplicate-families.json")
as_reversed_code=$(rc "$TOOLS/artifact-validate.sh" --path "$AS_DIR/reversed-range.json")
if [[ "$as_empty_code" == "1" && "$as_duplicate_code" == "1" \
      && "$as_reversed_code" == "1" ]]; then
    pass "AS-6: schema/runtime reject empty provenance, duplicate families, and reversed ranges"
else
    fail "AS-6: malformed finding provenance/range accepted" \
      "empty=$as_empty_code duplicate=$as_duplicate_code reversed=$as_reversed_code"
fi

# GB-1: --apply-decisions honors artifact gates.phase4_bands over the
# 45/60/75 defaults. Bands [50,70,90] → score 65 lands in the uncertain
# band (default would call it confirmed_* and demand actionability).
GB_DIR="$WORK/gb"
mkdir -p "$GB_DIR"
cp "$FIX/artifact-seed.json" "$GB_DIR/art.json"
"$TOOLS/artifact-patch.py" --path "$GB_DIR/art.json" \
    --set-json 'gates={"phase3_gate":45,"phase4_bands":[50,70,90],"fix_threshold":60,"walkthrough_threshold":60}' >/dev/null
gb_err=$("$TOOLS/artifact-patch.py" --path "$GB_DIR/art.json" \
    --apply-decisions '[{"id":"F001","score_phase4":65,"validation_result":null}]' 2>&1); code=$?
gb_disp=$(jq -r '.findings[] | select(.id=="F001") | .disposition' "$GB_DIR/art.json")
if [[ $code -eq 0 && "$gb_disp" == "uncertain" ]]; then
    pass "GB-1: --apply-decisions uses artifact gates.phase4_bands (65 with bands [50,70,90] → uncertain)"
else
    fail "GB-1: gates-band override mismatch" "code=$code disp=$gb_disp err=$gb_err"
fi

# GB-1b: strength is also derived from the resolved bands. Score 75 is
# moderate under [50,70,90], even if a legacy tuple supplies "strong"
# (which would match the default [45,60,75] bands).
cp "$FIX/artifact-seed.json" "$GB_DIR/art-strength.json"
"$TOOLS/artifact-patch.py" --path "$GB_DIR/art-strength.json" \
    --set-json 'gates={"phase3_gate":45,"phase4_bands":[50,70,90],"fix_threshold":60,"walkthrough_threshold":60}' >/dev/null
gb_err=$("$TOOLS/artifact-patch.py" --path "$GB_DIR/art-strength.json" \
    --apply-decisions '[{"id":"F001","score_phase4":75,"actionability":"auto_fixable","confirmed_strength":"strong"}]' 2>&1); code=$?
gb_strength=$(jq -r '.findings[] | select(.id=="F001") | .confirmed_strength' "$GB_DIR/art-strength.json")
if [[ $code -eq 0 && "$gb_strength" == "moderate" ]]; then
    pass "GB-1b: --apply-decisions derives strength from resolved bands and ignores legacy hints"
else
    fail "GB-1b: strength used stale/default bands" "code=$code strength=$gb_strength err=$gb_err"
fi

# GB-2: malformed persisted bands are never interpreted with fallback
# thresholds. Duplicate and descending triples are rejected at both canonical
# locations by the validator and renderer.
gb_invalid_problems=""
for gb_scope in top model-plan; do
    for gb_shape in duplicate descending; do
        case "$gb_shape" in
            duplicate) gb_bands='[45,60,60]' ;;
            descending) gb_bands='[45,75,60]' ;;
        esac
        gb_bad="$GB_DIR/$gb_scope-$gb_shape.json"
        case "$gb_scope" in
            top)
                jq --argjson bands "$gb_bands" \
                    '.gates.phase4_bands=$bands' "$AS_DIR/valid.json" > "$gb_bad"
                gb_path='$gates'
                ;;
            model-plan)
                jq --argjson bands "$gb_bands" \
                    '.model_plan.gates.phase4_bands=$bands' \
                    "$AS_DIR/valid.json" > "$gb_bad"
                gb_path='$model_plan.gates'
                ;;
        esac
        "$TOOLS/artifact-validate.sh" --path "$gb_bad" \
            >/dev/null 2>"$gb_bad.validate.err"
        gb_validate_code=$?
        "$TOOLS/artifact-render.py" --input "$gb_bad" \
            >/dev/null 2>"$gb_bad.render.err"
        gb_render_code=$?
        if [[ $gb_validate_code -ne 1 || $gb_render_code -ne 1 \
           || "$(cat "$gb_bad.validate.err")" != *"$gb_path"* \
           || "$(cat "$gb_bad.validate.err")" != *"phase4_bands"* \
           || "$(cat "$gb_bad.render.err")" != *"$gb_path"* \
           || "$(cat "$gb_bad.render.err")" != *"phase4_bands"* \
           || "$(cat "$gb_bad.validate.err")$(cat "$gb_bad.render.err")" == *"Traceback"* ]]; then
            gb_invalid_problems="$gb_invalid_problems $gb_scope/$gb_shape=validate:$gb_validate_code:$(cat "$gb_bad.validate.err");render:$gb_render_code:$(cat "$gb_bad.render.err")"
        fi
    done
done
if [[ -z "$gb_invalid_problems" ]]; then
    pass "GB-2: duplicate/descending phase4_bands reject canonically at gates and model_plan.gates"
else
    fail "GB-2: malformed persisted bands escaped canonical rejection" "$gb_invalid_problems"
fi

# GB-3: compatibility controls are intentionally narrow. Fully valid gates,
# absent/null top-level gates, an absent model_plan, and model_plan.gates=null
# all remain renderable. A present gates object is not weakened by this test.
gb_control_problems=""
for gb_control in valid top-absent top-null plan-absent plan-gates-null; do
    gb_control_art="$GB_DIR/control-$gb_control.json"
    case "$gb_control" in
        valid) cp "$AS_DIR/valid.json" "$gb_control_art" ;;
        top-absent) jq 'del(.gates)' "$AS_DIR/valid.json" > "$gb_control_art" ;;
        top-null) jq '.gates=null' "$AS_DIR/valid.json" > "$gb_control_art" ;;
        plan-absent) jq 'del(.model_plan)' "$AS_DIR/valid.json" > "$gb_control_art" ;;
        plan-gates-null)
            jq '.model_plan.gates=null' "$AS_DIR/valid.json" > "$gb_control_art"
            ;;
    esac
    "$TOOLS/artifact-validate.sh" --path "$gb_control_art" \
        >/dev/null 2>"$gb_control_art.validate.err"
    gb_control_validate=$?
    "$TOOLS/artifact-render.py" --input "$gb_control_art" \
        >/dev/null 2>"$gb_control_art.render.err"
    gb_control_render=$?
    if [[ $gb_control_validate -ne 0 || $gb_control_render -ne 0 ]]; then
        gb_control_problems="$gb_control_problems $gb_control=validate:$gb_control_validate:$(cat "$gb_control_art.validate.err");render:$gb_control_render:$(cat "$gb_control_art.render.err")"
    fi
done
if [[ -z "$gb_control_problems" ]]; then
    pass "GB-3: valid/absent/null canonical gate controls remain renderable"
else
    fail "GB-3: canonical gate compatibility control regressed" "$gb_control_problems"
fi

# GB-4: mutation is atomic too: proposing a descending top-level band object
# fails validation without changing a byte on disk.
cp "$AS_DIR/valid.json" "$GB_DIR/atomic-invalid.json"
gb_atomic_before=$(sha_of "$GB_DIR/atomic-invalid.json")
gb_atomic_err=$("$TOOLS/artifact-patch.py" \
    --path "$GB_DIR/atomic-invalid.json" \
    --set-json 'gates={"phase3_gate":45,"phase4_bands":[45,75,60],"fix_threshold":60,"walkthrough_threshold":60}' \
    2>&1 >/dev/null)
gb_atomic_code=$?
gb_atomic_after=$(sha_of "$GB_DIR/atomic-invalid.json")
if [[ $gb_atomic_code -eq 1 && "$gb_atomic_before" == "$gb_atomic_after" \
   && "$gb_atomic_err" == *"phase4_bands"* ]]; then
    pass "GB-4: artifact-patch rejects descending bands atomically"
else
    fail "GB-4: invalid gate mutation changed bytes or escaped validation" \
      "code=$gb_atomic_code unchanged=$([[ "$gb_atomic_before" == "$gb_atomic_after" ]] && echo yes || echo no) err=$gb_atomic_err"
fi

# CLI-1: every malformed artifact-patch / renderer invocation uses the shared
# usage boundary: rc64, no stdout payload, and anchored ERROR/Action guidance.
CLI_DIR="$WORK/cli-contract"
mkdir -p "$CLI_DIR"
cli_usage_problems=""
cli_usage_probe() {
    local cli_label="$1"
    shift
    "$@" >"$CLI_DIR/$cli_label.out" 2>"$CLI_DIR/$cli_label.err"
    local cli_code=$?
    local cli_errors cli_actions
    cli_errors=$(grep -c '^ERROR:' "$CLI_DIR/$cli_label.err")
    cli_actions=$(grep -c '^Action:' "$CLI_DIR/$cli_label.err")
    if [[ $cli_code -ne 64 || -s "$CLI_DIR/$cli_label.out" \
       || $cli_errors -ne 1 || $cli_actions -ne 1 ]]; then
        cli_usage_problems="$cli_usage_problems $cli_label=$cli_code:out=$(cat "$CLI_DIR/$cli_label.out"):err=$(cat "$CLI_DIR/$cli_label.err")"
    fi
}
cli_usage_probe patch-missing "$TOOLS/artifact-patch.py"
cli_usage_probe patch-unknown "$TOOLS/artifact-patch.py" \
    --path "$FIX/artifact-seed.json" --unknown-option
cli_usage_probe patch-expected-missing "$TOOLS/artifact-patch.py" \
    --path "$FIX/artifact-seed.json" --set-scores '[]'
cli_usage_probe patch-expected-zero "$TOOLS/artifact-patch.py" \
    --path "$FIX/artifact-seed.json" --set-scores '[]' --expected 0
cli_usage_probe patch-expected-negative "$TOOLS/artifact-patch.py" \
    --path "$FIX/artifact-seed.json" --set-scores '[]' --expected -1
cli_usage_probe patch-expected-nonint "$TOOLS/artifact-patch.py" \
    --path "$FIX/artifact-seed.json" --set-scores '[]' --expected nope
cli_usage_probe patch-conflict "$TOOLS/artifact-patch.py" \
    --path "$FIX/artifact-seed.json" --set-scores '[]' --expected 1 \
    --finding-id F001
cli_usage_probe patch-dry-run "$TOOLS/artifact-patch.py" \
    --path "$FIX/artifact-seed.json" --set-scores '[]' --expected 1 --dry-run
cli_usage_probe render-missing "$TOOLS/artifact-render.py"
cli_usage_probe render-unknown "$TOOLS/artifact-render.py" \
    --input "$FIX/artifact-seed.json" --unknown-option
cli_usage_probe render-dangling "$TOOLS/artifact-render.py" \
    --input "$FIX/artifact-seed.json" --format
cli_usage_probe render-typo "$TOOLS/artifact-render.py" \
    --input "$FIX/artifact-seed.json" --format markdwon
if [[ -z "$cli_usage_problems" ]]; then
    pass "CLI-1: artifact-patch and renderer usage failures are rc64 + one ERROR/Action block"
else
    fail "CLI-1: usage exit/stream contract mismatch" "$cli_usage_problems"
fi

# CLI-2: format typos carry an exact enum and nearest correction.
if grep -qF 'Valid values: markdown, dispositions, pr-comment' \
      "$CLI_DIR/render-typo.err" \
   && grep -qF "Did you mean 'markdown'?" "$CLI_DIR/render-typo.err"; then
    pass "CLI-2: renderer format typo lists exact values and suggests markdown"
else
    fail "CLI-2: renderer typo guidance drifted" "$(cat "$CLI_DIR/render-typo.err")"
fi

# CLI-3: help is informational rather than a usage failure.
"$TOOLS/artifact-patch.py" --help \
    >"$CLI_DIR/patch-help.out" 2>"$CLI_DIR/patch-help.err"
cli_patch_help_code=$?
"$TOOLS/artifact-render.py" --help \
    >"$CLI_DIR/render-help.out" 2>"$CLI_DIR/render-help.err"
cli_render_help_code=$?
if [[ $cli_patch_help_code -eq 0 && $cli_render_help_code -eq 0 \
   && -s "$CLI_DIR/patch-help.out" && -s "$CLI_DIR/render-help.out" \
   && ! -s "$CLI_DIR/patch-help.err" && ! -s "$CLI_DIR/render-help.err" ]]; then
    pass "CLI-3: artifact-patch and renderer --help exit 0 on stdout"
else
    fail "CLI-3: help treated as failure" \
      "patch=$cli_patch_help_code:$(cat "$CLI_DIR/patch-help.err") render=$cli_render_help_code:$(cat "$CLI_DIR/render-help.err")"
fi

# CLI-4: usage normalization must not collapse operational statuses.
cp "$FIX/artifact-seed.json" "$CLI_DIR/status.json"
cli_status_before=$(sha_of "$CLI_DIR/status.json")
"$TOOLS/artifact-patch.py" --path "$CLI_DIR/status.json" \
    --finding-id F001 --set current_state=resolved \
    >/dev/null 2>"$CLI_DIR/transition.err"
cli_transition_code=$?
"$TOOLS/artifact-patch.py" --path "$CLI_DIR/status.json" \
    --set-scores '[{"id":"F001","score_phase3":1}]' --expected 2 \
    >/dev/null 2>"$CLI_DIR/mismatch.err"
cli_mismatch_code=$?
cli_status_after=$(sha_of "$CLI_DIR/status.json")
if [[ $cli_transition_code -eq 2 && $cli_mismatch_code -eq 6 \
   && "$cli_status_before" == "$cli_status_after" ]]; then
    pass "CLI-4: invalid transition remains rc2; expected-count mismatch remains rc6"
else
    fail "CLI-4: operational statuses collapsed into usage/validation" \
      "transition=$cli_transition_code mismatch=$cli_mismatch_code unchanged=$([[ "$cli_status_before" == "$cli_status_after" ]] && echo yes || echo no)"
fi

# ------------------------------------------------------------------
# AD: agent-dispatch.sh — harness-neutral engine dispatch (stubbed engines)
AD_HOME="$WORK/ad"
mkdir -p "$AD_HOME/bin" "$AD_HOME/scratch"
cat > "$AD_HOME/bin/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$(dirname "$0")/claude.args"
cat >/dev/null
echo '{"type":"result","result":"claude done","usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":25,"cache_creation_input_tokens":10}}'
EOF
cat > "$AD_HOME/bin/codex" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "login" && "${2:-}" == "status" ]]; then
    exit 0
fi
printf '%s\n' "$@" > "$(dirname "$0")/codex.args"
cat >/dev/null
out=""
while [[ $# -gt 0 ]]; do case "$1" in -o) out="$2"; shift 2;; *) shift;; esac; done
# real codex exec JSONL terminal event shape (CLI 0.145.x)
echo '{"type":"turn.completed","usage":{"input_tokens":700,"cached_input_tokens":300,"output_tokens":77}}'
[[ -n "$out" ]] && echo "codex done" > "$out"
EOF
cat > "$AD_HOME/bin/omp" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$(dirname "$0")/omp.args"
printf 'omp done args=%s\n' "$*"
EOF
cat > "$AD_HOME/bin/claude-fail" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null; echo "boom: overloaded" >&2; exit 2
EOF
chmod +x "$AD_HOME/bin/"*
echo "test prompt" > "$AD_HOME/prompt.md"
AD="$TOOLS/agent-dispatch.sh"
ad_path() { PATH="$AD_HOME/bin:/usr/bin:/bin" "$@"; }
ad_arg_pair() {
    awk -v first="$2" -v second="$3" '
      previous == first && $0 == second { found=1 }
      { previous=$0 }
      END { exit(found ? 0 : 1) }
    ' "$1"
}
# Bounded verdict wait shared by the single-poll AD sites and AD-11/12/15
# — poll until the wanted verdict lands (≤5s), dcbd4de condition-loop
# style. A fixed `sleep 1` + single poll flakes under load: an instant
# stub can legitimately still be `alive` at the 1s mark (witnessed as an
# AD-1 abort). Sets AD_POLL_OUT (on timeout: the last poll, so a fail()
# shows what the poller actually said).
ad_poll_until() { # job scratch wanted-verdict
    local ad_pu_job="$1" ad_pu_scratch="$2" ad_pu_want="$3" ad_pu_i=0 ad_pu_v=""
    AD_POLL_OUT=""
    while [[ $ad_pu_i -lt 100 ]]; do
        AD_POLL_OUT=$(ad_path "$AD" poll --job "$ad_pu_job" --scratch-dir "$ad_pu_scratch")
        ad_pu_v=$(printf '%s' "$AD_POLL_OUT" | jq -r '.verdict' 2>/dev/null || echo "")
        [[ "$ad_pu_v" == "$ad_pu_want" ]] && return 0
        sleep 0.05
        ad_pu_i=$((ad_pu_i + 1))
    done
    return 1
}

# AD-1: claude engine completes with tokens summed across all usage buckets
ad_j=$(ad_path "$AD" start --engine claude --model opus --prompt-file "$AD_HOME/prompt.md" --scratch-dir "$AD_HOME/scratch" | jq -r .job_id)
ad_poll_until "$ad_j" "$AD_HOME/scratch" completed || true
ad_out="$AD_POLL_OUT"
if [[ $(printf '%s' "$ad_out" | jq -r '.verdict') == "completed" ]] \
   && [[ $(printf '%s' "$ad_out" | jq -r '.tokens') == "185" ]] \
   && [[ $(printf '%s' "$ad_out" | jq -r '.raw_output') == "claude done" ]]; then
    pass "AD-1: claude engine start/poll → completed, tokens=185 (all usage buckets), raw_output from .result"
else
    fail "AD-1: claude dispatch mismatch" "$ad_out"
fi

# AD-2: codex engine extracts last-message file + token_count JSONL
ad_j=$(ad_path "$AD" start --engine codex --effort high --prompt-file "$AD_HOME/prompt.md" --scratch-dir "$AD_HOME/scratch" | jq -r .job_id)
ad_poll_until "$ad_j" "$AD_HOME/scratch" completed || true
ad_out="$AD_POLL_OUT"
if [[ $(printf '%s' "$ad_out" | jq -r '.verdict') == "completed" ]] \
   && [[ $(printf '%s' "$ad_out" | jq -r '.tokens') == "777" ]] \
   && [[ $(printf '%s' "$ad_out" | jq -r '.raw_output') == "codex done" ]]; then
    pass "AD-2: codex engine start/poll → completed, tokens=777 (token_count event), raw_output from -o file"
else
    fail "AD-2: codex dispatch mismatch" "$ad_out"
fi

# AD-3: omp engine passes model and thinking as separate CLI options and
# completes with tokens null (no usage surface).
ad_j=$(ad_path "$AD" start --engine omp --model "openai-codex/gpt-5.6-sol" --effort max --prompt-file "$AD_HOME/prompt.md" --scratch-dir "$AD_HOME/scratch" | jq -r .job_id)
ad_poll_until "$ad_j" "$AD_HOME/scratch" completed || true
ad_out="$AD_POLL_OUT"
if [[ $(printf '%s' "$ad_out" | jq -r '.verdict') == "completed" ]] \
   && [[ $(printf '%s' "$ad_out" | jq -r '.tokens') == "null" ]] \
   && [[ $(printf '%s' "$ad_out" | jq -r '.raw_output') == *"--model openai-codex/gpt-5.6-sol --thinking max @"* ]]; then
    pass "AD-3: omp engine passes explicit --model + --thinking options, tokens=null"
else
    fail "AD-3: omp dispatch/thinking mismatch" "$ad_out"
fi

# AD-3b: read roles preserve exact argv boundaries and never inherit a write
# capability: Claude plan mode without Bash, Codex read-only, omp always-ask.
ad3b_claude_args=$(cat "$AD_HOME/bin/claude.args")
ad3b_codex_args=$(cat "$AD_HOME/bin/codex.args")
ad3b_omp_args=$(cat "$AD_HOME/bin/omp.args")
if ad_arg_pair "$AD_HOME/bin/claude.args" --permission-mode plan \
   && ! grep -qxF -- Bash "$AD_HOME/bin/claude.args" \
   && ad_arg_pair "$AD_HOME/bin/codex.args" --sandbox read-only \
   && ad_arg_pair "$AD_HOME/bin/omp.args" --approval-mode always-ask; then
    pass "AD-3b: Claude, Codex, and omp read argv boundaries stay constrained"
else
    fail "AD-3b: read-role permission/argv contract drifted" \
      "claude=$ad3b_claude_args codex=$ad3b_codex_args omp=$ad3b_omp_args"
fi

# AD-3c: --write opens each engine's documented write lane.
ad3c_c=$(ad_path "$AD" start --engine claude --write \
    --prompt-file "$AD_HOME/prompt.md" --scratch-dir "$AD_HOME/scratch" | jq -r .job_id)
ad3c_x=$(ad_path "$AD" start --engine codex --write \
    --prompt-file "$AD_HOME/prompt.md" --scratch-dir "$AD_HOME/scratch" | jq -r .job_id)
ad3c_o=$(ad_path "$AD" start --engine omp --write \
    --prompt-file "$AD_HOME/prompt.md" --scratch-dir "$AD_HOME/scratch" | jq -r .job_id)
ad_poll_until "$ad3c_c" "$AD_HOME/scratch" completed || true
ad_poll_until "$ad3c_x" "$AD_HOME/scratch" completed || true
ad_poll_until "$ad3c_o" "$AD_HOME/scratch" completed || true
ad3c_claude_args=$(cat "$AD_HOME/bin/claude.args")
ad3c_codex_args=$(cat "$AD_HOME/bin/codex.args")
ad3c_omp_args=$(cat "$AD_HOME/bin/omp.args")
if ad_arg_pair "$AD_HOME/bin/claude.args" --permission-mode acceptEdits \
   && ad_arg_pair "$AD_HOME/bin/claude.args" --allowedTools Bash \
   && ad_arg_pair "$AD_HOME/bin/codex.args" --sandbox workspace-write \
   && ad_arg_pair "$AD_HOME/bin/omp.args" --approval-mode yolo; then
    pass "AD-3c: write argv opens Claude Bash, Codex workspace, and omp yolo as separate arguments"
else
    fail "AD-3c: write-role permission/argv contract drifted" \
      "claude=$ad3c_claude_args codex=$ad3c_codex_args omp=$ad3c_omp_args"
fi

# AD-4: failed engine → failed_terminal with exit code + error tail
PATH="$AD_HOME/bin:/usr/bin:/bin" "$AD" start --engine claude-fail --model x --prompt-file "$AD_HOME/prompt.md" --scratch-dir "$AD_HOME/scratch" >/dev/null 2>&1
# start requires a KNOWN engine; claude-fail is not one — use claude with a failing stub instead
mv "$AD_HOME/bin/claude" "$AD_HOME/bin/claude-ok"
cp "$AD_HOME/bin/claude-fail" "$AD_HOME/bin/claude"
ad_j=$(ad_path "$AD" start --engine claude --model opus --prompt-file "$AD_HOME/prompt.md" --scratch-dir "$AD_HOME/scratch" | jq -r .job_id)
ad_poll_until "$ad_j" "$AD_HOME/scratch" failed_terminal || true
ad_out="$AD_POLL_OUT"
mv "$AD_HOME/bin/claude-ok" "$AD_HOME/bin/claude"
if [[ $(printf '%s' "$ad_out" | jq -r '.verdict') == "failed_terminal" ]] \
   && [[ $(printf '%s' "$ad_out" | jq -r '.exit_code') == "2" ]] \
   && [[ $(printf '%s' "$ad_out" | jq -r '.error_tail') == *"overloaded"* ]]; then
    pass "AD-4: failing engine → failed_terminal with exit_code + error_tail"
else
    fail "AD-4: failed-terminal path mismatch" "$ad_out"
fi

# AD-5: start returns immediately (background child must not hold the
# caller's stdout pipe), stop terminates the actual engine process, and
# poll reports an explicit cancelled terminal state.
cat > "$AD_HOME/bin/sleeper-engine.sh" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "login" && "${2:-}" == "status" ]]; then
    exit 0
fi
cat >/dev/null
exec /bin/sleep 30
EOF
chmod +x "$AD_HOME/bin/sleeper-engine.sh"
cp "$AD_HOME/bin/sleeper-engine.sh" "$AD_HOME/bin/codex.sav"
mv "$AD_HOME/bin/codex" "$AD_HOME/bin/codex.fast"
cp "$AD_HOME/bin/sleeper-engine.sh" "$AD_HOME/bin/codex"
ad_t0=$(date +%s)
ad_j=$(ad_path "$AD" start --engine codex --prompt-file "$AD_HOME/prompt.md" --scratch-dir "$AD_HOME/scratch" | jq -r .job_id)
ad_engine_pid=""
ad_wait=0
while [[ -z "$ad_engine_pid" && $ad_wait -lt 50 ]]; do
    [[ -s "$AD_HOME/scratch/$ad_j/child_pid" ]] \
        && ad_engine_pid=$(cat "$AD_HOME/scratch/$ad_j/child_pid")
    [[ -n "$ad_engine_pid" ]] || sleep 0.1
    ad_wait=$((ad_wait + 1))
done
ad_elapsed=$(( $(date +%s) - ad_t0 ))
ad_v1=$(ad_path "$AD" poll --job "$ad_j" --scratch-dir "$AD_HOME/scratch" | jq -r .verdict)
ad_path "$AD" stop --job "$ad_j" --scratch-dir "$AD_HOME/scratch" >/dev/null
ad_v2=$(ad_path "$AD" poll --job "$ad_j" --scratch-dir "$AD_HOME/scratch" | jq -r '.verdict + ":" + .status')
mv "$AD_HOME/bin/codex.fast" "$AD_HOME/bin/codex"
if [[ $ad_elapsed -lt 5 && "$ad_v1" == "alive" && "$ad_v2" == "cancelled:cancelled" ]] \
   && [[ -n "$ad_engine_pid" ]] && ! kill -0 "$ad_engine_pid" 2>/dev/null; then
    pass "AD-5: non-blocking start; alive → stop → cancelled; engine process terminated"
else
    fail "AD-5: lifecycle/process cleanup mismatch" "elapsed=${ad_elapsed}s v1=$ad_v1 v2=$ad_v2 child=$ad_engine_pid"
fi

# AD-5b: start is not observable until the engine PID + identity are durable.
# Delay only the child identity probe so the old parent/child race is
# deterministic: without the ready handshake, start returns before these
# files exist and an immediate stop can orphan the engine.
ad_real_ps=$(PATH="/usr/bin:/bin" command -v ps)
cat > "$AD_HOME/bin/identity-engine.sh" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "login" && "\${2:-}" == "status" ]]; then
    exit 0
fi
printf '%s\n' "\$\$" > "$AD_HOME/engine.pid"
cat >/dev/null
exec /bin/sleep 30
EOF
cat > "$AD_HOME/bin/ps" <<EOF
#!/usr/bin/env bash
target=""
previous=""
for arg in "\$@"; do
    if [[ "\$previous" == "-p" ]]; then target="\$arg"; fi
    previous="\$arg"
done
if [[ "\$*" == *"lstart="* && -s "$AD_HOME/engine.pid" ]] \
   && [[ "\$target" == "\$(cat "$AD_HOME/engine.pid")" ]]; then
    /bin/sleep 2
fi
exec "$ad_real_ps" "\$@"
EOF
chmod +x "$AD_HOME/bin/identity-engine.sh" "$AD_HOME/bin/ps"
mv "$AD_HOME/bin/codex" "$AD_HOME/bin/codex.fast"
cp "$AD_HOME/bin/identity-engine.sh" "$AD_HOME/bin/codex"
ad5b_out=$(ad_path "$AD" start --engine codex \
    --prompt-file "$AD_HOME/prompt.md" --scratch-dir "$AD_HOME/scratch")
ad5b_job=$(printf '%s' "$ad5b_out" | jq -r '.job_id // empty')
ad5b_ready=false
if [[ -n "$ad5b_job" && -s "$AD_HOME/scratch/$ad5b_job/child_identity" \
      && -f "$AD_HOME/scratch/$ad5b_job/ready" ]]; then
    ad5b_ready=true
fi
# Wait by condition before cleanup even on the intentionally failing old path,
# so this regression test never leaves its sleeper behind.
ad5b_wait=0
while [[ -n "$ad5b_job" && ! -f "$AD_HOME/scratch/$ad5b_job/ready" \
         && $ad5b_wait -lt 40 ]]; do
    sleep 0.1
    ad5b_wait=$((ad5b_wait + 1))
done
[[ -z "$ad5b_job" ]] || \
    ad_path "$AD" stop --job "$ad5b_job" --scratch-dir "$AD_HOME/scratch" >/dev/null
mv "$AD_HOME/bin/codex.fast" "$AD_HOME/bin/codex"
rm -f "$AD_HOME/bin/ps"
if [[ "$ad5b_ready" == "true" ]]; then
    pass "AD-5b: start waits for durable child PID/identity readiness"
else
    fail "AD-5b: start exposed a job before child identity was durable" \
      "job=$ad5b_job out=$ad5b_out"
fi

# AD-5c: setup failures are terminal. A scratch path that is a regular file
# must not produce a plausible job id or launch an untracked child.
printf 'not a directory\n' > "$AD_HOME/not-a-directory"
ad5c_out=$(ad_path "$AD" start --engine claude \
    --prompt-file "$AD_HOME/prompt.md" \
    --scratch-dir "$AD_HOME/not-a-directory" 2>&1)
ad5c_code=$?
if [[ $ad5c_code -ne 0 && "$ad5c_out" == *"Action:"* \
      && "$ad5c_out" != *'"job_id"'* ]]; then
    pass "AD-5c: setup write failure aborts before dispatch and names recovery"
else
    fail "AD-5c: setup failure emitted a plausible dispatch" \
      "code=$ad5c_code out=$ad5c_out"
fi

# AD-6: missing engine CLI → exit 5 with install action
ad_err=$(PATH="/usr/bin:/bin" "$AD" start --engine omp --prompt-file "$AD_HOME/prompt.md" --scratch-dir "$AD_HOME/scratch" 2>&1); code=$?
if [[ $code -eq 5 && "$ad_err" == *"not on PATH"* && "$ad_err" == *"Action:"* ]]; then
    pass "AD-6: missing engine CLI → exit 5 with install action"
else
    fail "AD-6: missing-CLI path mismatch" "code=$code err=$ad_err"
fi

# AD-7: malformed prompt/job paths keep the shared error-as-prompt recovery
# contract instead of emitting a bare terminal error.
ad_prompt_err=$(ad_path "$AD" start --engine claude --model opus --prompt-file "$AD_HOME/missing.md" --scratch-dir "$AD_HOME/scratch" 2>&1); ad_prompt_code=$?
ad_poll_err=$(ad_path "$AD" poll --job ad_20260720T000000Z_123 --scratch-dir "$AD_HOME/scratch" 2>&1); ad_poll_code=$?
ad_stop_err=$(ad_path "$AD" stop --job ad_20260720T000000Z_123 --scratch-dir "$AD_HOME/scratch" 2>&1); ad_stop_code=$?
if [[ $ad_prompt_code -eq 1 && "$ad_prompt_err" == *"Action:"* \
   && $ad_poll_code -eq 1 && "$ad_poll_err" == *"Action:"* \
   && $ad_stop_code -eq 1 && "$ad_stop_err" == *"Action:"* ]]; then
    pass "AD-7: missing prompt/job paths include recovery actions"
else
    fail "AD-7: structured path errors missing" "prompt=$ad_prompt_err poll=$ad_poll_err stop=$ad_stop_err"
fi

# AD-7b: job IDs are path components; traversal or arbitrary names are
# rejected before any scratch path is constructed.
ad7b_poll=$(ad_path "$AD" poll --job ../../tmp --scratch-dir "$AD_HOME/scratch" 2>&1)
ad7b_poll_code=$?
ad7b_stop=$(ad_path "$AD" stop --job not-a-dispatch-id --scratch-dir "$AD_HOME/scratch" 2>&1)
ad7b_stop_code=$?
if [[ $ad7b_poll_code -eq 64 && "$ad7b_poll" == *"invalid job id"* \
   && $ad7b_stop_code -eq 64 && "$ad7b_stop" == *"invalid job id"* ]]; then
    pass "AD-7b: poll/stop reject untrusted job path components"
else
    fail "AD-7b: malformed job id escaped validation" \
      "poll=$ad7b_poll_code:$ad7b_poll stop=$ad7b_stop_code:$ad7b_stop"
fi

# AD-7c: a missing/corrupt identity is unverifiable, not evidence that the
# PID is safe to signal or gone. Stop fails closed without a terminal marker.
/bin/sleep 30 &
ad7c_pid=$!
ad7c_job=ad_20260720T000001Z_456
ad7c_dir="$AD_HOME/scratch/$ad7c_job"
mkdir -p "$ad7c_dir"
printf '%s' "$ad7c_pid" > "$ad7c_dir/pid"
printf '%s' "definitely-not-a-v1-identity" > "$ad7c_dir/pid_identity"
ad7c_out=$(ad_path "$AD" stop --job "$ad7c_job" \
    --scratch-dir "$AD_HOME/scratch" 2>/dev/null)
ad7c_code=$?
if [[ $ad7c_code -ne 0 ]] && kill -0 "$ad7c_pid" 2>/dev/null \
   && printf '%s' "$ad7c_out" | jq -e --arg job "$ad7c_job" '
        keys == [
          "engine_alive", "engine_state", "job_id", "reason", "status",
          "verdict", "wrapper_alive", "wrapper_state"
        ]
        and .verdict == "stop_failed" and .status == "stop_failed"
        and .job_id == $job
        and (.reason | type == "string" and length > 0)
        and (.wrapper_alive | type == "boolean")
        and (.engine_alive | type == "boolean")
        and .wrapper_state == "unverifiable"
      ' >/dev/null \
   && [[ ! -e "$ad7c_dir/terminal/ready" ]]; then
    pass "AD-7c: unverifiable identity yields full stop_failed schema and no cancellation record"
else
    fail "AD-7c: stop trusted or sealed an unverifiable PID" \
      "code=$ad7c_code out=$ad7c_out terminal=$([[ -e "$ad7c_dir/terminal/ready" ]] && echo yes || echo no)"
fi
kill "$ad7c_pid" 2>/dev/null || true
wait "$ad7c_pid" 2>/dev/null || true

# AD-8: every value-taking option rejects a dangling flag with usage exit 64.
ad8_problems=""
for ad8_flag in --engine --model --effort --prompt-file --scratch-dir --job \
        --stall-threshold-sec --wall-clock-ceiling-sec; do
    ad8_err=$(ad_path "$AD" start "$ad8_flag" 2>&1); ad8_code=$?
    if [[ $ad8_code -ne 64 || "$ad8_err" != *"requires a value"* ]]; then
        ad8_problems="$ad8_problems $ad8_flag=$ad8_code:$ad8_err"
    fi
done
if [[ -z "$ad8_problems" ]]; then
    pass "AD-8: dangling value-taking options exit 64 with structured usage errors"
else
    fail "AD-8: dangling option handling mismatch" "$ad8_problems"
fi

# AD-9: jq is an explicit dependency, not a late command-not-found failure.
ad9_err=$(PATH="$AD_HOME/bin" /bin/bash "$AD" start --engine claude \
    --prompt-file "$AD_HOME/prompt.md" --scratch-dir "$AD_HOME/scratch" 2>&1)
ad9_code=$?
if [[ $ad9_code -eq 5 && "$ad9_err" == *"requires jq"* && "$ad9_err" == *"Action:"* ]]; then
    pass "AD-9: missing jq exits 5 with an install action before dispatch"
else
    fail "AD-9: missing-jq contract mismatch" "code=$ad9_code err=$ad9_err"
fi

# AD-10: large omp prompts are passed by @file reference, not copied into
# argv (which exceeds Darwin/Linux argument limits on realistic reviews).
AD_LARGE="$AD_HOME/large-prompt.md"
awk 'BEGIN { s="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"; for (i=0; i<16384; i++) printf "%s", s }' > "$AD_LARGE"
ad_j=$(ad_path "$AD" start --engine omp --model "openai-codex/gpt-5.6-sol" \
    --effort high --prompt-file "$AD_LARGE" --scratch-dir "$AD_HOME/scratch" | jq -r .job_id)
ad_poll_until "$ad_j" "$AD_HOME/scratch" completed || true
ad_out="$AD_POLL_OUT"
ad_large_raw=$(printf '%s' "$ad_out" | jq -r '.raw_output')
if [[ $(printf '%s' "$ad_out" | jq -r '.verdict') == "completed" ]] \
   && [[ "$ad_large_raw" == *"@$AD_HOME/scratch/$ad_j/prompt.md"* ]] \
   && [[ ${#ad_large_raw} -lt 500 ]]; then
    pass "AD-10: 1 MiB omp prompt dispatches via compact @file argument"
else
    fail "AD-10: large omp prompt was not file-backed" "$ad_out"
fi

# AD-11: rapid-completion acceptance — the wrapper of an instantly
# completing engine can die before ps ever yields its lstart identity.
# start must accept the job via the ready + terminal/ready sentinels
# instead of failing (no live process remains for stop to authenticate);
# pid_identity is legitimately absent. The ps interposition blanks
# lstart probes for exactly this job's wrapper pid (read from the pid
# file the parent persists before its first probe), so the parent never
# observes an identity even if it races ahead of the wrapper's death.
AD11_SCRATCH="$AD_HOME/scratch-ad11"
mkdir -p "$AD11_SCRATCH"
cat > "$AD_HOME/bin/ps" <<EOF
#!/usr/bin/env bash
target=""
previous=""
for arg in "\$@"; do
    if [[ "\$previous" == "-p" ]]; then target="\$arg"; fi
    previous="\$arg"
done
if [[ "\$*" == *"lstart="* ]]; then
    for ad11_pid_file in "$AD11_SCRATCH"/ad_*/pid; do
        [[ -f "\$ad11_pid_file" ]] || continue
        if [[ "\$target" == "\$(cat "\$ad11_pid_file")" ]]; then
            exit 0
        fi
    done
fi
exec "$ad_real_ps" "\$@"
EOF
chmod +x "$AD_HOME/bin/ps"
ad11_rc=0
ad11_start=$(ad_path "$AD" start --engine omp --model m1 \
    --prompt-file "$AD_HOME/prompt.md" --scratch-dir "$AD11_SCRATCH" 2>&1) || ad11_rc=$?
rm -f "$AD_HOME/bin/ps"
ad11_job=$(printf '%s' "$ad11_start" | jq -r '.job_id // empty' 2>/dev/null || echo "")
ad11_no_identity=false
[[ -n "$ad11_job" && ! -f "$AD11_SCRATCH/$ad11_job/pid_identity" ]] && ad11_no_identity=true
ad11_out=""
if [[ -n "$ad11_job" ]] && ad_poll_until "$ad11_job" "$AD11_SCRATCH" completed; then
    ad11_out="$AD_POLL_OUT"
fi
if [[ "$ad11_rc" == "0" && "$ad11_no_identity" == "true" ]] \
   && [[ $(printf '%s' "$ad11_out" | jq -r '.raw_output' 2>/dev/null) == *"omp done"* ]]; then
    pass "AD-11: rapid completion without observable wrapper identity — sentinel branch accepts the job"
else
    fail "AD-11: rapid-completion race regressed" \
      "rc=$ad11_rc start=$ad11_start no_identity=$ad11_no_identity poll=$ad11_out"
fi

# AD-12: malformed engine output degrades to the raw-copy fallback with
# tokens=null instead of failing the poll — claude emitting non-JSON and
# codex emitting non-JSONL with no -o file both still complete.
mv "$AD_HOME/bin/claude" "$AD_HOME/bin/claude.sav12"
cat > "$AD_HOME/bin/claude" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
echo 'plain-text-not-json'
EOF
chmod +x "$AD_HOME/bin/claude"
ad12_j1=$(ad_path "$AD" start --engine claude --model opus \
    --prompt-file "$AD_HOME/prompt.md" --scratch-dir "$AD_HOME/scratch" | jq -r .job_id)
ad12_out1=""
ad_poll_until "$ad12_j1" "$AD_HOME/scratch" completed && ad12_out1="$AD_POLL_OUT"
mv "$AD_HOME/bin/claude.sav12" "$AD_HOME/bin/claude"
mv "$AD_HOME/bin/codex" "$AD_HOME/bin/codex.sav12"
cat > "$AD_HOME/bin/codex" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "login" && "${2:-}" == "status" ]]; then
    exit 0
fi
cat >/dev/null
echo 'not jsonl {{{'
EOF
chmod +x "$AD_HOME/bin/codex"
ad12_j2=$(ad_path "$AD" start --engine codex \
    --prompt-file "$AD_HOME/prompt.md" --scratch-dir "$AD_HOME/scratch" | jq -r .job_id)
ad12_out2=""
ad_poll_until "$ad12_j2" "$AD_HOME/scratch" completed && ad12_out2="$AD_POLL_OUT"
mv "$AD_HOME/bin/codex.sav12" "$AD_HOME/bin/codex"
if [[ $(printf '%s' "$ad12_out1" | jq -r '.raw_output') == "plain-text-not-json" ]] \
   && [[ $(printf '%s' "$ad12_out1" | jq -r '.tokens') == "null" ]] \
   && [[ $(printf '%s' "$ad12_out2" | jq -r '.raw_output') == "not jsonl {{{" ]] \
   && [[ $(printf '%s' "$ad12_out2" | jq -r '.tokens') == "null" ]]; then
    pass "AD-12: malformed claude/codex output falls back to raw copy with tokens=null"
else
    fail "AD-12: malformed-output fallback mismatch" "claude=$ad12_out1 codex=$ad12_out2"
fi

# AD-13: malformed terminal records fail closed — poll and stop exit 1
# with error-as-prompt and never rewrite the record. Covers a garbage
# state token and an incoherent completed/exit_code pair.
ad13_a="$AD_HOME/scratch/ad_20260722T000010Z_131"
ad13_b="$AD_HOME/scratch/ad_20260722T000011Z_132"
mkdir -p "$ad13_a/terminal" "$ad13_b/terminal"
printf 'exploded\n' > "$ad13_a/terminal/state"
printf '1\n' > "$ad13_a/terminal/ready"
printf 'completed\n' > "$ad13_b/terminal/state"
printf '3\n' > "$ad13_b/terminal/exit_code"
printf '1\n' > "$ad13_b/terminal/ready"
ad13_sum_before=$(cat "$ad13_a/terminal/state" "$ad13_b/terminal/state" "$ad13_b/terminal/exit_code" | shasum | awk '{print $1}')
ad13_poll_a_err=$(ad_path "$AD" poll --job ad_20260722T000010Z_131 --scratch-dir "$AD_HOME/scratch" 2>&1 >/dev/null); ad13_poll_a_rc=$?
ad13_poll_b_err=$(ad_path "$AD" poll --job ad_20260722T000011Z_132 --scratch-dir "$AD_HOME/scratch" 2>&1 >/dev/null); ad13_poll_b_rc=$?
ad13_stop_err=$(ad_path "$AD" stop --job ad_20260722T000010Z_131 --scratch-dir "$AD_HOME/scratch" 2>&1 >/dev/null); ad13_stop_rc=$?
ad13_sum_after=$(cat "$ad13_a/terminal/state" "$ad13_b/terminal/state" "$ad13_b/terminal/exit_code" | shasum | awk '{print $1}')
if [[ $ad13_poll_a_rc -eq 1 && "$ad13_poll_a_err" == *"malformed"* && "$ad13_poll_a_err" == *"Action:"* \
   && $ad13_poll_b_rc -eq 1 && "$ad13_poll_b_err" == *"malformed"* \
   && $ad13_stop_rc -eq 1 && "$ad13_stop_err" == *"malformed"* \
   && "$ad13_sum_before" == "$ad13_sum_after" ]]; then
    pass "AD-13: malformed terminal records fail closed on poll and stop without rewrite"
else
    fail "AD-13: malformed-terminal handling mismatch" \
      "pa=$ad13_poll_a_rc:$ad13_poll_a_err pb=$ad13_poll_b_rc:$ad13_poll_b_err stop=$ad13_stop_rc:$ad13_stop_err sums=$ad13_sum_before/$ad13_sum_after"
fi

# AD-14: stall + ceiling verdicts from a live wrapper, and the codex-only
# stall rule. Sleeper engines keep the wrapper alive; mtime backdating
# (both out and err — poll maxes the two) and started_epoch poking drive
# each verdict without real waiting. Ceiling is checked before stall, so
# both-true pins the ordering. The omp sibling with identically backdated
# files must stay alive: only codex streams JSONL progress.
mv "$AD_HOME/bin/codex" "$AD_HOME/bin/codex.sav14"
cp "$AD_HOME/bin/sleeper-engine.sh" "$AD_HOME/bin/codex"
mv "$AD_HOME/bin/omp" "$AD_HOME/bin/omp.sav14"
cat > "$AD_HOME/bin/omp" <<'EOF'
#!/usr/bin/env bash
exec /bin/sleep 30
EOF
chmod +x "$AD_HOME/bin/omp"
ad14_cx=$(ad_path "$AD" start --engine codex \
    --prompt-file "$AD_HOME/prompt.md" --scratch-dir "$AD_HOME/scratch" | jq -r .job_id)
ad14_om=$(ad_path "$AD" start --engine omp \
    --prompt-file "$AD_HOME/prompt.md" --scratch-dir "$AD_HOME/scratch" | jq -r .job_id)
ad14_cxd="$AD_HOME/scratch/$ad14_cx"
ad14_omd="$AD_HOME/scratch/$ad14_om"
ad14_w=0
while [[ ( ! -f "$ad14_cxd/out" || ! -f "$ad14_cxd/err" \
        || ! -f "$ad14_omd/out" || ! -f "$ad14_omd/err" ) && $ad14_w -lt 100 ]]; do
    sleep 0.05
    ad14_w=$((ad14_w + 1))
done
ad14_v1=$(ad_path "$AD" poll --job "$ad14_cx" --scratch-dir "$AD_HOME/scratch" \
    --stall-threshold-sec 3600 --wall-clock-ceiling-sec 3600 | jq -r .verdict)
touch -t 202001010000 "$ad14_cxd/out" "$ad14_cxd/err"
ad14_p2=$(ad_path "$AD" poll --job "$ad14_cx" --scratch-dir "$AD_HOME/scratch" \
    --stall-threshold-sec 60 --wall-clock-ceiling-sec 3600)
printf '%s\n' "$(( $(date +%s) - 7200 ))" > "$ad14_cxd/started_epoch"
ad14_v3=$(ad_path "$AD" poll --job "$ad14_cx" --scratch-dir "$AD_HOME/scratch" \
    --stall-threshold-sec 60 --wall-clock-ceiling-sec 3600 | jq -r .verdict)
touch -t 202001010000 "$ad14_omd/out" "$ad14_omd/err"
ad14_v4=$(ad_path "$AD" poll --job "$ad14_om" --scratch-dir "$AD_HOME/scratch" \
    --stall-threshold-sec 60 --wall-clock-ceiling-sec 3600 | jq -r .verdict)
ad14_s1=$(ad_path "$AD" stop --job "$ad14_cx" --scratch-dir "$AD_HOME/scratch" | jq -r .verdict)
ad14_s2=$(ad_path "$AD" stop --job "$ad14_om" --scratch-dir "$AD_HOME/scratch" | jq -r .verdict)
mv "$AD_HOME/bin/codex.sav14" "$AD_HOME/bin/codex"
mv "$AD_HOME/bin/omp.sav14" "$AD_HOME/bin/omp"
if [[ "$ad14_v1" == "alive" ]] \
   && printf '%s' "$ad14_p2" | jq -e '.verdict == "stalled_suspect" and .output_age_sec > 60' >/dev/null \
   && [[ "$ad14_v3" == "wall_clock_exceeded" && "$ad14_v4" == "alive" \
      && "$ad14_s1" == "cancelled" && "$ad14_s2" == "cancelled" ]]; then
    pass "AD-14: stall/ceiling verdicts — alive, codex stalled_suspect, ceiling-before-stall, omp exempt"
else
    fail "AD-14: watchdog verdict matrix mismatch" \
      "v1=$ad14_v1 p2=$ad14_p2 v3=$ad14_v3 v4=$ad14_v4 s1=$ad14_s1 s2=$ad14_s2"
fi

# AD-15: parallel job isolation on one scratch dir — three gated omp jobs
# complete/cancel independently, each emitting its own job_id as marker
# (derived from the @prompt argv, so no cross-job env can leak), and a
# sibling's stop never perturbs another job's terminal payload.
mv "$AD_HOME/bin/omp" "$AD_HOME/bin/omp.sav15"
cat > "$AD_HOME/bin/omp" <<'EOF'
#!/usr/bin/env bash
job_dir=""
for arg in "$@"; do
    case "$arg" in @*) job_dir=$(dirname "${arg#@}") ;; esac
done
gate_wait=0
while [[ ! -f "$job_dir/gate" && $gate_wait -lt 600 ]]; do
    /bin/sleep 0.05
    gate_wait=$((gate_wait + 1))
done
[[ -f "$job_dir/gate" ]] || exit 9
printf 'marker=%s\n' "$(basename "$job_dir")"
EOF
chmod +x "$AD_HOME/bin/omp"
AD15_SCRATCH="$AD_HOME/scratch-ad15"
mkdir -p "$AD15_SCRATCH"
ad15_a=$(ad_path "$AD" start --engine omp \
    --prompt-file "$AD_HOME/prompt.md" --scratch-dir "$AD15_SCRATCH" | jq -r .job_id)
ad15_b=$(ad_path "$AD" start --engine omp \
    --prompt-file "$AD_HOME/prompt.md" --scratch-dir "$AD15_SCRATCH" | jq -r .job_id)
ad15_c=$(ad_path "$AD" start --engine omp \
    --prompt-file "$AD_HOME/prompt.md" --scratch-dir "$AD15_SCRATCH" | jq -r .job_id)
ad15_distinct=false
[[ -n "$ad15_a" && -n "$ad15_b" && -n "$ad15_c" \
   && "$ad15_a" != "$ad15_b" && "$ad15_b" != "$ad15_c" && "$ad15_a" != "$ad15_c" ]] \
    && ad15_distinct=true
touch "$AD15_SCRATCH/$ad15_c/gate"
ad15_c_out=""
ad_poll_until "$ad15_c" "$AD15_SCRATCH" completed && ad15_c_out="$AD_POLL_OUT"
touch "$AD15_SCRATCH/$ad15_a/gate"
ad15_a_out1=""
ad_poll_until "$ad15_a" "$AD15_SCRATCH" completed && ad15_a_out1="$AD_POLL_OUT"
ad15_b_v=$(ad_path "$AD" poll --job "$ad15_b" --scratch-dir "$AD15_SCRATCH" | jq -r .verdict)
ad15_b_s=$(ad_path "$AD" stop --job "$ad15_b" --scratch-dir "$AD15_SCRATCH" | jq -r .verdict)
ad15_a_out2=$(ad_path "$AD" poll --job "$ad15_a" --scratch-dir "$AD15_SCRATCH")
mv "$AD_HOME/bin/omp.sav15" "$AD_HOME/bin/omp"
if [[ "$ad15_distinct" == "true" ]] \
   && [[ $(printf '%s' "$ad15_c_out" | jq -r '.raw_output') == "marker=$ad15_c" ]] \
   && [[ $(printf '%s' "$ad15_a_out1" | jq -r '.raw_output') == "marker=$ad15_a" ]] \
   && [[ "$ad15_b_v" == "alive" && "$ad15_b_s" == "cancelled" ]] \
   && [[ "$ad15_a_out1" == "$ad15_a_out2" ]]; then
    pass "AD-15: three concurrent jobs on one scratch dir stay isolated through completion, stop, and re-poll"
else
    fail "AD-15: parallel-isolation contract mismatch" \
      "distinct=$ad15_distinct c=$ad15_c_out a1=$ad15_a_out1 bv=$ad15_b_v bs=$ad15_b_s a2=$ad15_a_out2"
fi

# CG-1: generated Codex skills preserve thematic `---` lines after command
# frontmatter; only the first frontmatter pair is stripped.
CG_REPO="$WORK/codex-gen"
mkdir -p "$CG_REPO/commands"
cat > "$CG_REPO/commands/example.md" <<'EOF'
---
description: Frontmatter parser fixture
---
# Example command

Before thematic break.

---

After thematic break.

Read `fragments/nested.md`.
EOF
if "$REPO/scripts/build-codex-skills.sh" "$CG_REPO" >/dev/null \
   && grep -qF -- '---' "$CG_REPO/dist/codex-skills/matthewsreview-example/SKILL.md" \
   && grep -qF 'After thematic break.' "$CG_REPO/dist/codex-skills/matthewsreview-example/SKILL.md"; then
    pass "CG-1: Codex generator strips only frontmatter and preserves later --- content"
else
    fail "CG-1: generated skill truncated content after a thematic break"
fi

# CG-2: generation is atomic. A later source failure cannot destroy the
# previously complete output tree that installed symlinks target.
cg_skill="$CG_REPO/dist/codex-skills/matthewsreview-example/SKILL.md"
cg_before=$(sha_of "$cg_skill")
ln -s "$CG_REPO/does-not-exist" "$CG_REPO/commands/zbad.md"
"$REPO/scripts/build-codex-skills.sh" "$CG_REPO" >/dev/null 2>&1
cg_code=$?
cg_after=$(sha_of "$cg_skill")
if [[ $cg_code -ne 0 && "$cg_before" == "$cg_after" \
      && ! -e "$CG_REPO/dist/codex-skills/matthewsreview-zbad" ]]; then
    pass "CG-2: failed Codex generation preserves the previous complete output"
else
    fail "CG-2: failed generation exposed a partial output tree" "code=$cg_code before=$cg_before after=$cg_after"
fi

# CG-3: an output-swap failure restores the previous complete tree instead
# of deleting the install target before the replacement can land.
CG_BIN="$WORK/codex-gen-bin"
mkdir -p "$CG_BIN"
cat > "$CG_BIN/mv" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == *"/.codex-skills.tmp."* && "${2:-}" == */dist/codex-skills ]]; then
    exit 70
fi
exec /bin/mv "$@"
EOF
chmod +x "$CG_BIN/mv"
cg_before=$(sha_of "$cg_skill")
rm "$CG_REPO/commands/zbad.md"
PATH="$CG_BIN:$PATH" "$REPO/scripts/build-codex-skills.sh" "$CG_REPO" >/dev/null 2>&1
cg_code=$?
cg_after=$(sha_of "$cg_skill")
if [[ $cg_code -ne 0 && "$cg_before" == "$cg_after" ]]; then
    pass "CG-3: failed output swap restores the previous generated tree"
else
    fail "CG-3: failed output swap destroyed the previous generated tree" "code=$cg_code before=$cg_before after=$cg_after"
fi

# CG-5: every shipped generated skill carries the same canonical plugin
# root and rooted nested-fragment rule.
cg5_bad=""
if ! "$REPO/scripts/build-codex-skills.sh" "$REPO" >/dev/null; then
    cg5_bad=" generator-failed"
else
    for cg5_skill in "$REPO"/dist/codex-skills/*/SKILL.md; do
        if ! grep -qF "MREVIEW_ROOT=$REPO" "$cg5_skill" \
           || ! grep -qF "\`$REPO/fragments/_prelude-shared.md\`" "$cg5_skill"; then
            cg5_bad="$cg5_bad $(basename "$(dirname "$cg5_skill")")"
        fi
    done
fi
if [[ -z "$cg5_bad" ]]; then
    pass "CG-5: every shipped Codex skill roots top-level and nested fragments"
else
    fail "CG-5: generated skills missing canonical fragment roots" "$cg5_bad"
fi

# CG-4: a relative repo argument is canonicalized before it is baked into
# generated skills, and every nested fragment read is rooted there.
(cd "$WORK" && "$REPO/scripts/build-codex-skills.sh" codex-gen >/dev/null)
cg_code=$?
if [[ $cg_code -eq 0 ]] \
   && grep -qF "MREVIEW_ROOT=$CG_REPO" "$cg_skill" \
   && grep -qF "\`$CG_REPO/fragments/nested.md\`" "$cg_skill"; then
    pass "CG-4: generated skills bake a canonical root for every fragment read"
else
    fail "CG-4: generated skill fragment root is missing or relative"
fi

# CG-6: every readable command must have a line-1 frontmatter opener, a later
# closer, and a nonblank description inside that first pair. A malformed later
# command must report its path/reason without replacing the prior complete tree.
CG_VALIDATE_REPO="$WORK/codex-frontmatter"
mkdir -p "$CG_VALIDATE_REPO/commands"
cat > "$CG_VALIDATE_REPO/commands/good.md" <<'EOF'
---
description: Known-good command
---
# Good
EOF
if "$REPO/scripts/build-codex-skills.sh" "$CG_VALIDATE_REPO" >/dev/null; then
    cg6_skill="$CG_VALIDATE_REPO/dist/codex-skills/matthewsreview-good/SKILL.md"
    cg6_before=$(sha_of "$cg6_skill")
    # Simulate a skill produced by a command that was removed after the prior
    # complete publication. Any partial tree replacement would drop this path
    # even if the regenerated good/SKILL.md happened to be byte-identical.
    cg6_prior_skill="$CG_VALIDATE_REPO/dist/codex-skills/matthewsreview-removed/SKILL.md"
    mkdir -p "$(dirname "$cg6_prior_skill")"
    printf 'prior complete tree marker\n' > "$cg6_prior_skill"
    cg6_prior_before=$(sha_of "$cg6_prior_skill")
    # Change an existing source after the baseline. A flawed builder that
    # writes valid commands directly into the live tree before a later failure
    # would now alter cg6_skill even if it preserved the removed-skill marker.
    cat > "$CG_VALIDATE_REPO/commands/good.md" <<'EOF'
---
description: Changed after the prior complete publication
---
# Changed good command
EOF
    cg6_failures=""
    for cg6_case in missing-opener missing-closer missing-description blank-description; do
        case "$cg6_case" in
            missing-opener)
                cat > "$CG_VALIDATE_REPO/commands/zbad.md" <<'EOF'
# Not frontmatter
---
description: Too late
---
EOF
                cg6_reason="line 1 must be ---"
                ;;
            missing-closer)
                cat > "$CG_VALIDATE_REPO/commands/zbad.md" <<'EOF'
---
description: No closing delimiter
# Body starts without a closer
EOF
                cg6_reason="missing closing ---"
                ;;
            missing-description)
                cat > "$CG_VALIDATE_REPO/commands/zbad.md" <<'EOF'
---
argument-hint: "[--full]"
---
description: Too late for the first frontmatter pair
# Missing in-pair description
EOF
                cg6_reason="description must be present and nonblank"
                ;;
            blank-description)
                cat > "$CG_VALIDATE_REPO/commands/zbad.md" <<'EOF'
---
description:    
---
# Blank description
EOF
                cg6_reason="description must be present and nonblank"
                ;;
        esac
        cg6_err=$("$REPO/scripts/build-codex-skills.sh" "$CG_VALIDATE_REPO" 2>&1)
        cg6_code=$?
        cg6_after=$(sha_of "$cg6_skill")
        if [[ -f "$cg6_prior_skill" ]]; then
            cg6_prior_after=$(sha_of "$cg6_prior_skill")
        else
            cg6_prior_after="<missing>"
        fi
        if [[ $cg6_code -eq 0 \
              || "$cg6_err" != *"$CG_VALIDATE_REPO/commands/zbad.md"* \
              || "$cg6_err" != *"$cg6_reason"* \
              || "$cg6_before" != "$cg6_after" \
              || "$cg6_prior_before" != "$cg6_prior_after" \
              || -e "$CG_VALIDATE_REPO/dist/codex-skills/matthewsreview-zbad" ]]; then
            cg6_failures="$cg6_failures $cg6_case(code=$cg6_code)"
        fi
        rm "$CG_VALIDATE_REPO/commands/zbad.md"
    done
    if [[ -z "$cg6_failures" ]]; then
        pass "CG-6: malformed frontmatter reports path/reason and preserves prior generated tree"
    else
        fail "CG-6: malformed frontmatter validation/atomicity mismatch" "$cg6_failures"
    fi
else
    fail "CG-6: baseline Codex generation failed"
fi


# CI-1: reinstall removes stale generated matthewsreview links even when
# they point at a checkout that moved, then refreshes current links.
CI_HOME="$WORK/codex-install-home"
mkdir -p "$CI_HOME/.agents/skills" \
    "$WORK/old-checkout/dist/codex-skills/matthewsreview-obsolete"
ln -s "$WORK/old-checkout/dist/codex-skills/matthewsreview-obsolete" \
    "$CI_HOME/.agents/skills/matthewsreview-obsolete"
if HOME="$CI_HOME" "$REPO/install.sh" --codex >/dev/null \
   && [[ ! -L "$CI_HOME/.agents/skills/matthewsreview-obsolete" ]] \
   && [[ -L "$CI_HOME/.agents/skills/matthewsreview-review" ]]; then
    pass "CI-1: Codex reinstall prunes stale owned links and refreshes current skills"
else
    fail "CI-1: Codex reinstall did not converge generated symlinks"
fi

# CI-2: a real skill directory is user data, never recursively replaced.
CI_COLLIDE_HOME="$WORK/codex-install-collision"
mkdir -p "$CI_COLLIDE_HOME/.agents/skills/matthewsreview-review"
printf 'keep\n' > "$CI_COLLIDE_HOME/.agents/skills/matthewsreview-review/sentinel"
ci_err=$(HOME="$CI_COLLIDE_HOME" "$REPO/install.sh" --codex 2>&1)
ci_code=$?
if [[ $ci_code -ne 0 && "$ci_err" == *"refusing to replace existing skill directory"* \
      && $(cat "$CI_COLLIDE_HOME/.agents/skills/matthewsreview-review/sentinel") == "keep" ]]; then
    pass "CI-2: Codex installer refuses real-directory collisions without data loss"
else
    fail "CI-2: Codex installer collision safety mismatch" "code=$ci_code err=$ci_err"
fi

# CI-3: destination preflight derives every desired skill from commands/*.md,
# so a newly added command collision aborts before rebuilding the live
# dist/codex-skills tree targeted by already-installed symlinks.
CI_PREFLIGHT_REPO="$WORK/codex-install-preflight"
CI_PREFLIGHT_HOME="$WORK/codex-install-preflight-home"
mkdir -p "$CI_PREFLIGHT_REPO/commands" \
    "$CI_PREFLIGHT_REPO/scripts" \
    "$CI_PREFLIGHT_REPO/skills/matthewsreview" \
    "$CI_PREFLIGHT_REPO/dist/codex-skills/matthewsreview-existing" \
    "$CI_PREFLIGHT_HOME/.agents/skills"
cp "$REPO/install.sh" "$CI_PREFLIGHT_REPO/install.sh"
cp "$REPO/scripts/build-codex-skills.sh" "$CI_PREFLIGHT_REPO/scripts/build-codex-skills.sh"
chmod +x "$CI_PREFLIGHT_REPO/install.sh" "$CI_PREFLIGHT_REPO/scripts/build-codex-skills.sh"
cat > "$CI_PREFLIGHT_REPO/commands/existing.md" <<'EOF'
---
description: Rebuilt content must stay hidden on collision
---
# Existing replacement
EOF
cat > "$CI_PREFLIGHT_REPO/commands/new-command.md" <<'EOF'
---
description: Newly added command
---
# New command
EOF
printf 'keep regular-file collision\n' \
    > "$CI_PREFLIGHT_HOME/.agents/skills/matthewsreview-new-command"
printf 'installed-before-collision\n' \
    > "$CI_PREFLIGHT_REPO/dist/codex-skills/matthewsreview-existing/SKILL.md"
ln -s "$CI_PREFLIGHT_REPO/dist/codex-skills/matthewsreview-existing" \
    "$CI_PREFLIGHT_HOME/.agents/skills/matthewsreview-existing"
ci3_before=$(sha_of "$CI_PREFLIGHT_HOME/.agents/skills/matthewsreview-existing/SKILL.md")
ci3_err=$(HOME="$CI_PREFLIGHT_HOME" "$CI_PREFLIGHT_REPO/install.sh" --codex 2>&1)
ci3_code=$?
ci3_after=$(sha_of "$CI_PREFLIGHT_HOME/.agents/skills/matthewsreview-existing/SKILL.md")
if [[ $ci3_code -ne 0 \
      && "$ci3_err" == *"matthewsreview-new-command"* \
      && "$ci3_before" == "$ci3_after" \
      && $(cat "$CI_PREFLIGHT_HOME/.agents/skills/matthewsreview-new-command") == "keep regular-file collision" \
      && ! -e "$CI_PREFLIGHT_REPO/dist/codex-skills/matthewsreview-new-command" ]]; then
    pass "CI-3: new-command regular-file collision aborts before rebuilding installed symlink targets"
else
    fail "CI-3: desired-command preflight ran after generated-tree rebuild" \
        "code=$ci3_code before=$ci3_before after=$ci3_after err=$ci3_err"
fi

# CI-4: the workflow front-door destination is part of the same preflight.
# Its collision must likewise leave every installed generated target unchanged.
rm -rf "$CI_PREFLIGHT_REPO/dist/codex-skills" \
    "$CI_PREFLIGHT_HOME/.agents/skills/matthewsreview-new-command"
mkdir -p "$CI_PREFLIGHT_REPO/dist/codex-skills/matthewsreview-existing" \
    "$CI_PREFLIGHT_HOME/.agents/skills/matthewsreview"
printf 'installed-before-front-door-collision\n' \
    > "$CI_PREFLIGHT_REPO/dist/codex-skills/matthewsreview-existing/SKILL.md"
ci4_before=$(sha_of "$CI_PREFLIGHT_HOME/.agents/skills/matthewsreview-existing/SKILL.md")
ci4_err=$(HOME="$CI_PREFLIGHT_HOME" "$CI_PREFLIGHT_REPO/install.sh" --codex 2>&1)
ci4_code=$?
ci4_after=$(sha_of "$CI_PREFLIGHT_HOME/.agents/skills/matthewsreview-existing/SKILL.md")
if [[ $ci4_code -ne 0 \
      && "$ci4_err" == *"$CI_PREFLIGHT_HOME/.agents/skills/matthewsreview"* \
      && "$ci4_before" == "$ci4_after" \
      && ! -e "$CI_PREFLIGHT_REPO/dist/codex-skills/matthewsreview-new-command" ]]; then
    pass "CI-4: front-door collision aborts before rebuilding installed symlink targets"
else
    fail "CI-4: front-door preflight ran after generated-tree rebuild" \
        "code=$ci4_code before=$ci4_before after=$ci4_after err=$ci4_err"
fi

# PKG-DOC-1: every schema-defined degraded counter is documented, along with
# the optional/nonnegative and at-least-one-positive semantics. Deriving the
# key set prevents the schema/docs drift this assertion is meant to catch.
pkg_missing_degraded=""
while IFS= read -r pkg_degraded_key; do
    if ! grep -qF "\`$pkg_degraded_key\`" "$REPO/docs/state-and-gates.md"; then
        pkg_missing_degraded="${pkg_missing_degraded}${pkg_degraded_key} "
    fi
done < <(jq -r '.["$defs"].degraded.properties | keys[]' "$TOOLS/schema-v1.json")
if [[ -z "$pkg_missing_degraded" ]] \
   && grep -qF 'All degraded counters are optional' "$REPO/docs/state-and-gates.md" \
   && grep -qF 'at least one present counter must be positive' "$REPO/docs/state-and-gates.md" \
   && grep -qF 'incomplete review coverage' "$REPO/docs/state-and-gates.md" \
   && grep -qF 'incomplete finalization' "$REPO/docs/state-and-gates.md"; then
    pass "PKG-DOC-1: degraded metadata docs cover every schema counter and invariant"
else
    fail "PKG-DOC-1: degraded metadata docs are incomplete" \
        "missing_schema_keys=$pkg_missing_degraded"
fi

# PKG-DOC-2: :review documents the supported model-plan override rather than
# advertising the rejected --codex-review-effort flag.
if ! grep -qF -- '--codex-review-effort' "$REPO/docs/pipeline.md" \
   && grep -qF -- "--models 'ensemble_detect=codex::<effort>'" "$REPO/docs/pipeline.md"; then
    pass "PKG-DOC-2: pipeline docs use the supported Codex ensemble effort override"
else
    fail "PKG-DOC-2: pipeline docs advertise a nonexistent review effort flag"
fi

# PKG-WF-1: validate permissions and checkout credentials in their YAML
# structure. A nested job override, comment, or unrelated step must not satisfy
# the contract.
pkg_workflow_shape=$(python3 - "$REPO/.github/workflows/smoke.yml" <<'PY'
import re
import sys
from pathlib import Path

lines = Path(sys.argv[1]).read_text().splitlines()
permissions = [
    (index, len(line) - len(line.lstrip()))
    for index, line in enumerate(lines)
    if re.match(r"^\s*permissions\s*:", line)
]
if permissions != [(next((i for i, line in enumerate(lines) if line == "permissions:"), -1), 0)]:
    print("bad-permissions-count-or-depth")
    raise SystemExit

permission_index = permissions[0][0]
permission_body = []
for line in lines[permission_index + 1:]:
    if line and not line[0].isspace() and not line.lstrip().startswith("#"):
        break
    if line.strip() and not line.lstrip().startswith("#"):
        permission_body.append(line)
if permission_body != ["  contents: read"]:
    print("bad-permissions-body")
    raise SystemExit

checkout = [
    index for index, line in enumerate(lines)
    if re.match(r"^\s*-\s+uses:\s*actions/checkout@", line)
]
if len(checkout) != 1:
    print("bad-checkout-count")
    raise SystemExit
start = checkout[0]
step_indent = len(lines[start]) - len(lines[start].lstrip())
end = len(lines)
for index in range(start + 1, len(lines)):
    stripped = lines[index].lstrip()
    indent = len(lines[index]) - len(stripped)
    if stripped.startswith("- ") and indent == step_indent:
        end = index
        break
segment = lines[start:end]
with_rows = [
    (index, len(line) - len(line.lstrip()))
    for index, line in enumerate(segment)
    if line.strip() == "with:"
]
credential_rows = [
    (index, len(line) - len(line.lstrip()))
    for index, line in enumerate(segment)
    if line.strip() == "persist-credentials: false"
]
if len(with_rows) != 1 or len(credential_rows) != 1:
    print("bad-checkout-with-shape")
elif credential_rows[0][0] <= with_rows[0][0] or credential_rows[0][1] <= with_rows[0][1]:
    print("misnested-checkout-credentials")
else:
    print("ok")
PY
)
if [[ "$pkg_workflow_shape" == "ok" ]]; then
    pass "PKG-WF-1: smoke workflow has exact top-level contents:read permissions and credentialless checkout"
else
    fail "PKG-WF-1: smoke workflow permission/checkout contract drifted" \
        "shape=$pkg_workflow_shape"
fi

# DP-1: artifact-render.py --format dispositions emits one row per finding
# plus a totals line; suggested actions follow the disposition mapping.
dp_out=$("$TOOLS/artifact-render.py" --input "$FIX/artifact-seed.json" --format dispositions)
dp_rows=$(printf '%s\n' "$dp_out" | grep -c '^| F0')
dp_findings=$(jq '.findings | length' "$FIX/artifact-seed.json")
if [[ "$dp_rows" == "$dp_findings" ]] \
   && printf '%s\n' "$dp_out" | grep -qE '\*\*[0-9]+ engage / [0-9]+ skip\*\*'; then
    pass "DP-1: dispositions export row count == findings count + totals line present"
else
    fail "DP-1: dispositions export mismatch" "rows=$dp_rows findings=$dp_findings"
fi

# DP-2: claim text is inert Markdown table content. Truncation remains based
# on the plain claim, then HTML-significant characters are escaped.
DP_ART="$WORK/dp-art.json"
jq '(.findings[] | select(.id == "F001") | .claim) = "<details>|unsafe"' \
    "$FIX/artifact-seed.json" > "$DP_ART"
dp_escaped=$("$TOOLS/artifact-render.py" --input "$DP_ART" --format dispositions)
if [[ "$dp_escaped" == *"&lt;details&gt;\\|unsafe"* && "$dp_escaped" != *"<details>"* ]]; then
    pass "DP-2: dispositions escape HTML-significant claim text"
else
    fail "DP-2: dispositions claim escaping mismatch" "$dp_escaped"
fi

# DP-3: an interrupted fix is recovery work, regardless of whether the
# finding was mechanical or manual. It must not inflate the executable engage
# queue; ordinary open/resolved rows remain walkthrough/done controls.
DP_ROUTE_ART="$WORK/dp-route.json"
jq '
  .findings |= map(select(.id == "F001" or .id == "F002" or .id == "F004" or .id == "F005"))
  | (.findings[] | select(.id == "F001" or .id == "F002") | .current_state) = "attempted"
  | (.findings[] | select(.id == "F005")) |=
      (.current_state = "resolved" | .disposition = "resolved" | .is_actionable = false)
' "$FIX/artifact-seed.json" > "$DP_ROUTE_ART"
dp_route=$("$TOOLS/artifact-render.py" \
    --input "$DP_ROUTE_ART" --format dispositions)
dp_attempted_mechanical=$(printf '%s\n' "$dp_route" | grep '^| F001 |')
dp_attempted_manual=$(printf '%s\n' "$dp_route" | grep '^| F002 |')
dp_open_control=$(printf '%s\n' "$dp_route" | grep '^| F004 |')
dp_resolved_control=$(printf '%s\n' "$dp_route" | grep '^| F005 |')
if [[ "$dp_attempted_mechanical" == *"| attempted | recover |"* \
   && "$dp_attempted_manual" == *"| attempted | recover |"* \
   && "$dp_open_control" == *"| open | walkthrough |"* \
   && "$dp_resolved_control" == *"| resolved | done |"* \
   && "$dp_route" == *"**1 engage / 3 skip**"* \
   && "$dp_route" == *"recover → finish or reset the interrupted fix before fix/walkthrough"* ]]; then
    pass "DP-3: attempted mechanical/manual findings recover without engaging; open/resolved controls remain"
else
    fail "DP-3: interrupted-fix disposition routing mismatch" \
      "mechanical=$dp_attempted_mechanical manual=$dp_attempted_manual open=$dp_open_control resolved=$dp_resolved_control totals=$(printf '%s\n' "$dp_route" | grep 'engage /')"
fi

# CAL-1: calibration-report.py aggregates a synthetic history — demote
# median, waste basis (disproven+uncertain)/total, band matrix row.
CAL_HOME="$WORK/cal"
mkdir -p "$CAL_HOME/slug-a/branch-x/rev_001" "$CAL_HOME/slug-b/nested/branch-y/rev_002"
cp "$FIX/artifact-seed.json" "$CAL_HOME/slug-a/branch-x/rev_001/artifact.json"
cp "$FIX/artifact-seed.json" "$CAL_HOME/slug-b/nested/branch-y/rev_002/artifact.json"
cal_tmp="$CAL_HOME/slug-b/nested/branch-y/rev_002/artifact.tmp"
jq '.gates={"phase3_gate":12,"phase4_bands":[10,20,30],"fix_threshold":25,"walkthrough_threshold":25}' \
    "$CAL_HOME/slug-b/nested/branch-y/rev_002/artifact.json" > "$cal_tmp"
mv "$cal_tmp" "$CAL_HOME/slug-b/nested/branch-y/rev_002/artifact.json"
printf '%s\n' '{"name":"scoring-gate","demote_rate":0.5}' > "$CAL_HOME/slug-a/branch-x/rev_001/phases.jsonl"
printf '%s\n' '{"phase":"phase_1","tokens":1000}' > "$CAL_HOME/slug-a/branch-x/rev_001/tokens.jsonl"
cat > "$CAL_HOME/slug-a/branch-x/rev_001/trace.md" <<'TRACE'
lens_L3 killed after stall (attempt 1)
lens_L5 wall_clock_exceeded at 600s
lens_L3 resumed on retry
lens_L1 dispatched cleanly
the lens was killed (prose decoy — must not count)
TRACE
cal_out=$("$TOOLS/calibration-report.py" "$CAL_HOME")
cal_findings=$(jq '[.findings[] | select(.disposition=="disproven" or .disposition=="uncertain")] | length' "$FIX/artifact-seed.json")
cal_total=$(jq '.findings | length' "$FIX/artifact-seed.json")
if printf '%s' "$cal_out" | grep -q 'Runs analyzed: \*\*2\*\*' \
   && printf '%s' "$cal_out" | grep -q 'median \*\*0.500\*\*' \
   && printf '%s' "$cal_out" | grep -qF "$(python3 -c "print(f'{$cal_findings/$cal_total:.1%}')")" \
   && printf '%s' "$cal_out" | grep -qF 'Phase 4 bands: **45 / 60 / 75** (1 run)' \
   && printf '%s' "$cal_out" | grep -qF 'Phase 4 bands: **10 / 20 / 30** (1 run)' \
   && printf '%s' "$cal_out" | grep -qF '| 20–<30 |'; then
    pass "CAL-1: calibration groups score matrices by each run's resolved bands"
else
    fail "CAL-1: calibration aggregation mismatch" "$(printf '%s' "$cal_out" | head -12)"
fi

# CAL-6: lens transport-anomaly counting from trace.md — boundary-delimited
# killed/resume(d)/wall_clock_exceeded tokens on lens_* event lines count
# (3 above); a clean dispatch line and a prose decoy that does not start
# with lens_ must not.
if printf '%s' "$cal_out" | grep -qF 'Total lens anomalies (killed/resume/wall_clock): **3**'; then
    pass "CAL-6: trace.md lens anomalies counted with token boundaries; decoys excluded"
else
    fail "CAL-6: lens-anomaly counting mismatch" \
      "$(printf '%s' "$cal_out" | grep -i 'anomal' || printf 'no anomaly line found')"
fi

# CAL-2: no-argument calibration honors the explicit review-root override.
cal_env_out=$(MATTHEWS_REVIEW_REVIEWS_ROOT="$CAL_HOME" "$TOOLS/calibration-report.py")
if printf '%s' "$cal_env_out" | grep -q 'Runs analyzed: \*\*2\*\*'; then
    pass "CAL-2: calibration honors MATTHEWS_REVIEW_REVIEWS_ROOT"
else
    fail "CAL-2: configured review root ignored" "$cal_env_out"
fi

# CAL-3: usage and invalid-root failures follow the shared exit/error contract.
cal_usage_err=$("$TOOLS/calibration-report.py" one two 2>&1); cal_usage_code=$?
cal_root_err=$(MATTHEWS_REVIEW_REVIEWS_ROOT="$WORK/cal-missing" "$TOOLS/calibration-report.py" 2>&1); cal_root_code=$?
if [[ $cal_usage_code -eq 64 && "$cal_usage_err" == *"Action:"* \
   && $cal_root_code -eq 1 && "$cal_root_err" == *"Action:"* ]]; then
    pass "CAL-3: calibration usage/root errors are structured with shared exits"
else
    fail "CAL-3: calibration error contract mismatch" "usage=$cal_usage_code:$cal_usage_err root=$cal_root_code:$cal_root_err"
fi

# CAL-4/CAL-5: mixed historical telemetry is row-isolated. Parseable invalid
# artifacts and malformed JSONL rows warn and skip, valid neighbors still
# aggregate, nullable tokens remain quiet, and huge integers use exact medians
# without float conversion or traceback.
CAL_MIX="$WORK/cal-mixed"
CAL_MIX_R1="$CAL_MIX/slug-a/branch/rev_001"
CAL_MIX_R2="$CAL_MIX/slug-b/branch/rev_002"
CAL_MIX_BAD1="$CAL_MIX/slug-c/branch/rev_003"
CAL_MIX_BAD2="$CAL_MIX/slug-d/branch/rev_004"
mkdir -p "$CAL_MIX_R1" "$CAL_MIX_R2" "$CAL_MIX_BAD1" "$CAL_MIX_BAD2"
cp "$FIX/artifact-seed.json" "$CAL_MIX_R1/artifact.json"
jq '.gates=null' "$FIX/artifact-seed.json" > "$CAL_MIX_R2/artifact.json"
printf '%s\n' '[]' > "$CAL_MIX_BAD1/artifact.json"
printf '%s\n' '{"schema_version":"1.0"}' > "$CAL_MIX_BAD2/artifact.json"
cat > "$CAL_MIX_R1/phases.jsonl" <<'JSONL'
{"name":"scoring-gate","demote_rate":0.25}
{bad
[]
true
{"name":"scoring-gate","demote_rate":1.25}
{"name":"scoring-gate","demote_rate":-0.1}
{"name":"scoring-gate","demote_rate":true}
{"name":"scoring-gate","demote_rate":0.5}
JSONL
cal_huge_a=$(printf '1%0400d' 0)
cal_huge_b=$(printf '3%0400d' 0)
cat > "$CAL_MIX_R1/tokens.jsonl" <<JSONL
{"phase":"phase_1","tokens":1000}
{bad
[]
true
{"phase":"","tokens":2}
{"phase":3,"tokens":2}
{"phase":"phase_1"}
{"phase":"phase_1","tokens":null}
{"phase":"phase_1","tokens":-1}
{"phase":"phase_1","tokens":1.5}
{"phase":"phase_1","tokens":true}
{"phase":"phase_huge","tokens":$cal_huge_a}
{"phase":"phase_1","tokens":500}
JSONL
cat > "$CAL_MIX_R2/tokens.jsonl" <<JSONL
{"phase":"phase_huge","tokens":$cal_huge_b}
JSONL
cal_mix_out=$("$TOOLS/calibration-report.py" "$CAL_MIX" \
    2>"$CAL_MIX/warnings.err")
cal_mix_code=$?
cal_mix_err=$(cat "$CAL_MIX/warnings.err")
cal_bad_artifacts=$(printf '%s\n' "$cal_mix_err" \
    | grep -c 'invalid artifact; skipping run')
if [[ $cal_mix_code -eq 0 && "$cal_mix_out" == \#\ Calibration\ report* \
   && "$cal_mix_out" == *"Runs analyzed: **2**"* \
   && "$cal_mix_out" == *"median **0.500**"* \
   && "$cal_mix_out" == *"| phase_1 | 1 | 1,500 | 1,500 |"* \
   && $cal_bad_artifacts -eq 2 \
   && "$cal_mix_err" == *"$CAL_MIX_R1/phases.jsonl:2: invalid JSON"* \
   && "$cal_mix_err" == *"$CAL_MIX_R1/phases.jsonl:3: expected a JSON object"* \
   && "$cal_mix_err" == *"$CAL_MIX_R1/tokens.jsonl:2: invalid JSON"* \
   && "$cal_mix_err" == *"$CAL_MIX_R1/tokens.jsonl:5: phase must be a non-empty string"* \
   && "$cal_mix_err" == *"$CAL_MIX_R1/tokens.jsonl:7: tokens is required"* \
   && "$cal_mix_out$cal_mix_err" != *"Traceback"* \
   && "$cal_mix_out$cal_mix_err" != *"OverflowError"* \
   && "$cal_mix_out" != *"WARNING:"* ]]; then
    pass "CAL-4: invalid artifacts/rows warn and skip while valid neighboring telemetry survives"
else
    fail "CAL-4: mixed-history isolation/diagnostics mismatch" \
      "code=$cal_mix_code bad_artifacts=$cal_bad_artifacts out=$cal_mix_out err=$cal_mix_err"
fi
cal_token_type_warnings=$(printf '%s\n' "$cal_mix_err" \
    | grep -c 'tokens must be a nonnegative integer or null')
cal_demote_warnings=$(printf '%s\n' "$cal_mix_err" \
    | grep -c 'demote_rate must be a finite number from 0 through 1')
if [[ $cal_token_type_warnings -eq 3 && $cal_demote_warnings -eq 3 \
   && "$cal_mix_out" == *"| phase_huge | 2 |"* \
   && "$cal_mix_err" != *"$CAL_MIX_R1/tokens.jsonl:8:"* \
   && "$cal_mix_err" != *"$CAL_MIX_R1/tokens.jsonl:12:"* \
   && "$cal_mix_out$cal_mix_err" != *"Traceback"* \
   && "$cal_mix_out$cal_mix_err" != *"OverflowError"* ]]; then
    pass "CAL-5: negative/fraction/bool tokens and out-of-range demotes warn; null/huge integers remain safe"
else
    fail "CAL-5: calibration numeric boundaries regressed" \
      "token_warnings=$cal_token_type_warnings demote_warnings=$cal_demote_warnings err=$cal_mix_err"
fi

# SS-1: --set-scores batch — one call writes N scores, appends score_history
SS_DIR="$WORK/ss"
mkdir -p "$SS_DIR"
cp "$FIX/artifact-seed.json" "$SS_DIR/art.json"
"$TOOLS/artifact-patch.py" --path "$SS_DIR/art.json" \
    --set-scores '[{"id":"F001","score_phase3":72,"reason":"r1"},{"id":"F002","score_phase3":null}]' \
    --expected 2 >/dev/null
ss_s1=$(jq -r '.findings[] | select(.id=="F001") | .score_phase3' "$SS_DIR/art.json")
ss_h1=$(jq '[.findings[] | select(.id=="F001") | .score_history[] | select(.phase=="phase_3")] | length' "$SS_DIR/art.json")
ss_s2=$(jq -r '.findings[] | select(.id=="F002") | .score_phase3' "$SS_DIR/art.json")
if [[ "$ss_s1" == "72" && "$ss_h1" -ge 2 && "$ss_s2" == "null" ]] \
   && "$TOOLS/artifact-validate.sh" --path "$SS_DIR/art.json" >/dev/null 2>&1; then
    pass "SS-1: --set-scores batch writes scores + appends history + schema-valid"
else
    fail "SS-1: batch score write mismatch" "s1=$ss_s1 h1=$ss_h1 s2=$ss_s2"
fi

# SS-2: --set-scores duplicate id rejected before any write
cp "$FIX/artifact-seed.json" "$SS_DIR/art2.json"
ss_err=$("$TOOLS/artifact-patch.py" --path "$SS_DIR/art2.json" \
    --set-scores '[{"id":"F001","score_phase3":1},{"id":"F001","score_phase3":2}]' \
    --expected 2 2>&1); code=$?
ss_unchanged=$(jq -r '.findings[] | select(.id=="F001") | .score_phase3' "$SS_DIR/art2.json")
if [[ $code -ne 0 && "$ss_err" == *"duplicate id 'F001'"* && "$ss_unchanged" == "85" ]]; then
    pass "SS-2: --set-scores duplicate id rejected first-fail-halt (artifact untouched)"
else
    fail "SS-2: duplicate rejection mismatch" "code=$code unchanged=$ss_unchanged err=$ss_err"
fi

# SS-3: a short scoring batch is rejected before any score mutation.
cp "$FIX/artifact-seed.json" "$SS_DIR/art3.json"
ss_short_err=$("$TOOLS/artifact-patch.py" --path "$SS_DIR/art3.json" \
    --set-scores '[{"id":"F001","score_phase3":1}]' \
    --expected 2 2>&1); ss_short_code=$?
ss_short_unchanged=$(jq -r \
    '.findings[] | select(.id=="F001") | .score_phase3' "$SS_DIR/art3.json")
if [[ $ss_short_code -eq 6 \
   && "$ss_short_err" == *"expected 2 tuple(s) but received 1"* \
   && "$ss_short_unchanged" == "85" ]]; then
    pass "SS-3: --set-scores count mismatch exits 6 before any write"
else
    fail "SS-3: score count guard mismatch" \
      "code=$ss_short_code unchanged=$ss_short_unchanged err=$ss_short_err"
fi

# SS-4: score_phase3 is nullable but required. Omission is a validation error,
# not an implicit null, and cannot change any artifact bytes.
cp "$FIX/artifact-seed.json" "$SS_DIR/required-phase3.json"
ss_required_before=$(sha_of "$SS_DIR/required-phase3.json")
ss_required_out=$("$TOOLS/artifact-patch.py" \
    --path "$SS_DIR/required-phase3.json" \
    --set-scores '[{"id":"F001"}]' --expected 1 \
    2>"$SS_DIR/required-phase3.err")
ss_required_code=$?
ss_required_after=$(sha_of "$SS_DIR/required-phase3.json")
if [[ $ss_required_code -eq 1 && -z "$ss_required_out" \
   && "$ss_required_before" == "$ss_required_after" \
   && "$(cat "$SS_DIR/required-phase3.err")" == *"'score_phase3' is required"* \
   && "$(cat "$SS_DIR/required-phase3.err")" == *"Action:"* ]]; then
    pass "SS-4: omitted required nullable score_phase3 rejects with bytes unchanged"
else
    fail "SS-4: omitted score_phase3 was defaulted or mutated bytes" \
      "code=$ss_required_code unchanged=$([[ "$ss_required_before" == "$ss_required_after" ]] && echo yes || echo no) out=$ss_required_out err=$(cat "$SS_DIR/required-phase3.err")"
fi

# SS-5: explicit null remains distinct from zero. Null clears the score
# without fabricating history; zero is stored and appended verbatim.
cp "$FIX/artifact-seed.json" "$SS_DIR/null-zero-phase3.json"
"$TOOLS/artifact-patch.py" --path "$SS_DIR/null-zero-phase3.json" \
    --set-scores '[{"id":"F001","score_phase3":null},{"id":"F002","score_phase3":0}]' \
    --expected 2 >/dev/null 2>"$SS_DIR/null-zero-phase3.err"
ss_null_zero_code=$?
ss_phase3_shape=$(jq -r '
  [
    (.findings[] | select(.id=="F001")
      | [.score_phase3, ([.score_history[] | select(.phase=="phase_3")] | length)]
      | map(tostring) | join("|")),
    (.findings[] | select(.id=="F002")
      | [.score_phase3, .score_history[-1].phase, .score_history[-1].score]
      | map(tostring) | join("|"))
  ] | join(";")
' "$SS_DIR/null-zero-phase3.json")
if [[ $ss_null_zero_code -eq 0 && "$ss_phase3_shape" == "null|1;0|phase_3|0" ]]; then
    pass "SS-5: explicit null score_phase3 succeeds without history; numeric zero is preserved"
else
    fail "SS-5: nullable/zero Phase-3 score semantics collapsed" \
      "code=$ss_null_zero_code shape=$ss_phase3_shape err=$(cat "$SS_DIR/null-zero-phase3.err")"
fi

# ADN-1: the Phase-4 batch contract mirrors Phase 3: score_phase4 must be
# present even though null is valid, and omission leaves the file byte-exact.
cp "$FIX/artifact-seed.json" "$SS_DIR/required-phase4.json"
adn_required_before=$(sha_of "$SS_DIR/required-phase4.json")
adn_required_out=$("$TOOLS/artifact-patch.py" \
    --path "$SS_DIR/required-phase4.json" \
    --apply-decisions '[{"id":"F001"}]' --expected 1 \
    2>"$SS_DIR/required-phase4.err")
adn_required_code=$?
adn_required_after=$(sha_of "$SS_DIR/required-phase4.json")
if [[ $adn_required_code -eq 1 && -z "$adn_required_out" \
   && "$adn_required_before" == "$adn_required_after" \
   && "$(cat "$SS_DIR/required-phase4.err")" == *"'score_phase4' is required"* \
   && "$(cat "$SS_DIR/required-phase4.err")" == *"Action:"* ]]; then
    pass "ADN-1: omitted required nullable score_phase4 rejects with bytes unchanged"
else
    fail "ADN-1: omitted score_phase4 was defaulted or mutated bytes" \
      "code=$adn_required_code unchanged=$([[ "$adn_required_before" == "$adn_required_after" ]] && echo yes || echo no) out=$adn_required_out err=$(cat "$SS_DIR/required-phase4.err")"
fi

# ADN-2: explicit Phase-4 null succeeds without history and zero survives
# routing as an actual score (disproven), rather than becoming missing.
cp "$FIX/artifact-seed.json" "$SS_DIR/null-zero-phase4.json"
"$TOOLS/artifact-patch.py" --path "$SS_DIR/null-zero-phase4.json" \
    --apply-decisions '[{"id":"F001","score_phase4":null},{"id":"F002","score_phase4":0}]' \
    --expected 2 >/dev/null 2>"$SS_DIR/null-zero-phase4.err"
adn_null_zero_code=$?
adn_phase4_shape=$(jq -r '
  [
    (.findings[] | select(.id=="F001")
      | [.score_phase4, .disposition,
         ([.score_history[] | select(.phase=="phase_4")] | length)]
      | map(tostring) | join("|")),
    (.findings[] | select(.id=="F002")
      | [.score_phase4, .disposition,
         .score_history[-1].phase, .score_history[-1].score]
      | map(tostring) | join("|"))
  ] | join(";")
' "$SS_DIR/null-zero-phase4.json")
if [[ $adn_null_zero_code -eq 0 \
   && "$adn_phase4_shape" == "null|uncertain|0;0|disproven|phase_4|0" ]]; then
    pass "ADN-2: explicit null score_phase4 succeeds without history; numeric zero is preserved"
else
    fail "ADN-2: nullable/zero Phase-4 decision semantics collapsed" \
      "code=$adn_null_zero_code shape=$adn_phase4_shape err=$(cat "$SS_DIR/null-zero-phase4.err")"
fi

# RC-11: orchestrator_defaults.omp.tiers apply between defaults and user
# tiers (omp harness gets omp-native models without per-run flags)
cat > "$RC_HOME/.matthews-reviews/config.json" <<'EOF'
{"orchestrator_defaults":{"omp":{"tiers":{"deep":"omp:moonshot/kimi-k3","light":"omp:moonshot/kimi-k3"}}}}
EOF
rc_out=$(rc_run --orchestrator omp)
rc_deep=$(printf '%s' "$rc_out" | jq -r '.roles.deep_validate | "\(.engine):\(.model)|\(.source)"')
rc_util=$(printf '%s' "$rc_out" | jq -r '.roles.dedup | "\(.engine):\(.model)|\(.source)"')
if [[ "$rc_deep" == "omp:moonshot/kimi-k3|orchestrator-default(omp) (tier:deep)" \
   && "$rc_util" == "claude:sonnet|default (tier:utility)" ]]; then
    pass "RC-11: orchestrator_defaults.omp.tiers override defaults only (utility untouched)"
else
    fail "RC-11: orchestrator_defaults mismatch" "deep=$rc_deep util=$rc_util"
fi

# RC-12: omp orchestrator + claude:* roles → availability warning names the
# roles + the orchestrator_defaults fix; claude-code orchestrator warns never
cat > "$RC_HOME/.matthews-reviews/config.json" <<'EOF'
{}
EOF
rc_out=$(rc_run --orchestrator omp)
rc_warn=$(printf '%s' "$rc_out" | jq -r '.warnings[0]')
rc_out2=$(rc_run --orchestrator claude-code)
rc_warn2=$(printf '%s' "$rc_out2" | jq -r '.warnings | length')
if [[ "$rc_warn" == *"require Anthropic auth in omp"* && "$rc_warn" == *"orchestrator_defaults.omp.tiers"* && "$rc_warn2" == "0" ]]; then
    pass "RC-12: omp+claude roles produce availability warning; claude-code clean"
else
    fail "RC-12: availability warning mismatch" "warn=$rc_warn warn2=$rc_warn2"
fi

# RC-13: the canonical review-root override controls both user model config
# resolution and doctor config diagnostics.
RC_CUSTOM="$WORK/rc-custom-root"
mkdir -p "$RC_CUSTOM"
cat > "$RC_CUSTOM/config.json" <<'EOF'
{"tiers":{"deep":"claude:sonnet"}}
EOF
rc_custom_out=$(MATTHEWS_REVIEW_REVIEWS_ROOT="$RC_CUSTOM" HOME="$RC_HOME" \
    "$TOOLS/review-config.sh" --repo-root "$RC_REPO" \
    --repo-config-ref "$RC_TRUSTED_REF" --orchestrator claude-code)
rc_custom_deep=$(printf '%s' "$rc_custom_out" | jq -r \
    '.roles.deep_validate | "\(.engine):\(.model)|\(.source)"')
printf '{\n' > "$RC_CUSTOM/config.json"
rc_custom_doctor=$(MATTHEWS_REVIEW_REVIEWS_ROOT="$RC_CUSTOM" HOME="$RC_HOME" \
    "$TOOLS/doctor.sh" --quiet 2>&1); rc_custom_doctor_code=$?
if [[ "$rc_custom_deep" == "claude:sonnet|user-config (tier:deep)" \
   && $rc_custom_doctor_code -eq 5 \
   && "$rc_custom_doctor" == *"$RC_CUSTOM/config.json is not valid JSON"* ]]; then
    pass "RC-13: custom reviews root governs model config and doctor checks"
else
    fail "RC-13: custom reviews root ignored" \
      "deep=$rc_custom_deep doctor=$rc_custom_doctor_code:$rc_custom_doctor"
fi
rm -f "$RC_HOME/.matthews-reviews/config.json"

# DG-1: degraded field → renderer emits the REVIEW DEGRADED banner at the
# top of artifact.md (the published-comment loud-failure surface)
DG_DIR="$WORK/dg"
mkdir -p "$DG_DIR"
cp "$FIX/artifact-seed.json" "$DG_DIR/art.json"
"$TOOLS/artifact-patch.py" --path "$DG_DIR/art.json" \
    --set-json 'degraded={"lens_dispatch_failures":6}' >/dev/null
dg_md=$("$TOOLS/artifact-render.py" --input "$DG_DIR/art.json")
if printf '%s' "$dg_md" | head -5 | grep -q 'REVIEW DEGRADED — 6 lens dispatch' \
   && "$TOOLS/artifact-validate.sh" --path "$DG_DIR/art.json" >/dev/null 2>&1; then
    pass "DG-1: degraded field renders top-of-report banner + schema-valid"
else
    fail "DG-1: degraded banner mismatch" "$(printf '%s' "$dg_md" | head -5)"
fi

# DG-2: no banner without the field
dg_md2=$("$TOOLS/artifact-render.py" --input "$FIX/artifact-seed.json")
if ! printf '%s' "$dg_md2" | grep -q 'REVIEW DEGRADED'; then
    pass "DG-2: no banner when degraded field absent"
else
    fail "DG-2: unexpected banner on clean artifact"
fi

# DG-2b: candidate loss alone must still render a degraded warning.
cp "$FIX/artifact-seed.json" "$DG_DIR/candidate-only.json"
"$TOOLS/artifact-patch.py" --path "$DG_DIR/candidate-only.json" \
    --set-json 'degraded={"candidate_drop_failures":2}' >/dev/null
dg_candidate_md=$("$TOOLS/artifact-render.py" --input "$DG_DIR/candidate-only.json")
if printf '%s' "$dg_candidate_md" | grep -q \
    'REVIEW DEGRADED — 2 candidate output(s) dropped'; then
    pass "DG-2b: candidate-only degradation renders top-of-report banner"
else
    fail "DG-2b: candidate-only degradation rendered as clean" "$dg_candidate_md"
fi

# DG-2c: persisted reports and dispositions use Codex skill names when the
# artifact records the Codex orchestrator.
dg_codex_plan=$("$TOOLS/review-config.sh" \
    --repo-root "$REPO" --orchestrator codex)
jq --argjson plan "$dg_codex_plan" \
    '.model_plan=$plan | .gates=$plan.gates' \
    "$FIX/artifact-seed.json" > "$DG_DIR/codex.json"
dg_codex_md=$("$TOOLS/artifact-render.py" --input "$DG_DIR/codex.json")
dg_codex_dispositions=$("$TOOLS/artifact-render.py" \
    --input "$DG_DIR/codex.json" --format dispositions)
if printf '%s\n%s' "$dg_codex_md" "$dg_codex_dispositions" \
      | grep -q '\$matthewsreview-fix' \
   && ! printf '%s\n%s' "$dg_codex_md" "$dg_codex_dispositions" \
      | grep -q '/matthewsreview:'; then
    pass "DG-2c: Codex artifacts render only Codex skill command names"
else
    fail "DG-2c: Codex artifact leaked slash-command names" \
      "$dg_codex_md
$dg_codex_dispositions"
fi

# DG-3: Phase 6.4b aggregates each structured degradation class.
printf '%s\n' \
  '{"name":"detection","elapsed_sec":10,"lens_dispatch_failures":2,"candidate_drop_failures":3}' \
  '{"name":"finalize","elapsed_sec":2,"finalization_failures":1}' \
  > "$DG_DIR/phases.jsonl"
dg_counts=$(jq -cs '{
  lens: ([.[].lens_dispatch_failures // 0] | add // 0),
  candidate: ([.[].candidate_drop_failures // 0] | add // 0),
  finalization: ([.[].finalization_failures // 0] | add // 0)
}' "$DG_DIR/phases.jsonl")
if [[ $(printf '%s' "$dg_counts" | jq -r '[.lens,.candidate,.finalization] | join(",")') == "2,3,1" ]]; then
    pass "DG-3: 6.4b aggregation retains all degradation classes"
else
    fail "DG-3: degradation aggregation mismatch" "counts=$dg_counts"
fi

# DG-4: the fragments wire the failure path end-to-end (tag write site,
# Phase-1 counters/record fields, and the Phase-6 atomic sync helper).
dg_frag="$REPO/fragments/01-detection.md"
dg_fin="$REPO/fragments/07-finalize.md"
if grep -Fq 'lens_dropped_dispatch_failed: lens=<lens-tag>' "$dg_frag" \
   && grep -Fq "grep -c '^lens_dropped_dispatch_failed:'" "$dg_frag" \
   && grep -Fq 'lens_dispatch_failures:$lens_dispatch_failures' "$dg_frag" \
   && grep -Fq 'candidate_drop_failures:$candidate_drop_failures' "$dg_frag" \
   && grep -Fq 'sync-degraded.py' "$dg_fin" \
   && grep -Fq -- '--phases-log "$phases_log_path"' "$dg_fin"; then
    pass "DG-4: fragments wire dispatch and candidate failures through final aggregation"
else
    fail "DG-4: fragment degradation wiring incomplete"
fi

# RC-13: built-in defaults are harness-invariant. A Codex orchestrator
# still uses the canonical Claude Opus/Sonnet stages unless the user
# explicitly selects Codex through --models/profile/config.
rc_out=$(env -u MATTHEWS_REVIEW_REVIEWS_ROOT HOME="$RC_EMPTY" \
    "$TOOLS/review-config.sh" --repo-root "$RC_REPO" \
    --repo-config-ref "$RC_TRUSTED_REF" --orchestrator codex)
rc_deep=$(printf '%s' "$rc_out" | jq -r '.roles.deep_validate | "\(.engine):\(.model)|\(.source)"')
rc_util=$(printf '%s' "$rc_out" | jq -r '.roles.dedup | "\(.engine):\(.model)"')
rc_out2=$(env -u MATTHEWS_REVIEW_REVIEWS_ROOT HOME="$RC_EMPTY" \
    "$TOOLS/review-config.sh" --repo-root "$RC_REPO" \
    --repo-config-ref "$RC_TRUSTED_REF" --orchestrator codex \
    --models "deep=codex::high")
rc_deep2=$(printf '%s' "$rc_out2" | jq -r '.roles.deep_validate | "\(.engine):\(.model):\(.effort)"')
if [[ "$rc_deep" == "claude:opus|default (tier:deep)" \
   && "$rc_util" == "claude:sonnet" && "$rc_deep2" == "codex::high" ]]; then
    pass "RC-13: Codex keeps canonical defaults; explicit Codex override wins"
else
    fail "RC-13: harness-invariant defaults mismatch" "deep=$rc_deep util=$rc_util deep2=$rc_deep2"
fi

# RC-14: omp roles accept an omp-native thinking suffix so per-stage model
# selection can request models such as GPT-5.6-Sol Max.
rc_out=$(env -u MATTHEWS_REVIEW_REVIEWS_ROOT HOME="$RC_EMPTY" \
    "$TOOLS/review-config.sh" --repo-root "$RC_REPO" \
    --repo-config-ref "$RC_TRUSTED_REF" --orchestrator omp \
    --models "deep=omp:openai-codex/gpt-5.6-sol:max" 2>&1); code=$?
if [[ $code -eq 0 ]] \
   && [[ $(printf '%s' "$rc_out" | jq -r '.roles.deep_validate | "\(.engine):\(.model):\(.effort)"') == "omp:openai-codex/gpt-5.6-sol:max" ]]; then
    pass "RC-14: omp role accepts model thinking suffix (:max)"
else
    fail "RC-14: omp thinking suffix rejected or misparsed" "code=$code out=$rc_out"
fi

# RC-15: profiles reject misspelled tier names instead of silently ignoring
# the requested model override.
cat > "$RC_HOME/.matthews-reviews/config.json" <<'EOF'
{"profiles":{"broken":{"tiers":{"deap":"claude:opus"}}}}
EOF
rc_err=$(rc_run --orchestrator claude-code --profile broken 2>&1); code=$?
if [[ $code -eq 1 && "$rc_err" == *"unknown tier 'deap'"* && "$rc_err" == *"profile 'broken'"* ]]; then
    pass "RC-15: unknown profile tier rejected"
else
    fail "RC-15: unknown profile tier accepted or misreported" "code=$code err=$rc_err"
fi

# RC-16: resolver-side and persisted-artifact gate validation are both loud
# (GB-2/GB-3 above cover canonical artifact rejection).
cat > "$RC_HOME/.matthews-reviews/config.json" <<'EOF'
{"gates":{"phase4_bands":[70,50,90]}}
EOF
rc_gate_order=$(rc_run --orchestrator claude-code 2>&1); rc_gate_order_code=$?
cat > "$RC_HOME/.matthews-reviews/config.json" <<'EOF'
{"gates":{"phase4_bands":[45,60]}}
EOF
rc_gate_len=$(rc_run --orchestrator claude-code 2>&1); rc_gate_len_code=$?
cat > "$RC_HOME/.matthews-reviews/config.json" <<'EOF'
{"gates":{"phase3_gate":"45"}}
EOF
rc_gate_type=$(rc_run --orchestrator claude-code 2>&1); rc_gate_type_code=$?
cat > "$RC_HOME/.matthews-reviews/config.json" <<'EOF'
{"gates":{"phase3_gait":45}}
EOF
rc_gate_key=$(rc_run --orchestrator claude-code 2>&1); rc_gate_key_code=$?
rm -f "$RC_HOME/.matthews-reviews/config.json"
if [[ $rc_gate_order_code -eq 1 && "$rc_gate_order" == *"strictly ascending"* \
   && $rc_gate_len_code -eq 1 && "$rc_gate_len" == *"exactly 3"* \
   && $rc_gate_type_code -eq 1 && "$rc_gate_type" == *"number"* \
   && $rc_gate_key_code -eq 1 && "$rc_gate_key" == *"unknown gate"* ]]; then
    pass "RC-16: malformed gate keys/types/bands rejected at config resolution"
else
    fail "RC-16: malformed gates accepted or misreported" "order=$rc_gate_order_code:$rc_gate_order len=$rc_gate_len_code:$rc_gate_len type=$rc_gate_type_code:$rc_gate_type key=$rc_gate_key_code:$rc_gate_key"
fi

# RC-17: every canonical role key is accepted through the same config path;
# an unknown key still fails loudly. This catches role-set drift between
# validation and emission.
rc_role_keys='[
  "deep_lens","deep_validate","cross_cutting","fix","post_fix_review","reconcile",
  "light_lens","light_validate",
  "classifier","normalizer","dedup","scoring","fix_hint","briefer","drafter",
  "ensemble_detect","codex_detect","codex_validate","codex_crosscut"
]'
jq -n --argjson keys "$rc_role_keys" '
  def codex_only: IN("ensemble_detect","codex_detect","codex_validate","codex_crosscut");
  {roles: ($keys | map({key:., value:(if codex_only then "codex::high" else "claude:sonnet" end)}) | from_entries)}
' > "$RC_HOME/.matthews-reviews/config.json"
rc_roles_out=$(rc_run --orchestrator claude-code 2>&1); rc_roles_code=$?
rc_roles_count=$(printf '%s' "$rc_roles_out" | jq '.roles | length' 2>/dev/null || echo 0)
rc_roles_overridden=$(printf '%s' "$rc_roles_out" \
  | jq '[.roles[] | select(.engine == "claude" and .model == "sonnet")] | length' \
    2>/dev/null || echo 0)
rc_roles_repo_light=$(printf '%s' "$rc_roles_out" \
  | jq '[.roles[] | select(.engine == "claude" and .model == "haiku")] | length' \
    2>/dev/null || echo 0)
rc_roles_codex=$(printf '%s' "$rc_roles_out" \
  | jq '[.roles[] | select(.engine == "codex" and .effort == "high")] | length' \
    2>/dev/null || echo 0)
cat > "$RC_HOME/.matthews-reviews/config.json" <<'EOF'
{"roles":{"future_typo":"claude:sonnet"}}
EOF
rc_unknown_role=$(rc_run --orchestrator claude-code 2>&1); rc_unknown_role_code=$?
rm -f "$RC_HOME/.matthews-reviews/config.json"
if [[ $rc_roles_code -eq 0 && "$rc_roles_count" == "19" \
   && "$rc_roles_overridden" == "13" && "$rc_roles_repo_light" == "2" \
   && "$rc_roles_codex" == "4" \
   && $rc_unknown_role_code -eq 1 && "$rc_unknown_role" == *"unknown role 'future_typo'"* ]]; then
    pass "RC-17: canonical role set validates and emits through one path"
else
    fail "RC-17: role-set validation/emission drift" "valid=$rc_roles_code count=$rc_roles_count claude=$rc_roles_overridden repo_light=$rc_roles_repo_light codex=$rc_roles_codex unknown=$rc_unknown_role_code:$rc_unknown_role"
fi

# RCG-1: accepted suffixes are exact enums, not prefix/substring matches.
rc_enum_problems=""
for rc_effort in low medium high xhigh max ultra; do
    rc_enum_out=$(rc_run --orchestrator claude-code \
        --models "deep=codex:model:$rc_effort" \
        2>"$WORK/rc-enum-codex-$rc_effort.err")
    rc_enum_code=$?
    rc_enum_got=$(printf '%s' "$rc_enum_out" | jq -r \
        '.roles.deep_validate.effort // "missing"' 2>/dev/null)
    if [[ $rc_enum_code -ne 0 || "$rc_enum_got" != "$rc_effort" ]]; then
        rc_enum_problems="$rc_enum_problems codex:$rc_effort=$rc_enum_code:$rc_enum_got:$(cat "$WORK/rc-enum-codex-$rc_effort.err")"
    fi
done
for rc_thinking in off minimal low medium high xhigh max; do
    rc_enum_out=$(rc_run --orchestrator omp \
        --models "deep=omp:vendor/model:$rc_thinking" \
        2>"$WORK/rc-enum-omp-$rc_thinking.err")
    rc_enum_code=$?
    rc_enum_got=$(printf '%s' "$rc_enum_out" | jq -r \
        '.roles.deep_validate.effort // "missing"' 2>/dev/null)
    if [[ $rc_enum_code -ne 0 || "$rc_enum_got" != "$rc_thinking" ]]; then
        rc_enum_problems="$rc_enum_problems omp:$rc_thinking=$rc_enum_code:$rc_enum_got:$(cat "$WORK/rc-enum-omp-$rc_thinking.err")"
    fi
done
rc_empty_model=$(rc_run --orchestrator claude-code \
    --models 'deep=codex::high' 2>"$WORK/rc-enum-empty-model.err")
rc_empty_model_code=$?
rc_empty_model_shape=$(printf '%s' "$rc_empty_model" | jq -r \
    '.roles.deep_validate | "\(.engine)|\(.model)|\(.effort)"' 2>/dev/null)
if [[ -z "$rc_enum_problems" && $rc_empty_model_code -eq 0 \
   && "$rc_empty_model_shape" == "codex||high" ]]; then
    pass "RCG-1: exact Codex effort/OMP thinking enums and codex::high resolve"
else
    fail "RCG-1: accepted role-string enum drift" \
      "problems=$rc_enum_problems empty=$rc_empty_model_code:$rc_empty_model_shape:$(cat "$WORK/rc-enum-empty-model.err")"
fi

# RCG-2: every explicit-but-empty third segment is malformed, even where an
# empty Codex model itself would otherwise be legal.
rc_empty_suffix_problems=""
rc_empty_suffix_n=0
for rc_empty_suffix in 'claude:opus:' 'codex:model:' 'codex::' 'omp:model:'; do
    rc_empty_suffix_n=$((rc_empty_suffix_n + 1))
    rc_empty_suffix_out=$(rc_run --orchestrator claude-code \
        --models "deep=$rc_empty_suffix" \
        2>"$WORK/rc-empty-suffix-$rc_empty_suffix_n.err")
    rc_empty_suffix_code=$?
    if [[ $rc_empty_suffix_code -ne 1 || -n "$rc_empty_suffix_out" \
       || "$(cat "$WORK/rc-empty-suffix-$rc_empty_suffix_n.err")" != *"has an empty third segment"* ]]; then
        rc_empty_suffix_problems="$rc_empty_suffix_problems $rc_empty_suffix=$rc_empty_suffix_code:$rc_empty_suffix_out:$(cat "$WORK/rc-empty-suffix-$rc_empty_suffix_n.err")"
    fi
done
if [[ -z "$rc_empty_suffix_problems" ]]; then
    pass "RCG-2: Claude/Codex/OMP empty third segments reject without plan output"
else
    fail "RCG-2: empty suffix accepted or misreported" "$rc_empty_suffix_problems"
fi

# RCG-3: joined and whitespace-padded near misses do not pass exact enums.
rc_bad_enum_problems=""
for rc_bad_enum_case in codex-joined codex-space omp-joined omp-space; do
    case "$rc_bad_enum_case" in
        codex-joined)
            rc_bad_enum_orch=claude-code
            rc_bad_enum_spec='codex:model:highest'
            rc_bad_enum_needle="unknown codex effort 'highest'"
            ;;
        codex-space)
            rc_bad_enum_orch=claude-code
            rc_bad_enum_spec='codex:model:high '
            rc_bad_enum_needle="unknown codex effort 'high '"
            ;;
        omp-joined)
            rc_bad_enum_orch=omp
            rc_bad_enum_spec='omp:vendor/model:maximal'
            rc_bad_enum_needle="unknown omp thinking level 'maximal'"
            ;;
        omp-space)
            rc_bad_enum_orch=omp
            rc_bad_enum_spec='omp:vendor/model:max '
            rc_bad_enum_needle="unknown omp thinking level 'max '"
            ;;
    esac
    rc_bad_enum_out=$(rc_run --orchestrator "$rc_bad_enum_orch" \
        --models "deep=$rc_bad_enum_spec" \
        2>"$WORK/rc-$rc_bad_enum_case.err")
    rc_bad_enum_code=$?
    if [[ $rc_bad_enum_code -ne 1 || -n "$rc_bad_enum_out" \
       || "$(cat "$WORK/rc-$rc_bad_enum_case.err")" != *"$rc_bad_enum_needle"* ]]; then
        rc_bad_enum_problems="$rc_bad_enum_problems $rc_bad_enum_case=$rc_bad_enum_code:$rc_bad_enum_out:$(cat "$WORK/rc-$rc_bad_enum_case.err")"
    fi
done
if [[ -z "$rc_bad_enum_problems" ]]; then
    pass "RCG-3: joined/whitespace Codex and OMP suffix near-misses reject exactly"
else
    fail "RCG-3: suffix enum matching is permissive" "$rc_bad_enum_problems"
fi

# RCG-4: malformed values are rejected even when dormant in an unselected
# profile/inactive harness default or masked by a higher-precedence repo value.
rc_dormant_bad_problems=""
for rc_dormant_case in profile inactive-default masked-user; do
    case "$rc_dormant_case" in
        profile)
            rc_dormant_json='{"profiles":{"later":{"roles":{"deep_validate":"unknown:model"}}}}'
            ;;
        inactive-default)
            rc_dormant_json='{"orchestrator_defaults":{"omp":{"tiers":{"deep":"unknown:model"}}}}'
            ;;
        masked-user)
            rc_dormant_json='{"roles":{"scoring":"unknown:model"}}'
            ;;
    esac
    printf '%s\n' "$rc_dormant_json" \
        > "$RC_HOME/.matthews-reviews/config.json"
    rc_dormant_out=$(rc_run --orchestrator claude-code \
        2>"$WORK/rc-dormant-$rc_dormant_case.err")
    rc_dormant_code=$?
    if [[ $rc_dormant_code -ne 1 || -n "$rc_dormant_out" \
       || "$(cat "$WORK/rc-dormant-$rc_dormant_case.err")" != *"unknown engine 'unknown'"* ]]; then
        rc_dormant_bad_problems="$rc_dormant_bad_problems $rc_dormant_case=$rc_dormant_code:$rc_dormant_out:$(cat "$WORK/rc-dormant-$rc_dormant_case.err")"
    fi
done
if [[ -z "$rc_dormant_bad_problems" ]]; then
    pass "RCG-4: malformed dormant/masked role values reject before plan emission"
else
    fail "RCG-4: dormant malformed role escaped validation" "$rc_dormant_bad_problems"
fi

# RCG-5: syntactically valid cross-harness roles remain dormant until selected
# or effective. This keeps portable profiles/configs storable without weakening
# the effective harness compatibility gate.
cat > "$RC_HOME/.matthews-reviews/config.json" <<'EOF'
{"profiles":{"later":{"tiers":{"deep":"omp:vendor/model:max"}}},"orchestrator_defaults":{"omp":{"tiers":{"light":"omp:vendor/model:high"}}}}
EOF
rc_dormant_claude=$(rc_run --orchestrator claude-code \
    2>"$WORK/rc-dormant-valid-claude.err")
rc_dormant_claude_code=$?
rc_dormant_codex=$(rc_run --orchestrator codex \
    2>"$WORK/rc-dormant-valid-codex.err")
rc_dormant_codex_code=$?
rc_selected_cross=$(rc_run --orchestrator claude-code --profile later \
    2>"$WORK/rc-selected-cross.err")
rc_selected_cross_code=$?
cat > "$RC_HOME/.matthews-reviews/config.json" <<'EOF'
{"roles":{"deep_validate":"omp:vendor/model:max"}}
EOF
rc_masked_cross=$(rc_run --orchestrator claude-code \
    --models 'deep_validate=claude:opus' 2>"$WORK/rc-masked-cross.err")
rc_masked_cross_code=$?
rc_effective_cross=$(rc_run --orchestrator claude-code \
    2>"$WORK/rc-effective-cross.err")
rc_effective_cross_code=$?
if [[ $rc_dormant_claude_code -eq 0 && -n "$rc_dormant_claude" \
   && $rc_dormant_codex_code -eq 0 && -n "$rc_dormant_codex" \
   && $rc_selected_cross_code -eq 1 && -z "$rc_selected_cross" \
   && "$(cat "$WORK/rc-selected-cross.err")" == *"wants omp:... but the orchestrator is Claude Code"* \
   && $rc_masked_cross_code -eq 0 && -n "$rc_masked_cross" \
   && $rc_effective_cross_code -eq 1 && -z "$rc_effective_cross" \
   && "$(cat "$WORK/rc-effective-cross.err")" == *"wants omp:... but the orchestrator is Claude Code"* ]]; then
    pass "RCG-5: valid cross-harness roles are storable when dormant/masked and reject when effective"
else
    fail "RCG-5: dormant/effective cross-harness boundary mismatch" \
      "dormant-claude=$rc_dormant_claude_code:$(cat "$WORK/rc-dormant-valid-claude.err") dormant-codex=$rc_dormant_codex_code:$(cat "$WORK/rc-dormant-valid-codex.err") selected=$rc_selected_cross_code:$rc_selected_cross:$(cat "$WORK/rc-selected-cross.err") masked=$rc_masked_cross_code:$(cat "$WORK/rc-masked-cross.err") effective=$rc_effective_cross_code:$rc_effective_cross:$(cat "$WORK/rc-effective-cross.err")"
fi

# RCG-6: pipe, C0/C1 controls, and Unicode line/paragraph separators are
# rejected in persisted user/repo specs and CLI model specs, always before a
# plan reaches stdout.
rc_unsafe_problems=""
for rc_unsafe_case in pipe c0 c1 u2028 u2029; do
    case "$rc_unsafe_case" in
        pipe)
            rc_unsafe_json='{"profiles":{"later":{"tiers":{"deep":"claude:op|us"}}}}'
            rc_unsafe_cli='deep=claude:op|us'
            ;;
        c0)
            rc_unsafe_json='{"profiles":{"later":{"tiers":{"deep":"claude:op\u0001us"}}}}'
            rc_unsafe_cli=$(printf 'deep=claude:op\001us')
            ;;
        c1)
            rc_unsafe_json='{"profiles":{"later":{"tiers":{"deep":"claude:op\u0085us"}}}}'
            rc_unsafe_cli=$(printf 'deep=claude:op\302\205us')
            ;;
        u2028)
            rc_unsafe_json='{"profiles":{"later":{"tiers":{"deep":"claude:op\u2028us"}}}}'
            rc_unsafe_cli=$(printf 'deep=claude:op\342\200\250us')
            ;;
        u2029)
            rc_unsafe_json='{"profiles":{"later":{"tiers":{"deep":"claude:op\u2029us"}}}}'
            rc_unsafe_cli=$(printf 'deep=claude:op\342\200\251us')
            ;;
    esac
    printf '%s\n' "$rc_unsafe_json" \
        > "$RC_HOME/.matthews-reviews/config.json"
    rc_unsafe_user_out=$(rc_run --orchestrator claude-code \
        2>"$WORK/rc-unsafe-user-$rc_unsafe_case.err")
    rc_unsafe_user_code=$?
    printf '%s\n' "$rc_unsafe_json" > "$RC_REPO/.matthewsreview.json"
    printf '%s\n' '{}' > "$RC_HOME/.matthews-reviews/config.json"
    rc_unsafe_repo_out=$(rc_run_worktree --orchestrator claude-code \
        2>"$WORK/rc-unsafe-repo-$rc_unsafe_case.err")
    rc_unsafe_repo_code=$?
    printf '%s\n' "$RC_WORKTREE_CONFIG" > "$RC_REPO/.matthewsreview.json"
    rc_unsafe_cli_out=$(rc_run --orchestrator claude-code \
        --models "$rc_unsafe_cli" \
        2>"$WORK/rc-unsafe-cli-$rc_unsafe_case.err")
    rc_unsafe_cli_code=$?
    if [[ $rc_unsafe_user_code -ne 1 || -n "$rc_unsafe_user_out" \
       || "$(cat "$WORK/rc-unsafe-user-$rc_unsafe_case.err")" != *"reserved delimiter or control character"* \
       || $rc_unsafe_repo_code -ne 1 || -n "$rc_unsafe_repo_out" \
       || "$(cat "$WORK/rc-unsafe-repo-$rc_unsafe_case.err")" != *"reserved delimiter or control character"* \
       || $rc_unsafe_cli_code -ne 1 || -n "$rc_unsafe_cli_out" \
       || "$(cat "$WORK/rc-unsafe-cli-$rc_unsafe_case.err")" != *"reserved delimiter or control character"* ]]; then
        rc_unsafe_problems="$rc_unsafe_problems $rc_unsafe_case=user:$rc_unsafe_user_code:$rc_unsafe_user_out:$(cat "$WORK/rc-unsafe-user-$rc_unsafe_case.err");repo:$rc_unsafe_repo_code:$rc_unsafe_repo_out:$(cat "$WORK/rc-unsafe-repo-$rc_unsafe_case.err");cli:$rc_unsafe_cli_code:$rc_unsafe_cli_out:$(cat "$WORK/rc-unsafe-cli-$rc_unsafe_case.err")"
    fi
done
rm -f "$RC_HOME/.matthews-reviews/config.json"
printf '%s\n' "$RC_WORKTREE_CONFIG" > "$RC_REPO/.matthewsreview.json"
if [[ -z "$rc_unsafe_problems" ]]; then
    pass "RCG-6: persisted/CLI pipe, C0, C1, U+2028, and U+2029 specs emit no plan"
else
    fail "RCG-6: unsafe internal delimiter escaped config validation" "$rc_unsafe_problems"
fi

# RCP-1: present config paths must be readable regular files before any JSON
# reader touches them. Cover a user-config directory and an explicit-worktree
# broken symlink; both fail structured with no plan output.
RC_SHAPE_ROOT="$WORK/rc-shape-root"
mkdir -p "$RC_SHAPE_ROOT/config.json"
RC_SHAPE_ROOT_CANON=$(cd "$RC_SHAPE_ROOT" && pwd -P)
rc_shape_user_out=$(MATTHEWS_REVIEW_REVIEWS_ROOT="$RC_SHAPE_ROOT" \
    HOME="$RC_HOME" "$TOOLS/review-config.sh" --repo-root "$RC_REPO" \
    --repo-config-ref "$RC_TRUSTED_REF" --orchestrator claude-code \
    2>"$WORK/rc-shape-user.err")
rc_shape_user_code=$?
rm -f "$RC_REPO/.matthewsreview.json"
ln -s "$WORK/does-not-exist.json" "$RC_REPO/.matthewsreview.json"
rc_shape_worktree_out=$(rc_run_worktree --orchestrator claude-code \
    2>"$WORK/rc-shape-worktree.err")
rc_shape_worktree_code=$?
rm -f "$RC_REPO/.matthewsreview.json"
printf '%s\n' "$RC_WORKTREE_CONFIG" > "$RC_REPO/.matthewsreview.json"
if [[ $rc_shape_user_code -eq 1 && -z "$rc_shape_user_out" \
   && "$(cat "$WORK/rc-shape-user.err")" == *"config path $RC_SHAPE_ROOT_CANON/config.json is not a readable regular file"* \
   && "$(cat "$WORK/rc-shape-user.err")" == *"Action:"* \
   && $rc_shape_worktree_code -eq 1 && -z "$rc_shape_worktree_out" \
   && "$(cat "$WORK/rc-shape-worktree.err")" == *"config path $RC_REPO/.matthewsreview.json is not a readable regular file"* \
   && "$(cat "$WORK/rc-shape-worktree.err")" == *"Action:"* ]]; then
    pass "RCP-1: user directory and worktree broken-symlink configs reject before read"
else
    fail "RCP-1: non-regular config path was read or emitted a plan" \
      "user=$rc_shape_user_code:$rc_shape_user_out:$(cat "$WORK/rc-shape-user.err") worktree=$rc_shape_worktree_code:$rc_shape_worktree_out:$(cat "$WORK/rc-shape-worktree.err")"
fi

# DOC-1: repository settings are rooted at git top-level even when doctor is
# launched deep below it.
DOC_DIR="$WORK/doctor-streams"
DOC_REPO="$DOC_DIR/repo"
DOC_HOME="$DOC_DIR/home"
DOC_REVIEWS="$DOC_HOME/reviews"
DOC_BIN_OK="$DOC_DIR/bin-ok"
DOC_BIN_FAIL="$DOC_DIR/bin-fail"
mkdir -p "$DOC_REPO/nested/deeper" "$DOC_REPO/.claude" "$DOC_REVIEWS" \
    "$DOC_BIN_OK" "$DOC_BIN_FAIL"
git -C "$DOC_REPO" init -q
printf '%s\n' '{"enabledPlugins":{"adamsreview@adamsreview":true}}' \
    > "$DOC_REPO/.claude/settings.json"
printf '%s\n' '{"permissions":{"allow":["plugins/cache/adamsreview/1/bin"]}}' \
    > "$DOC_REPO/.claude/settings.local.json"
ln -s /bin/bash "$DOC_BIN_OK/bash"
ln -s /bin/bash "$DOC_BIN_FAIL/bash"
for doc_tool in dirname jq gh git uname env grep cut tr sed head; do
    doc_tool_path=$(type -P "$doc_tool")
    ln -s "$doc_tool_path" "$DOC_BIN_OK/$doc_tool"
    ln -s "$doc_tool_path" "$DOC_BIN_FAIL/$doc_tool"
done
ln -s "$(type -P uv)" "$DOC_BIN_OK/uv"
(
    cd "$DOC_REPO/nested/deeper" || exit 1
    HOME="$DOC_HOME" MATTHEWS_REVIEW_REVIEWS_ROOT="$DOC_REVIEWS" \
        PATH="$DOC_BIN_OK" "$TOOLS/doctor.sh" --quiet
) >"$DOC_DIR/nested.out" 2>"$DOC_DIR/nested.err"
doc_nested_code=$?
doc_nested_out=$(cat "$DOC_DIR/nested.out")
if [[ $doc_nested_code -eq 0 && ! -s "$DOC_DIR/nested.err" \
   && "$doc_nested_out" == *"$DOC_REPO/.claude/settings.json enables adamsreview@adamsreview"* \
   && "$doc_nested_out" == *"$DOC_REPO/.claude/settings.local.json allowlists a versioned adamsreview cache path"* \
   && "$doc_nested_out" != *"$DOC_REPO/nested/deeper/.claude/"* ]]; then
    pass "DOC-1: nested-cwd doctor inspects repo-root settings and settings.local"
else
    fail "DOC-1: doctor derived settings paths from nested cwd" \
      "code=$doc_nested_code out=$doc_nested_out err=$(cat "$DOC_DIR/nested.err")"
fi

# DOC-2: detailed FAIL/fix guidance is stdout; stderr contains exactly one
# aggregate ERROR/Action block for hook-safe failure reporting.
(
    cd "$DOC_REPO/nested/deeper" || exit 1
    HOME="$DOC_HOME" MATTHEWS_REVIEW_REVIEWS_ROOT="$DOC_REVIEWS" \
        PATH="$DOC_BIN_FAIL" "$TOOLS/doctor.sh" --quiet
) >"$DOC_DIR/fail.out" 2>"$DOC_DIR/fail.err"
doc_fail_code=$?
doc_error_count=$(grep -c \
    '^ERROR: doctor found one or more required dependency or configuration failures\.$' \
    "$DOC_DIR/fail.err")
doc_action_count=$(grep -c \
    '^Action: apply each FAIL/fix item above, then rerun doctor\.sh\.$' \
    "$DOC_DIR/fail.err")
doc_stderr_lines=$(wc -l < "$DOC_DIR/fail.err")
if [[ $doc_fail_code -eq 5 && $doc_error_count -eq 1 \
   && $doc_action_count -eq 1 && $doc_stderr_lines -eq 2 \
   && $(grep -c '^FAIL dep: uv missing$' "$DOC_DIR/fail.out") -eq 1 \
   && $(grep -c '^      fix:' "$DOC_DIR/fail.out") -ge 1 \
   && $(grep -c '^ERROR:\|^Action:' "$DOC_DIR/fail.out") -eq 0 \
   && $(grep -c '^FAIL\|^      fix:' "$DOC_DIR/fail.err") -eq 0 ]]; then
    pass "DOC-2: doctor details stay stdout; stderr is one aggregate ERROR/Action block"
else
    fail "DOC-2: doctor failure streams/counts regressed" \
      "code=$doc_fail_code errors=$doc_error_count actions=$doc_action_count stderr_lines=$doc_stderr_lines out=$(cat "$DOC_DIR/fail.out") err=$(cat "$DOC_DIR/fail.err")"
fi

# DOC-3: doctor performs its own path-shape check before semantic resolution.
# A directory at config.json cannot block a reader and still aggregates as rc5.
DOC_BAD_REVIEWS="$DOC_HOME/bad-reviews"
mkdir -p "$DOC_BAD_REVIEWS/config.json"
DOC_BAD_REVIEWS_CANON=$(cd "$DOC_BAD_REVIEWS" && pwd -P)
(
    cd "$DOC_REPO/nested/deeper" || exit 1
    HOME="$DOC_HOME" MATTHEWS_REVIEW_REVIEWS_ROOT="$DOC_BAD_REVIEWS" \
        PATH="$DOC_BIN_OK" "$TOOLS/doctor.sh" --quiet
) >"$DOC_DIR/path-shape.out" 2>"$DOC_DIR/path-shape.err"
doc_path_code=$?
doc_path_errors=$(grep -c \
    '^ERROR: doctor found one or more required dependency or configuration failures\.$' \
    "$DOC_DIR/path-shape.err")
doc_path_actions=$(grep -c \
    '^Action: apply each FAIL/fix item above, then rerun doctor\.sh\.$' \
    "$DOC_DIR/path-shape.err")
if [[ $doc_path_code -eq 5 && $doc_path_errors -eq 1 \
   && $doc_path_actions -eq 1 \
   && "$(cat "$DOC_DIR/path-shape.out")" == *"FAIL config: $DOC_BAD_REVIEWS_CANON/config.json is not a readable regular file"* \
   && "$(cat "$DOC_DIR/path-shape.out")" == *"fix: replace $DOC_BAD_REVIEWS_CANON/config.json with a readable JSON configuration file"* \
   && $(wc -l < "$DOC_DIR/path-shape.err") -eq 2 ]]; then
    pass "DOC-3: non-regular config is checked without blocking and aggregates rc5"
else
    fail "DOC-3: doctor path-shape check/aggregate regressed" \
      "code=$doc_path_code errors=$doc_path_errors actions=$doc_path_actions out=$(cat "$DOC_DIR/path-shape.out") err=$(cat "$DOC_DIR/path-shape.err")"
fi

# ------------------------------------------------------------------ Project F: LLM output normalization
#
# Three helpers attack three distinct LLM-output-shape problems:
#   PR-* — parse-with-repair.py (tolerant JSON parse, foundation)
#   VR-* — parse-validator-result.py (Phase 4 score/shape normalizer)
#   SF-* — source-family-map.py (Phase 1 lens-family canonicalizer)
# Plus PF-INT-* for fragment integration proof.

# --- PR-* parse-with-repair.py

# PR-1: trailing-comma input → repaired to valid JSON.
pr1_out=$(echo '{"a": 1, "b": 2,}' | "$TOOLS/parse-with-repair.py" 2>&1)
if [[ $? -eq 0 ]] && echo "$pr1_out" | jq -e '.a == 1 and .b == 2' >/dev/null; then
    pass "PR-1: trailing-comma input repaired"
else
    fail "PR-1: trailing-comma repair failed" "$pr1_out"
fi

# PR-2: ```json ... ``` fence-wrapped input → fences stripped.
pr2_out=$(printf '```json\n{"x": "y"}\n```\n' | "$TOOLS/parse-with-repair.py" 2>&1)
if [[ $? -eq 0 ]] && echo "$pr2_out" | jq -e '.x == "y"' >/dev/null; then
    pass 'PR-2: code-fence (```json) stripped'
else
    fail "PR-2: fence-strip failed" "$pr2_out"
fi

# PR-3: single-quoted strings → repaired.
pr3_out=$(echo "{'a': 'hello'}" | "$TOOLS/parse-with-repair.py" 2>&1)
if [[ $? -eq 0 ]] && echo "$pr3_out" | jq -e '.a == "hello"' >/dev/null; then
    pass "PR-3: single-quoted strings repaired"
else
    fail "PR-3: single-quote repair failed" "$pr3_out"
fi

# PR-4: unrecoverable garbage → exit 1 with error-as-prompt.
pr4_out=$(echo "not json at all" | "$TOOLS/parse-with-repair.py" 2>&1)
pr4_exit=$?
if [[ $pr4_exit -eq 1 ]] && echo "$pr4_out" | grep -qF "ERROR: could not parse"; then
    pass "PR-4: unrecoverable input → exit 1 + error-as-prompt"
else
    fail "PR-4: expected exit 1 with ERROR line; exit=$pr4_exit" "$pr4_out"
fi

# PR-5: empty stdin → exit 1 (distinct from parse-failure exit 1 but same code).
pr5_out=$(printf '' | "$TOOLS/parse-with-repair.py" 2>&1)
if [[ $? -eq 1 ]] && echo "$pr5_out" | grep -qF "empty input on stdin"; then
    pass "PR-5: empty stdin → exit 1 + specific error"
else
    fail "PR-5: empty-stdin handling" "$pr5_out"
fi

# --- VR-* parse-validator-result.py

# VR-1: canonical shape — {score_phase4, actionability} passes through.
# confirmed_strength is deliberately absent: artifact-patch derives it from
# the run's resolved phase4_bands, not the normalizer's default bands.
vr1_out=$(echo '{"score_phase4": 72, "actionability": "auto_fixable", "decision": "confirmed"}' \
    | "$TOOLS/parse-validator-result.py" --lane deep 2>&1)
if [[ $? -eq 0 ]] \
    && printf '%s\n' "$vr1_out" | jq -e '.score_phase4 == 72 and .actionability == "auto_fixable" and (has("confirmed_strength") | not)' >/dev/null; then
    pass "VR-1: canonical {score_phase4,actionability} pass-through without derived strength"
else
    fail "VR-1: canonical shape failed" "$vr1_out"
fi

# VR-2: nested shape — {score:{correctness:N}}.
vr2_out=$(echo '{"score": {"correctness": 55}, "actionability": "manual"}' \
    | "$TOOLS/parse-validator-result.py" --lane deep 2>&1)
if [[ $? -eq 0 ]] \
    && printf '%s\n' "$vr2_out" | jq -e '.score_phase4 == 55 and .actionability == "manual" and (has("confirmed_strength") | not)' >/dev/null; then
    pass "VR-2: nested score.correctness extracted without strength hint"
else
    fail "VR-2: nested shape failed" "$vr2_out"
fi

# VR-3: 1-5 scale via overall_numeric.
vr3_out=$(echo '{"overall_numeric": 3.5}' \
    | "$TOOLS/parse-validator-result.py" --lane light 2>&1)
if [[ $? -eq 0 ]] \
    && echo "$vr3_out" | jq -e '.score_phase4 == 70 and (.notes | contains("scale_inferred"))' >/dev/null; then
    pass "VR-3: 1-5 overall_numeric scaled (*20) + scale_inferred in notes"
else
    fail "VR-3: overall_numeric scaling failed" "$vr3_out"
fi

# VR-4: severity string maps to bucket.
vr4_out=$(echo '{"severity": "medium", "actionability": "manual"}' \
    | "$TOOLS/parse-validator-result.py" --lane light 2>&1)
if [[ $? -eq 0 ]] \
    && echo "$vr4_out" | jq -e '.score_phase4 == 60 and (.notes | contains("severity=medium"))' >/dev/null; then
    pass "VR-4: severity=medium → 60 (scale_inferred noted)"
else
    fail "VR-4: severity mapping failed" "$vr4_out"
fi

# VR-5: ambiguous {score: 6} → heuristic 1-10 (*10).
vr5_out=$(echo '{"score": 6}' \
    | "$TOOLS/parse-validator-result.py" --lane light 2>&1)
if [[ $? -eq 0 ]] \
    && echo "$vr5_out" | jq -e '.score_phase4 == 60 and (.notes | contains("1-10"))' >/dev/null; then
    pass "VR-5: ambiguous {score: 6} heuristic (1-10 *10)"
else
    fail "VR-5: ambiguous-score heuristic failed" "$vr5_out"
fi

# VR-6: malformed input → exit 2 (score unrecoverable).
vr6_out=$(echo 'garbage' | "$TOOLS/parse-validator-result.py" --lane deep 2>&1)
vr6_exit=$?
if [[ $vr6_exit -eq 2 ]] && echo "$vr6_out" | grep -qF "ERROR:"; then
    pass "VR-6: malformed input → exit 2 + error-as-prompt"
else
    fail "VR-6: expected exit 2 on malformed; got $vr6_exit" "$vr6_out"
fi

# VR-7: deep-lane validation_result passthrough. Post-VR-10 the helper
# schema-checks vr against #/$defs/validation_result, so this fixture is
# a fully-shaped object (the old stub {"blast_radius": {}} pattern would
# now route to vr=null — correctly — and is covered by VR-10).
vr7_out=$(echo '{"score_phase4": 80, "actionability": "auto_fixable", "decision": "confirmed", "validation_result": {"evidence": ["e1"], "blast_radius": {"writers": [], "consumers": [], "parallel_paths": [], "invariants_at_stake": []}, "fix_proposal": {"approach": "x", "files_to_modify": []}, "verification_context": {"how_to_verify_fix": [], "edge_cases_to_preserve": [], "what_would_break_if_incomplete": []}}}' \
    | "$TOOLS/parse-validator-result.py" --lane deep 2>&1)
if [[ $? -eq 0 ]] \
    && printf '%s\n' "$vr7_out" | jq -e '.validation_result.evidence[0] == "e1" and (has("confirmed_strength") | not)' >/dev/null; then
    pass "VR-7: deep-lane validation_result passthrough without strength hint"
else
    fail "VR-7: deep-lane passthrough failed" "$vr7_out"
fi

# VR-8: precedence — out-of-band score_phase4 + out-of-band overall_numeric.
# Section A stashes the out-of-range score_phase4 (150) as the heuristic
# candidate; Section C must NOT overwrite that with its own out-of-band
# overall_numeric (7.5). Expected: heuristic rejects 150 → exit 2.
# Pre-fix (bug): C silently overwrote A, heuristic scaled 7.5 → 75 and
# exit 0 fabricated a confirmed_mechanical disposition.
vr8_out=$(echo '{"score_phase4": 150, "overall_numeric": 7.5}' \
    | "$TOOLS/parse-validator-result.py" --lane deep 2>&1)
vr8_exit=$?
if [[ $vr8_exit -eq 2 ]] && echo "$vr8_out" | grep -qF "ERROR: cannot coerce score to 0-100"; then
    pass "VR-8: out-of-band score_phase4 + out-of-band overall_numeric → exit 2 (A precedes C)"
else
    fail "VR-8: expected exit 2 on double-out-of-band; got $vr8_exit" "$vr8_out"
fi

# VR-9: in-band score_phase4 still wins over out-of-band overall_numeric.
# Section A's canonical-range return happens before Section C runs, so
# the guard added in VR-8's fix doesn't regress the common case.
vr9_out=$(echo '{"score_phase4": 72, "overall_numeric": 7.5}' \
    | "$TOOLS/parse-validator-result.py" --lane deep 2>&1)
if [[ $? -eq 0 ]] \
    && printf '%s\n' "$vr9_out" | jq -e '.score_phase4 == 72 and (has("confirmed_strength") | not)' >/dev/null; then
    pass "VR-9: in-band score_phase4 wins without strength hint"
else
    fail "VR-9: in-band score_phase4 precedence failed" "$vr9_out"
fi

# VR-10: deep-lane drifted validation_result is schema-checked and dropped
# to null with a "shape unrecoverable" note, rather than passing through
# malformed (F005-drift case: files_planned/sketch/risk/alternative_rejected
# instead of the schema's evidence/blast_radius/fix_proposal/verification_context
# shape). This prevents the downstream --apply-decisions batch-halt that
# the stage-4 regression surfaced.
vr10_out=$(echo '{"score_phase4": 80, "actionability": "auto_fixable", "decision": "confirmed", "validation_result": {"files_planned": ["a"], "sketch": "x", "risk": "r", "alternative_rejected": "alt"}}' \
    | "$TOOLS/parse-validator-result.py" --lane deep 2>&1)
if [[ $? -eq 0 ]] \
    && echo "$vr10_out" | jq -e '.validation_result == null and (.notes | contains("validation_result shape unrecoverable"))' >/dev/null; then
    pass "VR-10: drifted deep-lane validation_result → null + shape-unrecoverable note"
else
    fail "VR-10: expected vr=null + note on drift" "$vr10_out"
fi

# VR-11: valid deep-lane validation_result passes schema check and
# passes through unchanged — ensures VR-10's guard didn't break the
# happy path. Uses fully-shaped sub-objects so every required key is
# present per schema-v1.json#/$defs/validation_result.
vr11_out=$(echo '{"score_phase4": 72, "actionability": "auto_fixable", "decision": "confirmed", "validation_result": {"evidence": ["file:12 — observation"], "blast_radius": {"writers": ["a.py:1"], "consumers": [], "parallel_paths": [], "invariants_at_stake": []}, "fix_proposal": {"approach": "fix x", "files_to_modify": [{"file":"a.py","what":"change","why":"required"}]}, "verification_context": {"how_to_verify_fix": ["grep x"], "edge_cases_to_preserve": [], "what_would_break_if_incomplete": []}}}' \
    | "$TOOLS/parse-validator-result.py" --lane deep 2>&1)
if [[ $? -eq 0 ]] \
    && echo "$vr11_out" | jq -e '.validation_result.evidence[0] == "file:12 — observation" and .validation_result.fix_proposal.approach == "fix x" and (.notes | contains("shape unrecoverable") | not)' >/dev/null; then
    pass "VR-11: valid deep-lane validation_result passes through unchanged"
else
    fail "VR-11: valid vr failed to pass through" "$vr11_out"
fi

# VR-12: top-level lift still fires when validation_result is absent but
# the raw carries evidence/blast_radius/fix_proposal/verification_context
# at the top level (legitimate recoverable shape drift). The lift runs
# BEFORE the schema check, so a well-shaped lift still reaches the
# passthrough without a "shape unrecoverable" note.
vr12_out=$(echo '{"score_phase4": 72, "actionability": "auto_fixable", "decision": "confirmed", "evidence": ["x"], "blast_radius": {"writers": [], "consumers": [], "parallel_paths": [], "invariants_at_stake": []}, "fix_proposal": {"approach": "x", "files_to_modify": []}, "verification_context": {"how_to_verify_fix": [], "edge_cases_to_preserve": [], "what_would_break_if_incomplete": []}}' \
    | "$TOOLS/parse-validator-result.py" --lane deep 2>&1)
if [[ $? -eq 0 ]] \
    && echo "$vr12_out" | jq -e '.validation_result.evidence[0] == "x" and (.notes | contains("lifted from top-level"))' >/dev/null; then
    pass "VR-12: top-level lift still fires when validation_result absent"
else
    fail "VR-12: top-level lift regressed" "$vr12_out"
fi

# --- SF-* source-family-map.py

# SF-1: canonical family pass-through.
sf1_out=$("$TOOLS/source-family-map.py" --input security-family 2>&1)
if [[ $? -eq 0 ]] && [[ "$sf1_out" == "security-family" ]]; then
    pass "SF-1: canonical family (security-family) pass-through"
else
    fail "SF-1: canonical pass-through failed" "$sf1_out"
fi

# SF-2: known drift case maps to canonical.
sf2_out=$("$TOOLS/source-family-map.py" --input prompt-injection 2>&1)
if [[ $? -eq 0 ]] && [[ "$sf2_out" == "security-family" ]]; then
    pass "SF-2: drift prompt-injection → security-family"
else
    fail "SF-2: drift mapping failed" "$sf2_out"
fi

# SF-3: stale-line-ref → policy-family (different canonical target).
sf3_out=$("$TOOLS/source-family-map.py" --input stale-line-ref 2>&1)
if [[ $? -eq 0 ]] && [[ "$sf3_out" == "policy-family" ]]; then
    pass "SF-3: drift stale-line-ref → policy-family"
else
    fail "SF-3: stale-line-ref mapping failed" "$sf3_out"
fi

# SF-4: unknown family → exit 3 + UNKNOWN_FAMILY on stderr.
sf4_out=$("$TOOLS/source-family-map.py" --input completely-made-up 2>&1)
sf4_exit=$?
if [[ $sf4_exit -eq 3 ]] && echo "$sf4_out" | grep -qF "UNKNOWN_FAMILY: completely-made-up"; then
    pass "SF-4: unknown family → exit 3 + UNKNOWN_FAMILY stderr"
else
    fail "SF-4: expected exit 3 with UNKNOWN_FAMILY; got $sf4_exit" "$sf4_out"
fi

# SF-5: external-add-family canonical pass-through (commands/add.md emits this).
sf5_out=$("$TOOLS/source-family-map.py" --input external-add-family 2>&1)
if [[ $? -eq 0 ]] && [[ "$sf5_out" == "external-add-family" ]]; then
    pass "SF-5: canonical family (external-add-family) pass-through"
else
    fail "SF-5: external-add-family pass-through failed" "$sf5_out"
fi

# --- PF-INT-*: fragment integration guards

# PF-INT-1: middle-path ensemble-adapter migration — fragments/02-ensemble-adapter.md
# pipes the normalizer output through parse-with-repair.py BEFORE the
# jq schema-guard. This proves the middle-path migration landed in the
# fragment, not just in the helper. The grep pattern is specific enough
# that it catches the new bash block (not a stale reference).
ENSEMBLE_MD="$REPO/fragments/02-ensemble-adapter.md"
if grep -qF 'parse-with-repair.py' "$ENSEMBLE_MD" \
    && grep -qF 'normalizer_clean=' "$ENSEMBLE_MD" \
    && grep -qF 'phase_1_5_normalizer_unparseable' "$ENSEMBLE_MD"; then
    pass "PF-INT-1: ensemble-adapter normalizer migrated to parse-with-repair.py"
else
    fail "PF-INT-1: ensemble-adapter migration missing markers in $ENSEMBLE_MD"
fi

# PF-INT-2: parse-with-repair.py actually handles the kind of malformed
# JSON the ensemble normalizer emits in practice (single-quote + trailing
# comma + fence combo). End-to-end proof, not helper-unit.
# Write to a temp file via printf with escape codes to sidestep bash
# backtick-in-heredoc parsing issues — the raw payload is a JSON array
# wrapped in a markdown code fence ( triple-backtick + "json" ).
pf2_file=$(mktemp)
printf '\140\140\140json\n[{"file": "src/a.ts", "claim": "x'\''y",}]\n\140\140\140\n' > "$pf2_file"
pf2_out=$("$TOOLS/parse-with-repair.py" < "$pf2_file" 2>&1)
if [[ $? -eq 0 ]] \
    && echo "$pf2_out" | jq -e '.[0].file == "src/a.ts"' >/dev/null; then
    pass "PF-INT-2: ensemble-adapter-style malformed input (fence+single-quote+trailing-comma) repaired end-to-end"
else
    fail "PF-INT-2: ensemble-style malformed repair failed" "$pf2_out"
fi
rm -f "$pf2_file"

# PF-INT-3: fragments/05-validation.md references parse-validator-result.py
# for canonical shape normalization before --apply-decisions tuple compose.
VAL_MD="$REPO/fragments/05-validation.md"
if grep -qF 'parse-validator-result.py' "$VAL_MD" \
    && grep -qF -e '--lane deep' "$VAL_MD" \
    && grep -qF 'Phase 4 parse/score unrecoverable' "$VAL_MD"; then
    pass "PF-INT-3: fragments/05-validation.md integrates parse-validator-result.py"
else
    fail "PF-INT-3: validation fragment integration missing markers in $VAL_MD"
fi

# PF-INT-4: fragments/01-detection.md integrates batched --add-findings
# + in-jq fam_canonical at the join step with "unknown"-tag escalation
# (not silent drop). Stage-4 marker triple: fam_canonical proves in-jq
# canonicalization landed; --add-findings proves the batched helper
# replaced the per-call loop; lens_source_family_unknown proves drift
# escalation still works.
DET_MD="$REPO/fragments/01-detection.md"
if grep -qF 'fam_canonical' "$DET_MD" \
    && grep -qF -- '--add-findings' "$DET_MD" \
    && grep -qF 'lens_source_family_unknown' "$DET_MD"; then
    pass "PF-INT-4: detection fragment integrates batched --add-findings + in-jq fam_canonical (escalate-not-drop)"
else
    fail "PF-INT-4: detection fragment integration missing markers in $DET_MD"
fi

# PF-INT-5: commands/review.md frontmatter grants bare-name Bash permissions
# for the Phase 1 detection helpers invoked in transcluded fragments.
# Catches the permissions-vs-usage drift class.
REVIEW_CMD="$REPO/commands/review.md"
review_front=$(awk '/^---$/{c++; next} c==1{print}' "$REVIEW_CMD")
rh_missing=()
for helper in parse-with-repair.py parse-validator-result.py source-family-map.py assign-finding-ids.sh origin-crosscheck.sh; do
    if ! echo "$review_front" | grep -qF "Bash($helper:"; then
        rh_missing+=("$helper")
    fi
done
if [[ ${#rh_missing[@]} -eq 0 ]]; then
    pass "PF-INT-5: commands/review.md allowed-tools grants Phase 1 detection helpers"
else
    fail "PF-INT-5: missing Bash grants for: ${rh_missing[*]}"
fi

# ------------------------------------------------------------------ FG-* freshness-gate.sh
# Stage 4.A.1 — Phase 0.2a freshness reconciliation extracted into a
# helper. Covers happy path (clean remote, zero behind), no-remote case,
# and fetch-failure case.

FG_DIR="$WORK/freshness-gate"

# FG-1: happy path — origin exists, local base is up-to-date, behind=0.
mkdir -p "$FG_DIR/fg1/origin"
(
    cd "$FG_DIR/fg1/origin"
    git init --quiet --initial-branch=main 2>/dev/null || git init --quiet
    git symbolic-ref HEAD refs/heads/main 2>/dev/null || true
    git config user.email smoke@example.com
    git config user.name smoke
    printf 'a\n' > f.txt
    git add f.txt && git commit --quiet -m "initial"
)
git clone --quiet "$FG_DIR/fg1/origin" "$FG_DIR/fg1/repo" 2>/dev/null
(
    cd "$FG_DIR/fg1/repo"
    git config user.email smoke@example.com
    git config user.name smoke
    git checkout --quiet -b feat
    printf 'b\n' > f.txt
    git commit --quiet -am "feature"
)
out=$(cd "$FG_DIR/fg1/repo" && "$TOOLS/freshness-gate.sh" \
    --base-branch main --head-branch feat 2>/dev/null)
fg1_freshness=$(echo "$out" | jq -r '.base_freshness')
fg1_compref=$(echo "$out" | jq -r '.comparison_ref')
fg1_behind=$(echo "$out" | jq -r '.behind_count')
fg1_warn_len=$(echo "$out" | jq '.preflight_warnings | length')
if [[ "$fg1_freshness" == "fresh" && "$fg1_compref" == "main" \
    && "$fg1_behind" == "0" && "$fg1_warn_len" == "0" ]]; then
    pass "FG-1 (§13.10): happy path — origin fresh, behind=0 → base_freshness=fresh"
else
    fail "FG-1: expected fresh/main/0/[]; got freshness=$fg1_freshness compref=$fg1_compref behind=$fg1_behind warn_len=$fg1_warn_len"
fi

# FG-2: no-remote case — repo has no `origin` remote at all.
mkdir -p "$FG_DIR/fg2"
(
    cd "$FG_DIR/fg2"
    git init --quiet --initial-branch=main 2>/dev/null || git init --quiet
    git symbolic-ref HEAD refs/heads/main 2>/dev/null || true
    git config user.email smoke@example.com
    git config user.name smoke
    printf 'a\n' > f.txt
    git add f.txt && git commit --quiet -m "initial"
    git checkout --quiet -b feat
    printf 'b\n' > f.txt
    git commit --quiet -am "feature"
)
out=$(cd "$FG_DIR/fg2" && "$TOOLS/freshness-gate.sh" \
    --base-branch main --head-branch feat 2>/dev/null)
fg2_freshness=$(echo "$out" | jq -r '.base_freshness')
fg2_compref=$(echo "$out" | jq -r '.comparison_ref')
fg2_remote_sha=$(echo "$out" | jq -r '.remote_sha')
fg2_behind=$(echo "$out" | jq -r '.behind_count')
if [[ "$fg2_freshness" == "no_remote" && "$fg2_compref" == "main" \
    && "$fg2_remote_sha" == "null" && "$fg2_behind" == "null" ]]; then
    pass "FG-2 (§13.10): no-remote case — base_freshness=no_remote, remote_sha/behind_count null"
else
    fail "FG-2: expected no_remote/main/null/null; got freshness=$fg2_freshness compref=$fg2_compref rsha=$fg2_remote_sha behind=$fg2_behind"
fi

# FG-3: fetch-failure case — `origin` remote points at a nonexistent path.
mkdir -p "$FG_DIR/fg3"
(
    cd "$FG_DIR/fg3"
    git init --quiet --initial-branch=main 2>/dev/null || git init --quiet
    git symbolic-ref HEAD refs/heads/main 2>/dev/null || true
    git config user.email smoke@example.com
    git config user.name smoke
    printf 'a\n' > f.txt
    git add f.txt && git commit --quiet -m "initial"
    git remote add origin "$FG_DIR/fg3/nonexistent_remote_xyz"
    git checkout --quiet -b feat
    printf 'b\n' > f.txt
    git commit --quiet -am "feature"
)
out=$(cd "$FG_DIR/fg3" && "$TOOLS/freshness-gate.sh" \
    --base-branch main --head-branch feat 2>/dev/null)
fg3_freshness=$(echo "$out" | jq -r '.base_freshness')
fg3_compref=$(echo "$out" | jq -r '.comparison_ref')
fg3_warn_len=$(echo "$out" | jq '.preflight_warnings | length')
fg3_warn_head=$(echo "$out" | jq -r '.preflight_warnings[0] // ""')
if [[ "$fg3_freshness" == "no_fetch" && "$fg3_compref" == "main" \
    && "$fg3_warn_len" == "1" ]] \
    && echo "$fg3_warn_head" | grep -q '^fetch_failed '; then
    pass "FG-3 (§13.10): fetch-failure case — base_freshness=no_fetch, fetch_failed warning buffered"
else
    fail "FG-3: expected no_fetch/main/warn_len=1/'fetch_failed ...'; got freshness=$fg3_freshness compref=$fg3_compref warn_len=$fg3_warn_len warn_head='$fg3_warn_head'"
fi

# FG-4: jq entry guard — a jq-less PATH fails at entry with exit 5
# (error-as-prompt), before any git call or network side effect. Run via
# /bin/bash so the empty PATH only affects the script's own lookups, not
# the `#!/usr/bin/env bash` shebang. Only bash builtins run pre-guard.
mkdir -p "$FG_DIR/fg4-emptybin"
fg4_rc=0
fg4_err=$(PATH="$FG_DIR/fg4-emptybin" /bin/bash "$TOOLS/freshness-gate.sh" \
    --base-branch main --head-branch feat 2>&1 >/dev/null) || fg4_rc=$?
if [[ "$fg4_rc" == "5" ]] \
    && echo "$fg4_err" | grep -q 'jq not found' \
    && echo "$fg4_err" | grep -q '^Action:'; then
    pass "FG-4: jq entry guard — jq-less PATH exits 5 with error-as-prompt before any git call"
else
    fail "FG-4: expected rc=5 + 'jq not found' + 'Action:'; got rc=$fg4_rc err='$fg4_err'"
fi

# FG-5: EXIT-trap temp hygiene — a broken jq kills the helper under
# `set -e` between mktemp (ff_err_file) and its inline rm -f: the
# --after-choice a HEAD-on-base path fast-forwards cleanly ("already up
# to date" clone), then emit_terminal's jq fails. The trap must still
# remove the scratch file. Location is pinned via a PATH-interposed
# mktemp wrapper: macOS mktemp -t ignores TMPDIR (files land in the
# /var/folders system temp), so TMPDIR scoping alone would leave this
# leak check vacuous on the macOS CI leg.
mkdir -p "$FG_DIR/fg5/origin" "$FG_DIR/fg5/tmp" "$FG_DIR/fg5/stubbin"
(
    cd "$FG_DIR/fg5/origin"
    git init --quiet --initial-branch=main 2>/dev/null || git init --quiet
    git symbolic-ref HEAD refs/heads/main 2>/dev/null || true
    git config user.email smoke@example.com
    git config user.name smoke
    printf 'a\n' > f.txt
    git add f.txt && git commit --quiet -m "initial"
)
git clone --quiet "$FG_DIR/fg5/origin" "$FG_DIR/fg5/repo" 2>/dev/null
(
    cd "$FG_DIR/fg5/repo"
    git config user.email smoke@example.com
    git config user.name smoke
)
cat > "$FG_DIR/fg5/stubbin/jq" <<'EOS'
#!/usr/bin/env bash
exit 7
EOS
chmod +x "$FG_DIR/fg5/stubbin/jq"
FG5_REAL_MKTEMP=$(command -v mktemp)
cat > "$FG_DIR/fg5/stubbin/mktemp" <<EOS
#!/usr/bin/env bash
if [[ "\${1:-}" == "-t" && -n "\${2:-}" ]]; then
    exec "$FG5_REAL_MKTEMP" "$FG_DIR/fg5/tmp/\$2"
fi
exec "$FG5_REAL_MKTEMP" "\$@"
EOS
chmod +x "$FG_DIR/fg5/stubbin/mktemp"
fg5_rc=0
(cd "$FG_DIR/fg5/repo" && PATH="$FG_DIR/fg5/stubbin:$PATH" \
    "$TOOLS/freshness-gate.sh" --base-branch main --head-branch main \
    --after-choice a >/dev/null 2>&1) || fg5_rc=$?
fg5_leftover=$(find "$FG_DIR/fg5/tmp" -name 'matthews-ff-err.*' 2>/dev/null | wc -l | tr -d ' ')
if [[ "$fg5_rc" != "0" && "$fg5_leftover" == "0" ]]; then
    pass "FG-5: EXIT trap removes mktemp scratch when broken jq aborts emit under set -e"
else
    fail "FG-5: expected rc!=0 + zero leftover matthews-ff-err.*; got rc=$fg5_rc leftover=$fg5_leftover"
fi

# ------------------------------------------------------------------ TC-* trivial-check.sh
# Stage 4.A.2 — Phase 0.11 trivial-diff classification extracted into a
# helper. Covers trivial docs-only case, non-trivial mixed case, and
# empty-diff edge case (vacuously trivial; matches pre-extraction
# fragment behavior).

# TC-1: trivial docs-only — every file in the doc/config allow-list,
# num_files <= 3, lines_changed <= 30.
tc1_out=$(printf '%s\n' "README.md" "CHANGELOG.md" ".gitignore" \
    | "$TOOLS/trivial-check.sh" --num-files 3 --lines-changed 20)
tc1_mode=$(echo "$tc1_out" | jq -r '.trivial_mode')
tc1_reason=$(echo "$tc1_out" | jq -r '.reason')
if [[ "$tc1_mode" == "true" && "$tc1_reason" == "docs_only" ]]; then
    pass "TC-1 (§13.9): trivial docs-only — trivial_mode=true, reason=docs_only"
else
    fail "TC-1: expected true/docs_only; got mode=$tc1_mode reason=$tc1_reason"
fi

# TC-2: non-trivial mixed — one doc file + one source file fails the
# allow-list walk; reason must be null.
tc2_out=$(printf '%s\n' "README.md" "src/foo.ts" \
    | "$TOOLS/trivial-check.sh" --num-files 2 --lines-changed 10)
tc2_mode=$(echo "$tc2_out" | jq -r '.trivial_mode')
tc2_reason=$(echo "$tc2_out" | jq -r '.reason')
if [[ "$tc2_mode" == "false" && "$tc2_reason" == "null" ]]; then
    pass "TC-2 (§13.9): non-trivial mixed — trivial_mode=false, reason=null"
else
    fail "TC-2: expected false/null; got mode=$tc2_mode reason=$tc2_reason"
fi

# TC-3: empty-diff edge case — no files on stdin, zero counts. Vacuously
# trivial (allow-list walk never trips, 0<=3, 0<=30). Matches pre-
# extraction fragment behavior exactly.
tc3_out=$(printf '' | "$TOOLS/trivial-check.sh" --num-files 0 --lines-changed 0)
tc3_mode=$(echo "$tc3_out" | jq -r '.trivial_mode')
tc3_reason=$(echo "$tc3_out" | jq -r '.reason')
if [[ "$tc3_mode" == "true" && "$tc3_reason" == "docs_only" ]]; then
    pass "TC-3 (§13.9): empty-diff edge case — vacuously trivial, reason=docs_only"
else
    fail "TC-3: expected true/docs_only; got mode=$tc3_mode reason=$tc3_reason"
fi

# ------------------------------------------------------------------ AS-* artifact-seed.sh
# Stage 4.A.3 — Phase 0.15 artifact seed construction extracted into a
# helper. Covers happy-path (seed schema-validates via `artifact-patch.py
# --init -` and carries the expected top-level shape), missing-required-
# arg failure (error-as-prompt stderr + exit 64), and malformed
# `--base-context` failure (error-as-prompt stderr + exit 1).

AS_DIR="$WORK/artifact-seed"
mkdir -p "$AS_DIR"

# AS-1: happy-path — helper output satisfies schema-v1.json via
# `artifact-patch.py --init -`, and the resulting artifact carries the
# expected top-level fields (schema_version, review_id, mode, nullable
# comment_id persisted as null, reviewer_sources seeded to ["internal"],
# pr_size_buckets nested under metrics).
as1_base_ctx='{"freshness":"fresh","comparison_ref":"main","remote_sha":"def5678","behind_count":0}'
as1_art="$AS_DIR/as1.json"
as1_err="$AS_DIR/as1.err"
if "$TOOLS/artifact-seed.sh" \
    --review-id "rev_01HXAS1TESTIDENTIFIER" \
    --review-started-at "2026-04-22T12:34:56Z" \
    --reviewed-sha "abc1234" \
    --base-branch "main" --head-branch "feature/foo" \
    --mode "pr" --pr-state "open" \
    --pr-number "42" --comment-id "" \
    --trivial-mode "false" --base-context "$as1_base_ctx" \
    --reviewed-files-all "$(printf 'a.py\nb.py\n')" \
    --claude-md-paths "$(printf '/CLAUDE.md\n')" \
    --files-changed "2" --lines-changed "10" \
    | "$TOOLS/artifact-patch.py" --init - --path "$as1_art" 2>"$as1_err" >/dev/null; then
    as1_schema=$(jq -r '.schema_version' "$as1_art")
    as1_rid=$(jq -r '.review_id' "$as1_art")
    as1_mode=$(jq -r '.mode' "$as1_art")
    as1_cid=$(jq -r '.comment_id' "$as1_art")
    as1_rs=$(jq -r '.reviewer_sources | join(",")' "$as1_art")
    as1_files=$(jq -r '.metrics.pr_size_buckets.files_changed' "$as1_art")
    if [[ "$as1_schema" == "1" && "$as1_rid" == "rev_01HXAS1TESTIDENTIFIER" \
        && "$as1_mode" == "pr" && "$as1_cid" == "null" \
        && "$as1_rs" == "internal" && "$as1_files" == "2" ]]; then
        pass "AS-1 (§0.15): happy-path — seed schema-validates via --init and carries expected top-level shape"
    else
        fail "AS-1: shape mismatch — schema=$as1_schema rid=$as1_rid mode=$as1_mode cid=$as1_cid rs=$as1_rs files=$as1_files"
    fi
else
    fail "AS-1: --init rejected helper output" "$(cat "$as1_err" 2>/dev/null)"
fi

# AS-2: missing-required-arg — omit --review-started-at; expect usage
# error (exit 64) with error-as-prompt stderr (`ERROR:` + `Usage:`).
as2_err="$AS_DIR/as2.err"
"$TOOLS/artifact-seed.sh" \
    --review-id "rev_abc" \
    --reviewed-sha "abc1234" \
    --base-branch "main" --head-branch "hb" \
    --mode "pr" --pr-state "" --pr-number "" --comment-id "" \
    --trivial-mode "false" \
    --base-context '{"freshness":"fresh","comparison_ref":"main","remote_sha":null,"behind_count":null}' \
    --reviewed-files-all "" --claude-md-paths "" \
    --files-changed "0" --lines-changed "0" \
    >/dev/null 2>"$as2_err"
as2_rc=$?
if [[ "$as2_rc" == "64" ]] \
    && grep -q '^ERROR: --review-started-at is required' "$as2_err" \
    && grep -q '^Usage: ' "$as2_err"; then
    pass "AS-2 (§0.15): missing --review-started-at → exit 64 + error-as-prompt stderr"
else
    fail "AS-2: expected rc=64 with ERROR/Usage stderr; got rc=$as2_rc" "$(cat "$as2_err" 2>/dev/null)"
fi

# AS-3: malformed --base-context — not JSON; expect validation error
# (exit 1) with error-as-prompt stderr (`ERROR:` + `Action:`).
as3_err="$AS_DIR/as3.err"
"$TOOLS/artifact-seed.sh" \
    --review-id "rev_abc" \
    --review-started-at "2026-04-22T00:00:00Z" \
    --reviewed-sha "abc1234" \
    --base-branch "main" --head-branch "hb" \
    --mode "pr" --pr-state "" --pr-number "" --comment-id "" \
    --trivial-mode "false" --base-context "not-json" \
    --reviewed-files-all "" --claude-md-paths "" \
    --files-changed "0" --lines-changed "0" \
    >/dev/null 2>"$as3_err"
as3_rc=$?
if [[ "$as3_rc" == "1" ]] \
    && grep -q '^ERROR: --base-context must be a JSON object' "$as3_err" \
    && grep -q '^Action: ' "$as3_err"; then
    pass "AS-3 (§0.15): malformed --base-context → exit 1 + error-as-prompt stderr"
else
    fail "AS-3: expected rc=1 with ERROR/Action stderr; got rc=$as3_rc" "$(cat "$as3_err" 2>/dev/null)"
fi

# AS-4: --reviewer-sources internal-codex (single label) round-trips into
# the seeded artifact. Plan §4.1 / §3.9 — codex-review passes this label
# so downstream lifecycle commands (or analytics) can distinguish review
# lineage. Schema-validates via --init.
as4_base_ctx='{"freshness":"fresh","comparison_ref":"main","remote_sha":null,"behind_count":null}'
as4_art="$AS_DIR/as4.json"
as4_err="$AS_DIR/as4.err"
if "$TOOLS/artifact-seed.sh" \
    --review-id "rev_AS4" --review-started-at "2026-04-22T00:00:00Z" \
    --reviewed-sha "abc1234" \
    --base-branch "main" --head-branch "feat" \
    --mode "local" --pr-state "" --pr-number "" --comment-id "" \
    --trivial-mode "false" --base-context "$as4_base_ctx" \
    --reviewed-files-all "" --claude-md-paths "" \
    --files-changed "0" --lines-changed "0" \
    --reviewer-sources "internal-codex" \
    | "$TOOLS/artifact-patch.py" --init - --path "$as4_art" 2>"$as4_err" >/dev/null; then
    as4_rs=$(jq -c '.reviewer_sources' "$as4_art")
    if [[ "$as4_rs" == '["internal-codex"]' ]]; then
        pass "AS-4 (§4.1): --reviewer-sources internal-codex round-trips into artifact"
    else
        fail "AS-4: expected reviewer_sources=[\"internal-codex\"], got $as4_rs"
    fi
else
    fail "AS-4: --init rejected helper output" "$(cat "$as4_err" 2>/dev/null)"
fi

# AS-5: --reviewer-sources with multi-value comma-separated input and
# whitespace around each label — must trim whitespace and emit a 2-elem
# array preserving order.
as5_art="$AS_DIR/as5.json"
as5_err="$AS_DIR/as5.err"
if "$TOOLS/artifact-seed.sh" \
    --review-id "rev_AS5" --review-started-at "2026-04-22T00:00:00Z" \
    --reviewed-sha "abc1234" \
    --base-branch "main" --head-branch "feat" \
    --mode "local" --pr-state "" --pr-number "" --comment-id "" \
    --trivial-mode "false" --base-context "$as4_base_ctx" \
    --reviewed-files-all "" --claude-md-paths "" \
    --files-changed "0" --lines-changed "0" \
    --reviewer-sources "internal, internal-codex" \
    | "$TOOLS/artifact-patch.py" --init - --path "$as5_art" 2>"$as5_err" >/dev/null; then
    as5_rs=$(jq -c '.reviewer_sources' "$as5_art")
    if [[ "$as5_rs" == '["internal","internal-codex"]' ]]; then
        pass "AS-5 (§4.1): --reviewer-sources comma-sep with whitespace trims and preserves order"
    else
        fail "AS-5: expected reviewer_sources=[\"internal\",\"internal-codex\"], got $as5_rs"
    fi
else
    fail "AS-5: --init rejected helper output" "$(cat "$as5_err" 2>/dev/null)"
fi

# AS-6: empty --reviewer-sources → exit 1 with error-as-prompt stderr.
# Guards the validation path that prevents an empty array from being
# emitted (would violate downstream invariants).
as6_err="$AS_DIR/as6.err"
"$TOOLS/artifact-seed.sh" \
    --review-id "rev_AS6" --review-started-at "2026-04-22T00:00:00Z" \
    --reviewed-sha "abc1234" \
    --base-branch "main" --head-branch "feat" \
    --mode "local" --pr-state "" --pr-number "" --comment-id "" \
    --trivial-mode "false" --base-context "$as4_base_ctx" \
    --reviewed-files-all "" --claude-md-paths "" \
    --files-changed "0" --lines-changed "0" \
    --reviewer-sources "" \
    >/dev/null 2>"$as6_err"
as6_rc=$?
if [[ "$as6_rc" == "1" ]] \
    && grep -q '^ERROR: --reviewer-sources must contain at least one non-empty label' "$as6_err" \
    && grep -q '^Action: ' "$as6_err"; then
    pass "AS-6 (§4.1): empty --reviewer-sources → exit 1 + error-as-prompt stderr"
else
    fail "AS-6: expected rc=1 with ERROR/Action stderr; got rc=$as6_rc" "$(cat "$as6_err" 2>/dev/null)"
fi

# ------------------------------------------------------------------ AF-* batched --add-findings (Stage 3 / plans/batched-add-findings.md)
# Stage 3 — `bin/artifact-patch.py --add-findings <array>` is the
# batched create mode that replaces the per-finding loop in
# fragments/01-detection.md (Stage 4 wires it). Each finding flows
# through preflight (`_check_add_finding_shape`); rejections are
# logged as one-line `add-findings-rejected:` records on stderr and
# the rest of the batch still commits in a single atomic write.
#
# Exit-code policy (pinned in artifact-patch.py:cmd_add_findings):
#   0  — at least one finding accepted (rejections allowed; summary
#        names the skipped ids)
#   1  — EXIT_VALIDATION (post-write full-artifact schema failed —
#        defense-in-depth; AF-5 is deferred per design plan §5)
#   7  — EXIT_ALL_REJECTED (input was a JSON array, but every element
#        was rejected at preflight)
#  64  — EXIT_USAGE (non-array input, unparseable JSON, or mode-
#        conflict with --set / --finding-id / etc.)

AF_DIR="$WORK/af-batched"
mkdir -p "$AF_DIR"

# Reusable valid-finding template generator. id is the only thing that
# varies per assertion; everything else satisfies the schema's required-
# field set with deep-lane / pending_validation defaults — i.e., the
# shape Phase 1 join would emit before Phase 3 scoring. Bash 3.2-safe:
# uses jq -nc with --arg, no associative arrays.
af_mkfinding() {
    jq -nc --arg id "$1" '{
        id: $id,
        sources: ["L1-diff"],
        source_families: ["structural-family"],
        impact_type: "correctness",
        origin: "introduced_by_pr",
        origin_confidence: "high",
        actionability: "auto_fixable",
        validation_lane: "deep",
        current_state: "open",
        disposition: "pending_validation",
        is_actionable: false,
        reason: null,
        confirmed_strength: null,
        file: "src/a.ts",
        line_range: [10, 12],
        claim: "AF-* batched add-findings template",
        score_phase3: null,
        score_phase4: null,
        score_history: [],
        validation_result: null,
        fix_attempts: [],
        introduced_in_sha: null,
        suggested_follow_up: null,
        related_parent_finding_id: null
    }'
}

# AF-1: happy path. Three valid findings → exit 0, all three land,
# stdout summary names the count, stderr is silent.
af1_art="$AF_DIR/af1.json"
af1_err="$AF_DIR/af1.err"
"$TOOLS/artifact-patch.py" --init "@$FIX/artifact-seed.json" --path "$af1_art" >/dev/null
af1_f1=$(af_mkfinding F101)
af1_f2=$(af_mkfinding F102)
af1_f3=$(af_mkfinding F103)
af1_arr=$(jq -nc --argjson f1 "$af1_f1" --argjson f2 "$af1_f2" --argjson f3 "$af1_f3" '[$f1,$f2,$f3]')
af1_out=$("$TOOLS/artifact-patch.py" --path "$af1_art" --add-findings "$af1_arr" 2>"$af1_err")
af1_rc=$?
af1_disk_ids=$(jq -r '.findings | map(.id) | join(",")' "$af1_art")
if [[ "$af1_rc" == "0" ]] \
    && [[ "$af1_out" == "added 3 findings" ]] \
    && [[ ! -s "$af1_err" ]] \
    && [[ "$af1_disk_ids" == "F001,F002,F003,F004,F005,F006,F101,F102,F103" ]]; then
    pass "AF-1: happy-path 3-finding batch → exit 0, stdout summary, silent stderr, all three land on-disk"
else
    fail "AF-1: rc=$af1_rc out='$af1_out' err_size=$(wc -c <"$af1_err") ids='$af1_disk_ids'" "$(cat "$af1_err" 2>/dev/null)"
fi

# AF-2: mixed batch with R5 nested-key coverage.
#   #1 F201 valid                            — should land
#   #2 F202 invalid (top-level extra_field)  — schema_invalid
#   #3 F203 invalid (nested validation_result.blast_radius.extra_subkey)
#                                              — schema_invalid (nested
#                                                additionalProperties:false)
#   #4 F204 valid                            — should land
#   #5 F201 (duplicate of #1 in same batch)  — duplicate_id
# Verifies one mode catches drift at every depth: top-level AND nested
# `additionalProperties: false` rejections plus same-batch dup detection.
# F201 + F204 land. Stderr: TWO schema_invalid + ONE duplicate_id lines.
af2_art="$AF_DIR/af2.json"
af2_err="$AF_DIR/af2.err"
"$TOOLS/artifact-patch.py" --init "@$FIX/artifact-seed.json" --path "$af2_art" >/dev/null
af2_f1=$(af_mkfinding F201)
af2_f2=$(af_mkfinding F202 | jq -c '. + {extra_field: 1}')
af2_f3=$(af_mkfinding F203 | jq -c '.validation_result = {
    evidence: ["e"],
    blast_radius: {writers: [], consumers: [], parallel_paths: [], invariants_at_stake: [], extra_subkey: []},
    fix_proposal: {approach: "x", files_to_modify: []},
    verification_context: {how_to_verify_fix: [], edge_cases_to_preserve: [], what_would_break_if_incomplete: []}
}')
af2_f4=$(af_mkfinding F204)
af2_f5=$(af_mkfinding F201 | jq -c '.claim = "duplicate-of-F201-in-same-batch"')
af2_arr=$(jq -nc --argjson f1 "$af2_f1" --argjson f2 "$af2_f2" \
    --argjson f3 "$af2_f3" --argjson f4 "$af2_f4" --argjson f5 "$af2_f5" \
    '[$f1,$f2,$f3,$f4,$f5]')
af2_out=$("$TOOLS/artifact-patch.py" --path "$af2_art" --add-findings "$af2_arr" 2>"$af2_err")
af2_rc=$?
af2_disk_ids=$(jq -r '.findings | map(.id) | join(",")' "$af2_art")
af2_schema_count=$(grep -c 'reason=schema_invalid' "$af2_err")
af2_dup_count=$(grep -c 'reason=duplicate_id' "$af2_err")
af2_dup_detail=$(grep 'reason=duplicate_id' "$af2_err")
if [[ "$af2_rc" == "0" ]] \
    && [[ "$af2_out" == *"added 2 findings"* ]] \
    && [[ "$af2_out" == *"F202"* && "$af2_out" == *"F203"* && "$af2_out" == *"F201"* ]] \
    && [[ "$af2_disk_ids" == "F001,F002,F003,F004,F005,F006,F201,F204" ]] \
    && [[ "$af2_schema_count" == "2" ]] \
    && [[ "$af2_dup_count" == "1" ]] \
    && echo "$af2_dup_detail" | grep -qF 'id appears twice in this batch'; then
    pass "AF-2 (R5): mixed batch — top-level + nested additionalProperties + duplicate_id; F201 & F204 land"
else
    fail "AF-2: rc=$af2_rc schema_lines=$af2_schema_count dup_lines=$af2_dup_count ids='$af2_disk_ids' out='$af2_out'" "$(cat "$af2_err" 2>/dev/null)"
fi

# AF-3: all-rejected (T6 — batch-level error-as-prompt block).
# Two findings, both with bad impact_type enum values. Verify exit 7,
# TWO add-findings-rejected: lines, the batch-level ERROR: + Action:
# error-as-prompt, "added 0 findings (skipped 2: ...)" stdout summary,
# and on-disk artifact unchanged (no F301/F302).
af3_art="$AF_DIR/af3.json"
af3_err="$AF_DIR/af3.err"
"$TOOLS/artifact-patch.py" --init "@$FIX/artifact-seed.json" --path "$af3_art" >/dev/null
af3_pre_ids=$(jq -r '.findings | map(.id) | join(",")' "$af3_art")
af3_f1=$(af_mkfinding F301 | jq -c '.impact_type = "BAD_VAL"')
af3_f2=$(af_mkfinding F302 | jq -c '.impact_type = "ALSO_BAD"')
af3_arr=$(jq -nc --argjson f1 "$af3_f1" --argjson f2 "$af3_f2" '[$f1,$f2]')
af3_out=$("$TOOLS/artifact-patch.py" --path "$af3_art" --add-findings "$af3_arr" 2>"$af3_err")
af3_rc=$?
af3_post_ids=$(jq -r '.findings | map(.id) | join(",")' "$af3_art")
af3_rej_count=$(grep -c '^add-findings-rejected:' "$af3_err")
if [[ "$af3_rc" == "7" ]] \
    && [[ "$af3_rej_count" == "2" ]] \
    && grep -q '^ERROR: --add-findings: every input was rejected' "$af3_err" \
    && grep -q '^Action:' "$af3_err" \
    && [[ "$af3_out" == *"added 0 findings"* && "$af3_out" == *"F301"* && "$af3_out" == *"F302"* ]] \
    && [[ "$af3_post_ids" == "$af3_pre_ids" ]]; then
    pass "AF-3 (T6): all-rejected → exit 7 + batch-level ERROR/Action + 2 rejection lines + artifact unchanged"
else
    fail "AF-3: rc=$af3_rc rej_count=$af3_rej_count pre='$af3_pre_ids' post='$af3_post_ids' out='$af3_out'" "$(cat "$af3_err" 2>/dev/null)"
fi

# AF-4: stdin path. Same input as AF-1 piped via `printf | --add-findings -`
# must yield the same on-disk state. Proves read_json_arg's stdin branch
# composes with --add-findings (not just inline JSON or @file).
af4_art="$AF_DIR/af4.json"
af4_err="$AF_DIR/af4.err"
"$TOOLS/artifact-patch.py" --init "@$FIX/artifact-seed.json" --path "$af4_art" >/dev/null
# Reuse AF-1's array (F101..F103), pipe via stdin.
af4_out=$(printf '%s' "$af1_arr" | "$TOOLS/artifact-patch.py" --path "$af4_art" --add-findings - 2>"$af4_err")
af4_rc=$?
af4_disk_ids=$(jq -r '.findings | map(.id) | join(",")' "$af4_art")
if [[ "$af4_rc" == "0" ]] \
    && [[ "$af4_out" == "added 3 findings" ]] \
    && [[ ! -s "$af4_err" ]] \
    && [[ "$af4_disk_ids" == "$af1_disk_ids" ]]; then
    pass "AF-4: stdin (--add-findings -) matches AF-1 inline-JSON on-disk state"
else
    fail "AF-4: rc=$af4_rc out='$af4_out' ids='$af4_disk_ids' (vs AF-1 '$af1_disk_ids')" "$(cat "$af4_err" 2>/dev/null)"
fi

# AF-5: SKIPPED — defense-in-depth post-write validation case is deferred
# per plans/batched-add-findings.md §5 (would require a bug in the
# preflight validator vs. the artifact-level validator since they share
# schema-v1.json). Reserved for future regression coverage if such a
# divergence is ever introduced.

# AF-6: empty array. `[]` is a no-op success — exit 0, "added 0 findings"
# on stdout, silent stderr, on-disk artifact unchanged. Lets callers
# pipe a possibly-empty candidate list without special-casing.
af6_art="$AF_DIR/af6.json"
af6_err="$AF_DIR/af6.err"
"$TOOLS/artifact-patch.py" --init "@$FIX/artifact-seed.json" --path "$af6_art" >/dev/null
af6_pre_ids=$(jq -r '.findings | map(.id) | join(",")' "$af6_art")
af6_out=$("$TOOLS/artifact-patch.py" --path "$af6_art" --add-findings '[]' 2>"$af6_err")
af6_rc=$?
af6_post_ids=$(jq -r '.findings | map(.id) | join(",")' "$af6_art")
if [[ "$af6_rc" == "0" ]] \
    && [[ "$af6_out" == "added 0 findings" ]] \
    && [[ ! -s "$af6_err" ]] \
    && [[ "$af6_post_ids" == "$af6_pre_ids" ]]; then
    pass "AF-6: empty array → exit 0, 'added 0 findings', silent stderr, artifact unchanged"
else
    fail "AF-6: rc=$af6_rc out='$af6_out' err_size=$(wc -c <"$af6_err") pre='$af6_pre_ids' post='$af6_post_ids'" "$(cat "$af6_err" 2>/dev/null)"
fi

# AF-7a: usage error — non-array JSON value (string). exit 64. Artifact
# unchanged. read_json_arg parses successfully; cmd_add_findings rejects
# the non-list type.
af7_art="$AF_DIR/af7.json"
"$TOOLS/artifact-patch.py" --init "@$FIX/artifact-seed.json" --path "$af7_art" >/dev/null
af7_pre_ids=$(jq -r '.findings | map(.id) | join(",")' "$af7_art")
af7a_err="$AF_DIR/af7a.err"
"$TOOLS/artifact-patch.py" --path "$af7_art" --add-findings '"hello"' >/dev/null 2>"$af7a_err"
af7a_rc=$?
af7a_post_ids=$(jq -r '.findings | map(.id) | join(",")' "$af7_art")
if [[ "$af7a_rc" == "64" ]] \
    && grep -q 'JSON array' "$af7a_err" \
    && [[ "$af7a_post_ids" == "$af7_pre_ids" ]]; then
    pass "AF-7a: non-array JSON ('\"hello\"') → exit 64 + 'JSON array' stderr, artifact unchanged"
else
    fail "AF-7a: rc=$af7a_rc post='$af7a_post_ids'" "$(cat "$af7a_err" 2>/dev/null)"
fi

# AF-7b: usage error — unparseable JSON via stdin. exit 64 (read_json_arg
# branch; emits 'not valid JSON' / source = <stdin>). Artifact unchanged.
af7b_err="$AF_DIR/af7b.err"
printf 'not-json' | "$TOOLS/artifact-patch.py" --path "$af7_art" --add-findings - >/dev/null 2>"$af7b_err"
af7b_rc=$?
af7b_post_ids=$(jq -r '.findings | map(.id) | join(",")' "$af7_art")
if [[ "$af7b_rc" == "64" ]] \
    && grep -q 'not valid JSON' "$af7b_err" \
    && [[ "$af7b_post_ids" == "$af7_pre_ids" ]]; then
    pass "AF-7b: unparseable JSON via stdin → exit 64 + 'not valid JSON' stderr, artifact unchanged"
else
    fail "AF-7b: rc=$af7b_rc post='$af7b_post_ids'" "$(cat "$af7b_err" 2>/dev/null)"
fi

# AF-7c: usage error — mode conflict (--add-findings + --finding-id).
# exit 64 + 'cannot combine' stderr from cmd_add_findings's mode-conflict
# guard. Artifact unchanged.
af7c_err="$AF_DIR/af7c.err"
"$TOOLS/artifact-patch.py" --path "$af7_art" --add-findings '[]' --finding-id F001 >/dev/null 2>"$af7c_err"
af7c_rc=$?
af7c_post_ids=$(jq -r '.findings | map(.id) | join(",")' "$af7_art")
if [[ "$af7c_rc" == "64" ]] \
    && grep -q 'cannot combine' "$af7c_err" \
    && [[ "$af7c_post_ids" == "$af7_pre_ids" ]]; then
    pass "AF-7c: mode conflict (--add-findings + --finding-id) → exit 64 + 'cannot combine' stderr, artifact unchanged"
else
    fail "AF-7c: rc=$af7c_rc post='$af7c_post_ids'" "$(cat "$af7c_err" 2>/dev/null)"
fi

# ------------------------------------------------------------------ AF-DRIFT source-family canonicalization parity
# Catches divergence between bin/source-family-map.py (CANONICAL +
# DRIFT_MAP) and the in-jq `fam_canonical` table that Stage 4 inlines
# into fragments/01-detection.md §1.5 step 4. The jq table below is
# paste-duplicated verbatim from plans/batched-add-findings.md §3 — the
# SAME table Stage 4 will write into the fragment. Adding or removing a
# key in either source without updating the other (or changing a target
# canonical family) will fail this single fail-on-first-divergence loop.
#
# Why paste-duplicate instead of factoring into bin/fam_canonical.jq:
# the design plan (§5) chose this shape because (a) the table is small,
# (b) its callsite is a Bash here-doc inside a fragment, and (c) the
# verification boundary lives HERE in smoke — divergence fails AF-DRIFT
# loudly rather than silently dropping at runtime.
#
# importlib trick: source-family-map.py has hyphens in its name, so a
# plain `from source_family_map import ...` won't resolve. The script
# itself does `sys.path.insert(0, .../bin)` at module load to find
# `_common`, so importlib can reuse that path setup.
af_drift_keys=$(python3 -c "
import importlib.util
spec = importlib.util.spec_from_file_location('sfm', '$TOOLS/source-family-map.py')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
for k in sorted(mod.CANONICAL): print(k)
for k in sorted(mod.DRIFT_MAP): print(k)
" 2>/dev/null)
af_drift_fail=""
af_drift_count=0
while IFS= read -r k; do
    [[ -z "$k" ]] && continue
    af_drift_count=$((af_drift_count+1))
    py_out=$("$TOOLS/source-family-map.py" --input "$k" 2>/dev/null) || py_out="UNKNOWN"
    jq_out=$(printf '%s' "\"$k\"" | jq -r '
      def fam_canonical($raw):
        ((if ($raw | type) == "string" then $raw else "" end)
         | gsub("^[[:space:]]+|[[:space:]]+$"; "")
         | ascii_downcase) as $k |
        if   $k == "" then null
        elif $k == "diff-family"        or $k == "structural-family"
          or $k == "policy-family"      or $k == "ux-family"
          or $k == "security-family"    or $k == "holistic-family"
          or $k == "external-deep-family" or $k == "external-add-family" then $k
        elif $k == "stale-line-ref"     or $k == "stale_line_ref"
          or $k == "stale-behavior-claim" or $k == "stale_behavior_claim" then "policy-family"
        elif $k == "prompt-injection"   or $k == "prompt_injection"
          or $k == "input-validation"   or $k == "input_validation"
          or $k == "path-traversal"     or $k == "path_traversal"
          or $k == "terminal-injection" or $k == "terminal_injection" then "security-family"
        else null end;
      fam_canonical(.) // "UNKNOWN"
    ')
    if [[ "$py_out" != "$jq_out" ]]; then
        af_drift_fail="key='$k' Py='$py_out' jq='$jq_out'"
        break
    fi
done <<< "$af_drift_keys"

if [[ -z "$af_drift_fail" ]] && [[ "$af_drift_count" -gt 0 ]]; then
    pass "AF-DRIFT: bin/source-family-map.py CANONICAL+DRIFT_MAP ($af_drift_count keys) agree with in-jq fam_canonical (paste-duplicated from fragments/01-detection.md §1.5 step 4)"
elif [[ "$af_drift_count" == "0" ]]; then
    fail "AF-DRIFT: extracted 0 keys from source-family-map.py (importlib failure?)"
else
    fail "AF-DRIFT: $af_drift_fail"
fi

# AF-DRIFT-EDGE: normalization parity for the cases the table-key loop
# above doesn't exercise. Both readers strip whitespace and lowercase
# before lookup (Python: raw.strip().lower(); jq: gsub(...)
# | ascii_downcase). The empty / unknown cases also lump together —
# Python CLI exits 64 (empty) or 3 (unknown), test catches both as
# "UNKNOWN"; jq returns null, `// "UNKNOWN"` lifts both to "UNKNOWN".
# A regression in either reader's normalization (e.g., losing ascii_
# downcase, or Python switching to a Unicode-aware lower) shows up
# here even though both tables still agree on the canonical keys.
af_drift_edge_fail=""
af_drift_edge_count=0
# Each line: "<input>|<expected>". Bare-key loop above proves canonical
# pass-through; these probe whitespace, mixed-case, drift+case combo,
# empty, and a never-seen unknown.
for edge in \
    "  diff-family  |diff-family" \
    "Diff-Family|diff-family" \
    "PROMPT-INJECTION|security-family" \
    " stale_line_ref|policy-family" \
    "|UNKNOWN" \
    "totally-fake-family|UNKNOWN"
do
    af_drift_edge_count=$((af_drift_edge_count+1))
    in_val="${edge%%|*}"
    expected="${edge##*|}"
    py_out=$("$TOOLS/source-family-map.py" --input "$in_val" 2>/dev/null) || py_out="UNKNOWN"
    jq_out=$(jq -nr --arg raw "$in_val" '
      def fam_canonical($raw):
        ((if ($raw | type) == "string" then $raw else "" end)
         | gsub("^[[:space:]]+|[[:space:]]+$"; "")
         | ascii_downcase) as $k |
        if   $k == "" then null
        elif $k == "diff-family"        or $k == "structural-family"
          or $k == "policy-family"      or $k == "ux-family"
          or $k == "security-family"    or $k == "holistic-family"
          or $k == "external-deep-family" or $k == "external-add-family" then $k
        elif $k == "stale-line-ref"     or $k == "stale_line_ref"
          or $k == "stale-behavior-claim" or $k == "stale_behavior_claim" then "policy-family"
        elif $k == "prompt-injection"   or $k == "prompt_injection"
          or $k == "input-validation"   or $k == "input_validation"
          or $k == "path-traversal"     or $k == "path_traversal"
          or $k == "terminal-injection" or $k == "terminal_injection" then "security-family"
        else null end;
      fam_canonical($raw) // "UNKNOWN"
    ')
    if [[ "$py_out" != "$expected" ]] || [[ "$jq_out" != "$expected" ]]; then
        af_drift_edge_fail="input='$in_val' expected='$expected' py='$py_out' jq='$jq_out'"
        break
    fi
done

if [[ -z "$af_drift_edge_fail" ]] && [[ "$af_drift_edge_count" -gt 0 ]]; then
    pass "AF-DRIFT-EDGE: whitespace/case/empty/unknown normalization parity ($af_drift_edge_count cases agree across Python + in-jq readers)"
else
    fail "AF-DRIFT-EDGE: $af_drift_edge_fail"
fi

# BB-* assertions cover the three branch-behind-base advisory sites
# (§0.6a passive in :review, §7.6a active in :fix, §3a active in :add).
# Each block-scoped slice (awk-extracted) is checked for: section
# header, behind-count rev-list (passive) or fetch routing structure
# (active: fetch_ok flag + narrow refspec + 30s GNU-timeout branch),
# merge_ref / comparison_ref assignment AND consumer-side
# Stop-guidance consumption, conflict-aware stash-pop block (:fix
# only), AskUserQuestion grant + invocation prose (:add), Proceed /
# Stop / Abort trace fields (active) or Proceed-only
# preflight_warnings entry (passive — Stop/Abort audit lines deferred
# pending §0.15 trace-dir bring-up), and unresolvable-path warnings on
# degraded paths.
BB_PRE="$REPO/fragments/00-preflight.md"
# Section-extract §0.6a body so the consumer-side `git merge $comparison_ref`
# assertion can't be satisfied by drift elsewhere in the file (mirrors BB-2's
# §7.6a-scoping). The consumer assertion pins the Stop-guidance fix from
# round 1: a future regression to `git merge $base_branch` would leave the
# assignment-side greps satisfied while silently restoring the no-op-after-
# freshness-gate-option-(b) bug. Same idea drives the `git merge $merge_ref`
# greps in BB-2/BB-3.
BB_PRE_BODY=$(awk '/^### 0\.6a\. /{flag=1} /^### 0\.7\. /{flag=0} flag' "$BB_PRE")
if grep -q '### 0.6a. Branch-behind-base advisory' <<<"$BB_PRE_BODY" \
   && grep -qF 'git rev-list --count "HEAD..$comparison_ref"' <<<"$BB_PRE_BODY" \
   && grep -qF 'git merge $comparison_ref' <<<"$BB_PRE_BODY" \
   && grep -q 'preflight_warnings+=("branch_behind_base proceeded' <<<"$BB_PRE_BODY" \
   && grep -qF 'branch_behind_base unresolvable comparison_ref=' <<<"$BB_PRE_BODY"; then
    pass "BB-1: /matthewsreview:review §0.6a branch-behind-base gate present (passive count vs comparison_ref + Stop guidance merges comparison_ref + preflight_warnings buffer + unresolvable-path warning)"
else
    fail "BB-1: §0.6a header/rev-list/Stop-merge-comparison_ref/preflight_warnings/unresolvable-path warning missing in $BB_PRE (§0.6a slice)"
fi

BB_FIX="$REPO/fragments/08-fix-loader.md"
# Section-extract §7.6a body so assertions can't be satisfied by content
# from §7.6 or earlier — the legacy `git stash pop || true` line also
# appears in §7.6's staleness-abort block (out of scope), so a file-scoped
# grep would silently pass even if §7.6a's stash-pop bash regressed.
# (a) Stop and (c) Abort each reference the §7.6a stash-pop block via a
# distinct prose anchor; pin both so a future edit that drops the Abort
# path (while keeping Stop's) fails BB-2. The conflict-aware shape
# (`stash_pop_conflict=true` + `git stash pop 2>>"$trace_log_path"`) is
# pinned explicitly so a regression that reverts §7.6a back to bare
# `git stash pop || true` (or deletes the block entirely) fails BB-2 —
# both literals are required because the bare flag string `stash_pop_conflict`
# would also match the conditional prose hint, and we need to lock in the
# conflict-aware bash itself, not just the recovery suffix.
BB_FIX_BODY=$(awk '/^### 7\.6a\. /{flag=1} /^### 7\.7\. /{flag=0} flag' "$BB_FIX")
# Per-bullet slice for §7.6a (c) Abort, so the Abort bullet's bash is
# asserted to perform the action its prose names — not just appear
# somewhere in the enclosing §7.6a section. The (a) Stop bullet contains
# the same `git stash pop`/`stash_pop_conflict=true` literals inline;
# without per-bullet slicing a regression that drops (c)'s stash-pop
# bash (as round-3 of the dual-review loop nearly did) would still pass
# BB-2 by matching against (a)'s copies. The awk:
#   - starts capturing on `- **(c) Abort` line
#   - stops on the next bulleted `- **(` item (any letter)
#   - stops on the next `### ` header (defensive)
BB_FIX_ABORT_BODY=$(awk '/^- \*\*\(c\) Abort/{flag=1; print; next} /^- \*\*\(/{flag=0} /^### /{flag=0} flag' <<<"$BB_FIX_BODY")
# Routing structure assertions (`fetch_ok=true`, `|| fetch_ok=false`,
# `if $fetch_ok; then`, `merge_ref=`) prove the fetch-conditional shape
# itself — without them, a future regression to the old unconditional
# `||`-chain (`git fetch ... || true; behind=origin || local || 0`)
# would still satisfy the rev-list-string greps and silently revert the
# narrow-refspec stale-origin guard + Stop-guidance-uses-fresh-ref fixup.
# `timeout 30 git fetch` pins the GNU-timeout branch of the 30s soft
# timeout (the watchdog branch is fallback-only); a regression to bare
# `git fetch` would now fail BB-2.
if grep -q '### 7.6a. Branch-behind-base advisory' <<<"$BB_FIX_BODY" \
   && grep -qF 'git fetch origin' <<<"$BB_FIX_BODY" \
   && grep -qF 'timeout 30 git fetch' <<<"$BB_FIX_BODY" \
   && grep -qF 'refs/heads/$base_branch:refs/remotes/origin/$base_branch' <<<"$BB_FIX_BODY" \
   && grep -qF 'fetch_ok=true' <<<"$BB_FIX_BODY" \
   && grep -qF '|| fetch_ok=false' <<<"$BB_FIX_BODY" \
   && grep -qF 'if $fetch_ok; then' <<<"$BB_FIX_BODY" \
   && grep -qF 'git rev-list --count "HEAD..origin/$base_branch"' <<<"$BB_FIX_BODY" \
   && grep -qF 'git rev-list --count "HEAD..$base_branch"' <<<"$BB_FIX_BODY" \
   && grep -qF 'merge_ref=' <<<"$BB_FIX_BODY" \
   && grep -qF 'git merge $merge_ref' <<<"$BB_FIX_BODY" \
   && grep -qF 'fetch_note=' <<<"$BB_FIX_BODY" \
   && grep -qF 'stash_pop_conflict=true' <<<"$BB_FIX_BODY" \
   && grep -qF 'git stash pop 2>>"$trace_log_path"' <<<"$BB_FIX_BODY" \
   && grep -qF 'Run the stash-pop block' <<<"$BB_FIX_BODY" \
   && grep -qF 'Run the same stash-pop block as (a)' <<<"$BB_FIX_BODY" \
   && grep -qF 'branch_behind_base proceeded behind=%s merge_ref=%s fetch_ok=%s' <<<"$BB_FIX_BODY" \
   && grep -qF 'branch_behind_base stopped behind=%s merge_ref=%s fetch_ok=%s stash_pop_conflict=%s' <<<"$BB_FIX_BODY" \
   && grep -qF 'branch_behind_base aborted behind=%s merge_ref=%s fetch_ok=%s stash_pop_conflict=%s' <<<"$BB_FIX_BODY" \
   && grep -qF 'branch_behind_base unresolvable fetch_ok=true local_resolve=false' <<<"$BB_FIX_BODY" \
   && grep -qF 'branch_behind_base unresolvable fetch_ok=false local_resolve=false' <<<"$BB_FIX_BODY" \
   && grep -qF 'branch_behind_base degraded fetch_ok=false local_resolve=true behind=0' <<<"$BB_FIX_BODY" \
   && grep -qF 'stash_pop_conflict=false' <<<"$BB_FIX_ABORT_BODY" \
   && grep -qF 'git stash pop 2>>"$trace_log_path"' <<<"$BB_FIX_ABORT_BODY" \
   && grep -qF 'branch_behind_base aborted behind=%s merge_ref=%s fetch_ok=%s stash_pop_conflict=%s' <<<"$BB_FIX_ABORT_BODY"; then
    pass "BB-2: /matthewsreview:fix §7.6a branch-behind-base gate present (active fetch with 30s timeout + fetch_ok routing structure + merge_ref tracked AND consumed in Stop guidance + fetch_note + stash-pop conflict-aware block + Stop AND Abort references + Proceed/Stop/Abort traces + unresolvable-path warning both fetch_ok branches + degraded-path warning + Abort-bullet stash-pop literals pinned)"
else
    fail "BB-2: §7.6a header/fetch with 30s timeout/fetch_ok routing/merge_ref assignment AND Stop-consumer/fetch_note/stash-pop conflict-aware block/Stop AND Abort references/Proceed/Stop/Abort traces/unresolvable-path warning/degraded-path warning/Abort-bullet stash-pop literals missing in $BB_FIX (§7.6a slice)"
fi

BB_ADD="$REPO/commands/add.md"
# Section-extract §3a body so §3a-internal greps can't be satisfied by
# drift elsewhere in the file (mirrors BB-2's §7.6a-scoping). Frontmatter
# `AskUserQuestion` grant stays file-scoped against `$BB_ADD` (line 1 isn't
# in the §3a slice); the in-prose `AskUserQuestion` invocation grep stays
# slice-scoped so a regression that drops §3a's prompt while keeping the
# frontmatter grant still fails BB-3.
BB_ADD_BODY=$(awk '/^### 3a\. /{flag=1} /^### 4\. /{flag=0} flag' "$BB_ADD")
if grep -q '### 3a. Branch-behind-base advisory' <<<"$BB_ADD_BODY" \
   && grep -qF 'git fetch origin' <<<"$BB_ADD_BODY" \
   && grep -qF 'timeout 30 git fetch' <<<"$BB_ADD_BODY" \
   && grep -qF 'refs/heads/$base_branch:refs/remotes/origin/$base_branch' <<<"$BB_ADD_BODY" \
   && grep -qF 'fetch_ok=true' <<<"$BB_ADD_BODY" \
   && grep -qF '|| fetch_ok=false' <<<"$BB_ADD_BODY" \
   && grep -qF 'if $fetch_ok; then' <<<"$BB_ADD_BODY" \
   && grep -qF 'git rev-list --count "HEAD..origin/$base_branch"' <<<"$BB_ADD_BODY" \
   && grep -qF 'git rev-list --count "HEAD..$base_branch"' <<<"$BB_ADD_BODY" \
   && grep -qF 'merge_ref=' <<<"$BB_ADD_BODY" \
   && grep -qF 'git merge $merge_ref' <<<"$BB_ADD_BODY" \
   && grep -qF 'fetch_note=' <<<"$BB_ADD_BODY" \
   && grep -qE '^allowed-tools:.*AskUserQuestion' "$BB_ADD" \
   && grep -qF 'ASK once:' <<<"$BB_ADD_BODY" \
   && grep -qF 'branch_behind_base proceeded behind=%s merge_ref=%s fetch_ok=%s' <<<"$BB_ADD_BODY" \
   && grep -qF 'branch_behind_base stopped behind=%s merge_ref=%s fetch_ok=%s' <<<"$BB_ADD_BODY" \
   && grep -qF 'branch_behind_base aborted behind=%s merge_ref=%s fetch_ok=%s' <<<"$BB_ADD_BODY" \
   && grep -qF 'branch_behind_base unresolvable fetch_ok=true local_resolve=false' <<<"$BB_ADD_BODY" \
   && grep -qF 'branch_behind_base unresolvable fetch_ok=false local_resolve=false' <<<"$BB_ADD_BODY" \
   && grep -qF 'branch_behind_base degraded fetch_ok=false local_resolve=true behind=0' <<<"$BB_ADD_BODY"; then
    pass "BB-3: /matthewsreview:add §3a branch-behind-base gate present (active fetch with 30s timeout + fetch_ok routing structure + merge_ref tracked AND consumed in Stop guidance + fetch_note + AskUserQuestion grant + §3a ASK prose + Proceed/Stop/Abort traces + unresolvable-path warning both fetch_ok branches + degraded-path warning)"
else
    fail "BB-3: §3a header/fetch with 30s timeout/fetch_ok routing/merge_ref assignment AND Stop-consumer/fetch_note/AskUserQuestion grant AND §3a ASK/Proceed/Stop/Abort traces/unresolvable-path warning/degraded-path warning missing in $BB_ADD (§3a slice)"
fi

# UV-1: every uv-shebang Python helper uses `--quiet --script`, not bare
# `--script`. On a cold uv cache, `uv run --script` prints
# `Installed N packages in Xms` to stderr the first time each helper's
# inline-dep set is resolved; smoke captures stderr-into-stdout via
# `2>&1` and the install line then contaminates JSON outputs that
# downstream `jq`s parse — producing flaky `Invalid numeric literal`
# failures whose first-affected assertion drifts with cache state.
# `--quiet` suppresses the install summary; verified locally that the
# JSON output is otherwise unchanged. (GH #13.)
UV_HELPERS=(
    parse-with-repair.py
    group-fixes.py
    artifact-render.py
    artifact-patch.py
    source-family-map.py
    parse-validator-result.py
)
uv1_missing=()
for helper in "${UV_HELPERS[@]}"; do
    shebang=$(head -1 "$REPO/bin/$helper")
    if [[ "$shebang" != '#!/usr/bin/env -S uv run --quiet --script' ]]; then
        uv1_missing+=("$helper:$shebang")
    fi
done
if [[ ${#uv1_missing[@]} -eq 0 ]]; then
    pass "UV-1 (GH #13): all 6 bin/*.py helpers use 'uv run --quiet --script' shebang (suppresses cold-cache install summary)"
else
    fail "UV-1: helpers missing --quiet shebang: ${uv1_missing[*]}"
fi

# SG-1: Phase 3 below-gate `reason` write must not leak a raw null/empty
# `$score` into the persisted artifact. §3.4 (fragments/04-scoring-gate.md)
# now contains an explicit null-handling clause: when `score_phase3` is
# null, treat `(score >= 45)` as false and write a descriptive reason
# rather than `(score null)` / `(score )`. Prevents the GH #11 corruption
# where parse-failure / missing-id paths from §3.3 (which set score to
# null) bled raw internal state into a user-facing artifact field.
SG_MD="$REPO/fragments/04-scoring-gate.md"
sg1_missing=()
for phrase in \
    'When `score` is null' \
    'treat `(score >= $phase3_gate)` as false' \
    'score unavailable — Phase 3 score missing or unparseable'; do
    if ! grep -qF "$phrase" "$SG_MD"; then
        sg1_missing+=("$phrase")
    fi
done
if [[ ${#sg1_missing[@]} -eq 0 ]]; then
    pass "SG-1 (GH #11): §3.4 Phase-3 below-gate write null-guards \$score (no raw null/empty parens in user-visible reason)"
else
    fail "SG-1: missing §3.4 null-handling phrases in $SG_MD: ${sg1_missing[*]}"
fi

# PF-1: every role is materialized before the first classifier dispatch.
# Otherwise a configured classifier model is unavailable to the first
# model-consuming preflight step.
PF_MD="$REPO/fragments/00-preflight.md"
pf_plan_line=$(grep -n 'Materialize every role now' "$PF_MD" | cut -d: -f1)
pf_dispatch_line=$(grep -n 'agent-role user_facing_classifier' "$PF_MD" | cut -d: -f1 | head -1)
if [[ -n "$pf_plan_line" && -n "$pf_dispatch_line" \
   && "$pf_plan_line" -lt "$pf_dispatch_line" ]]; then
    pass "PF-1: preflight resolves the model plan before classifier dispatch"
else
    fail "PF-1: classifier can run before its configured role exists" \
      "plan=$pf_plan_line dispatch=$pf_dispatch_line"
fi

# ------------------------------------------------------------------ CR-* /matthewsreview:codex-review structural assertions
# Plan: codex-review (plans/codex-review.md). Codex-driven peer to
# /matthewsreview:review. These assertions guard the static structure of
# the new command + fragments — full end-to-end behavior requires real
# Codex jobs and real git diffs and is exercised by the user's
# pre-merge real-PR runs. Structural drift (missing flag, wrong
# allowed-tools, missing fragment reference) would silently degrade
# the command without failing any helper-level test, hence these.

CR_CMD="$REPO/commands/codex-review.md"

# CR-1: command file present, frontmatter has required allowed-tools
# entries (node grant for codex-companion, AskUserQuestion for retry
# escalation, Read/Agent/BashOutput/KillShell for orchestration), and
# the --effort + --full flags appear in argument-hint.
if [[ -f "$CR_CMD" ]] \
    && grep -qF 'Bash(node:*)' "$CR_CMD" \
    && grep -qF 'AskUserQuestion' "$CR_CMD" \
    && grep -qF 'Bash(artifact-seed.sh:*)' "$CR_CMD" \
    && grep -qF '[--effort <low|medium|high|xhigh|max|ultra>]' "$CR_CMD" \
    && grep -qF '[--full]' "$CR_CMD"; then
    pass "CR-1: commands/codex-review.md present with codex/effort/full grants"
else
    fail "CR-1: codex-review.md missing or has incomplete frontmatter (need node grant, AskUserQuestion, --effort, --full)"
fi

# CR-2: codex-review.md sets reviewer_sources_label=internal-codex in
# its argument-handling block so 00-preflight.md's --reviewer-sources
# substitution gets the right value. Guards against a regression that
# drops the working-context assignment and silently produces an
# artifact tagged ["internal"] (would still validate but lose the
# Codex-vs-Claude lineage marker).
if grep -qF 'reviewer_sources_label="internal-codex"' "$CR_CMD"; then
    pass "CR-2: codex-review.md sets reviewer_sources_label=internal-codex (Phase 0 step 0.15 substitution)"
else
    fail "CR-2: codex-review.md missing reviewer_sources_label working-context assignment"
fi

# CR-3: codex-review.md resolves a usable Codex transport before Phase 0.
# Companion readiness and the narrow shared-mode cold-start bypass remain;
# an authenticated standalone CLI selects agent-dispatch, and only the
# absence of both transports fails with actionable setup guidance.
if grep -qF 'node "$CODEX_COMPANION" setup --json' "$CR_CMD" \
    && grep -qF '"$cx_mode" == "shared"' "$CR_CMD" \
    && grep -qF 'command -v codex' "$CR_CMD" \
    && grep -qF 'codex_launch_mode="agent-dispatch"' "$CR_CMD" \
    && grep -qF 'ERROR: no usable Codex transport.' "$CR_CMD" \
    && grep -qF '/codex:setup, or install/authenticate the codex CLI' "$CR_CMD"; then
    pass "CR-3: codex-review.md selects companion or standalone Codex fallback and fails only when neither is usable"
else
    fail "CR-3: codex-review.md transport readiness gate missing or incomplete"
fi

# CR-4: each new Codex fragment exists, is non-trivial, and references
# the codex-companion task primitive. Catches an accidental commit
# of an empty file or a refactor that drops the companion invocation.
CR_FRAGMENTS=(
    "fragments/01-codex-detection.md"
    "fragments/05-codex-validation.md"
    "fragments/06-codex-cross-cutting.md"
)
cr4_missing=""
for f in "${CR_FRAGMENTS[@]}"; do
    p="$REPO/$f"
    if [[ ! -s "$p" ]] || [[ "$(wc -c <"$p")" -lt 1000 ]]; then
        cr4_missing="$cr4_missing $f(empty)"
    elif ! grep -qF 'node "$CODEX_COMPANION" task --background' "$p"; then
        cr4_missing="$cr4_missing $f(no-task-launch)"
    fi
done
if [[ -z "$cr4_missing" ]]; then
    pass "CR-4: codex fragments present (>= 1000 bytes each) and all reference 'node \"\$CODEX_COMPANION\" task --background'"
else
    fail "CR-4: codex fragments incomplete:$cr4_missing"
fi

# CR-5: 00-preflight.md step 0.15 passes --reviewer-sources to
# artifact-seed.sh so codex-review's reviewer_sources_label flows
# through. Guards against a regression that reverts to the old
# unconditional ["internal"] hardcode.
if grep -qF -- '--reviewer-sources "${reviewer_sources_label:-internal}"' "$REPO/fragments/00-preflight.md"; then
    pass "CR-5: 00-preflight.md step 0.15 passes --reviewer-sources to artifact-seed.sh"
else
    fail "CR-5: 00-preflight.md missing --reviewer-sources \"\${reviewer_sources_label:-internal}\" in artifact-seed.sh invocation"
fi

# CR-6: 01-codex-detection.md's lens dispatch table runs L7 always
# (when not trivial) — codex-review's holistic lens is NOT --ensemble-
# gated like in :review. This is a behavior fork from :review that
# the grill explicitly resolved.
if grep -qF '| L7 — holistic review | `$effort` | `trivial_mode != true` |' "$REPO/fragments/01-codex-detection.md"; then
    pass "CR-6: 01-codex-detection.md L7 always runs (not ensemble-gated; matches grill decision)"
else
    fail "CR-6: 01-codex-detection.md L7 row missing or wrongly gated"
fi

# CR-7: 05-codex-validation.md explicitly disables Wave 2 (chain
# retry). Plan §2: bounded scope. Guards against an accidental copy
# of 05-validation.md's Wave 2 logic.
if grep -qF 'Wave 2 — DISABLED in codex-review' "$REPO/fragments/05-codex-validation.md"; then
    pass "CR-7: 05-codex-validation.md explicitly disables Wave 2 (bounded scope per plan §2)"
else
    fail "CR-7: 05-codex-validation.md missing 'Wave 2 — DISABLED' marker"
fi

# CR-PVC-1: both Phase 4 fragments gate the tree-cleanliness sweep
# on `pre_validator_clean == true` so a user who chose Phase 0 step
# 0.8 option 2 ("include uncommitted changes") doesn't get their
# work clobbered by `git checkout -- .`. The pre_validator_clean
# capture lives in 00-preflight.md step 0.8; both validation
# fragments must consult it before sweeping. Same pattern
# commands/add.md uses.
PVC_PREFLIGHT="$REPO/fragments/00-preflight.md"
PVC_REVIEW="$REPO/fragments/05-validation.md"
PVC_CODEX="$REPO/fragments/05-codex-validation.md"
if grep -qF 'pre_validator_clean=true' "$PVC_PREFLIGHT" \
    && grep -qF 'pre_validator_clean=false' "$PVC_PREFLIGHT" \
    && grep -qF 'if [[ "$pre_validator_clean" == "true" ]]; then' "$PVC_REVIEW" \
    && grep -qF 'phase_4_tree_dirty_sweep_skipped' "$PVC_REVIEW" \
    && grep -qF 'if [[ "$pre_validator_clean" == "true" ]]; then' "$PVC_CODEX" \
    && grep -qF 'phase_4_tree_dirty_sweep_skipped' "$PVC_CODEX"; then
    pass "CR-PVC-1: 00-preflight captures pre_validator_clean; both Phase 4 fragments gate tree-cleanliness sweep on it (preserves user work when Phase 0 step 0.8 option 2 chosen)"
else
    fail "CR-PVC-1: pre_validator_clean wiring incomplete — preflight capture or Phase 4 gate missing"
fi

# CR-8: plugin.json version bumped to 0.3.0 for the new command.
# CLAUDE.md "How to work on new changes" requires a version bump on
# user-visible changes; minor bump for new command per precedent.
PV=$(jq -r '.version' "$REPO/.claude-plugin/plugin.json")
case "$PV" in
    0.[3-9].*|0.[1-9][0-9].*|[1-9].*)
        pass "CR-8: plugin.json version bumped to $PV (>= 0.3.0 for new codex-review command)"
        ;;
    *)
        fail "CR-8: plugin.json version is $PV — expected >= 0.3.0 for the new /matthewsreview:codex-review command"
        ;;
esac

# CR-9: codex-poll.sh owns the companion-specific storedJob pluck; all
# execution fragments consume its normalized raw_output field. Keeping the
# storage path in one helper prevents drift and lets agent-dispatch expose
# the same verdict shape.
CR_PLUCK_FRAGMENTS=(
    "fragments/01-codex-detection.md"
    "fragments/05-codex-validation.md"
    "fragments/06-codex-cross-cutting.md"
)
cr9_violations=""
if ! grep -qF '.storedJob.result.rawOutput // .storedJob.payload.rawOutput // .storedJob.rawOutput // ""' "$REPO/bin/codex-poll.sh"; then
    cr9_violations="$cr9_violations bin/codex-poll.sh(missing-canonical-chain)"
fi
for f in "${CR_PLUCK_FRAGMENTS[@]}"; do
    p="$REPO/$f"
    if grep -qF '.storedJob.' "$p"; then
        cr9_violations="$cr9_violations $f(direct-storage-pluck)"
    fi
    if ! grep -qF ".raw_output // \"\"" "$p"; then
        cr9_violations="$cr9_violations $f(missing-normalized-output)"
    fi
done
if [[ -z "$cr9_violations" ]]; then
    pass "CR-9: codex-poll owns storedJob pluck; fragments consume transport-neutral raw_output"
else
    fail "CR-9: Codex rawOutput normalization contract violated:$cr9_violations"
fi

# CR-10: Phase 4 codex-validation type-guards $raw_repaired to an object
# before the apply-decisions projection. parse-with-repair.py returns 0
# for arrays/strings/etc. when a shape-fixer's output is parseable but
# wrong-shape (e.g. wrapped its object in a single-element array, or
# repair salvaged garbage into a string). The downstream projection's
# $raw.note access and light-lane .id extraction both crash on non-
# object input — halting the apply-decisions batch via first-fail
# instead of degrading just that finding to `uncertain`. Guard requires
# a `jq -c 'if type=="object" then . else {} end'` filter between the
# parse-with-repair line and the projection.
if grep -qE 'jq -c .*if type==\"object\"' "$REPO/fragments/05-codex-validation.md"; then
    pass "CR-10: 05-codex-validation.md type-guards \$raw_repaired to object before projection (regression guard for non-object shape-fixer output)"
else
    fail "CR-10: 05-codex-validation.md missing jq type==\"object\" guard between parse-with-repair and the apply-decisions projection"
fi

# CR-11: Phase 1 codex-normalizer §1.5.1 filters non-object elements out
# of the normalizer array before the schema-guard `. + {file, line_range}`
# projection. Without `select(type == "object")`, a normalizer that
# returned a parseable array containing non-object elements (e.g.
# `["no findings"]` or `[{...}, "extra prose"]`) would crash jq with
# "string and object cannot be added", killing all Phase 1 candidates.
# Mirrors CR-10's defensive type-guard discipline (same bug class, found
# in two different fragments by sequential xhigh-effort Codex reviews).
if grep -qE 'select\(type == "object"\)' "$REPO/fragments/01-codex-detection.md"; then
    pass "CR-11: 01-codex-detection.md guards normalizer iteration with select(type == \"object\") (regression guard for non-object element crash)"
else
    fail "CR-11: 01-codex-detection.md missing select(type == \"object\") guard in §1.5.1 normalizer-array projection"
fi

# CR-12: fragments/01-detection.md §1.3 parallel-dispatch contract.
# Two-part guard against the lens-prompt-extraction regression class
# (PR #23 + the partial fix in 0466d04, then re-reproduced 2026-05-03
# on beta-briefing/onboard-page despite the directive being live).
#
# CR-12a: top-of-section "SINGLE orchestrator turn" directive present
# between the §1.3 header and the first L1 sub-section.
#
# CR-12b: per-lens sub-sections (#### L1 through end of §1.3) contain
# ZERO imperative dispatch phrases ("Launch one `Agent` tool-use" /
# "and dispatch."). The directive's prose alone is not load-bearing
# — local imperatives in the per-lens sub-sections override it
# structurally. This guard fails if a future fragment edit
# reintroduces imperative-shaped per-lens recipes.
#
# CR-12a window: between "### 1.3." and "#### L1 ".
# CR-12b window: between "#### L1 " and "### 1.4." (catches all per-lens
# sub-sections L1–L7 plus any closing dispatch sub-section before §1.4).

cr12a_window=$(awk '
    /^### 1\.3\./        {in_window=1; next}
    /^#### L1 /          {if (in_window) in_window=0}
    in_window            {print}
' "$REPO/fragments/01-detection.md" | tr '\n' ' ')
if printf '%s' "$cr12a_window" | grep -qE 'SINGLE[[:space:]]+(orchestrator[[:space:]]+turn|batch)'; then
    pass "CR-12a: fragments/01-detection.md §1.3 carries top-of-section SINGLE-turn parallel-dispatch directive (regression guard for lens-prompt extraction serializing dispatch)"
else
    fail "CR-12a: fragments/01-detection.md §1.3 missing top-of-section 'SINGLE turn/batch' directive between §1.3 header and the first L1 sub-section"
fi

# Flatten newlines before the imperative grep — the per-lens prose
# wraps at ~70 chars, so "and\ndispatch." (two-line wrap) is exactly
# the failure mode this guard targets. Mirrors PFD-9's tr-flatten
# pattern; without it a wrapped "Launch one ... and\ndispatch." would
# slip past line-anchored grep -c.
cr12b_window_flat=$(awk '
    /^#### L1 /     {in_window=1}
    /^### 1\.4\./   {in_window=0}
    in_window       {print}
' "$REPO/fragments/01-detection.md" | tr '\n' ' ')
cr12b_imperatives=$(printf '%s\n' "$cr12b_window_flat" \
    | grep -oE '(Launch one `Agent` tool-use|and[[:space:]]+dispatch\.)' \
    | wc -l \
    | tr -d '[:space:]')
if [[ "$cr12b_imperatives" == "0" ]]; then
    pass "CR-12b: per-lens sub-sections in fragments/01-detection.md §1.3 contain no imperative dispatch phrases (regression guard for serial-dispatch reintroduction via per-lens recipes)"
else
    fail "CR-12b: $cr12b_imperatives imperative dispatch phrase(s) ('Launch one \`Agent\` tool-use' / 'and dispatch.') found in fragments/01-detection.md §1.3 per-lens sub-sections — these reintroduce serial dispatch despite the §1.3 top-of-section directive"
fi

# CR-15: fragments/01-detection.md §1.3 "#### Dispatch turn"
# sub-section hosts the Phase 1 pre-dispatch init block
# (phase_1_start_epoch + internal_candidates). Without
# phase_1_start_epoch in the dispatch sub-section, a top-to-bottom
# orchestrator captures the start time AFTER §1.3 dispatches the
# lenses and phase_1_elapsed under-reports by the lens duration.
# internal_candidates is co-located for structural cleanliness (the
# seed value belongs with the dispatch it seeds); duplicating it
# back into §1.4 would re-introduce the original layout drift via
# last-write-wins source-order reading.
#
# Three sub-checks:
#   a. positive guard — both vars present in the **pre-dispatch**
#      window (`#### Dispatch turn` → `**Dispatch.**` paragraph
#      marker). Tightening from "anywhere in the dispatch sub-section"
#      to "before **Dispatch.**" closes the regression class where a
#      future edit relocates the inits *below* the dispatch prose
#      while leaving them inside the same `####` sub-section — the
#      original ordering defect under a new disguise. Codex-flagged
#      finding from the round-1 review of the relocation PR.
#   b. negative twin — neither var present in §1.4 (`### 1.4.` →
#      `### 1.5.`). Catches future-edit duplication.
#   c. window sanity — both the dispatch-turn opening heading AND
#      the closing `#### ` heading are present. If either boundary
#      drifts, 15a's window expands or shrinks invalidly and would
#      silently mis-fire. Sanity guard.

cr15_pre_dispatch=$(awk '
    /^#### Dispatch turn/   {in_window=1; next}
    /^\*\*Dispatch\.\*\*/   {if (in_window) in_window=0}
    /^#### /                {if (in_window) in_window=0}
    in_window               {print}
' "$REPO/fragments/01-detection.md")

# CR-15c needs to verify BOTH boundary headings exist (start +
# end), the body between them is non-empty, AND the load-bearing
# `**Dispatch.**` paragraph marker is present (CR-15a's
# pre-dispatch window relies on `**Dispatch.**` as its closing
# boundary; if the marker is removed while a later `#### ` heading
# still exists, CR-15a's window silently widens back to the whole
# sub-section and accepts inits placed AFTER the dispatch prose —
# the original ordering defect under a new disguise). Track all
# four properties in awk and emit a status sentinel so the bash
# check can assert each.
cr15_window_status=$(awk '
    BEGIN                   {found_start=0; found_end=0; found_dispatch=0; content=0}
    /^#### Dispatch turn/   {found_start=1; in_window=1; next}
    /^#### /                {if (in_window) {in_window=0; found_end=1}}
    in_window && /^\*\*Dispatch\.\*\*/ {found_dispatch=1}
    in_window               {content++}
    END {
        printf "found_start=%d found_end=%d found_dispatch=%d content=%d\n",
               found_start, found_end, found_dispatch, content
    }
' "$REPO/fragments/01-detection.md")

cr15_section_14=$(awk '
    /^### 1\.4\./           {in_window=1; next}
    /^### 1\.5\./           {in_window=0}
    in_window               {print}
' "$REPO/fragments/01-detection.md")

# CR-15b also needs a window-status sanity check: if `### 1.4.` or
# `### 1.5.` is renamed/removed, cr15_section_14 goes empty and the
# negative-init check passes vacuously — same fail-open class CR-15c
# now closes for the dispatch window. Track the §1.4 window's
# boundaries explicitly.
cr15_section_14_status=$(awk '
    BEGIN                   {found_start=0; found_end=0; content=0}
    /^### 1\.4\./           {found_start=1; in_window=1; next}
    /^### 1\.5\./           {if (in_window) {in_window=0; found_end=1}}
    in_window               {content++}
    END {
        printf "found_start=%d found_end=%d content=%d\n",
               found_start, found_end, content
    }
' "$REPO/fragments/01-detection.md")

# CR-15a — positive guard. Whitespace-tolerant regex (mirrors
# CR-12a's `[[:space:]]+` precedent). For internal_candidates the
# optional-quote class `['"]?` accepts `'[]'`, `"[]"`, or bare
# `=[]` so trivial reformats don't trip the assertion. Window
# is the *pre-dispatch* portion only — `#### Dispatch turn`
# heading up to (but excluding) the `**Dispatch.**` paragraph
# marker, so the inits must come BEFORE the dispatch prose.
# Additionally requires the `**Dispatch.**` marker is present
# (via found_dispatch sentinel below) — without that requirement,
# removing the marker would silently widen cr15_pre_dispatch back
# to the whole sub-section and accept inits below the lens
# dispatch prose, defeating the ordering guarantee.
cr15a_found_dispatch_for_window=$(printf '%s\n' "$cr15_window_status" | grep -oE 'found_dispatch=[01]' | head -1 | cut -d= -f2)
cr15a_has_epoch=0
cr15a_has_pool=0
# Anchored regex: full-line match with optional leading/trailing
# whitespace. The prefix-only forms accepted `$(date)` without
# `+%s` (non-integer output, breaks `$(( - phase_1_start_epoch))`)
# and `internal_candidates='[]garbage'` — silent-pass paths under
# the broader pre-dispatch-window check. Anchoring closes both.
printf '%s\n' "$cr15_pre_dispatch" \
    | grep -qE '^[[:space:]]*phase_1_start_epoch[[:space:]]*=[[:space:]]*\$\(date[[:space:]]+\+%s\)[[:space:]]*$' \
    && cr15a_has_epoch=1
printf '%s\n' "$cr15_pre_dispatch" \
    | grep -qE "^[[:space:]]*internal_candidates[[:space:]]*=[[:space:]]*['\"]?\[\]['\"]?[[:space:]]*\$" \
    && cr15a_has_pool=1
if [[ "$cr15a_has_epoch" == "1" && "$cr15a_has_pool" == "1" && "$cr15a_found_dispatch_for_window" == "1" ]]; then
    pass "CR-15a: fragments/01-detection.md §1.3 '#### Dispatch turn' pre-dispatch window (heading → '**Dispatch.**') contains Phase 1 pre-dispatch init (phase_1_start_epoch + internal_candidates), and the '**Dispatch.**' marker bounding the window is present"
else
    cr15a_missing=""
    [[ "$cr15a_has_epoch" == "0" ]] && cr15a_missing="$cr15a_missing phase_1_start_epoch=\$(date +%s)"
    [[ "$cr15a_has_pool" == "0" ]] && cr15a_missing="$cr15a_missing internal_candidates='[]'"
    [[ "$cr15a_found_dispatch_for_window" != "1" ]] && cr15a_missing="$cr15a_missing **Dispatch.**_marker"
    fail "CR-15a: fragments/01-detection.md §1.3 pre-dispatch window (heading → '**Dispatch.**') incomplete —$cr15a_missing — either the inits drifted *below* '**Dispatch.**' (top-to-bottom orchestrator dispatches lenses before capturing the phase epoch — phase_1_elapsed under-reports), or the '**Dispatch.**' marker itself is missing (which would silently widen the window back to the whole sub-section)"
fi

# CR-15b — negative twin. Catches the regression where a future
# edit re-introduces the init in §1.4 alongside the dispatch-turn
# placement. Same regex as 15a, applied to the §1.4 → §1.5 window.
# Precision matters: the regex requires `=` then optional quote
# then `[]`, so it does NOT match the existing §1.4 sites:
#   - `internal_candidates=$(jq ...)` (no `[]`)
#   - `--argjson accum "$internal_candidates"` (no `=` after the
#     var name; that's a variable expansion)
#   - `--argjson internal "$internal_candidates"` (same)
#   - the §1.4 forward-pointer parenthetical (backticks, no `=`)
# CR-15b composite: window must be structurally sound (start +
# end + non-empty body) AND no violations within it. Same anchored
# regexes as CR-15a so a `=$(date)` (no +%s) or `=[]garbage` site
# in §1.4 would still trigger the duplication catch.
cr15b_section_14_start=$(printf '%s\n' "$cr15_section_14_status" | grep -oE 'found_start=[01]' | head -1 | cut -d= -f2)
cr15b_section_14_end=$(printf '%s\n' "$cr15_section_14_status" | grep -oE 'found_end=[01]' | head -1 | cut -d= -f2)
cr15b_section_14_content=$(printf '%s\n' "$cr15_section_14_status" | grep -oE 'content=[0-9]+' | head -1 | cut -d= -f2)
cr15b_violations=""
printf '%s\n' "$cr15_section_14" \
    | grep -qE '^[[:space:]]*phase_1_start_epoch[[:space:]]*=[[:space:]]*\$\(date[[:space:]]+\+%s\)[[:space:]]*$' \
    && cr15b_violations="$cr15b_violations phase_1_start_epoch_in_§1.4"
printf '%s\n' "$cr15_section_14" \
    | grep -qE "^[[:space:]]*internal_candidates[[:space:]]*=[[:space:]]*['\"]?\[\]['\"]?[[:space:]]*\$" \
    && cr15b_violations="$cr15b_violations internal_candidates_in_§1.4"
if [[ "$cr15b_section_14_start" == "1" && "$cr15b_section_14_end" == "1" && "$cr15b_section_14_content" =~ ^[1-9][0-9]*$ && -z "$cr15b_violations" ]]; then
    pass "CR-15b: fragments/01-detection.md §1.4 (heading present, body=$cr15b_section_14_content lines) contains no Phase 1 pre-dispatch init (negative twin against duplication regression)"
else
    cr15b_problems=""
    [[ "$cr15b_section_14_start" != "1" ]] && cr15b_problems="$cr15b_problems no_§1.4_heading"
    [[ "$cr15b_section_14_end" != "1" ]] && cr15b_problems="$cr15b_problems no_§1.5_heading"
    [[ ! "$cr15b_section_14_content" =~ ^[1-9][0-9]*$ ]] && cr15b_problems="$cr15b_problems empty_or_unparseable_§1.4_body(=$cr15b_section_14_content)"
    [[ -n "$cr15b_violations" ]] && cr15b_problems="$cr15b_problems duplication:$cr15b_violations"
    fail "CR-15b: fragments/01-detection.md §1.4 check failed —$cr15b_problems. Either the §1.4 window boundaries drifted (heading rename/removal would silently pass the negative check) or the pre-dispatch init was duplicated back into §1.4 (would re-introduce original layout drift via last-write-wins source-order reading)"
fi

# CR-15c — window sanity. Verifies BOTH the opening `#### Dispatch
# turn` heading AND a subsequent `#### ` boundary heading exist,
# the body between them is non-empty, AND the load-bearing
# `**Dispatch.**` paragraph marker is present (CR-15a relies on
# the marker as its closing boundary). A non-empty-window check
# alone is not enough: if the closing `#### ` heading is removed
# or demoted, the awk window simply expands to EOF and remains
# non-empty, so the success message ("a subsequent '#### '
# boundary follows it") would be false.
#
# All four properties are tracked in cr15_window_status. Each
# field is parsed with an anchored positive-integer / 0|1 regex
# and the bash check requires each parsed value to match its
# expected shape — a missing or malformed sentinel field becomes
# fail-closed (empty string fails the shape check), not
# fail-open (empty != "0" was previously accepted).
cr15c_found_start=$(printf '%s\n' "$cr15_window_status" | grep -oE 'found_start=[01]' | head -1 | cut -d= -f2)
cr15c_found_end=$(printf '%s\n' "$cr15_window_status" | grep -oE 'found_end=[01]' | head -1 | cut -d= -f2)
cr15c_found_dispatch=$(printf '%s\n' "$cr15_window_status" | grep -oE 'found_dispatch=[01]' | head -1 | cut -d= -f2)
cr15c_content=$(printf '%s\n' "$cr15_window_status" | grep -oE 'content=[0-9]+' | head -1 | cut -d= -f2)
if [[ "$cr15c_found_start" == "1" && "$cr15c_found_end" == "1" && "$cr15c_found_dispatch" == "1" && "$cr15c_content" =~ ^[1-9][0-9]*$ ]]; then
    pass "CR-15c: fragments/01-detection.md '#### Dispatch turn' window structurally sound (start=found, end=found, dispatch_marker=found, body=$cr15c_content lines)"
else
    cr15c_problems=""
    [[ "$cr15c_found_start" != "1" ]] && cr15c_problems="$cr15c_problems no_start_heading"
    [[ "$cr15c_found_end" != "1" ]] && cr15c_problems="$cr15c_problems no_end_heading"
    [[ "$cr15c_found_dispatch" != "1" ]] && cr15c_problems="$cr15c_problems no_dispatch_marker"
    [[ ! "$cr15c_content" =~ ^[1-9][0-9]*$ ]] && cr15c_problems="$cr15c_problems empty_or_unparseable_body(=$cr15c_content)"
    fail "CR-15c: fragments/01-detection.md '#### Dispatch turn' window malformed —$cr15c_problems. Silent-mis-fire risk: CR-15a's window would expand or shrink invalidly. Verify the '^#### Dispatch turn' heading, the next '^#### ' heading, and the '**Dispatch.**' paragraph marker all exist with content between them."
fi

# CR-13: codex-poll.sh watchdog wires up cleanly — single source of truth
# for codex-job liveness checking. plans/codex-watchdog.md (FU-5) replaces
# raw `node "$CODEX_COMPANION" status --json` polls with a helper that
# detects broker-vs-disk desync via a two-signal liveness check. Without
# it, a stalled codex turn leaves the broker reporting `running`
# indefinitely (real failure observed 2026-05-03, beta-briefing/onboard-page).
#
# Three sub-checks:
#   a. bin/codex-poll.sh exists, is executable, has a bash shebang.
#   b. each of the four codex-fragment files invokes codex-poll.sh at
#      least once.
#   c. no fragment file outside bin/ calls `node "$CODEX_COMPANION"
#      status` directly anymore — every poll site MUST go through the
#      helper. (commands/codex-review.md is allowed to mention the
#      pattern in its prose; the assertion only fires on fragment files.)

# CR-13a — helper file exists, executable, bash shebang
CR13_HELPER="$REPO/bin/codex-poll.sh"
if [[ -x "$CR13_HELPER" ]] && head -1 "$CR13_HELPER" | grep -qE '^#!/usr/bin/env bash'; then
    pass "CR-13a: bin/codex-poll.sh exists, is executable, and uses #!/usr/bin/env bash"
else
    fail "CR-13a: bin/codex-poll.sh missing, not executable, or wrong shebang"
fi

# CR-13b — each codex fragment invokes the helper
CR13_FRAGMENTS=(
    "fragments/01-codex-detection.md"
    "fragments/05-codex-validation.md"
    "fragments/06-codex-cross-cutting.md"
)
cr13b_missing=""
for f in "${CR13_FRAGMENTS[@]}"; do
    p="$REPO/$f"
    if ! grep -qF 'codex-poll.sh' "$p"; then
        cr13b_missing="$cr13b_missing $f"
    fi
done
# 05-codex-validation.md hosts §4.2.3 AND §4.3.2 — require ≥2 invocations
# in that file specifically.
v05_count=$(grep -cF 'poll=$(codex-poll.sh' "$REPO/fragments/05-codex-validation.md" 2>/dev/null || echo 0)
if [[ -z "$cr13b_missing" ]] && [[ "$v05_count" -ge 2 ]]; then
    pass "CR-13b: every codex fragment invokes codex-poll.sh (05-codex-validation.md hosts both §4.2.3 and §4.3.2; v05_count=$v05_count)"
else
    fail "CR-13b: codex-poll.sh wiring incomplete:$cr13b_missing v05_count=$v05_count (expected ≥2 in 05-codex-validation.md)"
fi

# CR-13c — no fragment file calls `node "$CODEX_COMPANION" status` or
# `result` directly. Both subcommands must go through codex-poll.sh:
# `status` is the liveness signal the watchdog wraps; `result` is the
# raw_output pluck path the helper's `completed` short-circuit owns
# (with the documented .storedJob.result.rawOutput // .storedJob.payload.rawOutput
# // .storedJob.rawOutput // "" fallback chain). A direct call to either
# bypasses the watchdog and reintroduces the indefinite-`running` failure
# mode this branch was built to fix. Whitespace-tolerant so spacing
# variants (`node  "$CODEX_COMPANION"   status`) can't sneak past.
CR13_BYPASS_RE='node[[:space:]]+"\$CODEX_COMPANION"[[:space:]]+(status|result)'
cr13c_violations=""
for f in "${CR13_FRAGMENTS[@]}"; do
    p="$REPO/$f"
    if grep -nE "$CR13_BYPASS_RE" "$p" >/dev/null 2>&1; then
        # Allow inside `forbidden in this fragment` prose bands — those
        # mention the literal pattern as the rule being enforced. Use awk
        # to filter: lines starting with whitespace then `node "$CODEX_COMPANION"
        # status` or `result` (a bash invocation), with no surrounding
        # "forbidden" prose.
        offending=$(awk '
            /forbidden in this fragment/ { next }
            /^[[:space:]]*node[[:space:]]+"\$CODEX_COMPANION"[[:space:]]+(status|result)/ { print NR ": " $0 }
        ' "$p")
        if [[ -n "$offending" ]]; then
            cr13c_violations="$cr13c_violations $f($(echo "$offending" | tr '\n' ';'))"
        fi
    fi
done
if [[ -z "$cr13c_violations" ]]; then
    pass "CR-13c: no codex fragment calls 'node \"\$CODEX_COMPANION\" status|result' directly — all poll/fetch sites go through codex-poll.sh"
else
    fail "CR-13c: direct status/result-poll calls found:$cr13c_violations"
fi

# CR-13d — codex-poll.sh handles broker "No job found" status path gracefully.
# Without this, lib/job-control.mjs `buildSingleJobSnapshot` throwing on a
# pruned/unknown jobId aborts the helper with exit 5, and the fragments'
# `poll=$(codex-poll.sh ...)` invocation under `set -euo pipefail` would
# crash the whole --apply-decisions batch instead of producing a per-unit
# sentinel-uncertain.
if grep -qE "No job found" "$CR13_HELPER" \
   && grep -qE 'emit "unknown" "broker_desynced"' "$CR13_HELPER"; then
    pass "CR-13d: codex-poll.sh converts broker 'No job found' on status path to graceful broker_desynced verdict"
else
    fail "CR-13d: codex-poll.sh missing 'No job found' → broker_desynced fallback on the status read path"
fi

# CR-13e — no codex fragment uses non-portable `timeout` for cancel.
# `timeout` is GNU coreutils — not on stock macOS — and the prior pattern
# `timeout 30 node ... || true` silently no-ops there, leaving wedged jobs
# uncancelled while the orchestrator believes cancel happened.
cr13e_violations=""
for f in "${CR13_FRAGMENTS[@]}"; do
    p="$REPO/$f"
    if grep -nE '^[[:space:]]*timeout[[:space:]]+[0-9]+[[:space:]]+node' "$p" >/dev/null 2>&1; then
        offending=$(grep -nE '^[[:space:]]*timeout[[:space:]]+[0-9]+[[:space:]]+node' "$p" | tr '\n' ';')
        cr13e_violations="$cr13e_violations $f($offending)"
    fi
done
if [[ -z "$cr13e_violations" ]]; then
    pass "CR-13e: no codex fragment uses non-portable \`timeout\` to cancel codex jobs (Bash 3.2 macOS portable)"
else
    fail "CR-13e: non-portable \`timeout\` cancel pattern found:$cr13e_violations"
fi

# CR-13f — commands/codex-review.md must not teach a raw `node "$CODEX_COMPANION"
# status` or `result` poll recipe in its prose. The command body is read by
# the orchestrator as executable instruction — a stale recipe there bypasses
# codex-poll.sh and reintroduces the indefinite-`running` failure mode (status
# path) or loses the result-pluck fallback chain (result path). CR-13c covers
# fragments; this one covers the command file. Same whitespace-tolerant
# regex (CR13_BYPASS_RE) and same dual-subcommand coverage. Allowed:
# forbidden-prose mentions and the explicit Do-NOT-call directive that
# states the rule.
CR13F_COMMAND="$REPO/commands/codex-review.md"
cr13f_violations=""
if grep -nE "$CR13_BYPASS_RE" "$CR13F_COMMAND" >/dev/null 2>&1; then
    offending=$(awk '
        /forbidden|do NOT call|Do NOT call/ { next }
        /^[[:space:]]*node[[:space:]]+"\$CODEX_COMPANION"[[:space:]]+(status|result)/ { print NR ": " $0 }
    ' "$CR13F_COMMAND")
    if [[ -n "$offending" ]]; then
        cr13f_violations=" commands/codex-review.md($(echo "$offending" | tr '\n' ';'))"
    fi
fi
if [[ -z "$cr13f_violations" ]]; then
    pass "CR-13f: commands/codex-review.md does not teach a raw 'node \"\$CODEX_COMPANION\" status|result' poll/fetch recipe — orchestrator routed through codex-poll.sh"
else
    fail "CR-13f: commands/codex-review.md teaches raw status/result-poll recipe (bypasses watchdog):$cr13f_violations"
fi

# CR-13g — codex-review's standalone CLI fallback is end-to-end, not
# readiness-only. Both command entry points must grant agent-dispatch, and
# every codex-review execution fragment must branch launch/poll/stop on
# codex_launch_mode while retaining the companion path.
cr13g_problems=""
for f in commands/review.md commands/codex-review.md; do
    grep -qF 'Bash(agent-dispatch.sh:*)' "$REPO/$f" \
        || cr13g_problems="$cr13g_problems $f(no-agent-dispatch-grant)"
done
for f in fragments/01-codex-detection.md fragments/05-codex-validation.md fragments/06-codex-cross-cutting.md; do
    p="$REPO/$f"
    grep -qF 'codex_launch_mode' "$p" \
        || cr13g_problems="$cr13g_problems $f(no-mode-branch)"
    grep -qF 'agent-dispatch.sh" start --engine codex' "$p" \
        || cr13g_problems="$cr13g_problems $f(no-fallback-start)"
    grep -qF 'agent-dispatch.sh" poll' "$p" \
        || cr13g_problems="$cr13g_problems $f(no-fallback-poll)"
    grep -qF 'agent-dispatch.sh" stop' "$p" \
        || cr13g_problems="$cr13g_problems $f(no-fallback-stop)"
    grep -qF 'node "$CODEX_COMPANION" task --background' "$p" \
        || cr13g_problems="$cr13g_problems $f(no-companion-start)"
done
if grep -qF 'codex_launch_mode="agent-dispatch"' "$REPO/commands/codex-review.md" \
   && [[ -z "$cr13g_problems" ]]; then
    pass "CR-13g: codex CLI fallback branches readiness, launch, poll, stop, output collection, and permissions end-to-end"
else
    fail "CR-13g: codex CLI fallback wiring incomplete:$cr13g_problems"
fi

# CR-14 — fragments/00-preflight.md gates the --effort skip on working-context
# `effort` being set. Without the gate, `/matthewsreview:review --effort high`
# silently consumes the flag (no upstream parser owns it on :review) instead
# of falling through to the unexpected-token clarify path.
# Two-signal check: the multi-line gate prose mentions both "only when" the
# upstream parser owns the flag AND the unset-falls-through path.
if grep -qE 'only when the upstream parser actually owns the flag' "$REPO/fragments/00-preflight.md" \
   && grep -qE 'unexpected token and falls through to the clarify path' "$REPO/fragments/00-preflight.md"; then
    pass "CR-14: fragments/00-preflight.md gates --effort skip on working-context effort being set (\`/matthewsreview:review --effort\` falls through to clarify, not silent-consume)"
else
    fail "CR-14: fragments/00-preflight.md missing the working-context-effort gate around --effort skip"
fi

# CR-16a — fragments/01-detection.md Phase 1.2a cold-start bypass
# predicate must stay narrow: requires sessionRuntime.mode == "shared"
# AND the ENOENT+broker.sock failure signature, and must NOT
# re-introduce the redundant `cx_auth` check (`.auth.available` is
# hardcoded true in the companion's auth-status builder regardless of
# credential state — gating on it is cargo-cult that masks the actual
# bypass shape).
CR16A_FRAGMENT="$REPO/fragments/01-detection.md"
if grep -qE '"\$cx_mode" == "shared"' "$CR16A_FRAGMENT" \
   && grep -qE '"\$cx_cli" == "true"' "$CR16A_FRAGMENT" \
   && grep -qE '\*"ENOENT"\*"broker\.sock"\*' "$CR16A_FRAGMENT" \
   && ! grep -qE '"\$cx_auth" == "true"' "$CR16A_FRAGMENT"; then
    pass "CR-16a: fragments/01-detection.md Phase 1.2a bypass predicate stays narrow (mode=shared + cli=true + ENOENT+broker.sock; no cx_auth cargo-cult)"
else
    fail "CR-16a: fragments/01-detection.md Phase 1.2a bypass predicate has drifted (missing mode/cli/ENOENT signature, or re-introduced cx_auth)"
fi

# CR-16b — commands/codex-review.md bypass mirrors the fragment shape.
# Same narrow predicate, same drop of the redundant `cx_auth` check.
# Regression guard against the two probes drifting apart.
CR16B_COMMAND="$REPO/commands/codex-review.md"
if grep -qE '"\$cx_mode" == "shared"' "$CR16B_COMMAND" \
   && grep -qE '"\$cx_cli" == "true"' "$CR16B_COMMAND" \
   && grep -qE '\*"ENOENT"\*"broker\.sock"\*' "$CR16B_COMMAND" \
   && ! grep -qE '"\$cx_auth" == "true"' "$CR16B_COMMAND"; then
    pass "CR-16b: commands/codex-review.md readiness-gate bypass mirrors fragment shape (mode=shared + cli=true + ENOENT+broker.sock; no cx_auth cargo-cult)"
else
    fail "CR-16b: commands/codex-review.md readiness-gate bypass predicate has drifted from fragment shape (missing mode/cli/ENOENT signature, or re-introduced cx_auth)"
fi

# CR-16c — a not-ready companion may fall through to standalone Codex,
# but the final no-transport branch must remain fatal. This prevents the
# cold-start bypass from silently swallowing real auth/CLI failures when
# neither transport is usable.
CR16C_COMMAND="$REPO/commands/codex-review.md"
cr16c_block=$(awk '/^if \[\[ -z "\$codex_launch_mode" \]\]; then$/,/^[[:space:]]*fi[[:space:]]*$/' "$CR16C_COMMAND")
if printf '%s\n' "$cr16c_block" | grep -qF 'ERROR: no usable Codex transport.' \
   && printf '%s\n' "$cr16c_block" | grep -qE '^[[:space:]]*exit 1[[:space:]]*$'; then
    pass "CR-16c: codex-review.md retains fatal exit when companion and standalone Codex are both unavailable"
else
    fail "CR-16c: codex-review.md final no-transport branch is not fatal"
fi

# CR-17: jq entry guard — codex-poll.sh guards node and the companion
# but must also guard jq (its only JSON emitter) before any mktemp or
# external call. A PATH with node but no jq exits 5 error-as-prompt.
# Run via /bin/bash so the stripped PATH only affects the script's own
# lookups, not the `#!/usr/bin/env bash` shebang.
CR17_DIR="$WORK/cr17"
mkdir -p "$CR17_DIR/bin"
printf '#!/bin/sh\nexit 0\n' > "$CR17_DIR/bin/node"
chmod +x "$CR17_DIR/bin/node"
: > "$CR17_DIR/companion.mjs"
cr17_rc=0
cr17_err=$(PATH="$CR17_DIR/bin" /bin/bash "$TOOLS/codex-poll.sh" \
    --job cr17job --companion "$CR17_DIR/companion.mjs" \
    --stall-threshold-sec 5 --wall-clock-ceiling-sec 5 \
    2>&1 >/dev/null) || cr17_rc=$?
if [[ "$cr17_rc" == "5" ]] \
    && echo "$cr17_err" | grep -q 'jq not found' \
    && echo "$cr17_err" | grep -q '^Action:'; then
    pass "CR-17: jq entry guard — node-only PATH exits 5 with error-as-prompt before any mktemp"
else
    fail "CR-17: expected rc=5 + 'jq not found' + 'Action:'; got rc=$cr17_rc err='$cr17_err'"
fi

# CR-18: EXIT-trap temp hygiene on the signal path — TERM lands while
# codex-poll is blocked in `node "$COMPANION" status` (stub writes its
# pid marker then execs /bin/sleep). Kill both the script and the node
# child (bash defers a trapped TERM until the foreground child exits),
# then assert non-zero exit + zero leftover scratch files. Location is
# pinned via a PATH-interposed mktemp wrapper (macOS mktemp -t ignores
# TMPDIR — see FG-5). Without the traps an untrapped TERM kills bash
# mid-wait and leaks the mktemp file made just before the node call.
CR18_DIR="$WORK/cr18"
mkdir -p "$CR18_DIR/bin" "$CR18_DIR/tmp"
: > "$CR18_DIR/companion.mjs"
cat > "$CR18_DIR/bin/node" <<'EOS'
#!/usr/bin/env bash
printf '%s' "$$" > "$CR18_MARKER"
exec /bin/sleep 300
EOS
chmod +x "$CR18_DIR/bin/node"
CR18_REAL_MKTEMP=$(command -v mktemp)
cat > "$CR18_DIR/bin/mktemp" <<EOS
#!/usr/bin/env bash
if [[ "\${1:-}" == "-t" && -n "\${2:-}" ]]; then
    exec "$CR18_REAL_MKTEMP" "$CR18_DIR/tmp/\$2"
fi
exec "$CR18_REAL_MKTEMP" "\$@"
EOS
chmod +x "$CR18_DIR/bin/mktemp"
CR18_MARKER="$CR18_DIR/node.pid" \
    PATH="$CR18_DIR/bin:$PATH" "$TOOLS/codex-poll.sh" \
    --job cr18job --companion "$CR18_DIR/companion.mjs" \
    --stall-threshold-sec 600 --wall-clock-ceiling-sec 600 \
    >/dev/null 2>&1 &
cr18_script_pid=$!
cr18_w=0
while [[ ! -s "$CR18_DIR/node.pid" && "$cr18_w" -lt 100 ]]; do
    sleep 0.05
    cr18_w=$((cr18_w + 1))
done
cr18_node_pid=$(cat "$CR18_DIR/node.pid" 2>/dev/null || echo "")
kill -TERM "$cr18_script_pid" 2>/dev/null || true
[[ -n "$cr18_node_pid" ]] && kill -TERM "$cr18_node_pid" 2>/dev/null
cr18_w=0
while kill -0 "$cr18_script_pid" 2>/dev/null && [[ "$cr18_w" -lt 100 ]]; do
    sleep 0.05
    cr18_w=$((cr18_w + 1))
done
if kill -0 "$cr18_script_pid" 2>/dev/null; then
    kill -KILL "$cr18_script_pid" 2>/dev/null || true
    [[ -n "$cr18_node_pid" ]] && kill -KILL "$cr18_node_pid" 2>/dev/null
fi
cr18_rc=0
wait "$cr18_script_pid" 2>/dev/null || cr18_rc=$?
cr18_leftover=$(find "$CR18_DIR/tmp" -name 'matthews-codex-poll*' 2>/dev/null | wc -l | tr -d ' ')
if [[ "$cr18_rc" != "0" && "$cr18_leftover" == "0" && -n "$cr18_node_pid" ]]; then
    pass "CR-18: TERM during blocked companion call — trap re-raise leaves zero scratch files"
else
    fail "CR-18: expected rc!=0 + zero matthews-codex-poll* leftovers + node started; got rc=$cr18_rc leftover=$cr18_leftover node_pid='$cr18_node_pid'"
fi

# DF-1: large L1 diffs retain full ≤4k-line shard coverage while bounding
# concurrency in waves. A hard three-shard cap silently recreates oversized
# prompts above 12k changed lines.
DF1_FRAGMENT="$REPO/fragments/01-detection.md"
if ! grep -qF 'never more than 3' "$DF1_FRAGMENT" \
   && grep -qF 'waves of at most 3' "$DF1_FRAGMENT" \
   && grep -qF '≤4000 changed lines' "$DF1_FRAGMENT"; then
    pass "DF-1: L1 sharding bounds concurrency without exceeding the per-shard input ceiling"
else
    fail "DF-1: L1 sharding still caps total shards or lacks bounded-wave coverage"
fi

# DF-2: standalone ensemble polling must not consume its deadline variable
# before the size-scaled assignment executes.
DF2_FRAGMENT="$REPO/fragments/02-ensemble-adapter.md"
df2_assignment=$(grep -n '^ensemble_ceiling_sec=' "$DF2_FRAGMENT" | sed -n '1s/:.*//p')
df2_poll=$(grep -n -- '--wall-clock-ceiling-sec "\$ensemble_ceiling_sec"' "$DF2_FRAGMENT" | sed -n '1s/:.*//p')
if [[ "$df2_assignment" =~ ^[0-9]+$ && "$df2_poll" =~ ^[0-9]+$ \
      && "$df2_assignment" -lt "$df2_poll" ]]; then
    pass "DF-2: ensemble deadline is materialized before either transport polls"
else
    fail "DF-2: ensemble polling can expand an unset deadline" \
      "assignment=$df2_assignment poll=$df2_poll"
fi

# DF-3: generated findings preserve a genuinely unknown source line as null.
# [1,1] is an actual citation, not a safe missing-location sentinel.
df3_defaults=$(grep -nE 'line_range[^[:cntrl:]]*(//|//=)[[:space:]]*\[1,[[:space:]]*1\]' \
    "$REPO/fragments/01-detection.md" \
    "$REPO/fragments/01-codex-detection.md" \
    "$REPO/fragments/02-ensemble-adapter.md" \
    "$REPO/fragments/05-validation.md" \
    "$REPO/commands/add.md" || true)
if [[ -z "$df3_defaults" ]]; then
    pass "DF-3: no active candidate path fabricates line 1 for missing location data"
else
    fail "DF-3: active candidate paths still fabricate [1,1]" "$df3_defaults"
fi


# ---------------------------------------------------------------- EP-* early-pipeline dogfood regressions
# These execute the command bodies extracted from the shared fragments rather
# than copying their logic into the harness. Keep the anchors unique: an empty
# extraction is a failed contract, never a vacuous pass.
EP_DIR="$WORK/early-pipeline"
mkdir -p "$EP_DIR"

ep_extract_fence_after() {
    local source="$1" anchor="$2" destination="$3"
    awk -v anchor="$anchor" '
        !seen && index($0, anchor) { seen=1; next }
        seen && !fence {
            trimmed=$0
            sub(/^[[:space:]]*/, "", trimmed)
            if (trimmed == "```bash") fence=1
            next
        }
        fence {
            trimmed=$0
            sub(/^[[:space:]]*/, "", trimmed)
            if (trimmed == "```") exit
            output=$0
            sub(/^    /, "", output)
            print output
        }
    ' "$source" > "$destination"
}

# EP-1 / F004: Phase 0's model-plan writer must preserve the patcher's
# non-zero status while still removing its tempfile. Its success path must
# pass both model_plan and gates in the same artifact-patch invocation.
EP_PREFLIGHT="$REPO/fragments/00-preflight.md"
EP_PLAN_BLOCK="$EP_DIR/plan-writer.sh"
ep_extract_fence_after "$EP_PREFLIGHT" '### 0.15b. Store the model plan' "$EP_PLAN_BLOCK"
mkdir -p "$EP_DIR/plan-bin" "$EP_DIR/plan-tmp"
cat > "$EP_DIR/plan-bin/artifact-patch.py" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$EP_CAPTURE"
for arg in "$@"; do
    case "$arg" in
        model_plan=@*) cat "${arg#model_plan=@}" > "$EP_PLAN_CAPTURE" ;;
    esac
done
exit "${EP_PATCH_RC:-0}"
EOF
chmod +x "$EP_DIR/plan-bin/artifact-patch.py"

EP_CAPTURE="$EP_DIR/plan-fail.args" EP_PLAN_CAPTURE="$EP_DIR/plan-fail.json" \
EP_PATCH_RC=3 PATH="$EP_DIR/plan-bin:$PATH" TMPDIR="$EP_DIR/plan-tmp" \
artifact_path="$EP_DIR/artifact.json" model_plan_json='{"roles":{}}' \
gates_json='{"phase3_gate":45}' \
    /bin/bash "$EP_PLAN_BLOCK" >/dev/null 2>&1
ep_plan_fail_rc=$?
ep_plan_leftover=false
for ep_path in "$EP_DIR"/plan-tmp/matthews-model-plan.*; do
    [[ -e "$ep_path" ]] && ep_plan_leftover=true
done

EP_CAPTURE="$EP_DIR/plan-ok.args" EP_PLAN_CAPTURE="$EP_DIR/plan-ok.json" \
EP_PATCH_RC=0 PATH="$EP_DIR/plan-bin:$PATH" TMPDIR="$EP_DIR/plan-tmp" \
artifact_path="$EP_DIR/artifact.json" model_plan_json='{"roles":{"scoring":{"engine":"claude"}}}' \
gates_json='{"phase3_gate":45}' \
    /bin/bash "$EP_PLAN_BLOCK" >/dev/null 2>&1
ep_plan_ok_rc=$?
if [[ "$ep_plan_fail_rc" -eq 3 && "$ep_plan_leftover" == "false" \
   && "$ep_plan_ok_rc" -eq 0 \
   && "$(cat "$EP_DIR/plan-ok.json" 2>/dev/null)" == '{"roles":{"scoring":{"engine":"claude"}}}' \
   && "$(grep -cF -- '--set-json' "$EP_DIR/plan-ok.args" 2>/dev/null)" -eq 2 ]] \
   && grep -qF 'gates={"phase3_gate":45}' "$EP_DIR/plan-ok.args"; then
    pass "EP-1 (F004): Phase-0 model-plan writer preserves patch rc, cleans temp, and atomically passes model_plan + gates"
else
    fail "EP-1: model-plan writer masks patch failure, leaks temp, or splits model_plan/gates" \
      "fail_rc=$ep_plan_fail_rc leftover=$ep_plan_leftover ok_rc=$ep_plan_ok_rc"
fi

# EP-2 / F005: the size-scaled ensemble deadline initializer is a successful
# initializer whether or not the cap branch runs.
EP_ENSEMBLE="$REPO/fragments/02-ensemble-adapter.md"
EP_DEADLINE_BLOCK="$EP_DIR/deadline.sh"
ep_extract_fence_after "$EP_ENSEMBLE" 'Materialize the shared size-scaled deadline' "$EP_DEADLINE_BLOCK"
ep_deadline_case() {
    (
        lines_changed="$1"
        . "$EP_DEADLINE_BLOCK"
        ep_deadline_rc=$?
        printf '%s:%s\n' "$ep_deadline_rc" "${ensemble_ceiling_sec:-unset}"
    )
}
ep_deadline_0=$(ep_deadline_case 0)
ep_deadline_10000=$(ep_deadline_case 10000)
ep_deadline_10017=$(ep_deadline_case 10017)
if [[ "$ep_deadline_0" == "0:600" \
   && "$ep_deadline_10000" == "0:1200" \
   && "$ep_deadline_10017" == "0:1200" ]]; then
    pass "EP-2 (F005): ensemble deadline initializer returns 0 below, at, and above cap"
else
    fail "EP-2: ensemble deadline initializer has a false-predicate status leak" \
      "0=$ep_deadline_0 10000=$ep_deadline_10000 10017=$ep_deadline_10017"
fi

# EP-3 / F006: both transports emit exactly one common reviewer row after a
# launch. Companion usage is explicitly null; standalone numeric usage,
# including zero, is preserved; a skipped launch emits no row.
EP_REVIEWER_LOG_BLOCK="$EP_DIR/reviewer-token-log.sh"
ep_extract_fence_after "$EP_ENSEMBLE" '### 1.5.3b. Log CLI reviewer tokens' "$EP_REVIEWER_LOG_BLOCK"
EP_NORMALIZER_LOG_BLOCK="$EP_DIR/normalizer-token-log.sh"
ep_extract_fence_after "$EP_ENSEMBLE" '### 1.5.6. Log normalizer tokens' \
    "$EP_NORMALIZER_LOG_BLOCK"
python3 - "$EP_NORMALIZER_LOG_BLOCK" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
body = path.read_text()
body = body.replace("<id>", "normalizer-1").replace("<N or null>", "123")
path.write_text(body)
PY
mkdir -p "$EP_DIR/token-bin"
cat > "$EP_DIR/token-bin/log-tokens.sh" <<'EOF'
#!/usr/bin/env bash
role="" tokens="" agent_id=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --agent-role) role="$2"; shift 2 ;;
        --tokens) tokens="$2"; shift 2 ;;
        --agent-id) agent_id="$2"; shift 2 ;;
        *) shift ;;
    esac
done
printf '%s|%s|%s\n' "$role" "$tokens" "$agent_id" >> "$EP_TOKEN_LOG"
EOF
chmod +x "$EP_DIR/token-bin/log-tokens.sh"
: > "$EP_DIR/reviewer-tokens.log"
for ep_token_case in companion standalone skipped; do
    case "$ep_token_case" in
        companion)
            ep_launched=true; ep_mode=companion; ep_id=bg_1; ep_poll='' ;;
        standalone)
            ep_launched=true; ep_mode=agent-dispatch; ep_id=ad_1
            ep_poll='{"verdict":"completed","tokens":0}' ;;
        skipped)
            ep_launched=false; ep_mode=agent-dispatch; ep_id=''; ep_poll='' ;;
    esac
    EP_TOKEN_LOG="$EP_DIR/reviewer-tokens.log" PATH="$EP_DIR/token-bin:$PATH" \
    codex_reviewer_launched="$ep_launched" codex_launch_mode="$ep_mode" \
    codex_reviewer_agent_id="$ep_id" codex_poll="$ep_poll" \
    review_dir="$EP_DIR/review" role_ensemble_detect="codex:gpt-5.4:xhigh" \
        /bin/bash "$EP_REVIEWER_LOG_BLOCK" >/dev/null 2>&1
done
EP_TOKEN_LOG="$EP_DIR/reviewer-tokens.log" PATH="$EP_DIR/token-bin:$PATH" \
    review_dir="$EP_DIR/review" role_normalizer=sonnet \
    /bin/bash "$EP_NORMALIZER_LOG_BLOCK" >/dev/null 2>&1
ep_reviewer_rows=$(grep -c '^codex_ensemble_reviewer|' "$EP_DIR/reviewer-tokens.log" 2>/dev/null)
ep_normalizer_rows=$(grep -c '^external_normalizer|123|normalizer-1$' "$EP_DIR/reviewer-tokens.log" 2>/dev/null)
if [[ "$ep_reviewer_rows" == "2" \
   && "$(sed -n '1p' "$EP_DIR/reviewer-tokens.log")" == 'codex_ensemble_reviewer|null|bg_1' \
   && "$(sed -n '2p' "$EP_DIR/reviewer-tokens.log")" == 'codex_ensemble_reviewer|0|ad_1' \
   && "$ep_normalizer_rows" -eq 1 \
   && "$(wc -l < "$EP_DIR/reviewer-tokens.log" | tr -d '[:space:]')" == "3" ]]; then
    pass "EP-3 (F006): companion/standalone reviewer tokens normalize to one common row; skipped launch none; normalizer remains separate"
else
    fail "EP-3: transport-dependent reviewer token accounting remains" \
      "reviewer_rows=$ep_reviewer_rows normalizer_rows=$ep_normalizer_rows log=$(cat "$EP_DIR/reviewer-tokens.log")"
fi

# EP-4 / F007: candidate enumeration fails closed at both the artifact-read
# and JSON parse boundaries while preserving a valid empty list.
EP_SCORING="$REPO/fragments/04-scoring-gate.md"
EP_ENUM_BLOCK="$EP_DIR/scoring-enumeration.sh"
ep_extract_fence_after "$EP_SCORING" '### 3.2. Enumerate scoring candidates' "$EP_ENUM_BLOCK"
cat >> "$EP_ENUM_BLOCK" <<'EOF'
printf 'RESULT:%s:%s\n' "$scoring_count" "$scoring_ids"
EOF
mkdir -p "$EP_DIR/read-bin"
cat > "$EP_DIR/read-bin/artifact-read.sh" <<'EOF'
#!/usr/bin/env bash
case "$EP_READ_MODE" in
    fail) exit 7 ;;
    malformed) printf '%s\n' 'not-json' ;;
    empty) printf '%s\n' '[]' ;;
    two) printf '%s\n' '["F001","F002"]' ;;
esac
EOF
chmod +x "$EP_DIR/read-bin/artifact-read.sh"
EP_READ_MODE=fail PATH="$EP_DIR/read-bin:$PATH" artifact_path=/unused \
    /bin/bash "$EP_ENUM_BLOCK" >/dev/null 2>&1
ep_enum_read_rc=$?
EP_READ_MODE=malformed PATH="$EP_DIR/read-bin:$PATH" artifact_path=/unused \
    /bin/bash "$EP_ENUM_BLOCK" >/dev/null 2>&1
ep_enum_parse_rc=$?
ep_enum_empty=$(EP_READ_MODE=empty PATH="$EP_DIR/read-bin:$PATH" artifact_path=/unused \
    /bin/bash "$EP_ENUM_BLOCK" 2>/dev/null); ep_enum_empty_rc=$?
ep_enum_two=$(EP_READ_MODE=two PATH="$EP_DIR/read-bin:$PATH" artifact_path=/unused \
    /bin/bash "$EP_ENUM_BLOCK" 2>/dev/null); ep_enum_two_rc=$?
if [[ "$ep_enum_read_rc" -ne 0 && "$ep_enum_parse_rc" -ne 0 \
   && "$ep_enum_empty_rc" -eq 0 && "$ep_enum_empty" == 'RESULT:0:[]' \
   && "$ep_enum_two_rc" -eq 0 && "$ep_enum_two" == 'RESULT:2:["F001","F002"]' ]]; then
    pass "EP-4 (F007): scoring enumeration fails closed on read/parse errors and preserves [] semantics"
else
    fail "EP-4: scoring enumeration masks read/parse failure or rejects valid arrays" \
      "read_rc=$ep_enum_read_rc parse_rc=$ep_enum_parse_rc empty=$ep_enum_empty_rc:$ep_enum_empty two=$ep_enum_two_rc:$ep_enum_two"
fi

# EP-5 / F008: the score tuple stream is the patcher's stdin. An expected
# count mismatch must remain exit 6 and leave the artifact byte-identical;
# a valid batch persists score, reason, and history.
EP_SCORE_WRITE_BLOCK="$EP_DIR/score-write.sh"
ep_extract_fence_after "$EP_SCORING" 'Write all scores in ONE batched call' "$EP_SCORE_WRITE_BLOCK"
cp "$FIX/artifact-seed.json" "$EP_DIR/score-mismatch.json"
ep_score_before=$(sha_of "$EP_DIR/score-mismatch.json")
PATH="$TOOLS:$PATH" artifact_path="$EP_DIR/score-mismatch.json" scoring_count=2 \
all_chunk_tuples_json='[{"id":"F001","score_phase3":72,"reason":"rescored"}]' \
    /bin/bash "$EP_SCORE_WRITE_BLOCK" >/dev/null 2>&1
ep_score_mismatch_rc=$?
ep_score_after=$(sha_of "$EP_DIR/score-mismatch.json")

cp "$FIX/artifact-seed.json" "$EP_DIR/score-valid.json"
PATH="$TOOLS:$PATH" artifact_path="$EP_DIR/score-valid.json" scoring_count=1 \
all_chunk_tuples_json='[{"id":"F001","score_phase3":72,"reason":"rescored"}]' \
    /bin/bash "$EP_SCORE_WRITE_BLOCK" >/dev/null 2>&1
ep_score_valid_rc=$?
ep_score_valid_shape=$(jq -r '
  .findings[] | select(.id=="F001")
  | "\(.score_phase3)|\(.reason)|\(.score_history[-1].phase)|\(.score_history[-1].score)"
' "$EP_DIR/score-valid.json")
if [[ "$ep_score_mismatch_rc" -eq 6 && "$ep_score_before" == "$ep_score_after" \
   && "$ep_score_valid_rc" -eq 0 \
   && "$ep_score_valid_shape" == '72|rescored|phase_3|72' ]]; then
    pass "EP-5 (F008): streamed score batch preserves rc 6/atomicity and valid score+reason+history persistence"
else
    fail "EP-5: score-write cleanup masks failure or valid streamed batch is incomplete" \
      "mismatch_rc=$ep_score_mismatch_rc unchanged=$([[ "$ep_score_before" == "$ep_score_after" ]] && echo yes || echo no) valid_rc=$ep_score_valid_rc shape=$ep_score_valid_shape"
fi

# EP-6 / F009: materialize the artifact gate before first use and evaluate
# routing in jq so fractional thresholds and null scores are well-defined.
EP_GATE_LOAD_BLOCK="$EP_DIR/phase3-gate-load.sh"
ep_extract_fence_after "$EP_SCORING" 'Materialize the resolved Phase-3 gate' "$EP_GATE_LOAD_BLOCK"
cat >> "$EP_GATE_LOAD_BLOCK" <<'EOF'
printf 'RESULT:%s\n' "$phase3_gate"
EOF
printf '%s\n' '{"gates":{}}' > "$EP_DIR/gate-default.json"
printf '%s\n' '{"gates":{"phase3_gate":55.5}}' > "$EP_DIR/gate-fractional.json"
ep_gate_default=$(PATH="$TOOLS:$PATH" artifact_path="$EP_DIR/gate-default.json" \
    /bin/bash "$EP_GATE_LOAD_BLOCK" 2>/dev/null); ep_gate_default_rc=$?
ep_gate_fractional=$(PATH="$TOOLS:$PATH" artifact_path="$EP_DIR/gate-fractional.json" \
    /bin/bash "$EP_GATE_LOAD_BLOCK" 2>/dev/null); ep_gate_fractional_rc=$?
PATH="$TOOLS:$PATH" artifact_path="$EP_DIR/missing-gate-artifact.json" \
    /bin/bash "$EP_GATE_LOAD_BLOCK" >/dev/null 2>&1
ep_gate_missing_rc=$?

EP_GATE_PREDICATE_BLOCK="$EP_DIR/phase3-gate-predicate.sh"
ep_extract_fence_after "$EP_SCORING" 'For each returned `entry_json`, compute' "$EP_GATE_PREDICATE_BLOCK"
cat >> "$EP_GATE_PREDICATE_BLOCK" <<'EOF'
printf 'RESULT:%s\n' "$advances_to_phase_4"
EOF
ep_gate_case() {
    entry_json="$1" phase3_gate="$2" /bin/bash "$EP_GATE_PREDICATE_BLOCK" 2>/dev/null
}
ep_gate_54=$(ep_gate_case '{"id":"F1","score":54,"families":["a"]}' 55)
ep_gate_55=$(ep_gate_case '{"id":"F1","score":55,"families":["a"]}' 55)
ep_gate_null_one=$(ep_gate_case '{"id":"F1","score":null,"families":["a"]}' 55)
ep_gate_null_two=$(ep_gate_case '{"id":"F1","score":null,"families":["a","b"]}' 55)
ep_gate_frac_low=$(ep_gate_case '{"id":"F1","score":55,"families":["a"]}' 55.5)
ep_gate_frac_equal=$(ep_gate_case '{"id":"F1","score":55.5,"families":["a"]}' 55.5)
ep_gate_load_line=$(grep -n '^phase3_gate=' "$EP_SCORING" | sed -n '1s/:.*//p')
ep_gate_use_line=$(grep -n -- '--argjson gate "$phase3_gate"' "$EP_SCORING" | sed -n '1s/:.*//p')
if [[ "$ep_gate_default_rc" -eq 0 && "$ep_gate_default" == 'RESULT:45' \
   && "$ep_gate_fractional_rc" -eq 0 && "$ep_gate_fractional" == 'RESULT:55.5' \
   && "$ep_gate_missing_rc" -ne 0 \
   && "$ep_gate_54" == 'RESULT:false' && "$ep_gate_55" == 'RESULT:true' \
   && "$ep_gate_null_one" == 'RESULT:false' && "$ep_gate_null_two" == 'RESULT:true' \
   && "$ep_gate_frac_low" == 'RESULT:false' && "$ep_gate_frac_equal" == 'RESULT:true' \
   && "$ep_gate_load_line" =~ ^[0-9]+$ && "$ep_gate_use_line" =~ ^[0-9]+$ \
   && "$ep_gate_load_line" -lt "$ep_gate_use_line" ]]; then
    pass "EP-6 (F009): phase3_gate loads fail-fast/default 45, precedes use, and jq routing handles fractional/null/family cases"
else
    fail "EP-6: phase3_gate is unset, integer-only, fail-open, or used before materialization" \
      "default=$ep_gate_default_rc:$ep_gate_default fractional=$ep_gate_fractional_rc:$ep_gate_fractional missing_rc=$ep_gate_missing_rc cases=$ep_gate_54,$ep_gate_55,$ep_gate_null_one,$ep_gate_null_two,$ep_gate_frac_low,$ep_gate_frac_equal lines=$ep_gate_load_line/$ep_gate_use_line"
fi

# EP-7 / F011: an installed-but-unready companion falls through to a
# standalone transport only when both the Codex CLI and dispatcher exist.
# Ready/cold-start companion paths stay companion; max/ultra bypasses probe.
EP_DETECTION="$REPO/fragments/01-detection.md"
EP_TRANSPORT_BLOCK="$EP_DIR/transport-negotiation.sh"
ep_extract_fence_after "$EP_DETECTION" 'Check Codex availability:' "$EP_TRANSPORT_BLOCK"
cat >> "$EP_TRANSPORT_BLOCK" <<'EOF'
printf 'RESULT:%s|%s|%s\n' "${codex_launch_mode:-}" "${codex_available:-}" "${codex_reason:-}"
EOF
EP_TRANSPORT_HOME="$EP_DIR/transport-home"
mkdir -p "$EP_TRANSPORT_HOME/.claude/plugins/vendor/codex"
: > "$EP_TRANSPORT_HOME/.claude/plugins/vendor/codex/codex-companion.mjs"
EP_JQ_DIR=$(dirname "$(command -v jq)")
for ep_variant in full no_dispatch no_codex; do
    mkdir -p "$EP_DIR/transport-$ep_variant"
    cat > "$EP_DIR/transport-$ep_variant/node" <<'EOF'
#!/usr/bin/env bash
[[ -z "${EP_NODE_CALLED:-}" ]] || : > "$EP_NODE_CALLED"
printf '%s\n' "$EP_SETUP_JSON"
EOF
    chmod +x "$EP_DIR/transport-$ep_variant/node"
done
for ep_variant in full no_dispatch; do
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$EP_DIR/transport-$ep_variant/codex"
    chmod +x "$EP_DIR/transport-$ep_variant/codex"
done
for ep_variant in full no_codex; do
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$EP_DIR/transport-$ep_variant/agent-dispatch.sh"
    chmod +x "$EP_DIR/transport-$ep_variant/agent-dispatch.sh"
done
ep_transport_case() {
    local variant="$1" setup="$2" requires="$3" marker="$4"
    EP_SETUP_JSON="$setup" EP_NODE_CALLED="$marker" HOME="$EP_TRANSPORT_HOME" \
    PATH="$EP_DIR/transport-$variant:$EP_JQ_DIR:/usr/bin:/bin" \
    review_dir="$EP_DIR" codex_requires_standalone="$requires" MRB="" \
        /bin/bash "$EP_TRANSPORT_BLOCK" 2>/dev/null
}
ep_transport_fallback=$(ep_transport_case full '{"ready":false,"sessionRuntime":{"mode":"local"},"codex":{"available":true},"auth":{"detail":"not ready"}}' false "$EP_DIR/node-fallback")
ep_transport_no_dispatch=$(ep_transport_case no_dispatch '{"ready":false,"sessionRuntime":{"mode":"local"}}' false "$EP_DIR/node-no-dispatch")
ep_transport_no_codex=$(ep_transport_case no_codex '{"ready":false,"sessionRuntime":{"mode":"local"}}' false "$EP_DIR/node-no-codex")
ep_transport_ready=$(ep_transport_case full '{"ready":true}' false "$EP_DIR/node-ready")
ep_transport_cold=$(ep_transport_case full '{"ready":false,"sessionRuntime":{"mode":"shared"},"codex":{"available":true},"auth":{"detail":"connect ENOENT /tmp/broker.sock"}}' false "$EP_DIR/node-cold")
rm -f "$EP_DIR/node-max"
ep_transport_max=$(ep_transport_case full '{"ready":true}' true "$EP_DIR/node-max")
if [[ "$ep_transport_fallback" == RESULT:agent-dispatch\|true\|* \
   && "$ep_transport_no_dispatch" == RESULT:\|false\|* \
   && "$ep_transport_no_codex" == RESULT:\|false\|* \
   && "$ep_transport_ready" == RESULT:companion\|true\|* \
   && "$ep_transport_cold" == RESULT:companion\|true\|* \
   && "$ep_transport_max" == RESULT:agent-dispatch\|true\|* \
   && ! -e "$EP_DIR/node-max" ]]; then
    pass "EP-7 (F011): unready companion falls back only to complete standalone transport; ready/cold/max paths preserved"
else
    fail "EP-7: Codex transport negotiation suppresses fallback or weakens prerequisites/bypass" \
      "fallback=$ep_transport_fallback no_dispatch=$ep_transport_no_dispatch no_codex=$ep_transport_no_codex ready=$ep_transport_ready cold=$ep_transport_cold max=$ep_transport_max max_probed=$([[ -e "$EP_DIR/node-max" ]] && echo yes || echo no)"
fi

# EP-8 / F025: explicit --effort updates value and provenance for exactly the
# three Codex review roles. An omitted override is byte-for-byte inert.
EP_EFFORT_BLOCK="$EP_DIR/effort-override.sh"
awk '
    index($0, "# :codex-review only") { capture=1 }
    capture { print }
    capture && /^fi$/ { exit }
' "$EP_PREFLIGHT" > "$EP_EFFORT_BLOCK"
ep_model_plan='{"roles":{"codex_detect":{"effort":"low","source":"user-config"},"codex_validate":{"effort":"medium","source":"repo-config"},"codex_crosscut":{"effort":"high","source":"profile (strict)"},"ensemble_detect":{"effort":"xhigh","source":"default"}},"gates":{}}'
ep_effort_explicit=$(model_plan_json="$ep_model_plan" reviewer_sources_label=internal-codex \
    effort_explicit=true effort=xhigh /bin/bash -c '. "$1"; printf "%s" "$model_plan_json"' _ "$EP_EFFORT_BLOCK")
ep_effort_omitted=$(model_plan_json="$ep_model_plan" reviewer_sources_label=internal-codex \
    effort_explicit=false effort='' /bin/bash -c '. "$1"; printf "%s" "$model_plan_json"' _ "$EP_EFFORT_BLOCK")
ep_effort_roles=$(printf '%s\n' "$ep_effort_explicit" | jq -r '
  [.roles.codex_detect,.roles.codex_validate,.roles.codex_crosscut]
  | map("\(.effort)|\(.source)") | join(";")
')
ep_effort_ensemble=$(printf '%s\n' "$ep_effort_explicit" | jq -c '.roles.ensemble_detect')
ep_effort_ensemble_before=$(printf '%s\n' "$ep_model_plan" | jq -c '.roles.ensemble_detect')
if [[ "$ep_effort_roles" == 'xhigh|user-config + cli(--effort);xhigh|repo-config + cli(--effort);xhigh|profile (strict) + cli(--effort)' \
   && "$ep_effort_ensemble" == "$ep_effort_ensemble_before" \
   && "$ep_effort_omitted" == "$ep_model_plan" ]]; then
    pass "EP-8 (F025): explicit Codex effort updates all three role values + provenance and leaves omitted/ensemble paths untouched"
else
    fail "EP-8: explicit Codex effort leaves stale provenance or mutates unrelated/omitted paths" \
      "roles=$ep_effort_roles ensemble_same=$([[ "$ep_effort_ensemble" == "$ep_effort_ensemble_before" ]] && echo yes || echo no) omitted_same=$([[ "$ep_effort_omitted" == "$ep_model_plan" ]] && echo yes || echo no)"
fi

# EP-9 / F044: inventory only the unescaped shell expansions in the first
# unquoted light-validator heredoc, and prove all four values render.
EP_CODEX_VALIDATION="$REPO/fragments/05-codex-validation.md"
ep_heredoc_inventory=$(python3 - "$EP_CODEX_VALIDATION" <<'PY'
import re
import sys

lines = open(sys.argv[1], encoding="utf-8").read().splitlines()
start = next((i for i, line in enumerate(lines) if line == 'cat > "$prompt_file" <<PROMPT'), -1)
if start < 0:
    raise SystemExit("missing unquoted PROMPT heredoc")
end = next((i for i in range(start + 1, len(lines)) if lines[i] == "PROMPT"), -1)
if end < 0:
    raise SystemExit("missing PROMPT closer")
inventory_start = next(
    (i for i in range(max(0, start - 8), start)
     if lines[i].startswith("# Expansion inventory for this heredoc:")),
    -1,
)
if inventory_start < 0:
    raise SystemExit("missing expansion inventory comment")
inventory = "\n".join(lines[inventory_start:start])
body = "\n".join(lines[start + 1:end])
pattern = re.compile(r"(?<!\\)\$([A-Za-z_][A-Za-z0-9_]*)")
expected = sorted(set(pattern.findall(body)))
declared = sorted(set(pattern.findall(inventory)))
if declared != expected:
    raise SystemExit(f"declared={declared} actual={expected}")
print(",".join(expected))
PY
); ep_heredoc_inventory_rc=$?
EP_PROMPT_BLOCK="$EP_DIR/light-prompt.sh"
ep_extract_fence_after "$EP_CODEX_VALIDATION" '#### 4.3.1. Build per-chunk prompt' "$EP_PROMPT_BLOCK"
ep_prompt_path="/tmp/matthews-review-codex-ep_contract-LB-chunk7.md"
rm -f "$ep_prompt_path"
review_id=ep_contract chunk_n=7 chunk_candidates='[]' trivial_mode=TRIVIAL_SENTINEL \
phase4_b1=B1_SENTINEL phase4_b2=B2_SENTINEL phase4_b3=B3_SENTINEL \
claude_md_paths=CLAUDE_SENTINEL /bin/bash "$EP_PROMPT_BLOCK" >/dev/null 2>&1
ep_prompt_rc=$?
ep_prompt_missing=""
for sentinel in TRIVIAL_SENTINEL B1_SENTINEL B2_SENTINEL B3_SENTINEL; do
    grep -qF "$sentinel" "$ep_prompt_path" 2>/dev/null \
        || ep_prompt_missing="$ep_prompt_missing $sentinel"
done
rm -f "$ep_prompt_path"
if [[ "$ep_heredoc_inventory_rc" -eq 0 \
   && "$ep_heredoc_inventory" == 'phase4_b1,phase4_b2,phase4_b3,trivial_mode' \
   && "$ep_prompt_rc" -eq 0 && -z "$ep_prompt_missing" ]]; then
    pass "EP-9 (F044): Phase-4 heredoc inventory exactly matches and renders trivial_mode + three configured bands"
else
    fail "EP-9: Phase-4 heredoc expansion inventory/body drift" \
      "inventory_rc=$ep_heredoc_inventory_rc inventory=$ep_heredoc_inventory prompt_rc=$ep_prompt_rc missing=$ep_prompt_missing"
fi

# EP-10 / F077: root Markdown fences must balance without swallowing
# headings, and the exact scoring-enumeration fence must parse as Bash.
python3 - "$EP_SCORING" > "$EP_DIR/fence-scan.out" <<'PY'
import re
import sys

inside = False
opened = 0
violations = []
for number, raw in enumerate(open(sys.argv[1], encoding="utf-8"), 1):
    line = raw.rstrip("\n")
    if not inside and re.fullmatch(r"```[A-Za-z0-9_-]*", line):
        inside = True
        opened = number
        continue
    if inside and line == "```":
        inside = False
        opened = 0
        continue
    if inside and re.match(r"^#{2,3} ", line):
        violations.append(f"{opened}->{number}:{line}")
if inside:
    violations.append(f"{opened}->EOF:unclosed")
if violations:
    raise SystemExit("; ".join(violations))
print("balanced")
PY
ep_fence_scan_rc=$?
ep_fence_scan=$(cat "$EP_DIR/fence-scan.out" 2>/dev/null)
EP_ENUM_SYNTAX="$EP_DIR/scoring-enumeration-syntax.sh"
ep_extract_fence_after "$EP_SCORING" '### 3.2. Enumerate scoring candidates' "$EP_ENUM_SYNTAX"
/bin/bash -n "$EP_ENUM_SYNTAX" >/dev/null 2>&1
ep_enum_syntax_rc=$?
if [[ "$ep_fence_scan_rc" -eq 0 && "$ep_fence_scan" == "balanced" \
   && "$ep_enum_syntax_rc" -eq 0 && -s "$EP_ENUM_SYNTAX" ]]; then
    pass "EP-10 (F077): scoring fragment root fences balance before headings and enumeration fence is Bash-valid"
else
    fail "EP-10: scoring root fence swallows prose/headings or enumeration is not Bash-valid" \
      "scan_rc=$ep_fence_scan_rc scan=$ep_fence_scan syntax_rc=$ep_enum_syntax_rc size=$(wc -c < "$EP_ENUM_SYNTAX" | tr -d '[:space:]')"
fi

# EP-11 / F091: PR-comment recovery accepts current and legacy markers,
# applies the existing author filter, and selects the latest recognized id,
# while the renderer continues to write only the current marker.
EP_MARKER_BLOCK="$EP_DIR/comment-recovery.sh"
ep_extract_fence_after "$EP_PREFLIGHT" 'If `mode=pr` AND step 0.13 found no prior local artifact' "$EP_MARKER_BLOCK"
mkdir -p "$EP_DIR/gh-bin"
cat > "$EP_DIR/gh-bin/gh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "api" && "$2" == "user" ]]; then
    printf '%s\n' me
elif [[ "$1" == "api" && "$2" == "--paginate" ]]; then
    printf '%s\n' "$EP_COMMENTS"
elif [[ "$1" == "repo" && "$2" == "view" ]]; then
    printf '%s\n' owner/repo
else
    exit 64
fi
EOF
chmod +x "$EP_DIR/gh-bin/gh"
ep_marker_case() {
    EP_COMMENTS="$1" PATH="$EP_DIR/gh-bin:$PATH" pr_number=9 \
        /bin/bash "$EP_MARKER_BLOCK" 2>/dev/null
}
ep_marker_legacy=$(ep_marker_case '[{"id":11,"user":{"login":"me"},"body":"<!-- adams-review-v1 -->"}]')
ep_marker_current=$(ep_marker_case '[{"id":12,"user":{"login":"me"},"body":"<!-- matthews-review-v1 -->"}]')
ep_marker_mixed=$(ep_marker_case '[{"id":12,"user":{"login":"me"},"body":"<!-- matthews-review-v1 -->"},{"id":13,"user":{"login":"me"},"body":"<!-- adams-review-v1 -->"}]')
ep_marker_pages=$(ep_marker_case $'[{"id":16,"user":{"login":"me"},"body":"<!-- matthews-review-v1 -->"}]\n[{"id":19,"user":{"login":"me"},"body":"<!-- adams-review-v1 -->"},{"id":20,"user":{"login":"other"},"body":"<!-- matthews-review-v1 -->"}]')
ep_marker_wrong=$(ep_marker_case '[{"id":14,"user":{"login":"other"},"body":"<!-- matthews-review-v1 -->"}]')
ep_marker_none=$(ep_marker_case '[{"id":15,"user":{"login":"me"},"body":"ordinary comment"}]')
ep_renderer_output=$("$TOOLS/artifact-render.py" --input "$FIX/artifact-seed.json" 2>/dev/null)
ep_renderer_current=$(printf '%s\n' "$ep_renderer_output" | grep -cF '<!-- matthews-review-v1 -->')
ep_renderer_legacy=$(printf '%s\n' "$ep_renderer_output" | grep -cF '<!-- adams-review-v1 -->')
if [[ "$ep_marker_legacy" == "11" && "$ep_marker_current" == "12" \
   && "$ep_marker_mixed" == "13" && "$ep_marker_pages" == "19" \
   && -z "$ep_marker_wrong" && -z "$ep_marker_none" \
   && "$ep_renderer_current" -eq 1 && "$ep_renderer_legacy" -eq 0 ]]; then
    pass "EP-11 (F091): recovery reads legacy/current markers and latest author match; renderer writes current marker only"
else
    fail "EP-11: marker read compatibility/latest-author semantics or current-only write contract regressed" \
      "legacy=$ep_marker_legacy current=$ep_marker_current mixed=$ep_marker_mixed pages=$ep_marker_pages wrong=$ep_marker_wrong none=$ep_marker_none renderer_current=$ep_renderer_current renderer_legacy=$ep_renderer_legacy"
fi


# EP-12 / F006+F011: standalone launch/poll output must cross the Bash
# tool boundary instead of being swallowed in shell-local assignments.
EP_STANDALONE_LAUNCH="$EP_DIR/standalone-launch.sh"
ep_extract_fence_after "$EP_ENSEMBLE" \
    '*`codex_launch_mode == "agent-dispatch"` (standalone fallback' \
    "$EP_STANDALONE_LAUNCH"
mkdir -p "$EP_DIR/dispatch-bin" "$EP_DIR/dispatch-scratch"
cat > "$EP_DIR/dispatch-bin/agent-dispatch.sh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    start)
        printf '%s\n' "${EP_START_PAYLOAD:-{\"job_id\":\"opaque-7f3a\",\"pid\":42,\"out_file\":\"/tmp/out\"}}"
        ;;
    poll)
        shift
        received_job=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --job) received_job="$2"; shift 2 ;;
                *) shift ;;
            esac
        done
        printf '%s\n' "$received_job" > "$EP_POLL_JOB"
        count_file="$EP_POLL_COUNT"
        count=0
        [[ ! -f "$count_file" ]] || count=$(cat "$count_file")
        count=$((count + 1))
        printf '%s\n' "$count" > "$count_file"
        if [[ "$count" -eq 1 ]]; then
            printf '%s\n' '{"verdict":"alive","status":"running"}'
        else
            printf '%s\n' '{"verdict":"completed","status":"completed","raw_output":"review result","tokens":7}'
        fi
        ;;
    stop)
        printf '%s\n' '{"verdict":"cancelled","status":"cancelled"}'
        ;;
    *)
        exit 64
        ;;
esac
EOF
chmod +x "$EP_DIR/dispatch-bin/agent-dispatch.sh"
ep_launch_out=$(MRB="$EP_DIR/dispatch-bin/" review_id=ep \
    scratch_dir="$EP_DIR/dispatch-scratch" \
    role_ensemble_detect_model=gpt-5.4 role_ensemble_detect_effort=xhigh \
    /bin/bash "$EP_STANDALONE_LAUNCH" 2>/dev/null)
ep_launch_rc=$?
ep_launch_job_id=$(printf '%s\n' "$ep_launch_out" | jq -er '.job_id')
ep_launch_missing_out=$(EP_START_PAYLOAD='{"pid":42}' \
    MRB="$EP_DIR/dispatch-bin/" review_id=ep \
    scratch_dir="$EP_DIR/dispatch-scratch" \
    /bin/bash "$EP_STANDALONE_LAUNCH" 2>/dev/null)
ep_launch_missing_rc=$?
ep_launch_malformed_out=$(EP_START_PAYLOAD='not-json' \
    MRB="$EP_DIR/dispatch-bin/" review_id=ep \
    scratch_dir="$EP_DIR/dispatch-scratch" \
    /bin/bash "$EP_STANDALONE_LAUNCH" 2>/dev/null)
ep_launch_malformed_rc=$?

EP_STANDALONE_POLL="$EP_DIR/standalone-poll.sh"
ep_extract_fence_after "$EP_ENSEMBLE" \
    '*`codex_launch_mode == "agent-dispatch"`:* run one foreground collector' \
    "$EP_STANDALONE_POLL"
rm -f "$EP_DIR/poll-count" "$EP_DIR/poll-job"
ep_poll_out=$(EP_POLL_COUNT="$EP_DIR/poll-count" \
    EP_POLL_JOB="$EP_DIR/poll-job" MRB="$EP_DIR/dispatch-bin/" \
    codex_job_id="$ep_launch_job_id" \
    scratch_dir="$EP_DIR/dispatch-scratch" ensemble_ceiling_sec=600 \
    trace_log_path="$EP_DIR/trace.md" \
    /bin/bash "$EP_STANDALONE_POLL" 2>/dev/null)
ep_poll_rc=$?
ep_poll_body=$(cat "$EP_DIR/dispatch-scratch/codex.out" 2>/dev/null)
ep_poll_count=$(cat "$EP_DIR/poll-count" 2>/dev/null)
ep_poll_job=$(cat "$EP_DIR/poll-job" 2>/dev/null)
if [[ "$ep_launch_rc" -eq 0 \
   && "$ep_launch_job_id" == "opaque-7f3a" \
   && "$ep_launch_missing_rc" -ne 0 && "$ep_launch_malformed_rc" -ne 0 \
   && "$ep_poll_rc" -eq 0 \
   && "$(printf '%s\n' "$ep_poll_out" | jq -r '.verdict')" == "completed" \
   && "$ep_poll_body" == "review result" \
   && "$ep_poll_count" == "2" && "$ep_poll_job" == "$ep_launch_job_id" ]]; then
    pass "EP-12 (F006/F011): standalone launch and terminal poll JSON cross the tool boundary into orchestrator context"
else
    fail "EP-12: standalone dispatch state remains shell-local or collector output is incomplete" \
      "launch=$ep_launch_rc:$ep_launch_out missing=$ep_launch_missing_rc:$ep_launch_missing_out malformed=$ep_launch_malformed_rc:$ep_launch_malformed_out poll=$ep_poll_rc:$ep_poll_out job=$ep_poll_job body=$ep_poll_body count=$ep_poll_count"
fi

# ---------------------------------------------------------------- LF-* lifecycle regression contracts
# These execute the command fences where the Markdown exposes runnable Bash.
# Parser-only Markdown is checked as an instruction contract because there is
# no standalone parser binary to invoke.
LF_DIR="$WORK/lifecycle-regressions"
mkdir -p "$LF_DIR"

cat > "$LF_DIR/plan-refresh.py" <<'PY'
from pathlib import Path
import json
import os
import subprocess
import sys
import tempfile
import textwrap

root = Path(sys.argv[1])
work_root = Path(sys.argv[2])
paths = [
    root / "commands/add.md",
    root / "commands/walkthrough.md",
    root / "fragments/08-fix-loader.md",
]
runtime_plan = {
    "orchestrator": "claude-code",
    "roles": {
        "fix": {
            "engine": "claude",
            "model": "runtime-opus",
            "effort": None,
            "source": "fixture",
        }
    },
    "gates": {
        "phase3_gate": 12,
        "phase4_bands": [12, 34, 56],
        "fix_threshold": 70.25,
        "walkthrough_threshold": 55.5,
    },
    "warnings": [],
}
artifact = {
    "base_branch": "fallback-must-not-be-used",
    "base_context": {"comparison_ref": "trusted-ref", "freshness": "fresh"},
    "gates": {
        "phase3_gate": 37.5,
        "phase4_bands": [37.5, 62.5, 91],
        "fix_threshold": 60,
        "walkthrough_threshold": 60,
    },
    "model_plan": {
        "gates": {
            "phase3_gate": 37.5,
            "phase4_bands": [37.5, 62.5, 91],
        }
    },
}

with tempfile.TemporaryDirectory(prefix="plan-", dir=work_root) as td:
    work = Path(td)
    stubs = work / "bin"
    captures = work / "captures"
    stubs.mkdir()
    captures.mkdir()
    artifact_path = work / "artifact.json"
    artifact_path.write_text(json.dumps(artifact), encoding="utf-8")
    missing_path = work / "missing-comparison-ref.json"
    missing = json.loads(json.dumps(artifact))
    del missing["base_context"]
    missing_path.write_text(json.dumps(missing), encoding="utf-8")

    (stubs / "artifact-read.sh").write_text(textwrap.dedent("""\
        #!/usr/bin/env bash
        set -u
        path=""; filter=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --path) path="$2"; shift 2 ;;
            --filter) filter="$2"; shift 2 ;;
            *) exit 64 ;;
          esac
        done
        jq -c "$filter" "$path"
    """), encoding="utf-8")
    (stubs / "review-config.sh").write_text(textwrap.dedent("""\
        #!/usr/bin/env bash
        set -u
        ref=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --repo-root|--orchestrator|--profile|--models) shift 2 ;;
            --repo-config-ref) ref="$2"; shift 2 ;;
            *) exit 64 ;;
          esac
        done
        [[ "$ref" == trusted-ref ]] || {
          printf 'untrusted comparison ref: %s\n' "$ref" >&2
          exit 9
        }
        printf '%s\n' "$RUNTIME_PLAN_JSON"
    """), encoding="utf-8")
    (stubs / "artifact-patch.py").write_text(textwrap.dedent("""\
        #!/usr/bin/env bash
        set -u
        plan=""; gates=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --path) shift 2 ;;
            --set-json)
              pair="$2"; shift 2
              key="${pair%%=*}"; value="${pair#*=}"
              case "$key" in
                model_plan) plan="${value#@}" ;;
                gates) gates="$value" ;;
              esac
              ;;
            *) exit 64 ;;
          esac
        done
        [[ -z "$plan" ]] || cat "$plan" > "$CAPTURE_DIR/$CASE.plan.json"
        printf '%s\n' "$gates" > "$CAPTURE_DIR/$CASE.gates.json"
        exit "${PATCH_RC:-0}"
    """), encoding="utf-8")
    for stub in stubs.iterdir():
        stub.chmod(0o755)

    base_env = {
        **os.environ,
        "PATH": f"{stubs}:{os.environ['PATH']}",
        "RUNTIME_PLAN_JSON": json.dumps(runtime_plan, separators=(",", ":")),
        "CAPTURE_DIR": str(captures),
        "artifact_path": str(artifact_path),
        "repo_root": str(work),
        "harness_id": "claude-code",
        "profile": "",
        "models_csv": "",
        "threshold": "",
    }
    for source in paths:
        text = source.read_text(encoding="utf-8")
        anchor = text.index("comparison_ref=$(")
        assert text.index('artifact-validate.sh --path "$artifact_path"') < anchor
        start = text.rfind("```bash\n", 0, anchor) + len("```bash\n")
        end = text.index("\n```", anchor)
        block = text[start:end]
        case = source.name.replace(".", "-")
        result = subprocess.run(
            ["/bin/bash", "-c", block],
            env={**base_env, "CASE": case, "PATCH_RC": "0"},
            text=True,
            capture_output=True,
        )
        assert result.returncode == 0, (
            f"{source.relative_to(root)} success rc={result.returncode}: "
            f"{result.stderr}"
        )
        plan = json.loads((captures / f"{case}.plan.json").read_text())
        gates = json.loads((captures / f"{case}.gates.json").read_text())
        assert plan["roles"]["fix"]["model"] == "runtime-opus"
        assert plan["gates"]["phase3_gate"] == 37.5
        assert plan["gates"]["phase4_bands"] == [37.5, 62.5, 91]
        assert plan["gates"]["fix_threshold"] == 70.25
        assert plan["gates"]["walkthrough_threshold"] == 55.5
        assert gates == plan["gates"]

        failed = subprocess.run(
            ["/bin/bash", "-c", block],
            env={**base_env, "CASE": case + "-failed", "PATCH_RC": "23"},
            text=True,
            capture_output=True,
        )
        assert failed.returncode == 23, (
            f"{source.relative_to(root)} masked patch rc 23 "
            f"with {failed.returncode}"
        )

        missing_case = case + "-missing"
        absent = subprocess.run(
            ["/bin/bash", "-c", block],
            env={
                **base_env,
                "artifact_path": str(missing_path),
                "CASE": missing_case,
                "PATCH_RC": "0",
            },
            text=True,
            capture_output=True,
        )
        assert absent.returncode != 0
        assert "missing trusted base_context.comparison_ref" in absent.stderr
        assert not (captures / f"{missing_case}.plan.json").exists()
PY
lf_plan_out=$(python3 "$LF_DIR/plan-refresh.py" "$REPO" "$LF_DIR" 2>&1)
lf_plan_rc=$?
if [[ "$lf_plan_rc" -eq 0 ]]; then
    pass "LF-1 (F014/F082): extracted refreshes trust comparison_ref, preserve classification gates, refresh runtime plan, write coherent gates, and retain patch rc"
else
    fail "LF-1: extracted lifecycle plan refresh contract failed" "$lf_plan_out"
fi

cat > "$LF_DIR/parser-contracts.py" <<'PY'
from pathlib import Path
import os
import subprocess
import sys
import textwrap

root = Path(sys.argv[1])
paths = [
    root / "commands/fix.md",
    root / "commands/walkthrough.md",
    root / "fragments/08-fix-loader.md",
]
blocks = []
for path in paths:
    text = path.read_text(encoding="utf-8")
    start = text.index('  jq -en --arg token "$token"')
    end = (
        text.index("  ' >/dev/null 2>&1", start)
        + len("  ' >/dev/null 2>&1")
    )
    block = textwrap.dedent(text[start:end])
    blocks.append(block)
    assert "before any artifact lookup" in text
    assert "Accept at most one positional threshold token" in text
    assert "Keep the original token as `threshold`" in text
    assert "second positional" in text and "duplicate-threshold usage error" in text
    assert "unknown option" in text
    assert "Do not continue past parsing on any error" in text
assert len(set(blocks)) == 1
for token in ("0", "60.5", "100", "1e2"):
    result = subprocess.run(
        ["/bin/bash", "-c", blocks[0]],
        env={**os.environ, "token": token},
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, f"valid threshold rejected: {token}"
for token in ("101", "-1", "text", "NaN", "Infinity", "1e999", "60junk"):
    result = subprocess.run(
        ["/bin/bash", "-c", blocks[0]],
        env={**os.environ, "token": token},
        text=True,
        capture_output=True,
    )
    assert result.returncode != 0, f"invalid threshold accepted: {token}"

promote = (root / "commands/promote.md").read_text(encoding="utf-8")
promote_flat = " ".join(promote.split())
frontmatter = promote.split("---", 2)[1]
assert "--profile" not in promote and "--models" not in promote
assert "before asking for a reason" in promote
assert "A second finding id, a repeated flag, a missing/empty flag value" in promote_flat
assert "an unknown option, or any unconsumed token" in promote_flat
assert "exit with usage code 64" in promote_flat
assert "do not look up or mutate an artifact" in promote_flat
assert "exactly one tally pair" in promote_flat
assert "tally-subagent-tokens.sh" in frontmatter
assert "orchestrator-tokens.sh" in frontmatter
PY
lf_parser_out=$(python3 "$LF_DIR/parser-contracts.py" "$REPO" 2>&1)
lf_parser_rc=$?
if [[ "$lf_parser_rc" -eq 0 ]]; then
    pass "LF-2 (F018/F019/F082): finite threshold and strict promote parser instruction contracts reject invalid input before side effects"
else
    fail "LF-2: parser instruction contract drifted" "$lf_parser_out"
fi

ep_extract_fence_after "$REPO/commands/promote.md" \
    '### 6.5. Refresh cumulative token tallies' "$LF_DIR/promote-tally.sh"
ep_extract_fence_after "$REPO/commands/promote.md" \
    '### 7. Re-render `artifact.md`' "$LF_DIR/promote-render.sh"
cat "$LF_DIR/promote-tally.sh" "$LF_DIR/promote-render.sh" \
    > "$LF_DIR/promote-finalize.sh"
ep_extract_fence_after "$REPO/commands/walkthrough.md" \
    '#### 6.1. Re-tally `subagent_tokens` + `orchestrator_tokens`, then re-render `artifact.md`' \
    "$LF_DIR/walkthrough-finalize.sh"
mkdir -p "$LF_DIR/tally-bin" "$LF_DIR/review"
printf '{"review_started_at":"2026-07-21T00:00:00Z"}\n' \
    > "$LF_DIR/review/artifact.json"
: > "$LF_DIR/review/tokens.jsonl"
: > "$LF_DIR/review/trace.md"
cat > "$LF_DIR/tally-bin/tally-subagent-tokens.sh" <<'EOF'
#!/usr/bin/env bash
printf 'subagent\n' >> "$LF_ORDER"
exit 7
EOF
cat > "$LF_DIR/tally-bin/orchestrator-tokens.sh" <<'EOF'
#!/usr/bin/env bash
printf 'orchestrator\n' >> "$LF_ORDER"
exit 8
EOF
cat > "$LF_DIR/tally-bin/artifact-render.py" <<'EOF'
#!/usr/bin/env bash
printf 'render\n' >> "$LF_ORDER"
exit 0
EOF
chmod +x "$LF_DIR/tally-bin/"*
lf_tally_bad=""
for lf_tally_case in promote-finalize walkthrough-finalize; do
    LF_ORDER="$LF_DIR/$lf_tally_case.order"
    export LF_ORDER
    : > "$LF_ORDER"
    PATH="$LF_DIR/tally-bin:$PATH" \
      review_dir="$LF_DIR/review" \
      artifact_path="$LF_DIR/review/artifact.json" \
      trace_log_path="$LF_DIR/review/trace.md" \
      /bin/bash "$LF_DIR/$lf_tally_case.sh" >/dev/null 2>&1
    lf_tally_rc=$?
    lf_tally_order=$(tr '\n' ' ' < "$LF_ORDER" | sed 's/[[:space:]]*$//')
    if [[ "$lf_tally_rc" -ne 0 \
       || "$lf_tally_order" != "subagent orchestrator render" ]]; then
        lf_tally_bad="$lf_tally_bad $lf_tally_case=$lf_tally_rc:$lf_tally_order"
    fi
done
if [[ -z "$lf_tally_bad" ]]; then
    pass "LF-3 (F046): non-deferred promote and deferred walkthrough batch tally exactly once in subagent→orchestrator→render order"
else
    fail "LF-3: lifecycle tally order/count drifted" "$lf_tally_bad"
fi

cat > "$LF_DIR/locations.py" <<'PY'
from pathlib import Path
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
import textwrap

root = Path(sys.argv[1])
work_root = Path(sys.argv[2])
walk = (root / "commands/walkthrough.md").read_text(encoding="utf-8")
add = (root / "commands/add.md").read_text(encoding="utf-8")
loader = (root / "fragments/08-fix-loader.md").read_text(encoding="utf-8")

def fence(text, needle):
    anchor = text.index(needle)
    start = text.rfind("```bash\n", 0, anchor) + len("```bash\n")
    end = text.index("\n```", anchor)
    return text[start:end]

def run(block, env=None):
    result = subprocess.run(
        ["/bin/bash", "-c", block],
        env={**os.environ, **(env or {})},
        text=True,
        capture_output=True,
    )
    assert result.returncode == 0, (
        f"rc={result.returncode}\nstdout={result.stdout}\nstderr={result.stderr}"
    )
    return result.stdout

fixture = [
    {"id": "F1", "file": "src/ranged.py", "line_range": [4, 9],
     "score": 70, "disposition": "confirmed_manual",
     "auto_fix_hint": {"hint": "h", "confidence": "high",
                       "second_opinion": "concurs"}},
    {"id": "F2", "file": "src/no-range.py", "line_range": None,
     "score": 70, "disposition": "confirmed_manual",
     "auto_fix_hint": {"hint": "h", "confidence": "high",
                       "second_opinion": "concurs"}},
    {"id": "F3", "file": "(unknown)", "line_range": None,
     "score": 70, "disposition": "confirmed_manual",
     "auto_fix_hint": {"hint": "h", "confidence": "high",
                       "second_opinion": "concurs"}},
]
table = fence(walk, "auto_rec_table=$(jq -r '")
out = run(
    "auto_rec_in_scope=" +
    shlex.quote(json.dumps(fixture, separators=(",", ":"))) +
    "\n" + table + "\nprintf '%s\n' \"$auto_rec_table\""
)
assert "src/ranged.py:4" in out
assert "src/no-range.py" in out and "src/no-range.py:null" not in out
assert "(unknown)" in out and "(unknown):" not in out
assert "null-null" not in out

loader_location = fence(
    loader,
    "auto_rec_location=$(printf '%s\\n' \"$auto_rec_entry_json\"",
)
for entry, expected in ((fixture[0], "src/ranged.py:4-9"),
                        (fixture[1], "src/no-range.py"),
                        (fixture[2], "(unknown)")):
    out = run(
        "auto_rec_entry_json=" +
        shlex.quote(json.dumps(entry, separators=(",", ":"))) +
        "\n" + loader_location +
        "\nprintf '%s\n' \"$auto_rec_location\""
    ).strip()
    assert out == expected

with tempfile.TemporaryDirectory(prefix="locations-", dir=work_root) as td:
    work = Path(td)
    reader = work / "artifact-read.sh"
    reader.write_text(textwrap.dedent("""\
        #!/usr/bin/env bash
        set -u
        path=""; filter=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --path) path="$2"; shift 2 ;;
            --filter) filter="$2"; shift 2 ;;
            *) exit 64 ;;
          esac
        done
        jq "$filter" "$path"
    """), encoding="utf-8")
    reader.chmod(0o755)
    env = {"PATH": f"{work}:{os.environ['PATH']}"}
    artifact = work / "artifact.json"
    artifact.write_text(json.dumps({"findings": [
        {"id": "F1", "file": "src/ranged.py", "line_range": [4, 9],
         "claim": "ranged", "disposition": "confirmed_manual",
         "impact_type": "correctness", "score_phase4": 70,
         "human_confirmation": None},
        {"id": "F2", "file": "src/no-range.py", "line_range": None,
         "claim": "no range", "disposition": "confirmed_manual",
         "impact_type": "correctness", "score_phase4": 70,
         "human_confirmation": None},
        {"id": "F3", "file": "(unknown)", "line_range": None,
         "claim": "unknown", "disposition": "confirmed_manual",
         "impact_type": "correctness", "score_phase4": 70,
         "human_confirmation": None},
    ]}), encoding="utf-8")

    summary_anchor = add.index("Build the per-finding lines from `artifact-read.sh`")
    filter_anchor = add.index(
        "--filter \"[.findings[] | select(.id | IN", summary_anchor
    )
    start = add.rfind("```bash\n", 0, filter_anchor) + len("```bash\n")
    end = add.index("\n```", filter_anchor)
    add_block = add[start:end]
    add_block, count = re.subn(
        r"select\(\.id \| IN\(.*?\)\)", "select(true)", add_block, count=1
    )
    assert count == 1
    out = run(
        f"artifact_path={shlex.quote(str(artifact))}\n"
        "new_ids=F1,F2,F3\n" + add_block,
        env,
    )
    assert "src/ranged.py:4" in out
    assert "src/no-range.py:null" not in out
    assert "(unknown):" not in out
    assert "null-null" not in out

    brief = fence(
        walk,
        "f_line_range_json=$(jq -c '.line_range // null' <<<\"$finding_json\")",
    )
    issue = fence(walk, 'f_issue_location_rule="In the Location section')
    findings = json.loads(artifact.read_text())["findings"]
    for item, expected in zip(
        findings,
        ("src/ranged.py:4-9", "src/no-range.py", "(unknown)"),
    ):
        finding_json = shlex.quote(json.dumps(item, separators=(",", ":")))
        out = run(
            "finding_json=" + finding_json + "\n" + brief +
            "\nprintf '%s\n%s\n' \"$f_location\" \"$f_location_context\"",
            env,
        )
        lines = out.splitlines()
        assert lines[0] == expected
        if item["line_range"] is None:
            assert "claim/evidence" in lines[1]
        if item["file"] == "(unknown)":
            assert "Do not issue a Read request" in lines[1]
        assert "null-null" not in out

        out = run(
            f"artifact_path={shlex.quote(str(artifact))}\n"
            f"finding_id={item['id']}\n" + issue +
            "\nprintf '%s\n%s\n%s\n' \"$f_location\" "
            "\"$f_issue_location_rule\" \"$f_issue_context\"",
            env,
        )
        lines = out.splitlines()
        assert lines[0] == expected
        if item["line_range"] is None:
            assert "claim/evidence" in lines[2]
        if item["file"] == "(unknown)":
            assert "Do not issue a Read request" in lines[2]
            assert "exact source location is unknown" in lines[1]
        elif item["line_range"] is None:
            assert lines[1].endswith("with no line suffix.")
        assert "null-null" not in out
PY
lf_location_out=$(python3 "$LF_DIR/locations.py" "$REPO" "$LF_DIR" 2>&1)
lf_location_rc=$?
if [[ "$lf_location_rc" -eq 0 ]]; then
    pass "LF-4 (F085): extracted ranged/file-only/unknown consumers never fabricate ranges or placeholder Reads"
else
    fail "LF-4: nullable lifecycle location contract failed" "$lf_location_out"
fi


# ---------------------------------------------------------------- FT-* finalization regression contracts
FT_DIR="$WORK/finalization-regressions"
mkdir -p "$FT_DIR"

# Exercise the exact Phase 6.2b fence. A malformed active transcript must
# retain the prior telemetry bytes while persisting exactly one failure row.
ep_extract_fence_after "$REPO/fragments/07-finalize.md" \
    '### 6.2b. Tally `orchestrator_tokens` from the session transcript(s)' \
    "$FT_DIR/orchestrator-finalize.sh"
cat >> "$FT_DIR/orchestrator-finalize.sh" <<'EOF'
printf '%s|%s\n' "$orchestrator_tally_failed" "$finalization_record_failed"
EOF
mkdir -p "$FT_DIR/orchestrator"
cp "$FIX/artifact-seed.json" "$FT_DIR/orchestrator/artifact.json"
cat > "$FT_DIR/orchestrator/prior.jsonl" <<'JSONL'
{"type":"assistant","timestamp":"2026-07-21T00:01:00.000Z","sessionId":"prior-session","message":{"usage":{"input_tokens":17,"output_tokens":5,"cache_read_input_tokens":3,"cache_creation_input_tokens":2}}}
JSONL
MATTHEWS_REVIEW_TALLY_ORCHESTRATOR=1 \
  "$TOOLS/orchestrator-tokens.sh" \
    --artifact "$FT_DIR/orchestrator/artifact.json" \
    --since "2026-07-21T00:00:00.000Z" \
    --transcript-file "$FT_DIR/orchestrator/prior.jsonl" \
    --session-id prior-session >/dev/null 2>&1 \
  || fail "FT-1: could not seed prior orchestrator telemetry"
cat > "$FT_DIR/orchestrator/malformed.jsonl" <<'JSONL'
{"type":"assistant","timestamp":"2026-07-21T00:02:00.000Z","sessionId":"active-session","message":{"usage":{"input_tokens":999,"output_tokens":999}}}
{"type":
JSONL
: > "$FT_DIR/orchestrator/phases.jsonl"
: > "$FT_DIR/orchestrator/trace.md"
ft_orch_before=$(sha_of "$FT_DIR/orchestrator/artifact.json")
ft_orch_state=$(PATH="$TOOLS:$PATH" \
    MATTHEWS_REVIEW_TALLY_ORCHESTRATOR=1 \
    MATTHEWS_REVIEW_TRANSCRIPT_FILE="$FT_DIR/orchestrator/malformed.jsonl" \
    MATTHEWS_REVIEW_SESSION_ID=active-session \
    artifact_path="$FT_DIR/orchestrator/artifact.json" \
    review_started_at="2026-07-21T00:00:00.000Z" \
    review_dir="$FT_DIR/orchestrator" \
    trace_log_path="$FT_DIR/orchestrator/trace.md" \
    /bin/bash "$FT_DIR/orchestrator-finalize.sh" 2>&1)
ft_orch_rc=$?
ft_orch_after=$(sha_of "$FT_DIR/orchestrator/artifact.json")
ft_orch_rows=$(jq -s '
  [.[] | select(
    .name == "orchestrator-tally"
    and .finalization_failures == 1
  )] | length
' "$FT_DIR/orchestrator/phases.jsonl")
ft_orch_total=$(jq -r '.orchestrator_tokens.total_input' \
    "$FT_DIR/orchestrator/artifact.json")
if [[ "$ft_orch_rc" -eq 0 && "$ft_orch_before" == "$ft_orch_after" \
   && "$ft_orch_rows" == "1" && "$ft_orch_total" == "17" \
   && "$ft_orch_state" == *"true|false"* \
   && "$(cat "$FT_DIR/orchestrator/trace.md")" == *"orchestrator_tally_failed"* \
   && "$(cat "$FT_DIR/orchestrator/trace.md")" == *"ERROR:"* \
   && "$(cat "$FT_DIR/orchestrator/trace.md")" == *"Action:"* ]]; then
    pass "FT-1 (F012): malformed transcript retains telemetry bytes and records one persisted finalization failure without fake zero"
else
    fail "FT-1: malformed transcript finalization contract failed" \
      "rc=$ft_orch_rc hash=$ft_orch_before/$ft_orch_after rows=$ft_orch_rows total=$ft_orch_total state=$ft_orch_state trace=$(cat "$FT_DIR/orchestrator/trace.md")"
fi

# An empty scoped retally removes only the active session row and recomputes
# totals from retained siblings.
mkdir -p "$FT_DIR/empty-scope"
cp "$FIX/artifact-seed.json" "$FT_DIR/empty-scope/artifact.json"
cat > "$FT_DIR/empty-scope/a.jsonl" <<'JSONL'
{"type":"assistant","timestamp":"2026-07-21T01:00:00.000Z","sessionId":"session-a","message":{"usage":{"input_tokens":10,"output_tokens":11,"cache_read_input_tokens":12,"cache_creation_input_tokens":13}}}
JSONL
cat > "$FT_DIR/empty-scope/b.jsonl" <<'JSONL'
{"type":"assistant","timestamp":"2026-07-21T02:00:00.000Z","sessionId":"session-b","message":{"usage":{"input_tokens":20,"output_tokens":21,"cache_read_input_tokens":22,"cache_creation_input_tokens":23}}}
JSONL
: > "$FT_DIR/empty-scope/empty.jsonl"
ft_empty_bad=""
for ft_session in a b; do
    MATTHEWS_REVIEW_TALLY_ORCHESTRATOR=1 \
      "$TOOLS/orchestrator-tokens.sh" \
        --artifact "$FT_DIR/empty-scope/artifact.json" \
        --since "2026-07-21T00:00:00.000Z" \
        --transcript-file "$FT_DIR/empty-scope/$ft_session.jsonl" \
        --session-id "session-$ft_session" >/dev/null 2>&1 \
      || ft_empty_bad="$ft_empty_bad seed-$ft_session"
done
MATTHEWS_REVIEW_TALLY_ORCHESTRATOR=1 \
  "$TOOLS/orchestrator-tokens.sh" \
    --artifact "$FT_DIR/empty-scope/artifact.json" \
    --since "2026-07-21T00:00:00.000Z" \
    --transcript-file "$FT_DIR/empty-scope/empty.jsonl" \
    --session-id session-a >/dev/null 2>&1 \
  || ft_empty_bad="$ft_empty_bad retally"
ft_empty_summary=$(jq -r '
  [
    .orchestrator_tokens.total_input,
    .orchestrator_tokens.total_output,
    .orchestrator_tokens.cache_read,
    .orchestrator_tokens.cache_creation,
    .orchestrator_tokens.turn_count,
    (.orchestrator_tokens.sessions | length),
    .orchestrator_tokens.sessions[0].session_id
  ] | map(tostring) | join("|")
' "$FT_DIR/empty-scope/artifact.json")
if [[ -z "$ft_empty_bad" \
   && "$ft_empty_summary" == "20|21|22|23|1|1|session-b" ]]; then
    pass "FT-2 (F042): empty scoped retally removes only the active row and preserves sibling session totals"
else
    fail "FT-2: empty scoped orchestrator retally damaged sibling totals" \
      "errors=$ft_empty_bad summary=$ft_empty_summary"
fi

# sync-degraded.py rejects malformed encodings/shapes/counters without a
# partial write, accepts explicit null as zero, and removes an all-zero field.
mkdir -p "$FT_DIR/sync"
cp "$FIX/artifact-seed.json" "$FT_DIR/sync/baseline.json"
ft_sync_bad=""
ft_sync_invalid() {
    local name="$1" writer="$2"
    local artifact="$FT_DIR/sync/$name.json"
    local phases="$FT_DIR/sync/$name.jsonl"
    local output code before after
    cp "$FT_DIR/sync/baseline.json" "$artifact"
    case "$writer" in
        malformed)
            printf '{"lens_dispatch_failures":\n' > "$phases"
            ;;
        utf8)
            printf '\377\n' > "$phases"
            ;;
        nonobject)
            printf '[]\n' > "$phases"
            ;;
        wrongtype)
            printf '{"lens_dispatch_failures":"1"}\n' > "$phases"
            ;;
        negative)
            printf '{"candidate_drop_failures":-1}\n' > "$phases"
            ;;
    esac
    before=$(sha_of "$artifact")
    output=$("$TOOLS/sync-degraded.py" \
      --artifact "$artifact" --phases-log "$phases" 2>&1)
    code=$?
    after=$(sha_of "$artifact")
    if [[ "$code" -ne 1 || "$before" != "$after" \
       || "$output" != *"ERROR:"* || "$output" != *"Action:"* ]]; then
        ft_sync_bad="$ft_sync_bad $name=$code:$before/$after:$output"
    fi
}
for ft_sync_case in malformed utf8 nonobject wrongtype negative; do
    ft_sync_invalid "$ft_sync_case" "$ft_sync_case"
done

cp "$FT_DIR/sync/baseline.json" "$FT_DIR/sync/null-zero.json"
"$TOOLS/artifact-patch.py" \
  --path "$FT_DIR/sync/null-zero.json" \
  --set-json 'degraded={"lens_dispatch_failures":9,"candidate_drop_failures":8,"finalization_failures":7}' \
  >/dev/null
cat > "$FT_DIR/sync/null-zero.jsonl" <<'JSONL'
{"lens_dispatch_failures":null,"candidate_drop_failures":null,"finalization_failures":null}
{"lens_dispatch_failures":0,"candidate_drop_failures":0,"finalization_failures":0}
JSONL
ft_sync_null_out=$("$TOOLS/sync-degraded.py" \
  --artifact "$FT_DIR/sync/null-zero.json" \
  --phases-log "$FT_DIR/sync/null-zero.jsonl" 2>&1)
ft_sync_null_rc=$?
ft_sync_null_has=$(jq -r 'has("degraded")' "$FT_DIR/sync/null-zero.json")

cp "$FT_DIR/sync/baseline.json" "$FT_DIR/sync/positive.json"
cat > "$FT_DIR/sync/positive.jsonl" <<'JSONL'
{"lens_dispatch_failures":2,"candidate_drop_failures":null}
{"candidate_drop_failures":3,"finalization_failures":1}
JSONL
ft_sync_positive_out=$("$TOOLS/sync-degraded.py" \
  --artifact "$FT_DIR/sync/positive.json" \
  --phases-log "$FT_DIR/sync/positive.jsonl" 2>&1)
ft_sync_positive_rc=$?
ft_sync_positive=$(jq -c '.degraded' "$FT_DIR/sync/positive.json")
if [[ -z "$ft_sync_bad" && "$ft_sync_null_rc" -eq 0 \
   && "$ft_sync_null_has" == "false" && "$ft_sync_positive_rc" -eq 0 \
   && "$ft_sync_positive" == '{"lens_dispatch_failures":2,"candidate_drop_failures":3,"finalization_failures":1}' ]]; then
    pass "FT-3 (F086): degraded sync is strict/atomic, treats null as zero, canonicalizes positives, and removes all-zero field"
else
    fail "FT-3: degraded synchronization contract failed" \
      "invalid=$ft_sync_bad null=$ft_sync_null_rc:$ft_sync_null_has:$ft_sync_null_out positive=$ft_sync_positive_rc:$ft_sync_positive:$ft_sync_positive_out"
fi

# Assemble the exact current finalization fences into a scenario runner.
ep_extract_fence_after "$REPO/fragments/07-finalize.md" \
    '### 6.4b. Synchronize degraded runs' "$FT_DIR/sync-block.sh"
ep_extract_fence_after "$REPO/fragments/07-finalize.md" \
    '### 6.5. Render `artifact.md`' "$FT_DIR/render-block.sh"
ep_extract_fence_after "$REPO/fragments/07-finalize.md" \
    'Initialize publication state once:' "$FT_DIR/publish-init.sh"
ep_extract_fence_after "$REPO/fragments/07-finalize.md" \
    '**PR mode:**' "$FT_DIR/publish-pr.sh"
ep_extract_fence_after "$REPO/fragments/07-finalize.md" \
    'failure from either mode once' "$FT_DIR/publish-failure.sh"
ep_extract_fence_after "$REPO/fragments/07-finalize.md" \
    'Select the report body first:' "$FT_DIR/mirror.sh"
cat > "$FT_DIR/scenario-runner.sh" <<'EOF'
#!/usr/bin/env bash
set -u
EOF
cat "$FT_DIR/sync-block.sh" "$FT_DIR/render-block.sh" \
    "$FT_DIR/publish-init.sh" "$FT_DIR/publish-pr.sh" \
    "$FT_DIR/publish-failure.sh" "$FT_DIR/mirror.sh" \
    >> "$FT_DIR/scenario-runner.sh"
cat >> "$FT_DIR/scenario-runner.sh" <<'EOF'
printf '%s|%s|%s|%s|%s|%s\n' \
  "$finalization_record_failed" "$render_failed" "$render_recovery_failed" \
  "$publish_attempted" "$publish_failed" "$publish_recovery_render_failed" \
  > "$review_dir/state"
if [[ -n "$mirror_path" ]]; then
    cp "$mirror_path" "$review_dir/chat.md"
fi
EOF
chmod +x "$FT_DIR/scenario-runner.sh"

mkdir -p "$FT_DIR/scenario-bin"
cat > "$FT_DIR/scenario-bin/artifact-render.py" <<'EOF'
#!/usr/bin/env bash
set -u
printf 'render\n' >> "$FT_STATE/render.calls"
remaining=$(cat "$FT_STATE/render.failures")
if [[ "$remaining" -gt 0 ]]; then
    printf '%s\n' "$((remaining - 1))" > "$FT_STATE/render.failures"
    printf 'ERROR: injected renderer failure\n' >&2
    exit 1
fi
exec "$FT_REAL_RENDERER" "$@"
EOF
cat > "$FT_DIR/scenario-bin/artifact-publish.sh" <<'EOF'
#!/usr/bin/env bash
set -u
printf 'publish\n' >> "$FT_STATE/publish.calls"
review_dir=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --review-dir) review_dir="$2"; shift 2 ;;
        *) shift ;;
    esac
done
if [[ "$FT_PUBLISH_RESULT" == "failure" ]]; then
    printf 'ERROR: injected publisher failure\n' >&2
    exit 1
fi
printf '%s\n' '<!-- matthews-review-v1 -->' \
  'COMPACT FAKE PUBLICATION BODY' > "$review_dir/published.md"
printf '%s\n' '{"comment_id":9001}'
EOF
cat > "$FT_DIR/scenario-bin/log-phase.sh" <<'EOF'
#!/usr/bin/env bash
set -u
printf 'log\n' >> "$FT_STATE/log.calls"
if [[ "$FT_LOG_RESULT" == "failure" ]]; then
    printf 'ERROR: injected phase-log failure\n' >&2
    exit 70
fi
exec "$FT_REAL_LOG_PHASE" "$@"
EOF
cat > "$FT_DIR/scenario-bin/sync-degraded.py" <<'EOF'
#!/usr/bin/env bash
set -u
count=0
[[ ! -f "$FT_STATE/sync.calls" ]] || count=$(cat "$FT_STATE/sync.calls")
count=$((count + 1))
printf '%s\n' "$count" > "$FT_STATE/sync.calls"
if [[ "$FT_SYNC_FAIL_ON" -gt 0 && "$count" -eq "$FT_SYNC_FAIL_ON" ]]; then
    printf 'ERROR: injected degradation-sync failure\n' >&2
    printf 'Action: repair the phase log and retry.\n' >&2
    exit 71
fi
exec "$FT_REAL_SYNC" "$@"
EOF
chmod +x "$FT_DIR/scenario-bin/"*

ft_run_scenario() {
    local name="$1" render_failures="$2" publish_result="$3"
    local log_result="$4" sync_fail_on="$5"
    local dir="$FT_DIR/$name"
    mkdir -p "$dir"
    cp "$FIX/artifact-seed.json" "$dir/artifact.json"
    : > "$dir/phases.jsonl"
    : > "$dir/trace.md"
    : > "$dir/render.calls"
    : > "$dir/publish.calls"
    : > "$dir/log.calls"
    printf '%s\n' "$render_failures" > "$dir/render.failures"
    PATH="$FT_DIR/scenario-bin:$TOOLS:$PATH" \
      FT_STATE="$dir" \
      FT_REAL_RENDERER="$TOOLS/artifact-render.py" \
      FT_REAL_LOG_PHASE="$TOOLS/log-phase.sh" \
      FT_REAL_SYNC="$TOOLS/sync-degraded.py" \
      FT_PUBLISH_RESULT="$publish_result" \
      FT_LOG_RESULT="$log_result" \
      FT_SYNC_FAIL_ON="$sync_fail_on" \
      artifact_path="$dir/artifact.json" \
      phases_log_path="$dir/phases.jsonl" \
      trace_log_path="$dir/trace.md" \
      review_dir="$dir" \
      finalization_record_failed=false \
      mode=pr review_id=rev_test pr_number=1 \
      repo_slug=owner/repo head_branch=feature existing_comment_id="" \
      /bin/bash "$FT_DIR/scenario-runner.sh" >/dev/null 2>&1
}

ft_scenario_bad=""
ft_run_scenario render-failure 1 success success 0
if [[ "$(cat "$FT_DIR/render-failure/state")" != \
      "false|true|false|false|false|false" \
   || -s "$FT_DIR/render-failure/publish.calls" \
   || "$(wc -l < "$FT_DIR/render-failure/render.calls" | tr -d '[:space:]')" != "2" \
   || "$(jq -r '.degraded.finalization_failures' "$FT_DIR/render-failure/artifact.json")" != "1" \
   || "$(cat "$FT_DIR/render-failure/artifact.md")" != *"REVIEW DEGRADED"* ]] \
   || ! cmp -s "$FT_DIR/render-failure/artifact.md" "$FT_DIR/render-failure/chat.md"; then
    ft_scenario_bad="$ft_scenario_bad render-failure"
fi

ft_run_scenario publish-failure 0 failure success 0
if [[ "$(cat "$FT_DIR/publish-failure/state")" != \
      "false|false|false|true|true|false" \
   || "$(wc -l < "$FT_DIR/publish-failure/publish.calls" | tr -d '[:space:]')" != "1" \
   || "$(wc -l < "$FT_DIR/publish-failure/render.calls" | tr -d '[:space:]')" != "2" \
   || "$(jq -r '.degraded.finalization_failures' "$FT_DIR/publish-failure/artifact.json")" != "1" \
   || "$(cat "$FT_DIR/publish-failure/artifact.md")" != *"REVIEW DEGRADED"* ]] \
   || ! cmp -s "$FT_DIR/publish-failure/artifact.md" "$FT_DIR/publish-failure/chat.md"; then
    ft_scenario_bad="$ft_scenario_bad publish-failure"
fi

ft_run_scenario publish-success 0 success success 0
if [[ "$(cat "$FT_DIR/publish-success/state")" != \
      "false|false|false|true|false|false" \
   || "$(wc -l < "$FT_DIR/publish-success/publish.calls" | tr -d '[:space:]')" != "1" \
   || "$(jq -r 'has("degraded")' "$FT_DIR/publish-success/artifact.json")" != "false" ]] \
   || cmp -s "$FT_DIR/publish-success/artifact.md" "$FT_DIR/publish-success/published.md" \
   || ! cmp -s "$FT_DIR/publish-success/published.md" "$FT_DIR/publish-success/chat.md"; then
    ft_scenario_bad="$ft_scenario_bad publish-success"
fi

ft_run_scenario record-log-failure 1 success failure 0
ft_log_rows=$(wc -l < "$FT_DIR/record-log-failure/phases.jsonl" | tr -d '[:space:]')
if [[ "$(cat "$FT_DIR/record-log-failure/state")" != \
      "true|true|false|false|false|false" \
   || "$(wc -l < "$FT_DIR/record-log-failure/render.calls" | tr -d '[:space:]')" != "1" \
   || -s "$FT_DIR/record-log-failure/publish.calls" \
   || "$ft_log_rows" != "0" || -e "$FT_DIR/record-log-failure/chat.md" ]]; then
    ft_scenario_bad="$ft_scenario_bad record-log-failure"
fi

ft_run_scenario record-sync-failure 1 success success 2
ft_sync_rows=$(jq -s '
  [.[] | select(.finalization_failures == 1)] | length
' "$FT_DIR/record-sync-failure/phases.jsonl")
if [[ "$(cat "$FT_DIR/record-sync-failure/state")" != \
      "true|true|false|false|false|false" \
   || "$(wc -l < "$FT_DIR/record-sync-failure/render.calls" | tr -d '[:space:]')" != "1" \
   || -s "$FT_DIR/record-sync-failure/publish.calls" \
   || "$ft_sync_rows" != "1" || -e "$FT_DIR/record-sync-failure/chat.md" ]]; then
    ft_scenario_bad="$ft_scenario_bad record-sync-failure"
fi

if [[ -z "$ft_scenario_bad" ]]; then
    pass "FT-4 (F086): exact finalization fences fail closed, recover locally once, publish once, and mirror the exact published body"
else
    fail "FT-4: render/publish/failure-recorder scenario drift" "$ft_scenario_bad"
fi


# ---------------------------------------------------------------- DX-* dispatch/poller regression contracts
# DispatchStateFix explicitly declared the production protocol stable before
# these black-box assertions were added.
DX_DIR="$WORK/dispatch-regressions"
DX_SCRATCH="$DX_DIR/scratch"
mkdir -p "$DX_SCRATCH"

dx_raw_identity() {
    LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null \
      | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}
dx_init_job() {
    local job="$1" engine="$2" wrapper_pid="$3" wrapper_identity="$4"
    local child_pid="$5" child_identity="$6"
    local dir="$DX_SCRATCH/$job"
    mkdir -p "$dir"
    printf '%s\n' "$engine" > "$dir/engine"
    printf '%s\n' "$wrapper_pid" > "$dir/pid"
    printf 'v1|%s|%s\n' "$wrapper_pid" "$wrapper_identity" \
      > "$dir/pid_identity"
    printf '%s\n' "$child_pid" > "$dir/child_pid"
    printf 'v1|%s|%s\n' "$child_pid" "$child_identity" \
      > "$dir/child_identity"
    date +%s > "$dir/started_epoch"
    : > "$dir/out"
    : > "$dir/err"
}

# Identity tri-state: authenticated live, empty/invalid ps observations, and
# authenticated absence. Only the final case may seal a synthetic failure.
/bin/sleep 30 &
dx_live_pid=$!
dx_live_identity=$(dx_raw_identity "$dx_live_pid")
dx_live_job=ad_dx_live_1
dx_init_job "$dx_live_job" omp "$dx_live_pid" "$dx_live_identity" \
    "$dx_live_pid" "$dx_live_identity"
dx_live_out=$("$AD" poll --job "$dx_live_job" \
    --scratch-dir "$DX_SCRATCH")

mkdir -p "$DX_DIR/empty-ps-bin"
cat > "$DX_DIR/empty-ps-bin/ps" <<'EOF'
#!/usr/bin/env bash
case "$*" in
    *"lstart="*) exit 0 ;;
    *"-axo pid="*) printf 'not-a-pid\n'; exit 0 ;;
    *) exec /bin/ps "$@" ;;
esac
EOF
chmod +x "$DX_DIR/empty-ps-bin/ps"
dx_unknown_job=ad_dx_unknown_1
dx_init_job "$dx_unknown_job" omp "$dx_live_pid" "$dx_live_identity" \
    "$dx_live_pid" "$dx_live_identity"
dx_unknown_out=$(PATH="$DX_DIR/empty-ps-bin:$PATH" \
    "$AD" poll --job "$dx_unknown_job" --scratch-dir "$DX_SCRATCH")

dx_dead_pid=2147483000
dx_dead_identity=$(dx_raw_identity "$$")
dx_dead_job=ad_dx_dead_1
dx_init_job "$dx_dead_job" omp "$dx_dead_pid" "$dx_dead_identity" \
    "$dx_dead_pid" "$dx_dead_identity"
printf '%s\n' "$dx_dead_pid" > "$DX_SCRATCH/$dx_dead_job/child_pgid"
printf 'v1|%s|%s\n' "$dx_dead_pid" "$dx_dead_pid" \
  > "$DX_SCRATCH/$dx_dead_job/child_group"
printf 'orphan stderr\n' > "$DX_SCRATCH/$dx_dead_job/err"
dx_dead_first=$("$AD" poll --job "$dx_dead_job" \
    --scratch-dir "$DX_SCRATCH")
dx_dead_hash_before=$(
  shasum "$DX_SCRATCH/$dx_dead_job/terminal/"* | shasum | awk '{print $1}'
)
dx_dead_second=$("$AD" poll --job "$dx_dead_job" \
    --scratch-dir "$DX_SCRATCH")
dx_dead_hash_after=$(
  shasum "$DX_SCRATCH/$dx_dead_job/terminal/"* | shasum | awk '{print $1}'
)
kill "$dx_live_pid" 2>/dev/null || true
wait "$dx_live_pid" 2>/dev/null || true

if printf '%s' "$dx_live_out" | jq -e '
     keys == ["elapsed_sec", "status", "verdict"]
     and .verdict == "alive" and .status == "running"
   ' >/dev/null \
   && printf '%s' "$dx_unknown_out" | jq -e '
     keys == ["elapsed_sec", "process_verification", "status", "verdict"]
     and .verdict == "alive" and .status == "running"
     and .process_verification == "unverifiable"
   ' >/dev/null \
   && [[ ! -e "$DX_SCRATCH/$dx_unknown_job/terminal/ready" ]] \
   && printf '%s' "$dx_dead_first" | jq -e '
     keys == ["error_tail", "exit_code", "status", "verdict"]
     and .verdict == "failed_terminal" and .status == "failed"
     and .exit_code == 255
   ' >/dev/null \
   && [[ "$dx_dead_first" == "$dx_dead_second" \
      && "$dx_dead_hash_before" == "$dx_dead_hash_after" ]]; then
    pass "DX-1 (F030/F041/F055): identity tri-state fails closed and dead wrapper+child seals failed_terminal(255) exactly once"
else
    fail "DX-1: process identity/sealing contract failed" \
      "live=$dx_live_out unknown=$dx_unknown_out dead1=$dx_dead_first dead2=$dx_dead_second hash=$dx_dead_hash_before/$dx_dead_hash_after"
fi

# A dead wrapper with an authenticated live child group remains live across
# polls. Launch through the real dispatcher so the platform-neutral group
# supervisor and every ownership marker are exercised.
DX_ENGINE_BIN="$DX_DIR/engine-bin"
mkdir -p "$DX_ENGINE_BIN"
cat > "$DX_ENGINE_BIN/omp" <<'EOF'
#!/usr/bin/env bash
if [[ "${DX_OMP_MODE:-sleep}" == "ignore-term" ]]; then
    trap '' TERM
    while :; do /bin/sleep 1; done
fi
exec /bin/sleep 30
EOF
chmod +x "$DX_ENGINE_BIN/omp"
printf 'dispatch prompt\n' > "$DX_DIR/prompt.md"
dx_orphan_start=$(PATH="$DX_ENGINE_BIN:$PATH" \
    DX_OMP_MODE=sleep \
    "$AD" start --engine omp --prompt-file "$DX_DIR/prompt.md" \
      --scratch-dir "$DX_SCRATCH")
dx_orphan_job=$(printf '%s' "$dx_orphan_start" | jq -r '.job_id')
dx_orphan_wrapper=$(cat "$DX_SCRATCH/$dx_orphan_job/pid")
dx_orphan_pid=$(cat "$DX_SCRATCH/$dx_orphan_job/child_pid")
/bin/kill -KILL "$dx_orphan_wrapper"
dx_orphan_wait=0
dx_orphan_first=""
while [[ "$dx_orphan_wait" -lt 60 ]]; do
    dx_orphan_first=$("$AD" poll --job "$dx_orphan_job" \
        --scratch-dir "$DX_SCRATCH")
    [[ "$(printf '%s' "$dx_orphan_first" | jq -r \
      '.wrapper_state // empty')" == "dead" ]] && break
    sleep 0.05
    dx_orphan_wait=$((dx_orphan_wait + 1))
done
dx_orphan_second=$("$AD" poll --job "$dx_orphan_job" \
    --scratch-dir "$DX_SCRATCH")
dx_orphan_terminal=false
[[ -e "$DX_SCRATCH/$dx_orphan_job/terminal/ready" ]] \
    && dx_orphan_terminal=true
dx_orphan_stop=$("$AD" stop --job "$dx_orphan_job" \
    --scratch-dir "$DX_SCRATCH" 2>/dev/null)
dx_orphan_stop_rc=$?
if [[ "$dx_orphan_terminal" == "false" \
   && "$dx_orphan_stop_rc" -eq 0 ]] \
   && ! /bin/kill -0 "$dx_orphan_pid" 2>/dev/null \
   && printf '%s' "$dx_orphan_first" | jq -e '
        keys == ["elapsed_sec", "engine_state", "status", "verdict", "wrapper_state"]
        and .verdict == "alive" and .status == "running"
        and .wrapper_state == "dead" and .engine_state == "alive"
      ' >/dev/null \
   && printf '%s' "$dx_orphan_second" | jq -e \
      --argjson first "$dx_orphan_first" '
        keys == ["elapsed_sec", "engine_state", "status", "verdict", "wrapper_state"]
        and .verdict == "alive" and .status == "running"
        and .wrapper_state == "dead" and .engine_state == "alive"
        and .elapsed_sec >= $first.elapsed_sec
      ' >/dev/null \
   && printf '%s' "$dx_orphan_stop" | jq -e --arg job "$dx_orphan_job" '
        keys == ["job_id", "status", "verdict"]
        and .job_id == $job and .verdict == "cancelled"
        and .status == "cancelled"
      ' >/dev/null; then
    pass "DX-2 (F021/F034/F041): dead wrapper plus live child cannot seal/retry until authenticated stop removes the group"
else
    /bin/kill -KILL -- "-$dx_orphan_pid" 2>/dev/null || true
    fail "DX-2: orphan engine group was sealed or left running" \
      "start=$dx_orphan_start first=$dx_orphan_first second=$dx_orphan_second terminal=$dx_orphan_terminal stop=$dx_orphan_stop_rc:$dx_orphan_stop"
fi

# Force the full authenticated cancellation sequence with a process that
# ignores TERM. A PATH-scoped kill wrapper records TERM before KILL while
# delegating the real signals.
mkdir -p "$DX_DIR/kill-bin"
cat > "$DX_DIR/kill-bin/kill" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" != "-0" ]]; then
    last=""
    for arg in "$@"; do last="$arg"; done
    printf '%s|%s\n' "${1:-}" "$last" >> "$DX_KILL_LOG"
fi
exec /bin/kill "$@"
EOF
chmod +x "$DX_DIR/kill-bin/kill"
: > "$DX_DIR/kill.log"
dx_term_start=$(PATH="$DX_DIR/kill-bin:$DX_ENGINE_BIN:$PATH" \
    DX_KILL_LOG="$DX_DIR/kill.log" DX_OMP_MODE=ignore-term \
    "$AD" start --engine omp --prompt-file "$DX_DIR/prompt.md" \
      --scratch-dir "$DX_SCRATCH")
dx_term_job=$(printf '%s' "$dx_term_start" | jq -r '.job_id')
dx_term_pid=$(cat "$DX_SCRATCH/$dx_term_job/pid")
dx_term_child_pid=$(cat "$DX_SCRATCH/$dx_term_job/child_pid")
dx_term_stop=$(PATH="$DX_DIR/kill-bin:$PATH" \
    DX_KILL_LOG="$DX_DIR/kill.log" \
    "$AD" stop --job "$dx_term_job" --scratch-dir "$DX_SCRATCH" 2>/dev/null)
dx_term_rc=$?
dx_term_poll=$("$AD" poll --job "$dx_term_job" \
    --scratch-dir "$DX_SCRATCH")
dx_term_stop_again=$("$AD" stop --job "$dx_term_job" \
    --scratch-dir "$DX_SCRATCH")
dx_signal_order=$(awk -F'|' -v target="-$dx_term_child_pid" '
  $2 == target && $1 == "-TERM" && !term { printf "TERM "; term=1 }
  $2 == target && $1 == "-KILL" && term && !killed {
    printf "KILL"; killed=1
  }
' "$DX_DIR/kill.log")

# Completion wins the other ordering: later stop/poll calls must decode the
# immutable completed record rather than rewriting it as cancelled.
dx_complete_job=ad_dx_complete_1
dx_init_job "$dx_complete_job" omp "$dx_dead_pid" "$dx_dead_identity" \
    "$dx_dead_pid" "$dx_dead_identity"
printf 'completed body\n' > "$DX_SCRATCH/$dx_complete_job/out"
mkdir -p "$DX_SCRATCH/$dx_complete_job/terminal"
printf 'completed\n' > "$DX_SCRATCH/$dx_complete_job/terminal/state"
printf '0\n' > "$DX_SCRATCH/$dx_complete_job/terminal/exit_code"
printf '1\n' > "$DX_SCRATCH/$dx_complete_job/terminal/ready"
dx_complete_stop=$("$AD" stop --job "$dx_complete_job" \
    --scratch-dir "$DX_SCRATCH")
dx_complete_poll=$("$AD" poll --job "$dx_complete_job" \
    --scratch-dir "$DX_SCRATCH")

if [[ "$dx_term_rc" -eq 0 && "$dx_signal_order" == "TERM KILL" \
   && "$(cat "$DX_SCRATCH/$dx_term_job/terminal/state")" == "cancelled" ]] \
   && printf '%s' "$dx_term_stop" | jq -e --arg job "$dx_term_job" '
        keys == ["job_id", "status", "verdict"]
        and .job_id == $job and .verdict == "cancelled"
      ' >/dev/null \
   && printf '%s' "$dx_term_poll" | jq -e --arg job "$dx_term_job" '
        keys == ["job_id", "status", "verdict"]
        and .job_id == $job and .verdict == "cancelled"
      ' >/dev/null \
   && printf '%s' "$dx_term_stop_again" | jq -e --arg job "$dx_term_job" '
        keys == ["job_id", "status", "stop_noop", "verdict"]
        and .job_id == $job and .verdict == "cancelled"
        and .stop_noop == true
      ' >/dev/null \
   && printf '%s' "$dx_complete_stop" | jq -e --arg job "$dx_complete_job" '
        keys == ["job_id", "status", "stop_noop", "terminal_verdict", "verdict"]
        and .job_id == $job and .verdict == "already_finished"
        and .status == "completed" and .terminal_verdict == "completed"
        and .stop_noop == true
      ' >/dev/null \
   && printf '%s' "$dx_complete_poll" | jq -e '
        keys == ["raw_output", "status", "tokens", "verdict"]
        and .verdict == "completed" and .status == "completed"
        and .raw_output == "completed body\n"
      ' >/dev/null \
   && [[ "$(cat "$DX_SCRATCH/$dx_complete_job/terminal/state")" == "completed" ]]; then
    pass "DX-3 (F016/F055/F056): authenticated TERM→check→KILL→check and completion/cancel first-writer outcomes stay monotonic"
else
    fail "DX-3: cancellation sequence or terminal monotonicity failed" \
      "rc=$dx_term_rc signals=$dx_signal_order stop=$dx_term_stop poll=$dx_term_poll again=$dx_term_stop_again complete_stop=$dx_complete_stop complete_poll=$dx_complete_poll"
fi

# Completion-during-poll: the first wrapper-identity observation releases a
# real engine, then waits for its terminal commit before reporting liveness.
# The poller's initial terminal read has already missed; it must re-read after
# the wrapper observation rather than synthesize failure or lose output.
DX_RACE_DIR="$DX_DIR/completion-races"
DX_RACE_BIN="$DX_RACE_DIR/engine-bin"
mkdir -p "$DX_RACE_BIN" "$DX_RACE_DIR/ps-bin" "$DX_RACE_DIR/mkdir-bin"
cat > "$DX_RACE_BIN/omp" <<'EOF'
#!/usr/bin/env bash
while [[ ! -e "$DX_RACE_RELEASE" ]]; do
    /bin/sleep 0.01
done
printf '%s\n' "$DX_RACE_OUTPUT"
EOF
chmod +x "$DX_RACE_BIN/omp"

dx_poll_race_release="$DX_RACE_DIR/poll.release"
dx_poll_race_fired="$DX_RACE_DIR/poll.fired"
rm -f "$dx_poll_race_release" "$dx_poll_race_fired"
dx_poll_race_start=$(PATH="$DX_RACE_BIN:/usr/bin:/bin" \
    DX_RACE_RELEASE="$dx_poll_race_release" \
    DX_RACE_OUTPUT=poll-race-result \
    "$AD" start --engine omp --prompt-file "$DX_DIR/prompt.md" \
      --scratch-dir "$DX_SCRATCH")
dx_poll_race_job=$(printf '%s' "$dx_poll_race_start" | jq -r '.job_id')
dx_poll_race_dir="$DX_SCRATCH/$dx_poll_race_job"
dx_real_ps=$(PATH="/usr/bin:/bin" command -v ps)
cat > "$DX_RACE_DIR/ps-bin/ps" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"lstart="* && ! -e "$DX_POLL_RACE_FIRED" ]]; then
    : > "$DX_POLL_RACE_FIRED"
    : > "$DX_POLL_RACE_RELEASE"
    probe=0
    while [[ ! -f "$DX_POLL_RACE_JOB_DIR/terminal/ready" \
          && "$probe" -lt 500 ]]; do
        /bin/sleep 0.01
        probe=$((probe + 1))
    done
fi
exec "$DX_REAL_PS" "$@"
EOF
chmod +x "$DX_RACE_DIR/ps-bin/ps"
dx_poll_race_first=$(PATH="$DX_RACE_DIR/ps-bin:/usr/bin:/bin" \
    DX_POLL_RACE_FIRED="$dx_poll_race_fired" \
    DX_POLL_RACE_RELEASE="$dx_poll_race_release" \
    DX_POLL_RACE_JOB_DIR="$dx_poll_race_dir" DX_REAL_PS="$dx_real_ps" \
    "$AD" poll --job "$dx_poll_race_job" --scratch-dir "$DX_SCRATCH")
dx_poll_race_first_rc=$?
dx_poll_race_body_before=$(cat "$dx_poll_race_dir/out" 2>/dev/null || true)
dx_poll_race_second=$("$AD" poll --job "$dx_poll_race_job" \
    --scratch-dir "$DX_SCRATCH")
dx_poll_race_second_rc=$?
dx_poll_race_body_after=$(cat "$dx_poll_race_dir/out" 2>/dev/null || true)
if [[ "$dx_poll_race_first_rc" -eq 0 \
   && "$dx_poll_race_second_rc" -eq 0 \
   && -e "$dx_poll_race_fired" \
   && "$dx_poll_race_first" == "$dx_poll_race_second" \
   && "$dx_poll_race_body_before" == "$dx_poll_race_body_after" \
   && "$dx_poll_race_body_after" == "poll-race-result" \
   && "$(cat "$dx_poll_race_dir/terminal/state" 2>/dev/null)" == \
      "completed" ]] \
   && printf '%s' "$dx_poll_race_first" | jq -e '
        keys == ["raw_output", "status", "tokens", "verdict"]
        and .verdict == "completed" and .status == "completed"
        and .raw_output == "poll-race-result\n"
      ' >/dev/null; then
    pass "DX-3a (F055/F056): completion between poll terminal/liveness checks wins once with repeatable preserved output"
else
    "$AD" stop --job "$dx_poll_race_job" \
      --scratch-dir "$DX_SCRATCH" >/dev/null 2>&1 || true
    fail "DX-3a: completion-during-poll race was not monotonic" \
      "start=$dx_poll_race_start first=$dx_poll_race_first_rc:$dx_poll_race_first second=$dx_poll_race_second_rc:$dx_poll_race_second body=$dx_poll_race_body_before/$dx_poll_race_body_after"
fi

# Completion-during-stop: interpose only the cancellation claim's terminal
# mkdir. Releasing the engine before that mkdir executes lets the real
# completion writer win the exclusive directory claim. Stop must report
# already_finished, and subsequent polls must retain the exact output.
dx_stop_race_release="$DX_RACE_DIR/stop.release"
dx_stop_race_fired="$DX_RACE_DIR/stop.fired"
rm -f "$dx_stop_race_release" "$dx_stop_race_fired"
dx_stop_race_start=$(PATH="$DX_RACE_BIN:/usr/bin:/bin" \
    DX_RACE_RELEASE="$dx_stop_race_release" \
    DX_RACE_OUTPUT=stop-race-result \
    "$AD" start --engine omp --prompt-file "$DX_DIR/prompt.md" \
      --scratch-dir "$DX_SCRATCH")
dx_stop_race_job=$(printf '%s' "$dx_stop_race_start" | jq -r '.job_id')
dx_stop_race_dir="$DX_SCRATCH/$dx_stop_race_job"
dx_real_mkdir=$(PATH="/usr/bin:/bin" command -v mkdir)
cat > "$DX_RACE_DIR/mkdir-bin/mkdir" <<'EOF'
#!/usr/bin/env bash
last=""
for arg in "$@"; do last="$arg"; done
if [[ "$last" == "$DX_STOP_RACE_JOB_DIR/terminal" \
      && ! -e "$DX_STOP_RACE_FIRED" ]]; then
    : > "$DX_STOP_RACE_FIRED"
    : > "$DX_STOP_RACE_RELEASE"
    probe=0
    while [[ ! -f "$DX_STOP_RACE_JOB_DIR/terminal/ready" \
          && "$probe" -lt 500 ]]; do
        /bin/sleep 0.01
        probe=$((probe + 1))
    done
fi
exec "$DX_REAL_MKDIR" "$@"
EOF
chmod +x "$DX_RACE_DIR/mkdir-bin/mkdir"
dx_stop_race_out=$(PATH="$DX_RACE_DIR/mkdir-bin:/usr/bin:/bin" \
    DX_STOP_RACE_FIRED="$dx_stop_race_fired" \
    DX_STOP_RACE_RELEASE="$dx_stop_race_release" \
    DX_STOP_RACE_JOB_DIR="$dx_stop_race_dir" \
    DX_REAL_MKDIR="$dx_real_mkdir" \
    "$AD" stop --job "$dx_stop_race_job" --scratch-dir "$DX_SCRATCH" \
      2>/dev/null)
dx_stop_race_rc=$?
dx_stop_race_body_before=$(cat "$dx_stop_race_dir/out" 2>/dev/null || true)
dx_stop_race_poll_first=$("$AD" poll --job "$dx_stop_race_job" \
    --scratch-dir "$DX_SCRATCH")
dx_stop_race_poll_second=$("$AD" poll --job "$dx_stop_race_job" \
    --scratch-dir "$DX_SCRATCH")
dx_stop_race_body_after=$(cat "$dx_stop_race_dir/out" 2>/dev/null || true)
if [[ "$dx_stop_race_rc" -eq 0 && -e "$dx_stop_race_fired" \
   && "$dx_stop_race_poll_first" == "$dx_stop_race_poll_second" \
   && "$dx_stop_race_body_before" == "$dx_stop_race_body_after" \
   && "$dx_stop_race_body_after" == "stop-race-result" \
   && "$(cat "$dx_stop_race_dir/terminal/state" 2>/dev/null)" == \
      "completed" ]] \
   && printf '%s' "$dx_stop_race_out" | jq -e \
      --arg job "$dx_stop_race_job" '
        keys == ["job_id", "status", "stop_noop", "terminal_verdict", "verdict"]
        and .job_id == $job and .verdict == "already_finished"
        and .status == "completed" and .terminal_verdict == "completed"
        and .stop_noop == true
      ' >/dev/null \
   && printf '%s' "$dx_stop_race_poll_first" | jq -e '
        keys == ["raw_output", "status", "tokens", "verdict"]
        and .verdict == "completed" and .status == "completed"
        and .raw_output == "stop-race-result\n"
      ' >/dev/null; then
    pass "DX-3b (F055/F056): completion while stop claims terminal returns already_finished and preserves repeated poll output"
else
    "$AD" stop --job "$dx_stop_race_job" \
      --scratch-dir "$DX_SCRATCH" >/dev/null 2>&1 || true
    fail "DX-3b: completion-during-stop race was not monotonic" \
      "start=$dx_stop_race_start stop=$dx_stop_race_rc:$dx_stop_race_out poll1=$dx_stop_race_poll_first poll2=$dx_stop_race_poll_second body=$dx_stop_race_body_before/$dx_stop_race_body_after"
fi

# Thresholds are canonicalized before arithmetic and invalid/overflow values
# fail before job/companion access. Also black-box the companion poller's
# verdict-specific completed/alive/failed JSON surfaces.
dx_threshold_bad=""
dx_padded=$("$AD" poll --job ad_dx_missing_1 --scratch-dir "$DX_DIR/missing" \
    --stall-threshold-sec 0000000005 \
    --wall-clock-ceiling-sec 0000000010 2>&1)
dx_padded_rc=$?
dx_spaced=$("$AD" poll --job ad_dx_missing_1 --scratch-dir "$DX_DIR/missing" \
    --stall-threshold-sec " 5 " --wall-clock-ceiling-sec 10 2>&1)
dx_spaced_rc=$?
dx_overflow=$("$AD" poll --job ad_dx_missing_1 --scratch-dir "$DX_DIR/missing" \
    --stall-threshold-sec 5 \
    --wall-clock-ceiling-sec 9223372036854775808 2>&1)
dx_overflow_rc=$?
if [[ "$dx_padded_rc" -ne 1 || "$dx_padded" != *"no job dir"* \
   || "$dx_spaced_rc" -ne 64 || "$dx_spaced" == *"no job dir"* \
   || "$dx_overflow_rc" -ne 64 || "$dx_overflow" == *"no job dir"* ]]; then
    dx_threshold_bad="$dx_threshold_bad dispatcher=padded:$dx_padded_rc:$dx_padded spaced:$dx_spaced_rc:$dx_spaced overflow:$dx_overflow_rc:$dx_overflow"
fi

dx_cp_padded=$("$TOOLS/codex-poll.sh" --job missing \
    --companion "$DX_DIR/no-companion.mjs" \
    --stall-threshold-sec 0000000005 \
    --wall-clock-ceiling-sec 0000000010 2>&1)
dx_cp_padded_rc=$?
dx_cp_spaced=$("$TOOLS/codex-poll.sh" --job missing \
    --companion "$DX_DIR/no-companion.mjs" \
    --stall-threshold-sec " 5 " \
    --wall-clock-ceiling-sec 10 2>&1)
dx_cp_spaced_rc=$?
dx_cp_overflow=$("$TOOLS/codex-poll.sh" --job missing \
    --companion "$DX_DIR/no-companion.mjs" \
    --stall-threshold-sec 5 \
    --wall-clock-ceiling-sec 9223372036854775808 2>&1)
dx_cp_overflow_rc=$?
if [[ "$dx_cp_padded_rc" -ne 5 \
   || "$dx_cp_padded" != *"codex-companion not found"* \
   || "$dx_cp_spaced_rc" -ne 64 \
   || "$dx_cp_spaced" == *"codex-companion not found"* \
   || "$dx_cp_overflow_rc" -ne 64 \
   || "$dx_cp_overflow" == *"codex-companion not found"* ]]; then
    dx_threshold_bad="$dx_threshold_bad poller=padded:$dx_cp_padded_rc:$dx_cp_padded spaced:$dx_cp_spaced_rc:$dx_cp_spaced overflow:$dx_cp_overflow_rc:$dx_cp_overflow"
fi

mkdir -p "$DX_DIR/node-bin"
printf '// fixture\n' > "$DX_DIR/companion.mjs"
: > "$DX_DIR/companion.log"
cat > "$DX_DIR/node-bin/node" <<'EOF'
#!/usr/bin/env bash
sub="${2:-}"
if [[ "$sub" == "status" ]]; then
    case "$DX_NODE_MODE" in
        completed)
            printf '{"job":{"status":"completed","logFile":"%s"}}\n' "$DX_NODE_LOG"
            ;;
        running|stalled-agree|desync-result)
            printf '{"job":{"status":"running","logFile":"%s"}}\n' "$DX_NODE_LOG"
            ;;
        failed)
            printf '{"job":{"status":"failed","logFile":"%s"}}\n' "$DX_NODE_LOG"
            ;;
        desync-status)
            printf '%s\n' 'No job found for "opaque". Run /codex:status to list jobs.' >&2
            exit 1
            ;;
    esac
elif [[ "$sub" == "result" ]]; then
    case "$DX_NODE_MODE" in
        stalled-agree)
            printf '%s\n' 'resolveResultJob: job "opaque" is still running' >&2
            exit 1
            ;;
        desync-result)
            printf '%s\n' 'No finished job found for "opaque". Run /codex:status to inspect.' >&2
            exit 1
            ;;
        *)
            printf '{"storedJob":{"result":{"rawOutput":"companion result"}}}\n'
            ;;
    esac
else
    exit 64
fi
EOF
chmod +x "$DX_DIR/node-bin/node"
dx_cp_completed=$(PATH="$DX_DIR/node-bin:$PATH" \
    DX_NODE_MODE=completed DX_NODE_LOG="$DX_DIR/companion.log" \
    "$TOOLS/codex-poll.sh" --job opaque \
      --companion "$DX_DIR/companion.mjs" \
      --stall-threshold-sec 00090 --wall-clock-ceiling-sec 00600)
dx_cp_alive=$(PATH="$DX_DIR/node-bin:$PATH" \
    DX_NODE_MODE=running DX_NODE_LOG="$DX_DIR/companion.log" \
    "$TOOLS/codex-poll.sh" --job opaque \
      --companion "$DX_DIR/companion.mjs" \
      --stall-threshold-sec 00090 --wall-clock-ceiling-sec 00600)
dx_cp_failed=$(PATH="$DX_DIR/node-bin:$PATH" \
    DX_NODE_MODE=failed DX_NODE_LOG="$DX_DIR/companion.log" \
    "$TOOLS/codex-poll.sh" --job opaque \
      --companion "$DX_DIR/companion.mjs" \
      --stall-threshold-sec 00090 --wall-clock-ceiling-sec 00600)
if [[ -z "$dx_threshold_bad" ]] \
   && printf '%s' "$dx_cp_completed" | jq -e '
        keys == [
          "elapsed_sec", "log_file", "log_mtime_age_sec", "raw_output",
          "status", "verdict"
        ]
        and .status == "completed" and .verdict == "completed"
        and .raw_output == "companion result"
      ' >/dev/null \
   && printf '%s' "$dx_cp_alive" | jq -e '
        keys == [
          "elapsed_sec", "log_file", "log_mtime_age_sec", "status", "verdict"
        ]
        and .status == "running" and .verdict == "alive"
      ' >/dev/null \
   && printf '%s' "$dx_cp_failed" | jq -e '
        keys == [
          "elapsed_sec", "log_file", "log_mtime_age_sec", "status", "verdict"
        ]
        and .status == "failed" and .verdict == "failed_terminal"
      ' >/dev/null; then
    pass "DX-4 (F034/F057): dispatcher/poller canonicalize padded thresholds, reject overflow pre-access, and emit full verdict schemas"
else
    fail "DX-4: threshold ordering or companion verdict schema failed" \
      "thresholds=$dx_threshold_bad completed=$dx_cp_completed alive=$dx_cp_alive failed=$dx_cp_failed"
fi

# DX-4b (#7): the two-signal stall/desync fork, behaviorally. CR-13d
# source-greps the status-path fallback; these probes drive both result-
# path outcomes and the status-path desync end-to-end through the mode-
# aware companion stub above. The stale log is backdated past the 90s
# stall threshold; the stub's status JSON carries no startedAt, so the
# wall-clock ceiling stays out of the way and the mtime check is reached.
# A result failure whose stderr says the job is still running must stay
# stalled_suspect — only the "No (finished )?job found" store-miss
# confirms the desync.
: > "$DX_DIR/companion-stale.log"
touch -t 202001010000 "$DX_DIR/companion-stale.log"
dx_cp_stalled=$(PATH="$DX_DIR/node-bin:$PATH" \
    DX_NODE_MODE=stalled-agree DX_NODE_LOG="$DX_DIR/companion-stale.log" \
    "$TOOLS/codex-poll.sh" --job opaque \
      --companion "$DX_DIR/companion.mjs" \
      --stall-threshold-sec 90 --wall-clock-ceiling-sec 600)
dx_cp_stalled_rc=$?
dx_cp_desync_result=$(PATH="$DX_DIR/node-bin:$PATH" \
    DX_NODE_MODE=desync-result DX_NODE_LOG="$DX_DIR/companion-stale.log" \
    "$TOOLS/codex-poll.sh" --job opaque \
      --companion "$DX_DIR/companion.mjs" \
      --stall-threshold-sec 90 --wall-clock-ceiling-sec 600)
dx_cp_desync_result_rc=$?
dx_cp_desync_status=$(PATH="$DX_DIR/node-bin:$PATH" \
    DX_NODE_MODE=desync-status DX_NODE_LOG="$DX_DIR/companion-stale.log" \
    "$TOOLS/codex-poll.sh" --job opaque \
      --companion "$DX_DIR/companion.mjs" \
      --stall-threshold-sec 90 --wall-clock-ceiling-sec 600)
dx_cp_desync_status_rc=$?
if [[ "$dx_cp_stalled_rc" -eq 0 && "$dx_cp_desync_result_rc" -eq 0 \
   && "$dx_cp_desync_status_rc" -eq 0 ]] \
   && printf '%s' "$dx_cp_stalled" | jq -e '
        keys == [
          "elapsed_sec", "log_file", "log_mtime_age_sec", "status", "verdict"
        ]
        and .status == "running" and .verdict == "stalled_suspect"
        and .log_mtime_age_sec > 90 and .elapsed_sec == null
      ' >/dev/null \
   && printf '%s' "$dx_cp_desync_result" | jq -e '
        keys == [
          "elapsed_sec", "log_file", "log_mtime_age_sec", "status", "verdict"
        ]
        and .status == "running" and .verdict == "broker_desynced"
        and .log_mtime_age_sec > 90
      ' >/dev/null \
   && printf '%s' "$dx_cp_desync_status" | jq -e '
        keys == [
          "elapsed_sec", "log_file", "log_mtime_age_sec", "status", "verdict"
        ]
        and .status == "unknown" and .verdict == "broker_desynced"
        and .log_file == null and .log_mtime_age_sec == null
      ' >/dev/null; then
    pass "DX-4b (#7): still-running result failure stays stalled_suspect; store-miss on result or status path is broker_desynced"
else
    fail "DX-4b: two-signal fork misrouted" \
      "stalled=$dx_cp_stalled_rc:$dx_cp_stalled desync_result=$dx_cp_desync_result_rc:$dx_cp_desync_result desync_status=$dx_cp_desync_status_rc:$dx_cp_desync_status"
fi

# Standalone Codex must authenticate before creating job state or executing an
# engine. The authenticated control must execute exactly once and complete.
DX_AUTH="$DX_DIR/auth"
mkdir -p "$DX_AUTH/bin" "$DX_AUTH/scratch"
cat > "$DX_AUTH/bin/codex" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "login" && "${2:-}" == "status" ]]; then
    printf 'probe\n' >> "$DX_AUTH_STATE/auth.calls"
    [[ "$DX_AUTH_OK" == "true" ]]
    exit $?
fi
printf 'exec\n' >> "$DX_AUTH_STATE/exec.calls"
out=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        *) shift ;;
    esac
done
cat >/dev/null
printf '{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":2}}\n'
[[ -z "$out" ]] || printf 'authenticated result\n' > "$out"
EOF
chmod +x "$DX_AUTH/bin/codex"
: > "$DX_AUTH/auth.calls"
: > "$DX_AUTH/exec.calls"
printf 'auth prompt\n' > "$DX_AUTH/prompt.md"
dx_unauth_out=$(PATH="$DX_AUTH/bin:$PATH" \
    DX_AUTH_STATE="$DX_AUTH" DX_AUTH_OK=false \
    "$AD" start --engine codex --prompt-file "$DX_AUTH/prompt.md" \
      --scratch-dir "$DX_AUTH/scratch" 2>&1)
dx_unauth_rc=$?
dx_unauth_state_count=$(
  shopt -s nullglob
  dx_unauth_dirs=("$DX_AUTH/scratch"/ad_*)
  printf '%s' "${#dx_unauth_dirs[@]}"
)
dx_unauth_exec_count=$(wc -l < "$DX_AUTH/exec.calls" | tr -d '[:space:]')
dx_auth_start=$(PATH="$DX_AUTH/bin:$PATH" \
    DX_AUTH_STATE="$DX_AUTH" DX_AUTH_OK=true \
    "$AD" start --engine codex --prompt-file "$DX_AUTH/prompt.md" \
      --scratch-dir "$DX_AUTH/scratch")
dx_auth_rc=$?
dx_auth_job=$(printf '%s' "$dx_auth_start" | jq -r '.job_id // empty')
dx_auth_poll=""
dx_auth_wait=0
while [[ "$dx_auth_wait" -lt 60 ]]; do
    dx_auth_poll=$("$AD" poll --job "$dx_auth_job" \
        --scratch-dir "$DX_AUTH/scratch" 2>/dev/null)
    [[ "$(printf '%s' "$dx_auth_poll" | jq -r '.verdict // empty')" == \
       "completed" ]] && break
    sleep 0.05
    dx_auth_wait=$((dx_auth_wait + 1))
done
dx_auth_exec_count=$(wc -l < "$DX_AUTH/exec.calls" | tr -d '[:space:]')
if [[ "$dx_unauth_rc" -eq 5 && "$dx_unauth_out" == *"not authenticated"* \
   && "$dx_unauth_state_count" == "0" && "$dx_unauth_exec_count" == "0" \
   && "$dx_auth_rc" -eq 0 && -n "$dx_auth_job" \
   && "$dx_auth_exec_count" == "1" \
   && "$(printf '%s' "$dx_auth_poll" | jq -r '.raw_output')" == \
      "authenticated result" ]] \
   && grep -qF 'Bash(codex login status)' "$REPO/commands/codex-review.md" \
   && grep -qF '`max` and `ultra` require the authenticated standalone Codex transport.' \
      "$REPO/commands/codex-review.md"; then
    pass "DX-5 (F030/F056): unauthenticated Codex has zero exec/state; auth control completes; command grants/describes auth-only max/ultra"
else
    fail "DX-5: standalone authentication gate or command contract failed" \
      "unauth=$dx_unauth_rc:$dx_unauth_out state=$dx_unauth_state_count unauth_exec=$dx_unauth_exec_count auth=$dx_auth_rc:$dx_auth_start exec=$dx_auth_exec_count poll=$dx_auth_poll"
fi

# Execute the exact Phase 4a/4b/5 stop handlers. Valid already_finished must
# re-poll the matching job and replace stale output/tokens; malformed,
# mismatched, or verdict/exit-incoherent stop schemas must abort.
cat > "$DX_DIR/extract-stop-handlers.py" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
destination = Path(sys.argv[2])
specs = [
    ("fragments/05-codex-validation.md", "phase_4a_codex_watchdog:",
     "phase4a.sh",
     'printf "%s|%s|%s\\n" "$verdict" "$codex_output" "$codex_tokens"'),
    ("fragments/05-codex-validation.md", "phase_4b_codex_watchdog:",
     "phase4b.sh",
     'printf "%s|%s|%s\\n" "$verdict" "$codex_chunk_output" "$codex_chunk_tokens"'),
    ("fragments/06-codex-cross-cutting.md", "phase_5_codex_watchdog:",
     "phase5.sh",
     'printf "%s|%s|%s\\n" "$verdict" "$xc_codex_output" "$xc_codex_tokens"'),
]
for relative, needle, name, trailer in specs:
    text = (root / relative).read_text(encoding="utf-8")
    anchor = text.index(needle)
    start = text.rfind("```bash\n", 0, anchor) + len("```bash\n")
    end = text.index("\n```", anchor)
    (destination / name).write_text(
        text[start:end] + "\n" + trailer + "\n",
        encoding="utf-8",
    )
PY
dx_extract_out=$(python3 "$DX_DIR/extract-stop-handlers.py" \
    "$REPO" "$DX_DIR" 2>&1)
dx_extract_rc=$?
mkdir -p "$DX_DIR/caller-bin" "$DX_DIR/caller-scratch"
cat > "$DX_DIR/caller-bin/agent-dispatch.sh" <<'EOF'
#!/usr/bin/env bash
sub="$1"
shift
job=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --job) job="$2"; shift 2 ;;
        *) shift ;;
    esac
done
printf '%s:%s\n' "$sub" "$job" >> "$DX_CALLS"
if [[ "$sub" == "poll" ]]; then
    printf '{"verdict":"completed","status":"completed","raw_output":"rematerialized-%s","tokens":42}\n' "$job"
    exit 0
fi
case "$DX_STOP_MODE" in
    already)
        jq -nc --arg job "$job" \
          '{verdict:"already_finished",status:"completed",
            terminal_verdict:"completed",job_id:$job,stop_noop:true}'
        ;;
    cancelled)
        jq -nc --arg job "$job" \
          '{verdict:"cancelled",status:"cancelled",job_id:$job}'
        ;;
    stop-failed)
        jq -nc --arg job "$job" \
          '{verdict:"stop_failed",status:"stop_failed",job_id:$job,
            reason:"still alive",wrapper_alive:true,engine_alive:false,
            wrapper_state:"alive",engine_state:"gone"}'
        exit 9
        ;;
    stop-failed-zero)
        jq -nc --arg job "$job" \
          '{verdict:"stop_failed",status:"stop_failed",job_id:$job,
            reason:"still alive",wrapper_alive:true,engine_alive:false}'
        ;;
    mismatch)
        jq -nc \
          '{verdict:"cancelled",status:"cancelled",job_id:"wrong-job"}'
        ;;
    invalid-already)
        jq -nc --arg job "$job" \
          '{verdict:"already_finished",status:"completed",
            terminal_verdict:"failed_terminal",job_id:$job,stop_noop:true}'
        ;;
    partial-stop-failed)
        jq -nc --arg job "$job" \
          '{verdict:"stop_failed",status:"stop_failed",job_id:$job}'
        exit 9
        ;;
    duplicate)
        jq -nc --arg job "$job" \
          '{verdict:"cancelled",status:"cancelled",job_id:$job}'
        jq -nc --arg job "$job" \
          '{verdict:"cancelled",status:"cancelled",job_id:$job}'
        ;;
esac
EOF
chmod +x "$DX_DIR/caller-bin/agent-dispatch.sh"

dx_run_handler() {
    local script="$1" job_var="$2" job="$3" extra_name="$4" extra_value="$5"
    local calls="$DX_DIR/$script.calls" trace="$DX_DIR/$script.trace"
    : > "$calls"
    : > "$trace"
    env \
      DX_CALLS="$calls" DX_STOP_MODE=already \
      MRB="$DX_DIR/caller-bin/" \
      codex_launch_mode=agent-dispatch \
      codex_dispatch_scratch="$DX_DIR/caller-scratch" \
      ceiling=600 \
      poll='{"verdict":"wall_clock_exceeded","status":"running"}' \
      verdict=wall_clock_exceeded \
      codex_output=stale codex_tokens=stale \
      codex_chunk_output=stale codex_chunk_tokens=stale \
      xc_codex_output=stale xc_codex_tokens=stale \
      trace_log_path="$trace" \
      "$job_var=$job" "$extra_name=$extra_value" \
      /bin/bash "$DX_DIR/$script"
}
dx_p4a=$(dx_run_handler phase4a.sh job_id ad_dx_p4a finding_id F001 2>&1)
dx_p4a_rc=$?
dx_p4b=$(dx_run_handler phase4b.sh job_id ad_dx_p4b chunk_n 3 2>&1)
dx_p4b_rc=$?
dx_p5=$(dx_run_handler phase5.sh xc_job_id ad_dx_p5 unused unused 2>&1)
dx_p5_rc=$?
dx_remat_bad=""
for dx_remat_case in \
    "phase4a.sh:$dx_p4a_rc:$dx_p4a:ad_dx_p4a" \
    "phase4b.sh:$dx_p4b_rc:$dx_p4b:ad_dx_p4b" \
    "phase5.sh:$dx_p5_rc:$dx_p5:ad_dx_p5"; do
    dx_remat_name=${dx_remat_case%%:*}
    dx_remat_rest=${dx_remat_case#*:}
    dx_remat_code=${dx_remat_rest%%:*}
    dx_remat_rest=${dx_remat_rest#*:}
    dx_remat_output=${dx_remat_rest%:*}
    dx_remat_job=${dx_remat_rest##*:}
    dx_remat_calls=$(cat "$DX_DIR/$dx_remat_name.calls")
    if [[ "$dx_remat_code" -ne 0 \
       || "$dx_remat_output" != \
          "completed|rematerialized-$dx_remat_job|42" \
       || "$dx_remat_calls" != \
          $'stop:'"$dx_remat_job"$'\n''poll:'"$dx_remat_job" ]]; then
        dx_remat_bad="$dx_remat_bad $dx_remat_name=$dx_remat_code:$dx_remat_output:$dx_remat_calls"
    fi
done

dx_schema_bad=""
dx_schema_case() {
    local mode="$1" expected="$2" marker="$3"
    local calls="$DX_DIR/schema-$mode.calls"
    local trace="$DX_DIR/schema-$mode.trace"
    local output code
    : > "$calls"
    : > "$trace"
    output=$(env \
      DX_CALLS="$calls" DX_STOP_MODE="$mode" \
      MRB="$DX_DIR/caller-bin/" codex_launch_mode=agent-dispatch \
      codex_dispatch_scratch="$DX_DIR/caller-scratch" ceiling=600 \
      poll='{"verdict":"wall_clock_exceeded","status":"running"}' \
      verdict=wall_clock_exceeded codex_output=stale codex_tokens=stale \
      trace_log_path="$trace" job_id=ad_dx_schema finding_id=F001 \
      /bin/bash "$DX_DIR/phase4a.sh" 2>&1)
    code=$?
    if [[ "$code" -ne "$expected" || "$output" != *"$marker"* ]]; then
        dx_schema_bad="$dx_schema_bad $mode=$code:$output"
    fi
}
dx_schema_case cancelled 0 'wall_clock_exceeded|stale|stale'
dx_schema_case stop-failed 1 'cancellation could not be verified'
dx_schema_case stop-failed-zero 1 'exited 0 with verdict stop_failed'
dx_schema_case mismatch 1 'malformed, partial, or mismatched'
dx_schema_case invalid-already 1 'malformed, partial, or mismatched'
dx_schema_case partial-stop-failed 1 'malformed, partial, or mismatched'
dx_schema_case duplicate 1 'malformed, partial, or mismatched'

if [[ "$dx_extract_rc" -eq 0 && -z "$dx_remat_bad" \
   && -z "$dx_schema_bad" ]]; then
    pass "DX-6 (F041/F055/F057): Phase 4a/4b/5 enforce matching verdict schemas and already_finished re-poll rematerializes output/tokens"
else
    fail "DX-6: standalone caller schema/rematerialization contract failed" \
      "extract=$dx_extract_rc:$dx_extract_out remat=$dx_remat_bad schema=$dx_schema_bad"
fi

echo
echo "smoke: PASS ($N assertions)"
exit 0
