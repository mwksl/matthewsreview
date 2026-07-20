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
# Role strings: engine:model[:effort-or-thinking]
#   engines: claude | codex | omp
#   codex effort: low|medium|high|xhigh|max|ultra
#   omp thinking: off|minimal|low|medium|high|xhigh|max
#   claude roles reject the third segment.
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
# Canonical tier, role, and gate definitions. Validation, error messages,
# merge loops, and emission all derive from these objects.
TIERS_DEFAULT='{"deep":"claude:opus","light":"claude:sonnet","utility":"claude:sonnet"}'
ROLE_DEFS='{
  "deep_lens":{"tier":"deep"},"deep_validate":{"tier":"deep"},"cross_cutting":{"tier":"deep"},
  "fix":{"tier":"deep"},"post_fix_review":{"tier":"deep"},"reconcile":{"tier":"deep"},
  "light_lens":{"tier":"light"},"light_validate":{"tier":"light"},
  "classifier":{"tier":"utility"},"normalizer":{"tier":"utility"},"dedup":{"tier":"utility"},
  "scoring":{"tier":"utility"},"fix_hint":{"tier":"utility"},"briefer":{"tier":"utility"},"drafter":{"tier":"utility"},
  "ensemble_detect":{"default":"codex::high"},"codex_detect":{"default":"codex::high"},
  "codex_validate":{"default":"codex::high"},"codex_crosscut":{"default":"codex::high"}
}'
GATE_DEFS='{
  "phase3_gate":{"default":45,"kind":"score"},
  "phase4_bands":{"default":[45,60,75],"kind":"bands3"},
  "fix_threshold":{"default":60,"kind":"score"},
  "walkthrough_threshold":{"default":60,"kind":"score"}
}'
GATES_DEFAULT=$(jq -c 'with_entries(.value = .value.default)' <<<"$GATE_DEFS")
CODEX_EFFORT_SET=' low medium high xhigh max ultra '
OMP_THINKING_SET=' off minimal low medium high xhigh max '
VALID_TIER_KEYS=$(jq -r 'keys | join(" | ")' <<<"$TIERS_DEFAULT")
VALID_ROLE_KEYS=$(jq -r 'keys | join(" | ")' <<<"$ROLE_DEFS")
VALID_GATE_KEYS=$(jq -r 'keys | join(" | ")' <<<"$GATE_DEFS")

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
# Assoc-free (bash 3.2): tiers/roles stay newline "key|value|source" lists.
TIER_LIST=""   # deep|claude:opus|default
ROLE_LIST=""   # deep_validate|claude:sonnet|repo-config (empty = inherit tier)
GATES_JSON="$GATES_DEFAULT"

set_kv() { # listname key value source
    local listname="$1" key="$2" value="$3" source="$4"
    local cur="" line updated=0 out=""
    cur="${!listname}"
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if [[ "${line%%|*}" == "$key" ]]; then
            out="$out$key|$value|$source"$'\n'; updated=1
        else
            out="$out$line"$'\n'
        fi
    done <<< "$cur"
    if [[ "$updated" == "0" ]]; then out="$out$key|$value|$source"$'\n'; fi
    printf -v "$listname" '%s' "$out"
}

get_kv() { # listname key -> "value|source" or empty
    local listname="$1" key="$2" cur line
    cur="${!listname}"
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if [[ "${line%%|*}" == "$key" ]]; then printf '%s' "${line#*|}"; return; fi
    done <<< "$cur"
}

json_object_has() { # json key
    jq -e --arg k "$2" 'has($k)' <<<"$1" >/dev/null
}

json_object_keys() { # json
    jq -r 'keys[]' <<<"$1"
}

is_valid_tier_key() {
    json_object_has "$TIERS_DEFAULT" "$1"
}

is_valid_role_key() {
    json_object_has "$ROLE_DEFS" "$1"
}

is_valid_gate_key() {
    json_object_has "$GATE_DEFS" "$1"
}

require_tier_key() { # key source-context
    local key="$1" context="$2"
    is_valid_tier_key "$key" \
        || die_validation "unknown tier '$key' $context" "Valid tiers: $VALID_TIER_KEYS"
}

require_role_key() { # key source-context
    local key="$1" context="$2"
    is_valid_role_key "$key" \
        || die_validation "unknown role '$key' $context" "Valid roles: $VALID_ROLE_KEYS"
}

