#!/usr/bin/env bash
# review-config.sh — resolve the per-role model plan + gate thresholds.
#
# Merge order (later wins):
#   built-in defaults
#   $MATTHEWS_REVIEW_REVIEWS_ROOT/config.json
#     (user config; canonical/legacy home fallback via review-root.sh)
#   trusted <git-ref>:.matthewsreview.json (or explicit diagnostic worktree)
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
#                    [--repo-config-ref <git-ref|worktree>] [--profile <name>] [--models "<k=v,k=v>"]
#
# Output (stdout): one JSON object
#   {orchestrator, roles: {<role>: {engine, model, effort, source}},
#    gates: {...}, warnings: []}
#
# Exit codes (bin/_common.py conventions): 0 OK, 1 validation, 5 dependency, 64 usage.
set -u

PROG=review-config.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

err() { # msg
    echo "ERROR: $1" >&2
}
die_usage() {
    err "$1"
    echo "Valid input: $PROG --repo-root <abs> --orchestrator <claude-code|omp|codex> [--repo-config-ref <git-ref> | --repo-config-worktree] [--profile <name>] [--models \"<k=v,k=v>\"]" >&2
    exit 64
}
require_value() {
    [[ $# -ge 2 ]] || die_usage "$1 requires a value"
}
die_validation() { # msg action
    err "$1"
    [[ -n "${2:-}" ]] && echo "Action: $2" >&2
    exit 1
}
die_dependency() { # msg action
    err "$1"
    [[ -n "${2:-}" ]] && echo "Action: $2" >&2
    exit 5
}

REPO_ROOT=""
REPO_CONFIG_REF=""
REPO_CONFIG_WORKTREE=0
ORCHESTRATOR=""
PROFILE=""
MODELS_CSV=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo-root)       require_value "$@"; REPO_ROOT="$2"; shift 2 ;;
        --repo-config-ref) require_value "$@"; REPO_CONFIG_REF="$2"; shift 2 ;;
        --repo-config-worktree) REPO_CONFIG_WORKTREE=1; shift ;;
        --orchestrator)    require_value "$@"; ORCHESTRATOR="$2"; shift 2 ;;
        --profile)         require_value "$@"; PROFILE="$2"; shift 2 ;;
        --models)          require_value "$@"; MODELS_CSV="$2"; shift 2 ;;
        *) die_usage "unknown argument: $1" ;;
    esac
done

[[ -n "$REPO_ROOT" && -d "$REPO_ROOT" ]] || die_usage "--repo-root must be an existing directory"
case "$ORCHESTRATOR" in
    claude-code|omp|codex) ;;
    *) die_usage "--orchestrator must be one of: claude-code | omp | codex" ;;
esac
if [[ "$REPO_CONFIG_WORKTREE" == "1" && -n "$REPO_CONFIG_REF" ]]; then
    die_usage "--repo-config-ref cannot combine with --repo-config-worktree"
fi

command -v jq >/dev/null 2>&1 \
    || die_dependency "required dependency 'jq' is not available" \
        "install jq, then rerun $PROG"

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
VALID_TIER_KEYS=$(jq -r 'keys | join(" | ")' <<<"$TIERS_DEFAULT")
VALID_ROLE_KEYS=$(jq -r 'keys | join(" | ")' <<<"$ROLE_DEFS")
VALID_GATE_KEYS=$(jq -r 'keys | join(" | ")' <<<"$GATE_DEFS")

# ---------------------------------------------------------------- load files
REVIEWS_ROOT=$("$SCRIPT_DIR/review-root.sh")
review_root_rc=$?
if [[ "$review_root_rc" -ne 0 ]]; then
    exit "$review_root_rc"
fi
[[ -n "$REVIEWS_ROOT" ]] \
    || die_validation "review-root.sh returned an empty reviews root" \
        "set MATTHEWS_REVIEW_REVIEWS_ROOT to a one-line absolute path"

