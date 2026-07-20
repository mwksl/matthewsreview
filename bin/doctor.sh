#!/usr/bin/env bash
# doctor.sh — matthewsreview environment diagnostic.
#
# Prints one PASS / WARN / FAIL line per check plus the exact fix for
# anything not PASS. Run after install, after upgrades, or when a
# command misbehaves and you suspect the environment.
#
# Checks:
#   deps       uv, jq, gh, git, bash >= 3.2
#   harnesses  claude / codex / omp CLIs (informational — any one is enough)
#   config     ~/.matthews-reviews/config.json and ./.matthewsreview.json parse
#   stale      pre-rename remnants: ~/.adams-reviews, ADAMS_REVIEW_* env,
#              adamsreview@adamsreview in Claude settings, cache-path allowlists
#
# Usage:
#   doctor.sh            full report, exit 0 (warnings are informational)
#   doctor.sh --quiet    only print WARN/FAIL lines (SessionStart hook mode)
#
# Exit codes (bin/_common.py conventions):
#   0  all checks pass or warn only
#   5  missing required dependency
set -u

QUIET=0
[[ "${1:-}" == "--quiet" ]] && QUIET=1

had_fail=0

say() { # level message
    local level="$1" msg="$2"
    if [[ "$QUIET" == "1" && "$level" == "PASS" ]]; then return; fi
    printf '%-4s %s\n' "$level" "$msg"
}
fix() { printf '      fix: %s\n' "$1"; }

# --- deps -----------------------------------------------------------------
for tool in uv jq gh git; do
    if command -v "$tool" >/dev/null 2>&1; then
        say PASS "dep: $tool found ($(command -v "$tool"))"
    else
        say FAIL "dep: $tool missing"
        case "$(uname -s)" in
            Darwin) fix "brew install $tool" ;;
            *)      fix "install $tool via your package manager" ;;
        esac
        had_fail=1
    fi
done
bash_ver="${BASH_VERSINFO[0]:-0}.${BASH_VERSINFO[1]:-0}"
if [[ "${BASH_VERSINFO[0]:-0}" -ge 3 ]]; then
    say PASS "dep: bash $bash_ver (3.2-portable helpers OK)"
else
    say FAIL "dep: bash $bash_ver too old (need >= 3.2)"
    fix "use a newer bash"
    had_fail=1
fi

# --- harnesses ------------------------------------------------------------
found_harness=0
for h in claude codex omp; do
    if command -v "$h" >/dev/null 2>&1; then
        say PASS "harness: $h found"
        found_harness=1
    else
        say WARN "harness: $h not on PATH"
    fi
done
if [[ "$found_harness" == "0" ]]; then
    say WARN "harness: no claude/codex/omp CLI found — matthewsreview needs at least one"
    fix "install Claude Code, Codex CLI, or Oh My Pi"
fi

# --- model availability (per harness) --------------------------------------
# A role whose model the active harness can't serve fails at dispatch time,
# deep into a run. Probe resolvability upfront for the default tier models.
if command -v omp >/dev/null 2>&1 && command -v review-config.sh >/dev/null 2>&1; then
    plan_json=$(review-config.sh --repo-root "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" --orchestrator omp 2>/dev/null || true)
    if [[ -n "$plan_json" ]]; then
        plan_warn=$(printf '%s' "$plan_json" | jq -r '.warnings[0] // empty')
        if [[ -n "$plan_warn" ]]; then
            say WARN "models: $plan_warn"
            fix "set orchestrator_defaults.omp.tiers in ~/.matthews-reviews/config.json"
        else
            say PASS "models: default roles resolve for omp orchestrator"
        fi
    fi
fi

# --- config ---------------------------------------------------------------
for cfg in "$HOME/.matthews-reviews/config.json" ".matthewsreview.json"; do
    if [[ -f "$cfg" ]]; then
        if jq empty "$cfg" 2>/dev/null; then
            say PASS "config: $cfg parses"
        else
            say FAIL "config: $cfg is not valid JSON"
            fix "jq . $cfg   # locate the syntax error"
            had_fail=1
        fi
    fi
done

# --- stale pre-rename remnants --------------------------------------------
if [[ -d "$HOME/.adams-reviews" && ! -d "$HOME/.matthews-reviews" ]]; then
    say WARN "stale: ~/.adams-reviews still present (state falls back with a migrate nudge)"
    fix "mv ~/.adams-reviews ~/.matthews-reviews"
fi
legacy_env="$(env | grep '^ADAMS_REVIEW_' || true)"
if [[ -n "$legacy_env" ]]; then
    say WARN "stale: pre-rename env var(s) set: $(printf '%s' "$legacy_env" | cut -d= -f1 | tr '\n' ' ')"
    fix "rename ADAMS_REVIEW_* exports to MATTHEWS_REVIEW_* in your shell rc"
fi
for settings in "$HOME/.claude/settings.json" ".claude/settings.json"; do
    if [[ -f "$settings" ]] && grep -q 'adamsreview@adamsreview' "$settings"; then
        say WARN "stale: $settings enables adamsreview@adamsreview"
        fix "replace with matthewsreview@matthewsreview in $settings"
    fi
done
for local_settings in "$HOME/.claude/settings.local.json" ".claude/settings.local.json"; do
    if [[ -f "$local_settings" ]] && grep -q 'plugins/cache/adamsreview' "$local_settings"; then
        say WARN "stale: $local_settings allowlists a versioned adamsreview cache path"
        fix "remove the plugins/cache/adamsreview/.../bin PATH line from $local_settings"
    fi
done

if [[ "$had_fail" == "1" ]]; then exit 5; fi
exit 0
