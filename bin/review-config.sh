#!/usr/bin/env bash
# review-config.sh — resolve the per-role model plan + gate thresholds.
#
# Merge order (later wins):
#   built-in defaults
#   ~/.matthews-reviews/config.json      (user config; legacy ~/.adams-reviews fallback)
#   <repo>/.matthewsreview.json          (repo config)
#   profiles.<name> (repo config first, then user config)   [--profile]
#   --models "<k=v,k=v>"                 (CLI; keys = tier name or role name)
#
# Role strings: engine:model[:effort]
#   engines: claude | codex | omp
#   effort:  low|medium|high|xhigh|max|ultra — CODEX ONLY. Present on
#            claude:/omp: values → exit 1.
#   codex: may carry an empty model ("codex::high") = CLI default model.
#
# Engine support matrix (per --orchestrator):
#   claude-code: claude:* native (Task model param), codex:* subprocess,
#                omp:* REJECTED
#   omp:         claude:* native (eval bridge), codex:* subprocess,
#                omp:* native
#   codex:       claude:* subprocess, codex:* subprocess,
#                omp:* subprocess (requires omp CLI on PATH)
#
# Usage:
#   review-config.sh --repo-root <abs> --orchestrator <claude-code|omp|codex> \
#                    [--profile <name>] [--models "<k=v,k=v>"]
#
# Output (stdout): one JSON object
#   {orchestrator, roles: {<role>: {engine, model, effort, source}},
#    gates: {...}, warnings: []}
#
# Exit codes (bin/_common.py conventions): 0 OK, 1 validation, 64 usage.
set -u

PROG=review-config.sh

err() { # msg
    echo "ERROR: $1" >&2
}
die_usage() {
    err "$1"
    echo "Valid input: $PROG --repo-root <abs> --orchestrator <claude-code|omp|codex> [--profile <name>] [--models \"<k=v,k=v>\"]" >&2
    exit 64
}
die_validation() { # msg action
    err "$1"
    [[ -n "${2:-}" ]] && echo "Action: $2" >&2
    exit 1
}

REPO_ROOT=""
ORCHESTRATOR=""
PROFILE=""
MODELS_CSV=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo-root)    REPO_ROOT="${2:-}"; shift 2 ;;
        --orchestrator) ORCHESTRATOR="${2:-}"; shift 2 ;;
        --profile)      PROFILE="${2:-}"; shift 2 ;;
        --models)       MODELS_CSV="${2:-}"; shift 2 ;;
        *) die_usage "unknown argument: $1" ;;
    esac
done

[[ -n "$REPO_ROOT" && -d "$REPO_ROOT" ]] || die_usage "--repo-root must be an existing directory"
case "$ORCHESTRATOR" in
    claude-code|omp|codex) ;;
    *) die_usage "--orchestrator must be one of: claude-code | omp | codex" ;;
esac

# ---------------------------------------------------------------- defaults
# Canonical role set. Tiers: deep / light / utility. Explicit (tier-less)
# roles are the codex-engine lanes.
TIERS_DEFAULT='{"deep":"claude:opus","light":"claude:sonnet","utility":"claude:sonnet"}'
ROLE_TIER_MAP='{
  "deep_lens":"deep","deep_validate":"deep","cross_cutting":"deep",
  "fix":"deep","post_fix_review":"deep","reconcile":"deep",
  "light_lens":"light","light_validate":"light",
  "classifier":"utility","normalizer":"utility","dedup":"utility",
  "scoring":"utility","fix_hint":"utility","briefer":"utility","drafter":"utility"
}'
ROLES_EXPLICIT='{"ensemble_detect":"codex::high","codex_detect":"codex::high","codex_validate":"codex::high","codex_crosscut":"codex::high"}'
GATES_DEFAULT='{"phase3_gate":45,"phase4_bands":[45,60,75],"fix_threshold":60,"walkthrough_threshold":60}'
EFFORT_SET=' low medium high xhigh max ultra '

# ---------------------------------------------------------------- load files
USER_CFG=""
if [[ -f "$HOME/.matthews-reviews/config.json" ]]; then
    USER_CFG="$HOME/.matthews-reviews/config.json"
elif [[ -f "$HOME/.adams-reviews/config.json" ]]; then
    USER_CFG="$HOME/.adams-reviews/config.json"
    LEGACY_WARN="legacy config path ~/.adams-reviews/config.json in use; run: mv ~/.adams-reviews ~/.matthews-reviews"
fi
REPO_CFG="$REPO_ROOT/.matthewsreview.json"
[[ -f "$REPO_CFG" ]] || REPO_CFG=""