USER_CFG="$REVIEWS_ROOT/config.json"
if [[ -e "$USER_CFG" || -L "$USER_CFG" ]]; then
    if [[ ! -f "$USER_CFG" || ! -r "$USER_CFG" ]]; then
        die_validation "config path $USER_CFG is not a readable regular file" \
            "replace it with a readable JSON configuration file"
    fi
else
    USER_CFG=""
fi
if [[ -n "$USER_CFG" && "$REVIEWS_ROOT" == "$HOME/.adams-reviews" ]]; then
    LEGACY_WARN="legacy config path ~/.adams-reviews/config.json in use; run: mv ~/.adams-reviews ~/.matthews-reviews"
elif [[ -n "${ADAMS_REVIEW_REVIEWS_ROOT:-}" \
     && -z "${MATTHEWS_REVIEW_REVIEWS_ROOT:-}" ]]; then
    LEGACY_WARN="legacy ADAMS_REVIEW_REVIEWS_ROOT is in use; rename it to MATTHEWS_REVIEW_REVIEWS_ROOT"
fi

WORKTREE_REPO_CFG="$REPO_ROOT/.matthewsreview.json"
REPO_CFG=""
REPO_CFG_LABEL="$WORKTREE_REPO_CFG"
REPO_CFG_ACTION="jq . $WORKTREE_REPO_CFG   # locate the syntax error"
REPO_CFG_TMP=""
cleanup_repo_config() {
    [[ -z "$REPO_CFG_TMP" ]] || rm -f "$REPO_CFG_TMP"
}
trap cleanup_repo_config EXIT

if [[ "$REPO_CONFIG_WORKTREE" == "1" ]]; then
    if [[ -e "$WORKTREE_REPO_CFG" || -L "$WORKTREE_REPO_CFG" ]]; then
        if [[ ! -f "$WORKTREE_REPO_CFG" || ! -r "$WORKTREE_REPO_CFG" ]]; then
            die_validation "config path $WORKTREE_REPO_CFG is not a readable regular file" \
                "replace it with a readable JSON configuration file"
        fi
        REPO_CFG="$WORKTREE_REPO_CFG"
    fi
elif [[ -z "$REPO_CONFIG_REF" ]]; then
    if [[ -e "$WORKTREE_REPO_CFG" || -L "$WORKTREE_REPO_CFG" ]]; then
        die_validation "worktree repo config exists but no trusted repo config source was selected" \
            "pass --repo-config-ref <trusted-git-ref>; use --repo-config-worktree only for doctor diagnostics"
    fi
else
    command -v git >/dev/null 2>&1 \
        || die_dependency "required dependency 'git' is not available for --repo-config-ref" \
            "install git, then rerun $PROG"
    REPO_CONFIG_COMMIT=$(git -C "$REPO_ROOT" rev-parse --verify --end-of-options "${REPO_CONFIG_REF}^{commit}" 2>/dev/null)
    repo_ref_rc=$?
    if [[ "$repo_ref_rc" -ne 0 || -z "$REPO_CONFIG_COMMIT" ]]; then
        die_validation "repo config ref '$REPO_CONFIG_REF' does not resolve to a commit" \
            "pass the trusted artifact comparison_ref, or use --repo-config-worktree only for doctor diagnostics"
    fi
    REPO_CFG_LABEL="$WORKTREE_REPO_CFG at $REPO_CONFIG_COMMIT"
    REPO_CFG_ACTION="git -C $REPO_ROOT show $REPO_CONFIG_COMMIT:.matthewsreview.json | jq ."
    repo_tree_entry=$(git -C "$REPO_ROOT" ls-tree "$REPO_CONFIG_COMMIT" -- .matthewsreview.json 2>/dev/null)
    repo_tree_rc=$?
    if [[ "$repo_tree_rc" -ne 0 ]]; then
        die_validation "could not inspect .matthewsreview.json at commit $REPO_CONFIG_COMMIT" \
            "verify the trusted ref and repository object database, then rerun $PROG"
    fi
    if [[ -n "$repo_tree_entry" ]]; then
        REPO_CFG_TMP=$(mktemp "${TMPDIR:-/tmp}/matthewsreview-repo-config.XXXXXX") \
            || die_validation "could not create a temporary file for trusted repo config" \
                "check TMPDIR permissions, then rerun $PROG"
        if ! git -C "$REPO_ROOT" show "$REPO_CONFIG_COMMIT:.matthewsreview.json" >"$REPO_CFG_TMP" 2>/dev/null; then
            die_validation "could not read .matthewsreview.json from commit $REPO_CONFIG_COMMIT" \
                "verify the trusted ref and repository object database, then rerun $PROG"
        fi
        REPO_CFG="$REPO_CFG_TMP"
    fi