require_gate_key() { # key source-context
    local key="$1" context="$2"
    is_valid_gate_key "$key" \
        || die_validation "unknown gate '$key' $context" "Valid gates: $VALID_GATE_KEYS"
}

validate_tier_object() { # json source-context
    local tiers="$1" context="$2" key
    jq -e 'type == "object"' <<<"$tiers" >/dev/null \
        || die_validation "tiers $context must be a JSON object" "Valid tiers: $VALID_TIER_KEYS"
    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        require_tier_key "$key" "$context"
    done < <(json_object_keys "$tiers")
}

validate_role_object() { # json source-context
    local roles="$1" context="$2" key
    jq -e 'type == "object"' <<<"$roles" >/dev/null \
        || die_validation "roles $context must be a JSON object" "Valid roles: $VALID_ROLE_KEYS"
    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        require_role_key "$key" "$context"
    done < <(json_object_keys "$roles")
}

validate_gates_object() { # json source-context
    local gates="$1" context="$2" key value kind
    jq -e 'type == "object"' <<<"$gates" >/dev/null \
        || die_validation "gates $context must be a JSON object" "Valid gates: $VALID_GATE_KEYS"
    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        require_gate_key "$key" "$context"
        value=$(jq -c --arg k "$key" '.[$k]' <<<"$gates")
        kind=$(jq -r --arg k "$key" '.[$k].kind' <<<"$GATE_DEFS")
        case "$kind" in
            score)
                jq -e 'type == "number" and . >= 0 and . <= 100' <<<"$value" >/dev/null \
                    || die_validation "gate '$key' $context must be a number from 0 to 100" "replace it with a numeric score threshold"
                ;;
            bands3)
                jq -e 'type == "array"' <<<"$value" >/dev/null \
                    || die_validation "gate '$key' $context must be an array of exactly 3 numbers" "use three ascending score boundaries, e.g. [45,60,75]"
                jq -e 'length == 3' <<<"$value" >/dev/null \
                    || die_validation "gate '$key' $context must contain exactly 3 numbers" "use three ascending score boundaries, e.g. [45,60,75]"
                jq -e 'all(.[]; type == "number" and . >= 0 and . <= 100)' <<<"$value" >/dev/null \
                    || die_validation "gate '$key' $context must contain only numbers from 0 to 100" "use three ascending score boundaries, e.g. [45,60,75]"
                jq -e '.[0] < .[1] and .[1] < .[2]' <<<"$value" >/dev/null \
                    || die_validation "gate '$key' $context must be strictly ascending" "use three ascending score boundaries, e.g. [45,60,75]"
                ;;
            *)
                die_validation "gate '$key' $context has unknown validator '$kind'" "fix GATE_DEFS in review-config.sh"
                ;;
        esac
    done < <(json_object_keys "$gates")
}

# seed defaults. On the codex orchestrator the built-in tiers switch to
# the codex engine (codex::high) — a codex-driven run should be
# self-contained (matches :codex-review's all-codex shape) instead of
# stalling on cross-engine consent prompts. Config/CLI still overrides.
TIERS_SEED="$TIERS_DEFAULT"
if [[ "$ORCHESTRATOR" == "codex" ]]; then
    TIERS_SEED=$(jq -c 'with_entries(.value = "codex::high")' <<<"$TIERS_DEFAULT")
fi
while IFS= read -r t; do
    set_kv TIER_LIST "$t" "$(jq -r --arg k "$t" '.[$k]' <<<"$TIERS_SEED")" "default"
done < <(json_object_keys "$TIERS_DEFAULT")

apply_file() { # file source
    local f="$1" source="$2"
    [[ -n "$f" ]] || return 0
    local tiers roles gates k v rkeys rk
    tiers=$(jq -c '.tiers // empty' "$f")
    if [[ -n "$tiers" ]]; then
        validate_tier_object "$tiers" "in $f"
        while IFS= read -r k; do
            [[ -z "$k" ]] && continue
            v=$(jq -r --arg k "$k" '.[$k] // empty' <<<"$tiers")
            [[ -n "$v" ]] && set_kv TIER_LIST "$k" "$v" "$source"
        done < <(json_object_keys "$TIERS_DEFAULT")
    fi
    roles=$(jq -c '.roles // empty' "$f")
    if [[ -n "$roles" ]]; then
        validate_role_object "$roles" "in $f"
        rkeys=$(jq -r 'keys[]' <<<"$roles")
        while IFS= read -r rk; do
            [[ -z "$rk" ]] && continue
            require_role_key "$rk" "in $f"
            set_kv ROLE_LIST "$rk" "$(jq -r --arg k "$rk" '.[$k]' <<<"$roles")" "$source"
        done <<< "$rkeys"
    fi
    gates=$(jq -c '.gates // empty' "$f")
    if [[ -n "$gates" ]]; then
        validate_gates_object "$gates" "in $f"
        GATES_JSON=$(jq -c -n --argjson base "$GATES_JSON" --argjson over "$gates" '$base * $over')
    fi
}