for f in "$USER_CFG" "$REPO_CFG"; do
    if [[ -n "$f" ]] && ! jq empty "$f" 2>/dev/null; then
        die_validation "config file $f is not valid JSON" "jq . $f   # locate the syntax error"
    fi
done

cfg_get() { # file expr  — empty string when file missing or key absent
    local f="$1" expr="$2"
    [[ -n "$f" ]] || { echo ""; return; }
    jq -r "$expr // empty" "$f" 2>/dev/null
}

# ---------------------------------------------------------------- merge
# assoc-free (bash 3.2): tiers/roles kept as newline "key|value|source" lists.
TIER_LIST=""   # deep|claude:opus|default
ROLE_LIST=""   # deep_validate|claude:sonnet|repo-config (empty = inherit tier)
GATES_JSON="$GATES_DEFAULT"

set_kv() { # listname key value source
    local listname="$1" key="$2" value="$3" source="$4"
    local cur="" line updated=0 out=""
    cur=$(eval "printf '%s' \"\$$listname\"")
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if [[ "${line%%|*}" == "$key" ]]; then
            out="$out$key|$value|$source"$'\n'; updated=1
        else
            out="$out$line"$'\n'
        fi
    done <<< "$cur"
    if [[ "$updated" == "0" ]]; then out="$out$key|$value|$source"$'\n'; fi
    eval "$listname=\"\$out\""
}

get_kv() { # listname key -> "value|source" or empty
    local listname="$1" key="$2" cur line
    cur=$(eval "printf '%s' \"\$$listname\"")
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if [[ "${line%%|*}" == "$key" ]]; then printf '%s' "${line#*|}"; return; fi
    done <<< "$cur"
}

# seed defaults
for t in deep light utility; do
    set_kv TIER_LIST "$t" "$(jq -r --arg k "$t" '.[$k]' <<<"$TIERS_DEFAULT")" "default"
done

apply_file() { # file source
    local f="$1" source="$2"
    [[ -n "$f" ]] || return 0
    local tiers roles
    tiers=$(jq -c '.tiers // empty' "$f")
    if [[ -n "$tiers" ]]; then
        local k
        for k in deep light utility; do
            local v
            v=$(jq -r --arg k "$k" '.[$k] // empty' <<<"$tiers")
            [[ -n "$v" ]] && set_kv TIER_LIST "$k" "$v" "$source"
        done
        # unknown tier keys → hard error
        local bad
        bad=$(jq -r 'keys[] | select(. != "deep" and . != "light" and . != "utility")' <<<"$tiers" | head -1)
        [[ -n "$bad" ]] && die_validation "unknown tier '$bad' in $f" "Valid values: deep | light | utility"
    fi
    roles=$(jq -c '.roles // empty' "$f")
    if [[ -n "$roles" ]]; then
        local rkeys
        rkeys=$(jq -r 'keys[]' <<<"$roles")
        while IFS= read -r rk; do
            [[ -z "$rk" ]] && continue
            if ! jq -e --arg k "$rk" 'has($k)' <<<"$ROLE_TIER_MAP" >/dev/null \
               && ! jq -e --arg k "$rk" 'has($k)' <<<"$ROLES_EXPLICIT" >/dev/null; then
                die_validation "unknown role '$rk' in $f" "Valid roles: $(jq -r 'keys[]' <<<"$ROLE_TIER_MAP" | tr '\n' ' ')$(jq -r 'keys[]' <<<"$ROLES_EXPLICIT" | tr '\n' ' ')"
            fi
            set_kv ROLE_LIST "$rk" "$(jq -r --arg k "$rk" '.[$k]' <<<"$roles")" "$source"
        done <<< "$rkeys"
    fi
    local gates
    gates=$(jq -c '.gates // empty' "$f")
    if [[ -n "$gates" ]]; then
        GATES_JSON=$(jq -c -n --argjson base "$GATES_JSON" --argjson over "$gates" '$base * $over')
    fi
}