fi

if [[ -n "$USER_CFG" ]] && ! jq empty "$USER_CFG" 2>/dev/null; then
    die_validation "config file $USER_CFG is not valid JSON" "jq . $USER_CFG   # locate the syntax error"
fi
if [[ -n "$REPO_CFG" ]] && ! jq empty "$REPO_CFG" 2>/dev/null; then
    die_validation "config file $REPO_CFG_LABEL is not valid JSON" "$REPO_CFG_ACTION"
fi

cfg_get() { # file expr  — empty string when file missing or key absent
    local f="$1" expr="$2"
    [[ -n "$f" ]] || { echo ""; return; }
    jq -r "$expr // empty" "$f" 2>/dev/null
}

# ---------------------------------------------------------------- merge
# Assoc-free (bash 3.2): tiers/roles stay newline "key|value|source" lists.
# shellcheck disable=SC2034 # accessed indirectly by name in set_kv/get_kv
TIER_LIST=""   # deep|claude:opus|default
# shellcheck disable=SC2034 # accessed indirectly by name in set_kv/get_kv
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

# Tier and direct-role assignments share one precedence ladder. A later layer
# wins across namespaces; a direct role is more specific only within a layer.
SOURCE_RANK=0
set_source_rank() { # source
    case "$1" in
        default) SOURCE_RANK=0 ;;
        orchestrator-default*) SOURCE_RANK=1 ;;
        user-config) SOURCE_RANK=2 ;;
        repo-config) SOURCE_RANK=3 ;;
        user-profile\(*\)|repo-profile\(*\)) SOURCE_RANK=4 ;;
        cli) SOURCE_RANK=5 ;;
        *) die_validation "internal config source '$1' has no precedence rank" \
            "report this review-config.sh source label" ;;
    esac
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

validate_role_syntax() { # subject role-key-or-empty value
    local subject="$1" role="$2" value="$3"
    local engine rest model effort third_segment=0
    if ! jq -en --arg value "$value" '
        $value
        | (contains("|") | not)
          and (explode | all(.[]; . >= 32 and (. < 127 or . > 159) and . != 8232 and . != 8233))
    ' >/dev/null; then
        die_validation "$subject contains a reserved delimiter or control character" \
            "use a one-line engine:model[:effort-or-thinking] value without '|'"
    fi
    engine="${value%%:*}"
    rest="${value#*:}"
    if [[ "$rest" == "$value" || -z "$engine" ]]; then
        die_validation "$subject value '$value' is not engine:model[:effort-or-thinking]" \
            "Valid engines: claude | codex | omp"
    fi
    case "$engine" in
        claude|codex|omp) ;;
        *) die_validation "$subject uses unknown engine '$engine'" "Valid engines: claude | codex | omp" ;;
    esac
    if [[ "$rest" == *:* ]]; then
        third_segment=1
        model="${rest%%:*}"
        effort="${rest#*:}"
    else
        model="$rest"
        effort=""
    fi
    if [[ "$third_segment" == "1" && -z "$effort" ]]; then
        die_validation "$subject has an empty third segment in '$value'" \
            "remove the trailing colon, or provide a valid codex effort / omp thinking level"
    fi
    if [[ "$third_segment" == "1" ]]; then
        case "$engine" in
            claude)
                die_validation "$subject: Claude roles do not accept a third segment (got '$value')" \
                    "use claude:<model>"
                ;;
            codex)
                case "$effort" in
                    low|medium|high|xhigh|max|ultra) ;;
                    *) die_validation "$subject: unknown codex effort '$effort'" \
                        "Valid efforts: low | medium | high | xhigh | max | ultra" ;;
                esac
                ;;
            omp)
                case "$effort" in
                    off|minimal|low|medium|high|xhigh|max) ;;
                    *) die_validation "$subject: unknown omp thinking level '$effort'" \
                        "Valid levels: off | minimal | low | medium | high | xhigh | max" ;;
                esac
                ;;
        esac
    fi
    if [[ -z "$model" && "$engine" != "codex" ]]; then
        die_validation "$subject: empty model only allowed for codex: (got '$value')" \
            "specify a model, e.g. $engine:opus"
    fi
    case "$role" in
        ensemble_detect|codex_detect|codex_validate|codex_crosscut)
            [[ "$engine" == "codex" ]] \
                || die_validation "$subject must use the codex engine (got '$value')" \
                    "set $role=codex:<model>:<effort> (empty model is allowed as codex::<effort>)"
            ;;
    esac
    printf '%s|%s|%s' "$engine" "$model" "$effort"
}