apply_profile() { # file source — returns 10 when profile absent
    local f="$1" source="$2"
    [[ -n "$f" ]] || return 10
    local prof tiers roles k v rkeys rk
    prof=$(jq -c --arg p "$PROFILE" '.profiles[$p] // empty' "$f")
    [[ -n "$prof" ]] || return 10
    jq -e 'type == "object"' <<<"$prof" >/dev/null \
        || die_validation "profile '$PROFILE' in $f must be a JSON object" "define tiers and/or roles under profiles.$PROFILE"
    tiers=$(jq -c '.tiers // empty' <<<"$prof")
    if [[ -n "$tiers" ]]; then
        validate_tier_object "$tiers" "in profile '$PROFILE'"
        while IFS= read -r k; do
            [[ -z "$k" ]] && continue
            v=$(jq -r --arg k "$k" '.[$k] // empty' <<<"$tiers")
            [[ -n "$v" ]] && set_kv TIER_LIST "$k" "$v" "profile($PROFILE)"
        done < <(json_object_keys "$TIERS_DEFAULT")
    fi
    roles=$(jq -c '.roles // empty' <<<"$prof")
    if [[ -n "$roles" ]]; then
        validate_role_object "$roles" "in profile '$PROFILE'"
        rkeys=$(jq -r 'keys[]' <<<"$roles")
        while IFS= read -r rk; do
            [[ -z "$rk" ]] && continue
            require_role_key "$rk" "in profile '$PROFILE'"
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
    validate_tier_object "$od_tiers" "in orchestrator_defaults.$ORCHESTRATOR.tiers"
    while IFS= read -r k; do
        [[ -z "$k" ]] && continue
        v=$(jq -r --arg k "$k" '.[$k] // empty' <<<"$od_tiers")
        [[ -n "$v" ]] && set_kv TIER_LIST "$k" "$v" "orchestrator-default($ORCHESTRATOR)"
    done < <(json_object_keys "$TIERS_DEFAULT")
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
        if is_valid_tier_key "$key"; then
            set_kv TIER_LIST "$key" "$val" "cli"
        elif is_valid_role_key "$key"; then
            set_kv ROLE_LIST "$key" "$val" "cli"
        else
            die_validation "unknown --models key '$key'" "Valid keys: $VALID_TIER_KEYS | $VALID_ROLE_KEYS"
        fi
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
        die_validation "role '$role' value '$value' is not engine:model[:effort-or-thinking]" "Valid engines: claude | codex | omp"
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
    if [[ -n "$effort" ]]; then
        case "$engine" in
            claude)
                die_validation "role '$role': effort is only valid for codex: engines or omp: model thinking (got '$value')" "drop the :$effort segment"
                ;;
            codex)
                if [[ "${CODEX_EFFORT_SET#* $effort }" == "$CODEX_EFFORT_SET" ]]; then
                    die_validation "role '$role': unknown codex effort '$effort'" "Valid efforts: low | medium | high | xhigh | max | ultra"
                fi
                ;;
            omp)
                if [[ "${OMP_THINKING_SET#* $effort }" == "$OMP_THINKING_SET" ]]; then
                    die_validation "role '$role': unknown omp thinking level '$effort'" "Valid levels: off | minimal | low | medium | high | xhigh | max"
                fi
                ;;
        esac
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
        value=$(jq -r --arg k "$role" '.[$k].default' <<<"$ROLE_DEFS"); source="default"
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

while IFS='|' read -r role tier; do
    [[ -z "$role" ]] && continue
    emit_role "$role" "$tier"
done <<< "$(jq -r 'to_entries[] | "\(.key)|\(.value.tier // "EXPLICIT")"' <<<"$ROLE_DEFS")"

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