apply_profile() { # file source — returns 10 when profile absent
    local f="$1" source="$2"
    [[ -n "$f" ]] || return 10
    local prof
    prof=$(jq -c --arg p "$PROFILE" '.profiles[$p] // empty' "$f")
    [[ -n "$prof" ]] || return 10
    local tiers roles
    tiers=$(jq -c '.tiers // empty' <<<"$prof")
    if [[ -n "$tiers" ]]; then
        local k
        for k in deep light utility; do
            local v
            v=$(jq -r --arg k "$k" '.[$k] // empty' <<<"$tiers")
            [[ -n "$v" ]] && set_kv TIER_LIST "$k" "$v" "profile($PROFILE)"
        done
    fi
    roles=$(jq -c '.roles // empty' <<<"$prof")
    if [[ -n "$roles" ]]; then
        local rkeys
        rkeys=$(jq -r 'keys[]' <<<"$roles")
        while IFS= read -r rk; do
            [[ -z "$rk" ]] && continue
            if ! jq -e --arg k "$rk" 'has($k)' <<<"$ROLE_TIER_MAP" >/dev/null \
               && ! jq -e --arg k "$rk" 'has($k)' <<<"$ROLES_EXPLICIT" >/dev/null; then
                die_validation "unknown role '$rk' in profile '$PROFILE'" "Valid roles: $(jq -r 'keys[]' <<<"$ROLE_TIER_MAP" | tr '\n' ' ')$(jq -r 'keys[]' <<<"$ROLES_EXPLICIT" | tr '\n' ' ')"
            fi
            set_kv ROLE_LIST "$rk" "$(jq -r --arg k "$rk" '.[$k]' <<<"$roles")" "profile($PROFILE)"
        done <<< "$rkeys"
    fi
    return 0
}

# Per-orchestrator tier defaults (user config only — machine-specific model
# availability belongs to the user, not the repo). Applied between built-in
# defaults and user tiers, so explicit tiers/roles still win:
#   {"orchestrator_defaults": {"omp": {"tiers": {"deep": "omp:moonshot/kimi-k3"}}}}
od_tiers=""
if [[ -n "$USER_CFG" ]]; then
    od_tiers=$(jq -c --arg o "$ORCHESTRATOR" '.orchestrator_defaults[$o].tiers // empty' "$USER_CFG" 2>/dev/null)
fi
if [[ -n "$od_tiers" && "$od_tiers" != "null" ]]; then
    for k in deep light utility; do
        v=$(jq -r --arg k "$k" '.[$k] // empty' <<<"$od_tiers")
        [[ -n "$v" ]] && set_kv TIER_LIST "$k" "$v" "orchestrator-default($ORCHESTRATOR)"
    done
fi

apply_file "$USER_CFG" "user-config"
apply_file "$REPO_CFG" "repo-config"

if [[ -n "$PROFILE" ]]; then
    apply_profile "$REPO_CFG" "repo-profile"
    rc=$?
    if [[ $rc -eq 10 ]]; then
        apply_profile "$USER_CFG" "user-profile"
        rc=$?
    fi
    if [[ $rc -ne 0 ]]; then
        die_validation "profile '$PROFILE' not found in repo or user config" "define it under profiles.$PROFILE in $REPO_ROOT/.matthewsreview.json or ~/.matthews-reviews/config.json"
    fi
fi

if [[ -n "$MODELS_CSV" ]]; then
    OLDIFS="$IFS"; IFS=','
    for pair in $MODELS_CSV; do
        IFS="$OLDIFS"
        [[ -z "$pair" ]] && continue
        key="${pair%%=*}"; val="${pair#*=}"
        if [[ "$key" == "$val" || -z "$val" ]]; then
            die_validation "--models entry '$pair' is not key=value" "Valid input: --models \"deep=claude:opus,light=codex::medium\""
        fi
        case "$key" in
            deep|light|utility) set_kv TIER_LIST "$key" "$val" "cli" ;;
            *)
                if jq -e --arg k "$key" 'has($k)' <<<"$ROLE_TIER_MAP" >/dev/null \
                   || jq -e --arg k "$key" 'has($k)' <<<"$ROLES_EXPLICIT" >/dev/null; then
                    set_kv ROLE_LIST "$key" "$val" "cli"
                else
                    die_validation "unknown --models key '$key'" "Valid keys: deep | light | utility | $(jq -r 'keys[]' <<<"$ROLE_TIER_MAP" | tr '\n' ' ')$(jq -r 'keys[]' <<<"$ROLES_EXPLICIT" | tr '\n' ' ')"
                fi
                ;;
        esac
        IFS=','
    done
    IFS="$OLDIFS"
fi