validate_tier_object() { # json source-context
    local tiers="$1" context="$2" key value
    jq -e 'type == "object"' <<<"$tiers" >/dev/null \
        || die_validation "tiers $context must be a JSON object" "Valid tiers: $VALID_TIER_KEYS"
    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        require_tier_key "$key" "$context"
    done < <(json_object_keys "$tiers")
    jq -e 'all(to_entries[];
        (.value | type) == "string"
        and (.value | length) > 0
        and (.value | explode | all(.[]; . >= 32 and (. < 127 or . > 159) and . != 8232 and . != 8233)))' \
        <<<"$tiers" >/dev/null \
        || die_validation "tier values $context must be non-empty role strings without control characters" \
            "use engine:model[:effort-or-thinking] for every tier"
    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        value=$(jq -r --arg k "$key" '.[$k]' <<<"$tiers")
        validate_role_syntax "tier '$key' $context" "" "$value" >/dev/null
    done < <(json_object_keys "$tiers")
}

validate_role_object() { # json source-context
    local roles="$1" context="$2" key value
    jq -e 'type == "object"' <<<"$roles" >/dev/null \
        || die_validation "roles $context must be a JSON object" "Valid roles: $VALID_ROLE_KEYS"
    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        require_role_key "$key" "$context"
    done < <(json_object_keys "$roles")
    jq -e 'all(to_entries[];
        (.value | type) == "string"
        and (.value | length) > 0
        and (.value | explode | all(.[]; . >= 32 and (. < 127 or . > 159) and . != 8232 and . != 8233)))' \
        <<<"$roles" >/dev/null \
        || die_validation "role values $context must be non-empty role strings without control characters" \
            "use engine:model[:effort-or-thinking] for every role"
    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        value=$(jq -r --arg k "$key" '.[$k]' <<<"$roles")
        validate_role_syntax "role '$key' $context" "$key" "$value" >/dev/null
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

validate_profile_object() { # json profile-name source-file
    local prof="$1" profile_name="$2" source_file="$3" key section
    jq -e 'type == "object"' <<<"$prof" >/dev/null \
        || die_validation "profile '$profile_name' in $source_file must be a JSON object" \
            "define only tiers and/or roles under profiles.$profile_name"
    while IFS= read -r key; do
        case "$key" in
            tiers|roles) ;;
            *) die_validation "unknown profile key '$key' in profiles.$profile_name in $source_file" \
                "Valid profile keys: tiers | roles" ;;
        esac
    done < <(json_object_keys "$prof")
    if jq -e 'has("tiers")' <<<"$prof" >/dev/null; then
        section=$(jq -c '.tiers' <<<"$prof")
        validate_tier_object "$section" "in profile '$profile_name' in $source_file"
    fi
    if jq -e 'has("roles")' <<<"$prof" >/dev/null; then
        section=$(jq -c '.roles' <<<"$prof")
        validate_role_object "$section" "in profile '$profile_name' in $source_file"
    fi
}

