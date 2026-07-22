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
#   config     user/repo config syntax and semantic schema
#   stale      pre-rename remnants: ~/.adams-reviews, ADAMS_REVIEW_* env,
#              adamsreview@adamsreview in Claude settings, cache-path allowlists
#
# Usage:
#   doctor.sh            full report, exit 0 (warnings are informational)
#   doctor.sh --quiet    only print WARN/FAIL lines (SessionStart hook mode)
#
# Exit codes (bin/_common.py conventions):
#   0   all checks pass or warn only
#   5   missing required dependency or invalid configuration
#   64  usage error
set -u

usage() {
    echo "Usage: doctor.sh [--quiet]" >&2
}
if [[ $# -gt 1 || ( $# -eq 1 && "${1:-}" != "--quiet" && "${1:-}" != "-h" && "${1:-}" != "--help" ) ]]; then
    echo "ERROR: unsupported doctor.sh arguments: $*" >&2
    usage
    echo "Action: run doctor.sh with no arguments, or pass only --quiet." >&2
    exit 64
fi
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi
QUIET=0
[[ "${1:-}" == "--quiet" ]] && QUIET=1
THIS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

had_fail=0

say() { # level message
    local level="$1" msg="$2"
    if [[ "$QUIET" == "1" && "$level" != "WARN" && "$level" != "FAIL" ]]; then return; fi
    printf '%-4s %s\n' "$level" "$msg"
}
fix() { printf '      fix: %s\n' "$1"; }

REVIEWS_ROOT=$("$THIS/review-root.sh" 2>/dev/null)
review_root_rc=$?
if [[ "$review_root_rc" -ne 0 || -z "$REVIEWS_ROOT" ]]; then
    say FAIL "config: could not resolve a non-empty reviews root"
    fix "set MATTHEWS_REVIEW_REVIEWS_ROOT to a one-line absolute path"
    echo "ERROR: doctor found a required configuration failure." >&2
    echo "Action: apply the FAIL/fix guidance above, then rerun doctor.sh." >&2
    exit 5
fi

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
bash_major="${BASH_VERSINFO[0]:-0}"
bash_minor="${BASH_VERSINFO[1]:-0}"
bash_ver="$bash_major.$bash_minor"
if [[ "$bash_major" -gt 3 || ( "$bash_major" -eq 3 && "$bash_minor" -ge 2 ) ]]; then
    say PASS "dep: bash $bash_ver (3.2-portable helpers OK)"
else
    say FAIL "dep: bash $bash_ver too old (need >= 3.2)"
    fix "use a newer bash"
    had_fail=1
fi

# --- harnesses ------------------------------------------------------------
found_harness=0
missing_harnesses=""
for h in claude codex omp; do
    if command -v "$h" >/dev/null 2>&1; then
        say PASS "harness: $h found"
        found_harness=1
    else
        missing_harnesses="${missing_harnesses}${missing_harnesses:+, }$h"
    fi
done
if [[ "$found_harness" == "0" ]]; then
    say WARN "harness: no claude/codex/omp CLI found — matthewsreview needs at least one"
    fix "install Claude Code, Codex CLI, or Oh My Pi"
elif [[ -n "$missing_harnesses" ]]; then
    say INFO "optional harnesses not installed: $missing_harnesses"
fi

# --- model availability (per harness) --------------------------------------
# A role whose model the active harness can't serve fails at dispatch time,
# deep into a run. Resolve the plan, then compare every omp-native selector
# with the live registry rather than treating syntactic validity as
# availability.
if command -v omp >/dev/null 2>&1; then
    plan_rc=0
    plan_json=$("$THIS/review-config.sh" --repo-root "$REPO_ROOT" --repo-config-worktree --orchestrator omp 2>/dev/null) \
        || plan_rc=$?
    if [[ "$plan_rc" -ne 0 ]]; then
        say FAIL "models: could not resolve the configured model plan"
        fix "run $THIS/review-config.sh --repo-root \"$REPO_ROOT\" --repo-config-worktree --orchestrator omp"
        had_fail=1
    elif [[ -n "$plan_json" ]]; then
        model_warning=0
        plan_warn=$(printf '%s' "$plan_json" | jq -r '.warnings[0] // empty')
        if [[ -n "$plan_warn" ]]; then
            say WARN "models: $plan_warn"
            fix "set orchestrator_defaults.omp.tiers in ~/.matthews-reviews/config.json"
            model_warning=1
        fi

        omp_registry=$(omp models --json 2>/dev/null)
        registry_rc=$?
        if [[ "$registry_rc" -ne 0 ]] \
           || ! printf '%s' "$omp_registry" | jq -e '.models | type == "array"' >/dev/null 2>&1; then
            say WARN "models: could not read the live omp model registry"
            fix "run 'omp models --json' and repair omp provider/model configuration"
            model_warning=1
        else
            required_omp_models=$(printf '%s' "$plan_json" | jq -r '
              .roles | to_entries[]
              | select(.value.engine == "omp")
              | .value.model' | sort -u)
            missing_omp_models=""
            if [[ -n "$required_omp_models" ]]; then
                while IFS= read -r model; do
                    [[ -n "$model" ]] || continue
                    if ! printf '%s' "$omp_registry" \
                        | jq -e --arg model "$model" \
                            '.models | any(.selector == $model)' >/dev/null 2>&1; then
                        if [[ -n "$missing_omp_models" ]]; then
                            missing_omp_models="$missing_omp_models, $model"
                        else
                            missing_omp_models="$model"
                        fi
                    fi
                done <<EOF
$required_omp_models
EOF
            fi
            if [[ -n "$missing_omp_models" ]]; then
                say WARN "models: omp selector(s) $missing_omp_models not present in \`omp models\`"
                fix "choose installed selectors from 'omp models', or configure the missing provider"
                model_warning=1
            fi
        fi

        if [[ "$model_warning" == "0" ]]; then
            say PASS "models: resolved omp roles exist in the live registry"
        fi
    fi
fi

# --- config ---------------------------------------------------------------
config_seen=0
config_syntax_ok=1
for cfg in "$REVIEWS_ROOT/config.json" "$REPO_ROOT/.matthewsreview.json"; do
    if [[ -e "$cfg" || -L "$cfg" ]]; then
        config_seen=1
        if [[ ! -f "$cfg" || ! -r "$cfg" ]]; then
            say FAIL "config: $cfg is not a readable regular file"
            fix "replace $cfg with a readable JSON configuration file"
            had_fail=1
            config_syntax_ok=0
        elif jq empty "$cfg" 2>/dev/null; then
            say PASS "config: $cfg parses"
        else
            say FAIL "config: $cfg is not valid JSON"
            fix "jq . $cfg   # locate the syntax error"
            had_fail=1
            config_syntax_ok=0
        fi
    fi
done
if [[ "$config_seen" == "1" && "$config_syntax_ok" == "1" ]]; then
    config_rc=0
    config_error=$("$THIS/review-config.sh" \
        --repo-root "$REPO_ROOT" --repo-config-worktree --orchestrator omp 2>&1 >/dev/null) \
        || config_rc=$?
    if [[ "$config_rc" == "0" ]]; then
        say PASS "config: semantic schema valid"
    else
        say FAIL "config: semantic validation failed — $(printf '%s' "$config_error" | head -1)"
        config_action=$(printf '%s\n' "$config_error" | grep '^Action:' | head -1 | sed 's/^Action: //')
        fix "${config_action:-run $THIS/review-config.sh --repo-root \"$REPO_ROOT\" --repo-config-worktree --orchestrator omp}"
        had_fail=1
    fi
fi

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
for settings in "$HOME/.claude/settings.json" "$REPO_ROOT/.claude/settings.json"; do
    if [[ -f "$settings" ]] && grep -q 'adamsreview@adamsreview' "$settings"; then
        say WARN "stale: $settings enables adamsreview@adamsreview"
        fix "replace with matthewsreview@matthewsreview in $settings"
    fi
done
for local_settings in "$HOME/.claude/settings.local.json" "$REPO_ROOT/.claude/settings.local.json"; do
    if [[ -f "$local_settings" ]] && grep -q 'plugins/cache/adamsreview' "$local_settings"; then
        say WARN "stale: $local_settings allowlists a versioned adamsreview cache path"
        fix "remove the plugins/cache/adamsreview/.../bin PATH line from $local_settings"
    fi
done

if [[ "$had_fail" == "1" ]]; then
    echo "ERROR: doctor found one or more required dependency or configuration failures." >&2
    echo "Action: apply each FAIL/fix item above, then rerun doctor.sh." >&2
    exit 5
fi
exit 0