# ---------------------------------------------------------------- validate + emit
validate_role_string() { # role value
    local role="$1" value="$2"
    local engine rest model effort
    engine="${value%%:*}"; rest="${value#*:}"
    if [[ "$rest" == "$value" || -z "$engine" ]]; then
        die_validation "role '$role' value '$value' is not engine:model[:effort]" "Valid engines: claude | codex | omp"
    fi
    case "$engine" in
        claude|codex|omp) ;;
        *) die_validation "role '$role' uses unknown engine '$engine'" "Valid engines: claude | codex | omp" ;;
    esac
    if [[ "$rest" == *:* ]]; then
        model="${rest%%:*}"; effort="${rest#*:}"
    else
        model="$rest"; effort=""
    fi
    if [[ -n "$effort" && "$engine" != "codex" ]]; then
        die_validation "role '$role': effort is only valid for codex: engines (got '$value')" "drop the :$effort segment"
    fi
    if [[ -n "$effort" && "${EFFORT_SET#* $effort }" == "$EFFORT_SET" ]]; then
        die_validation "role '$role': unknown effort '$effort'" "Valid efforts: low | medium | high | xhigh | max | ultra"
    fi
    if [[ -z "$model" && "$engine" != "codex" ]]; then
        die_validation "role '$role': empty model only allowed for codex: (got '$value')" "specify a model, e.g. $engine:opus"
    fi
    # orchestrator matrix
    if [[ "$engine" == "omp" ]]; then
        case "$ORCHESTRATOR" in
            claude-code) die_validation "role '$role' wants omp:... but the orchestrator is Claude Code" "run from omp, or choose claude:/codex: for this role" ;;
            codex) command -v omp >/dev/null 2>&1 || die_validation "role '$role' wants omp:... but no omp CLI is on PATH" "install omp, or choose claude:/codex: for this role" ;;
        esac
    fi
    printf '%s|%s|%s' "$engine" "$model" "$effort"
}

ROLES_JSON="{}"
emit_role() { # role tier|EXPLICIT
    local role="$1" tier="$2"
    local rv value source
    rv=$(get_kv ROLE_LIST "$role")
    if [[ -n "$rv" ]]; then
        value="${rv%%|*}"; source="${rv#*|}"
    elif [[ "$tier" == "EXPLICIT" ]]; then
        value=$(jq -r --arg k "$role" '.[$k]' <<<"$ROLES_EXPLICIT"); source="default"
    else
        rv=$(get_kv TIER_LIST "$tier")
        value="${rv%%|*}"; source="${rv#*|} (tier:$tier)"
    fi
    local parts
    parts=$(validate_role_string "$role" "$value") || exit 1
    local engine model effort
    engine="${parts%%|*}"; parts="${parts#*|}"
    model="${parts%%|*}"; effort="${parts#*|}"
    ROLES_JSON=$(jq -c --arg r "$role" --arg e "$engine" --arg m "$model" --arg f "$effort" --arg s "$source" \
        '.[$r] = {engine:$e, model:$m, effort:(if $f=="" then null else $f end), source:$s}' <<<"$ROLES_JSON")
}

for role in deep_lens deep_validate cross_cutting fix post_fix_review reconcile; do emit_role "$role" deep; done
for role in light_lens light_validate; do emit_role "$role" light; done
for role in classifier normalizer dedup scoring fix_hint briefer drafter; do emit_role "$role" utility; done
for role in ensemble_detect codex_detect codex_validate codex_crosscut; do emit_role "$role" EXPLICIT; done

WARNINGS="[]"
if [[ -n "${LEGACY_WARN:-}" ]]; then
    WARNINGS=$(jq -c --arg w "$LEGACY_WARN" '. + [$w]' <<<"$WARNINGS")
fi

# Availability hint: claude:* roles under the omp orchestrator dispatch via
# the eval bridge, which requires Anthropic auth in omp. Without it the
# dispatch 404s ("claude models not served"). Warn at resolution so the
# preflight Model plan table surfaces it before any token spend.
if [[ "$ORCHESTRATOR" == "omp" ]]; then
    claude_roles=$(jq -r '[to_entries[] | select(.value.engine == "claude") | .key] | join(", ")' <<<"$ROLES_JSON")
    if [[ -n "$claude_roles" ]]; then
        WARNINGS=$(jq -c --arg w "roles using claude: ($claude_roles) require Anthropic auth in omp — if dispatch 404s, set orchestrator_defaults.omp.tiers in ~/.matthews-reviews/config.json (e.g. \"deep\": \"omp:moonshot/kimi-k3\")" '. + [$w]' <<<"$WARNINGS")
    fi
fi

jq -n \
    --arg o "$ORCHESTRATOR" \
    --argjson roles "$ROLES_JSON" \
    --argjson gates "$GATES_JSON" \
    --argjson warnings "$WARNINGS" \
    '{orchestrator:$o, roles:$roles, gates:$gates, warnings:$warnings}'