validate_config_file() { # file user|repo [display-label]
    local file="$1" kind="$2" file_label="${3:-$1}"
    local key section profile_name profile_json orch
    jq -e 'type == "object"' "$file" >/dev/null \
        || die_validation "config file $file_label must contain a top-level JSON object" \
            "replace the top-level value with an object"
    jq -e '
        def safe_internal:
            (contains("|") | not)
            and (explode | all(.[]; . >= 32 and (. < 127 or . > 159) and . != 8232 and . != 8233));
        all(.. | strings; safe_internal)
        and all(.. | objects | keys[]; safe_internal)
    ' "$file" >/dev/null \
        || die_validation "config file $file_label contains a reserved delimiter or control character" \
            "use one-line keys and engine:model[:effort-or-thinking] values without '|'"
    while IFS= read -r key; do
        case "$key" in
            tiers|roles|gates|profiles) ;;
            orchestrator_defaults)
                [[ "$kind" == "user" ]] \
                    || die_validation "orchestrator_defaults is only valid in the user config, not $file_label" \
                        "move it to ~/.matthews-reviews/config.json"
                ;;
            *) die_validation "unknown top-level config key '$key' in $file_label" \
                "Valid keys: tiers | roles | gates | profiles$([[ "$kind" == "user" ]] && printf ' | orchestrator_defaults')" ;;
        esac
    done < <(jq -r 'keys[]' "$file")

    if jq -e 'has("tiers")' "$file" >/dev/null; then
        validate_tier_object "$(jq -c '.tiers' "$file")" "in $file_label"
    fi
    if jq -e 'has("roles")' "$file" >/dev/null; then
        validate_role_object "$(jq -c '.roles' "$file")" "in $file_label"
    fi
    if jq -e 'has("gates")' "$file" >/dev/null; then
        validate_gates_object "$(jq -c '.gates' "$file")" "in $file_label"
    fi
    if jq -e 'has("profiles")' "$file" >/dev/null; then
        section=$(jq -c '.profiles' "$file")
        jq -e 'type == "object"' <<<"$section" >/dev/null \
            || die_validation "profiles in $file_label must be a JSON object" \
                "map each profile name to an object containing tiers and/or roles"
        while IFS= read -r profile_name; do
            profile_json=$(jq -c --arg p "$profile_name" '.[$p]' <<<"$section")
            validate_profile_object "$profile_json" "$profile_name" "$file_label"
        done < <(json_object_keys "$section")
    fi
    if jq -e 'has("orchestrator_defaults")' "$file" >/dev/null; then
        section=$(jq -c '.orchestrator_defaults' "$file")
        jq -e 'type == "object"' <<<"$section" >/dev/null \
            || die_validation "orchestrator_defaults in $file_label must be a JSON object" \
                "map orchestrator names to objects containing tiers"
        while IFS= read -r orch; do
            case "$orch" in
                claude-code|omp|codex) ;;
                *) die_validation "unknown orchestrator_defaults key '$orch' in $file_label" \
                    "Valid orchestrators: claude-code | omp | codex" ;;
            esac
            profile_json=$(jq -c --arg o "$orch" '.[$o]' <<<"$section")
            jq -e 'type == "object" and (keys - ["tiers"] | length == 0) and has("tiers")' \
                <<<"$profile_json" >/dev/null \
                || die_validation "orchestrator_defaults.$orch in $file_label must contain only a tiers object" \
                    "use {\"tiers\":{\"deep\":\"engine:model\"}}"
            validate_tier_object "$(jq -c '.tiers' <<<"$profile_json")" \
                "in orchestrator_defaults.$orch in $file_label"
        done < <(json_object_keys "$section")
    fi
}

[[ -n "$USER_CFG" ]] && validate_config_file "$USER_CFG" user "$USER_CFG"
[[ -n "$REPO_CFG" ]] && validate_config_file "$REPO_CFG" repo "$REPO_CFG_LABEL"

# Built-in model choices are harness-invariant. Users who want a
# self-contained Codex run opt in through config, profiles, or --models.
TIERS_SEED="$TIERS_DEFAULT"
while IFS= read -r t; do
    set_kv TIER_LIST "$t" "$(jq -r --arg k "$t" '.[$k]' <<<"$TIERS_SEED")" "default"
done < <(json_object_keys "$TIERS_DEFAULT")

apply_file() { # file source [display-label]
    local f="$1" source="$2" file_label="${3:-$1}"
    [[ -n "$f" ]] || return 0
    local tiers roles gates k v rkeys rk
    tiers=$(jq -c '.tiers // empty' "$f")
    if [[ -n "$tiers" ]]; then
        validate_tier_object "$tiers" "in $file_label"
        while IFS= read -r k; do
            [[ -z "$k" ]] && continue
            v=$(jq -r --arg k "$k" '.[$k] // empty' <<<"$tiers")
            [[ -n "$v" ]] && set_kv TIER_LIST "$k" "$v" "$source"
        done < <(json_object_keys "$TIERS_DEFAULT")
    fi
    roles=$(jq -c '.roles // empty' "$f")
    if [[ -n "$roles" ]]; then
        validate_role_object "$roles" "in $file_label"
        rkeys=$(jq -r 'keys[]' <<<"$roles")
        while IFS= read -r rk; do
            [[ -z "$rk" ]] && continue
            require_role_key "$rk" "in $file_label"
            set_kv ROLE_LIST "$rk" "$(jq -r --arg k "$rk" '.[$k]' <<<"$roles")" "$source"
        done <<< "$rkeys"
    fi
    gates=$(jq -c '.gates // empty' "$f")
    if [[ -n "$gates" ]]; then
        validate_gates_object "$gates" "in $file_label"
        GATES_JSON=$(jq -c -n --argjson base "$GATES_JSON" --argjson over "$gates" '$base * $over')
    fi
}

apply_profile() { # file source [display-label] — returns 10 when profile absent
    local f="$1" source="$2" file_label="${3:-$1}"
    [[ -n "$f" ]] || return 10
    local prof tiers roles k v rkeys rk
    prof=$(jq -c --arg p "$PROFILE" '.profiles[$p] // empty' "$f")
    [[ -n "$prof" ]] || return 10
    jq -e 'type == "object"' <<<"$prof" >/dev/null \
        || die_validation "profile '$PROFILE' in $file_label must be a JSON object" \
            "define tiers and/or roles under profiles.$PROFILE"
    tiers=$(jq -c '.tiers // empty' <<<"$prof")
    if [[ -n "$tiers" ]]; then
        validate_tier_object "$tiers" "in profile '$PROFILE' in $file_label"
        while IFS= read -r k; do
            [[ -z "$k" ]] && continue
            v=$(jq -r --arg k "$k" '.[$k] // empty' <<<"$tiers")
            [[ -n "$v" ]] && set_kv TIER_LIST "$k" "$v" "$source"
        done < <(json_object_keys "$TIERS_DEFAULT")
    fi
    roles=$(jq -c '.roles // empty' <<<"$prof")
    if [[ -n "$roles" ]]; then
        validate_role_object "$roles" "in profile '$PROFILE' in $file_label"
        rkeys=$(jq -r 'keys[]' <<<"$roles")
        while IFS= read -r rk; do
            [[ -z "$rk" ]] && continue
            require_role_key "$rk" "in profile '$PROFILE' in $file_label"
            set_kv ROLE_LIST "$rk" "$(jq -r --arg k "$rk" '.[$k]' <<<"$roles")" "$source"
        done <<< "$rkeys"
    fi
    return 0
}

profile_exists() { # file
    local f="$1"
    [[ -n "$f" ]] || return 1
    jq -e --arg p "$PROFILE" '.profiles | type == "object" and has($p)' "$f" >/dev/null
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

SELECTED_PROFILE_SOURCE=""
if [[ -n "$PROFILE" ]]; then
    if profile_exists "$REPO_CFG"; then
        SELECTED_PROFILE_SOURCE="repo"
    elif profile_exists "$USER_CFG"; then
        SELECTED_PROFILE_SOURCE="user"
    else
        die_validation "profile '$PROFILE' not found in repo or user config" \
            "define it under profiles.$PROFILE in the trusted repo config or ~/.matthews-reviews/config.json"
    fi
fi

apply_file "$USER_CFG" "user-config"
apply_file "$REPO_CFG" "repo-config" "$REPO_CFG_LABEL"
if [[ "$SELECTED_PROFILE_SOURCE" == "user" ]]; then
    apply_profile "$USER_CFG" "user-profile($PROFILE)" "$USER_CFG"
elif [[ "$SELECTED_PROFILE_SOURCE" == "repo" ]]; then
    apply_profile "$REPO_CFG" "repo-profile($PROFILE)" "$REPO_CFG_LABEL"
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
            validate_role_syntax "--models tier '$key'" "" "$val" >/dev/null
            set_kv TIER_LIST "$key" "$val" "cli"
        elif is_valid_role_key "$key"; then
            validate_role_syntax "--models role '$key'" "$key" "$val" >/dev/null
            set_kv ROLE_LIST "$key" "$val" "cli"
        else
            die_validation "unknown --models key '$key'" "Valid keys: $VALID_TIER_KEYS | $VALID_ROLE_KEYS"
        fi
        IFS=','
    done
    IFS="$OLDIFS"
fi

# ---------------------------------------------------------------- validate + emit
validate_effective_role() { # role value
    local role="$1" value="$2" parts engine
    parts=$(validate_role_syntax "role '$role'" "$role" "$value") || exit 1
    engine="${parts%%|*}"

    # Harness/engine availability is an effective-plan constraint, not
    # persisted-source grammar. Dormant valid profiles remain portable.
    if [[ "$engine" == "omp" ]]; then
        case "$ORCHESTRATOR" in
            claude-code)
                die_validation "role '$role' wants omp:... but the orchestrator is Claude Code" \
                    "run from omp, or choose claude:/codex: for this role"
                ;;
            codex)
                command -v omp >/dev/null 2>&1 \
                    || die_validation "role '$role' wants omp:... but no omp CLI is on PATH" \
                        "install omp, or choose claude:/codex: for this role"
                ;;
        esac
    fi
    printf '%s' "$parts"
}

ROLES_JSON="{}"
emit_role() { # role tier|EXPLICIT
    local role="$1" tier="$2"
    local role_rv tier_rv role_value role_source tier_value tier_source
    local role_rank tier_rank value source
    role_rv=$(get_kv ROLE_LIST "$role")
    if [[ "$tier" == "EXPLICIT" ]]; then
        if [[ -n "$role_rv" ]]; then
            value="${role_rv%%|*}"
            source="${role_rv#*|}"
        else
            value=$(jq -r --arg k "$role" '.[$k].default' <<<"$ROLE_DEFS")
            source="default"
        fi
    else
        tier_rv=$(get_kv TIER_LIST "$tier")
        tier_value="${tier_rv%%|*}"
        tier_source="${tier_rv#*|}"
        if [[ -n "$role_rv" ]]; then
            role_value="${role_rv%%|*}"
            role_source="${role_rv#*|}"
            set_source_rank "$role_source"
            role_rank="$SOURCE_RANK"
            set_source_rank "$tier_source"
            tier_rank="$SOURCE_RANK"
            if [[ "$role_rank" -ge "$tier_rank" ]]; then
                value="$role_value"
                source="$role_source"
            else
                value="$tier_value"
                source="$tier_source (tier:$tier)"
            fi
        else
            value="$tier_value"
            source="$tier_source (tier:$tier)"
        fi
    fi
    local parts
    parts=$(validate_effective_role "$role" "$value") || exit 1
    local engine model effort
    engine="${parts%%|*}"; parts="${parts#*|}"
    model="${parts%%|*}"; effort="${parts#*|}"
    case "$source" in
        user-profile\(*|repo-profile\(*)
            source="profile${source#*-profile}"
            ;;
    esac
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
