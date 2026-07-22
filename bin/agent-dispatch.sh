#!/usr/bin/env bash
# agent-dispatch.sh — harness-neutral sub-agent dispatch over CLI engines.
#
# One job = one CLI child process running a prompt file. Generalizes the
# codex-poll.sh pattern to three engines so any orchestrator (Claude Code,
# omp, Codex CLI) can reach any engine:
#
#   claude  → claude -p --model <m> --output-format json (prompt on stdin)
#   codex   → codex exec - --model <m> -c model_reasoning_effort=<e>
#             --sandbox read-only|workspace-write --json -o <last-msg>
#   omp     → omp -p --model <m> --thinking <level> @<prompt-file>
#
# Job layout: <scratch-dir>/<job_id>/{pid,child_pid,engine,model,effort,
# started_epoch,out,err,last_message,terminal/{state,exit_code,ready},prompt.md}
#
# Subcommands:
#   start --engine <claude|codex|omp> --model <m> [--effort <e>]
#         (`<e>` = codex effort or omp thinking level)
#         --prompt-file <abs> --scratch-dir <abs> [--write]
#     → stdout {"job_id","pid","out_file"}
#   poll --job <id> --scratch-dir <abs>
#        [--stall-threshold-sec N (90)] [--wall-clock-ceiling-sec N (600)]
#     → stdout one verdict object:
#       {"verdict":"completed","status":"completed","raw_output":"...","tokens":N|null}
#       {"verdict":"failed_terminal","status":"failed","error_tail":"..."}
#       {"verdict":"cancelled","status":"cancelled"}
#       {"verdict":"alive","status":"running"}
#       {"verdict":"stalled_suspect","status":"running"}
#       {"verdict":"wall_clock_exceeded","status":"running"}
#   stop --job <id> --scratch-dir <abs>
#     → claims cancellation atomically, authenticates the wrapper and engine,
#       then TERM/check/KILL/check. Emits cancelled only after both are gone.
#       Completion that won first emits already_finished; an unverifiable stop
#       emits stop_failed on stdout and exits non-zero.
#
# Caller branches on `verdict` exactly as with codex-poll.sh:
#   alive | stalled_suspect → keep polling
#   completed               → consume raw_output/tokens
#   cancelled               → terminal; never issue a redundant stop
#   failed_terminal | wall_clock_exceeded → retry / drop per fragment policy
#
# Exit codes (bin/_common.py conventions): 0 OK, 1 validation/stop_failed,
# 5 missing dependency or unauthenticated engine, 64 usage.
set -u
umask 077

PROG=agent-dispatch.sh
KILL_CMD=$(type -P kill 2>/dev/null || printf '%s' /bin/kill)

print_usage() { cat >&2 <<USAGE
Usage:
  $PROG start --engine <claude|codex|omp> --model <m> [--effort <codex-effort|omp-thinking>] --prompt-file <abs> --scratch-dir <abs> [--write]
  $PROG poll  --job <id> --scratch-dir <abs> [--stall-threshold-sec N] [--wall-clock-ceiling-sec N]
  $PROG stop  --job <id> --scratch-dir <abs>
USAGE
}
err() { echo "ERROR: $1" >&2; }
die_usage() {
    err "$1"
    print_usage
    echo "Action: correct the invocation using the usage above, then retry." >&2
    exit 64
}
require_value() {
    [[ $# -ge 2 ]] || die_usage "$1 requires a value"
}

normalize_nonnegative_integer() { # flag value → NORMALIZED_INTEGER
    local flag="$1" value="$2" max_value=9223372036854775807
    if [[ ! "$value" =~ ^[0-9]+$ ]]; then
        die_usage "$flag must be a non-negative base-10 integer (got '$value')"
    fi
    while [[ "${#value}" -gt 1 && "${value:0:1}" == "0" ]]; do
        value="${value#0}"
    done
    [[ -n "$value" ]] || value=0
    # shellcheck disable=SC2071  # equal-length digit strings compare lexically
    if [[ "${#value}" -gt "${#max_value}" \
          || ( "${#value}" -eq "${#max_value}" && "$value" > "$max_value" ) ]]; then
        die_usage "$flag exceeds the largest arithmetic-safe integer ($max_value)"
    fi
    NORMALIZED_INTEGER="$value"
}
require_jq() {
    if ! command -v jq >/dev/null 2>&1; then
        err "agent-dispatch.sh requires jq, which is not on PATH"
        echo "Action: install jq before dispatching model jobs." >&2
        exit 5
    fi
}
atomic_write() { # path value
    local path="$1" value="$2" tmp="${1}.tmp.$$.$RANDOM"
    if ! printf '%s\n' "$value" > "$tmp"; then
        rm -f "$tmp" 2>/dev/null || true
        return 1
    fi
    if ! mv "$tmp" "$path"; then
        rm -f "$tmp" 2>/dev/null || true
        return 1
    fi
}
atomic_copy() { # source destination
    local source="$1" path="$2" tmp="${2}.tmp.$$.$RANDOM"
    if ! cp "$source" "$tmp"; then
        rm -f "$tmp" 2>/dev/null || true
        return 1
    fi
    if ! mv "$tmp" "$path"; then
        rm -f "$tmp" 2>/dev/null || true
        return 1
    fi
}

SUB="${1:-}"
[[ $# -ge 1 ]] || die_usage "missing subcommand"
shift

ENGINE="" MODEL="" EFFORT="" PROMPT_FILE="" SCRATCH="" JOB="" WRITE=0
STALL=90 CEILING=600

while [[ $# -gt 0 ]]; do
    case "$1" in
        --engine) require_value "$@"; ENGINE="$2"; shift 2 ;;
        --model) require_value "$@"; MODEL="$2"; shift 2 ;;
        --effort) require_value "$@"; EFFORT="$2"; shift 2 ;;
        --prompt-file) require_value "$@"; PROMPT_FILE="$2"; shift 2 ;;
        --scratch-dir) require_value "$@"; SCRATCH="$2"; shift 2 ;;
        --job) require_value "$@"; JOB="$2"; shift 2 ;;
        --write) WRITE=1; shift ;;
        --stall-threshold-sec) require_value "$@"; STALL="$2"; shift 2 ;;
        --wall-clock-ceiling-sec) require_value "$@"; CEILING="$2"; shift 2 ;;
        *) die_usage "unknown argument: $1" ;;
    esac
done

require_job_id() {
    [[ "$JOB" =~ ^ad_[0-9A-Za-z_]+$ ]] || {
        err "invalid job id '$JOB'"
        echo "Action: use the exact job_id returned by agent-dispatch.sh start." >&2
        exit 64
    }
}

process_identity() { # pid
    local identity
    identity=$(LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null) || return 1
    identity=$(printf '%s\n' "$identity" \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    valid_process_identity "$identity" || return 1
    printf '%s\n' "$identity"
}

valid_process_identity() { # raw lstart identity
    [[ "$1" =~ ^[[:alpha:]]{3}[[:space:]]+[[:alpha:]]{3}[[:space:]]+[[:digit:]]{1,2}[[:space:]]+[[:digit:]]{2}:[[:digit:]]{2}:[[:digit:]]{2}[[:space:]]+[[:digit:]]{4}$ ]]
}

encode_process_identity() { # pid raw-identity
    local candidate="$1" identity="$2"
    [[ "$candidate" =~ ^[0-9]+$ ]] || return 1
    valid_process_identity "$identity" || return 1
    printf 'v1|%s|%s\n' "$candidate" "$identity"
}

process_table_contains() { # pid; 0 present, 1 absent, 2 unverifiable
    local candidate="$1" process_ids table_result=0
    if ! process_ids=$(LC_ALL=C ps -axo pid= 2>/dev/null); then
        return 2
    fi
    printf '%s\n' "$process_ids" | awk -v candidate="$candidate" '
        $1 ~ /^[0-9]+$/ {
            valid=1
            if ($1 == candidate) found=1
        }
        END {
            if (!valid) exit 2
            exit(found ? 0 : 1)
        }
    ' || table_result=$?
    case "$table_result" in
        0) return 0 ;;
        1) return 1 ;;
        *) return 2 ;;
    esac
}

process_state() { # pid identity-file; 0 alive, 1 verified dead/replaced, 2 unverifiable
    local candidate="$1" identity_file="$2" stored prefix recorded current table_state
    PROCESS_STATE_DETAIL=unverifiable
    [[ "$candidate" =~ ^[0-9]+$ && -f "$identity_file" ]] || return 2
    if ! stored=$(cat "$identity_file" 2>/dev/null); then
        return 2
    fi
    prefix="v1|$candidate|"
    [[ "$stored" == "$prefix"* ]] || return 2
    recorded=${stored#"$prefix"}
    valid_process_identity "$recorded" || return 2

    if current=$(process_identity "$candidate") \
       && valid_process_identity "$current"; then
        if [[ "$current" == "$recorded" ]]; then
            PROCESS_STATE_DETAIL=matched
            return 0
        fi
        PROCESS_STATE_DETAIL=replaced
        return 1
    fi

    # A targeted ps failure is not evidence of death. Fall back to a complete
    # process-table snapshot; only a successful non-empty snapshot that omits
    # the PID proves the recorded process is gone.
    table_state=0
    process_table_contains "$candidate" || table_state=$?
    case "$table_state" in
        0) PROCESS_STATE_DETAIL=present_unverifiable; return 2 ;;
        1) PROCESS_STATE_DETAIL=absent; return 1 ;;
        *) return 2 ;;
    esac
}

process_group_contains() { # pgid; 0 present, 1 empty, 2 unverifiable
    local pgid="$1" process_rows table_result=0
    if ! process_rows=$(LC_ALL=C ps -axo pid=,pgid= 2>/dev/null); then
        return 2
    fi
    printf '%s\n' "$process_rows" | awk -v pgid="$pgid" '
        $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ {
            valid=1
            if ($2 == pgid) found=1
        }
        END {
            if (!valid) exit 2
            exit(found ? 0 : 1)
        }
    ' || table_result=$?
    case "$table_result" in
        0) return 0 ;;
        1) return 1 ;;
        *) return 2 ;;
    esac
}

process_group_contains_other() { # pgid excluded-pid; 0 other present, 1 none, 2 unverifiable
    local pgid="$1" excluded_pid="$2" process_rows table_result=0
    if ! process_rows=$(LC_ALL=C ps -axo pid=,pgid= 2>/dev/null); then
        return 2
    fi
    printf '%s\n' "$process_rows" | awk -v pgid="$pgid" -v excluded="$excluded_pid" '
        $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ {
            valid=1
            if ($2 == pgid && $1 != excluded) found=1
        }
        END {
            if (!valid) exit 2
            exit(found ? 0 : 1)
        }
    ' || table_result=$?
    case "$table_result" in
        0) return 0 ;;
        1) return 1 ;;
        *) return 2 ;;
    esac
}

process_group_state() { # job-dir; 0 owned group alive, 1 verified empty, 2 unverifiable
    local job_dir="$1" child_pid child_pgid marker expected
    local leader_state=0 leader_detail group_state=0
    child_pid=$(cat "$job_dir/child_pid" 2>/dev/null || echo "")
    child_pgid=$(cat "$job_dir/child_pgid" 2>/dev/null || echo "")
    marker=$(cat "$job_dir/child_group" 2>/dev/null || echo "")
    [[ "$child_pid" =~ ^[0-9]+$ && "$child_pgid" =~ ^[0-9]+$ \
       && "$child_pgid" -gt 1 && "$child_pgid" == "$child_pid" ]] || return 2
    expected="v1|$child_pid|$child_pgid"
    [[ "$marker" == "$expected" ]] || return 2

    process_state "$child_pid" "$job_dir/child_identity" || leader_state=$?
    leader_detail=$PROCESS_STATE_DETAIL
    [[ "$leader_state" -ne 2 ]] || return 2
    process_group_contains "$child_pgid" || group_state=$?
    case "$group_state" in
        1) return 1 ;;
        0)
            # With a valid v1 group marker, an absent (not replaced) anchor
            # leaves only members of the originally isolated process group.
            # A reused leader PID/PGID remains unverifiable and is not signaled.
            if [[ "$leader_state" -eq 0 || "$leader_detail" == "absent" ]]; then
                return 0
            fi
            return 2
            ;;
        *) return 2 ;;
    esac
}

job_dir() { printf '%s/%s' "$SCRATCH" "$JOB"; }

engine_cli() { # engine → cli name (or empty for unknown)
    case "$1" in
        claude) echo claude ;;
        codex)  echo codex ;;
        omp)    echo omp ;;
        *)      echo "" ;;
    esac
}

require_engine() { # validates engine + CLI readiness
    local cli
    cli=$(engine_cli "$ENGINE")
    if [[ -z "$cli" ]]; then
        err "unknown engine '$ENGINE'"
        echo "Valid values: claude | codex | omp" >&2
        exit 1
    fi
    if ! command -v "$cli" >/dev/null 2>&1; then
        err "engine '$ENGINE' requires the '$cli' CLI, which is not on PATH"
        echo "Action: install $cli, or choose a different engine for this role." >&2
        exit 5
    fi
    if [[ "$ENGINE" == "codex" ]] && ! codex login status >/dev/null 2>&1; then
        err "engine 'codex' is installed but not authenticated"
        echo "Action: run 'codex login', verify 'codex login status' succeeds, then retry." >&2
        exit 5
    fi
}

pid_exists() { # pid
    "$KILL_CMD" -0 "$1" >/dev/null 2>&1
}


terminate_pid_tree() { # root-pid signal
    local root_pid="$1" signal_name="$2" child
    for child in $(ps -axo pid=,ppid= 2>/dev/null \
        | awk -v parent="$root_pid" '$2 == parent { print $1 }'); do
        terminate_pid_tree "$child" "$signal_name"
    done
    if pid_exists "$root_pid"; then
        "$KILL_CMD" "-$signal_name" "$root_pid" 2>/dev/null || true
    fi
}

terminate_child_processes() { # job-dir signal
    local job_dir="$1" signal_name="$2" child_pgid group_state=0
    process_group_state "$job_dir" || group_state=$?
    [[ "$group_state" -eq 0 ]] || return 0
    child_pgid=$(cat "$job_dir/child_pgid" 2>/dev/null || echo "")
    "$KILL_CMD" "-$signal_name" -- "-$child_pgid" 2>/dev/null || true
}

terminate_wrapper_process() { # job-dir signal
    local job_dir="$1" signal_name="$2" wrapper_pid
    wrapper_pid=$(cat "$job_dir/pid" 2>/dev/null || echo "")
    process_state "$wrapper_pid" "$job_dir/pid_identity" || return 0
    "$KILL_CMD" "-$signal_name" "$wrapper_pid" 2>/dev/null || true
}

job_targets_gone() { # job-dir
    local job_dir="$1" wrapper_pid wrapper_state=0 group_state=0
    wrapper_pid=$(cat "$job_dir/pid" 2>/dev/null || echo "")
    process_state "$wrapper_pid" "$job_dir/pid_identity" || wrapper_state=$?
    process_group_state "$job_dir" || group_state=$?
    [[ "$wrapper_state" -eq 1 && "$group_state" -eq 1 ]]
}

wait_for_targets_gone() { # job-dir max-probes
    local job_dir="$1" max_probes="$2" probe=0
    while [[ "$probe" -lt "$max_probes" ]]; do
        job_targets_gone "$job_dir" && return 0
        sleep 0.05
        probe=$((probe + 1))
    done
    job_targets_gone "$job_dir"
}

publish_terminal_completion() { # job-dir exit-code
    local job_dir="$1" code="$2" terminal_dir="$1/terminal" state=failed
    [[ "$code" == "0" ]] && state=completed
    mkdir "$terminal_dir" 2>/dev/null || return 1
    if ! atomic_write "$terminal_dir/state" "$state" \
       || ! atomic_write "$terminal_dir/exit_code" "$code" \
       || ! atomic_write "$terminal_dir/ready" 1; then
        rm -rf "$terminal_dir" 2>/dev/null || true
        return 1
    fi
}

claim_cancellation() { # job-dir
    local terminal_dir="$1/terminal" probe=0
    while ! mkdir "$terminal_dir" 2>/dev/null; do
        [[ -f "$terminal_dir/ready" ]] && return 2
        [[ "$probe" -lt 120 ]] || return 1
        sleep 0.05
        probe=$((probe + 1))
    done
}

release_terminal_claim() { # job-dir
    rm -rf "$1/terminal" 2>/dev/null || true
}

publish_cancelled_claim() { # job-dir
    local terminal_dir="$1/terminal"
    if ! atomic_write "$terminal_dir/state" cancelled \
       || ! atomic_write "$terminal_dir/ready" 1; then
        release_terminal_claim "$1"
        return 1
    fi
}

read_terminal() { # job-dir → TERMINAL_STATE / TERMINAL_CODE
    local job_dir="$1" terminal_dir="$1/terminal"
    TERMINAL_STATE=""
    TERMINAL_CODE=""
    [[ -f "$terminal_dir/ready" ]] || return 1
    TERMINAL_STATE=$(tr -d '[:space:]' < "$terminal_dir/state" 2>/dev/null || true)
    case "$TERMINAL_STATE" in
        completed|failed)
            TERMINAL_CODE=$(tr -d '[:space:]' < "$terminal_dir/exit_code" 2>/dev/null || true)
            [[ "$TERMINAL_CODE" =~ ^[0-9]+$ ]] || return 2
            [[ "$TERMINAL_STATE" != "completed" || "$TERMINAL_CODE" == "0" ]] || return 2
            [[ "$TERMINAL_STATE" != "failed" || "$TERMINAL_CODE" != "0" ]] || return 2
            ;;
        cancelled) ;;
        *) return 2 ;;
    esac
}

emit_poll_terminal() { # job-dir
    local job_dir="$1" terminal_rc raw_file tokens tail_err
    read_terminal "$job_dir"
    terminal_rc=$?
    if [[ "$terminal_rc" -ne 0 ]]; then
        [[ "$terminal_rc" -eq 1 ]] && return 1
        err "dispatch terminal record is malformed under: $job_dir/terminal"
        echo "Action: preserve the job directory for inspection and restart this role." >&2
        return 2
    fi
    case "$TERMINAL_STATE" in
        cancelled)
            jq -n --arg j "$JOB" \
                '{verdict:"cancelled", status:"cancelled", job_id:$j}'
            ;;
        completed)
            # Materialize raw output in a file. Passing a model response via
            # jq --arg exceeds ARG_MAX on realistic large reviews.
            raw_file="$job_dir/.poll-raw.$$"
            : > "$raw_file"
            tokens="null"
            case "$ENGINE" in
                claude)
                    jq -r '.result // empty' "$job_dir/out" > "$raw_file" 2>/dev/null || true
                    [[ -s "$raw_file" ]] || cp "$job_dir/out" "$raw_file"
                    tokens=$(jq -r '
                        if .usage then
                          ((.usage.input_tokens // 0) + (.usage.output_tokens // 0)
                           + (.usage.cache_read_input_tokens // 0)
                           + (.usage.cache_creation_input_tokens // 0))
                        else null end' "$job_dir/out" 2>/dev/null || echo null)
                    [[ -z "$tokens" ]] && tokens=null
                    ;;
                codex)
                    if [[ -f "$job_dir/last_message" ]]; then
                        cp "$job_dir/last_message" "$raw_file"
                    else
                        jq -rs '[.[] | objects | (.msg // .) | select(.type? == "agent_message") | .message] | last // ""' \
                            "$job_dir/out" > "$raw_file" 2>/dev/null || true
                        [[ -s "$raw_file" ]] || cp "$job_dir/out" "$raw_file"
                    fi
                    # cached_input_tokens is a subset of input_tokens.
                    tokens=$(jq -rs '
                        ([.. | objects | select(.type? == "turn.completed") | .usage
                          | ((.input_tokens // 0) + (.output_tokens // 0))] | last)
                        // ([.. | objects | (.msg // .) | select(.type? == "token_count")
                          | (.payload.info.total_token_usage.total_tokens? // .payload.total_tokens? // empty)] | last)
                        // null' "$job_dir/out" 2>/dev/null || echo null)
                    [[ -z "$tokens" ]] && tokens=null
                    ;;
                omp|*) cp "$job_dir/out" "$raw_file" ;;
            esac
            jq -n --rawfile r "$raw_file" --argjson t "${tokens:-null}" \
                '{verdict:"completed", status:"completed", raw_output:$r, tokens:$t}'
            rm -f "$raw_file"
            ;;
        failed)
            tail_err=$(tail -5 "$job_dir/err" 2>/dev/null || true)
            jq -n --arg c "$TERMINAL_CODE" --arg e "$tail_err" \
                '{verdict:"failed_terminal", status:"failed", exit_code:($c|tonumber), error_tail:$e}'
            ;;
    esac
}

emit_stop_terminal() { # job-dir
    local job_dir="$1" terminal_rc terminal_verdict
    read_terminal "$job_dir"
    terminal_rc=$?
    if [[ "$terminal_rc" -ne 0 ]]; then
        [[ "$terminal_rc" -eq 1 ]] && return 1
        err "dispatch terminal record is malformed under: $job_dir/terminal"
        echo "Action: preserve the job directory for inspection; do not signal an unauthenticated process." >&2
        return 2
    fi
    if [[ "$TERMINAL_STATE" == "cancelled" ]]; then
        jq -n --arg j "$JOB" \
            '{verdict:"cancelled", status:"cancelled", job_id:$j, stop_noop:true}'
    else
        terminal_verdict=failed_terminal
        [[ "$TERMINAL_STATE" == "completed" ]] && terminal_verdict=completed
        jq -n --arg j "$JOB" --arg s "$TERMINAL_STATE" --arg v "$terminal_verdict" \
            '{verdict:"already_finished", status:$s, terminal_verdict:$v,
              job_id:$j, stop_noop:true}'
    fi
}

emit_stop_failed() { # job-dir reason
    local job_dir="$1" reason="$2" wrapper_pid
    local wrapper_state=0 engine_state=0 wrapper_state_name engine_state_name
    local wrapper_alive=false engine_alive=false
    wrapper_pid=$(cat "$job_dir/pid" 2>/dev/null || echo "")
    process_state "$wrapper_pid" "$job_dir/pid_identity" || wrapper_state=$?
    process_group_state "$job_dir" || engine_state=$?
    case "$wrapper_state" in
        0) wrapper_state_name=alive; wrapper_alive=true ;;
        1) wrapper_state_name=gone ;;
        *) wrapper_state_name=unverifiable ;;
    esac
    case "$engine_state" in
        0) engine_state_name=alive; engine_alive=true ;;
        1) engine_state_name=gone ;;
        *) engine_state_name=unverifiable ;;
    esac
    err "could not verify dispatch cancellation for job '$JOB': $reason"
    echo "Action: inspect the authenticated wrapper/engine process group; do not retry as if cancellation succeeded." >&2
    jq -n --arg j "$JOB" --arg r "$reason" \
        --arg ws "$wrapper_state_name" --arg es "$engine_state_name" \
        --argjson w "$wrapper_alive" --argjson e "$engine_alive" \
        '{verdict:"stop_failed", status:"stop_failed", job_id:$j, reason:$r,
          wrapper_alive:$w, engine_alive:$e, wrapper_state:$ws, engine_state:$es}'
}

case "$SUB" in

# ---------------------------------------------------------------- start
start)
    require_jq
    [[ -n "$ENGINE" && -n "$PROMPT_FILE" && -n "$SCRATCH" ]] \
        || die_usage "start requires --engine, --prompt-file, and --scratch-dir"
    if [[ ! -f "$PROMPT_FILE" ]]; then
        err "prompt file not found: $PROMPT_FILE"
        echo "Action: verify --prompt-file points to a readable prompt created before dispatch." >&2
        exit 1
    fi
    require_engine

    job_id="ad_$(date +%Y%m%dT%H%M%SZ)_$$_$RANDOM"
    dir="$SCRATCH/$job_id"
    if ! mkdir -p "$dir"; then
        err "cannot create dispatch job directory: $dir"
        echo "Action: verify --scratch-dir exists on a writable filesystem." >&2
        exit 1
    fi
    if ! atomic_copy "$PROMPT_FILE" "$dir/prompt.md" \
       || ! atomic_write "$dir/engine" "$ENGINE" \
       || ! atomic_write "$dir/model" "$MODEL" \
       || ! atomic_write "$dir/effort" "$EFFORT" \
       || ! atomic_write "$dir/started_epoch" "$(date +%s)"; then
        rm -rf -- "$dir" 2>/dev/null || true
        err "cannot initialize dispatch job files under: $dir"
        echo "Action: verify --scratch-dir is writable and has free space." >&2
        exit 1
    fi

    prompt_mode=stdin
    case "$ENGINE" in
        claude)
            args=(claude -p --output-format json)
            if [[ "$WRITE" == "1" ]]; then
                args+=(--permission-mode acceptEdits --allowedTools Bash)
            else
                args+=(--permission-mode plan)
            fi
            [[ -n "$MODEL" ]] && args+=(--model "$MODEL")
            ;;
        codex)
            sandbox=read-only
            [[ "$WRITE" == "1" ]] && sandbox=workspace-write
            args=(codex exec - --sandbox "$sandbox" --json --skip-git-repo-check -o "$dir/last_message")
            [[ -n "$MODEL" ]] && args+=(--model "$MODEL")
            [[ -n "$EFFORT" ]] && args+=(-c "model_reasoning_effort=\"$EFFORT\"")
            ;;
        omp)
            prompt_mode=file-argument
            args=(omp -p)
            if [[ "$WRITE" == "1" ]]; then
                args+=(--approval-mode yolo)
            else
                args+=(--approval-mode always-ask)
            fi
            [[ -n "$MODEL" ]] && args+=(--model "$MODEL")
            [[ -n "$EFFORT" ]] && args+=(--thinking "$EFFORT")
            ;;
    esac

    (
        child_pid=""
        group_supervisor() {
            local engine_pid code=1 wait_rc
            set +m
            # TERM is delivered to the whole group. The supervisor ignores it
            # so its authenticated PID remains the ownership anchor while the
            # engine and any descendants drain.
            trap ':' TERM INT HUP
            if [[ "$prompt_mode" == "file-argument" ]]; then
                "${args[@]}" "@$dir/prompt.md" > "$dir/out" 2> "$dir/err" &
            else
                "${args[@]}" < "$dir/prompt.md" > "$dir/out" 2> "$dir/err" &
            fi
            engine_pid=$!
            while :; do
                wait "$engine_pid"
                wait_rc=$?
                if ! kill -0 "$engine_pid" >/dev/null 2>&1; then
                    code=$wait_rc
                    break
                fi
            done
            atomic_write "$dir/engine_exit_code" "$code" || exit 1
            IFS= read -r < "$dir/group_release" || true
            trap - TERM INT HUP
            exit "$code"
        }
        release_group_supervisor_when_drained() {
            local child_state other_state
            while :; do
                child_state=0
                process_state "$child_pid" "$dir/child_identity" || child_state=$?
                [[ "$child_state" -eq 1 ]] && return 0
                if [[ "$child_state" -eq 0 ]]; then
                    other_state=0
                    process_group_contains_other "$child_pid" "$child_pid" || other_state=$?
                    if [[ "$other_state" -eq 1 ]]; then
                        printf 'release\n' > "$dir/group_release"
                        return 0
                    fi
                fi
                sleep 0.05
            done
        }
        forward_signal() {
            trap - TERM INT HUP
            terminate_child_processes "$dir" TERM
            if [[ -n "$child_pid" ]]; then
                release_group_supervisor_when_drained
                wait "$child_pid" 2>/dev/null || true
            fi
            publish_terminal_completion "$dir" 143 || true
            exit 143
        }
        trap forward_signal TERM INT HUP

        if ! mkfifo "$dir/group_release"; then
            exit 1
        fi
        # Bash 3.2 job control gives this dedicated supervisor a fresh process
        # group without relying on a platform-specific setsid executable.
        set -m
        group_supervisor &
        child_pid=$!
        set +m
        atomic_write "$dir/child_pid" "$child_pid" || {
            "$KILL_CMD" -KILL -- "-$child_pid" 2>/dev/null || true
            exit 1
        }
        atomic_write "$dir/child_pgid" "$child_pid" || {
            "$KILL_CMD" -KILL -- "-$child_pid" 2>/dev/null || true
            exit 1
        }
        atomic_write "$dir/child_group" "v1|$child_pid|$child_pid" || {
            "$KILL_CMD" -KILL -- "-$child_pid" 2>/dev/null || true
            exit 1
        }
        child_identity=""
        identity_attempt=0
        while [[ -z "$child_identity" ]] && pid_exists "$child_pid" \
              && [[ "$identity_attempt" -lt 100 ]]; do
            child_identity=$(process_identity "$child_pid")
            [[ -n "$child_identity" ]] || sleep 0.05
            identity_attempt=$((identity_attempt + 1))
        done
        if pid_exists "$child_pid" && [[ -z "$child_identity" ]]; then
            "$KILL_CMD" -KILL -- "-$child_pid" 2>/dev/null || true
            exit 1
        fi
        if [[ -n "$child_identity" ]]; then
            child_identity=$(encode_process_identity "$child_pid" "$child_identity") || {
                "$KILL_CMD" -KILL -- "-$child_pid" 2>/dev/null || true
                exit 1
            }
        fi
        atomic_write "$dir/child_identity" "$child_identity" || {
            "$KILL_CMD" -KILL -- "-$child_pid" 2>/dev/null || true
            exit 1
        }
        # The parent must not expose job_id until this sentinel exists.
        # stop can now safely authenticate and signal the engine process group.
        atomic_write "$dir/ready" 1 || {
            "$KILL_CMD" -KILL -- "-$child_pid" 2>/dev/null || true
            exit 1
        }
        while [[ ! -f "$dir/engine_exit_code" ]]; do
            child_state=0
            process_state "$child_pid" "$dir/child_identity" || child_state=$?
            [[ "$child_state" -eq 1 ]] && break
            sleep 0.05
        done
        code=$(cat "$dir/engine_exit_code" 2>/dev/null || echo 1)
        [[ "$code" =~ ^[0-9]+$ && "$code" -le 255 ]] || code=1
        release_group_supervisor_when_drained
        wait "$child_pid" 2>/dev/null || true
        while :; do
            group_state=0
            process_group_state "$dir" || group_state=$?
            [[ "$group_state" -eq 1 ]] && break
            sleep 0.05
        done
        trap - TERM INT HUP
        publish_terminal_completion "$dir" "$code" || true
        exit "$code"
    ) >/dev/null 2>&1 &
    pid=$!
    if ! atomic_write "$dir/pid" "$pid"; then
        terminate_pid_tree "$pid" TERM
        err "cannot persist dispatch wrapper PID under: $dir"
        echo "Action: verify --scratch-dir remains writable and has free space." >&2
        exit 1
    fi
    pid_identity=""
    identity_attempt=0
    while [[ -z "$pid_identity" ]] && pid_exists "$pid" \
          && [[ "$identity_attempt" -lt 100 ]]; do
        pid_identity=$(process_identity "$pid")
        [[ -n "$pid_identity" ]] || sleep 0.05
        identity_attempt=$((identity_attempt + 1))
    done
    if [[ -z "$pid_identity" ]]; then
        # A fast engine may complete and be reaped before ps can identify the
        # wrapper. The startup and terminal sentinels prove no live process
        # remains for stop to authenticate.
        if [[ ! -f "$dir/ready" || ! -f "$dir/terminal/ready" ]]; then
            terminate_pid_tree "$pid" TERM
            err "cannot persist dispatch wrapper identity under: $dir"
            echo "Action: inspect process permissions and verify --scratch-dir remains writable." >&2
            exit 1
        fi
    else
        pid_identity=$(encode_process_identity "$pid" "$pid_identity") || {
            terminate_pid_tree "$pid" TERM
            err "cannot encode dispatch wrapper identity for PID $pid"
            echo "Action: inspect process metadata and retry this role dispatch." >&2
            exit 1
        }
        if ! atomic_write "$dir/pid_identity" "$pid_identity"; then
            terminate_pid_tree "$pid" TERM
            err "cannot persist dispatch wrapper identity under: $dir"
            echo "Action: inspect process permissions and verify --scratch-dir remains writable." >&2
            exit 1
        fi
    fi

    ready_deadline=$(( $(date +%s) + 10 ))
    while [[ ! -f "$dir/ready" ]]; do
        if ! pid_exists "$pid"; then
            err "engine process failed before dispatch startup completed"
            echo "Action: inspect $dir/err, then retry this role dispatch." >&2
            exit 1
        fi
        if [[ $(date +%s) -ge "$ready_deadline" ]]; then
            terminate_pid_tree "$pid" TERM
            err "engine process did not complete its startup handshake"
            echo "Action: inspect $dir/err and process permissions, then retry." >&2
            exit 1
        fi
        sleep 0.05
    done

    jq -n --arg j "$job_id" --argjson p "$pid" --arg o "$dir/out" \
        '{job_id:$j, pid:$p, out_file:$o}'
    ;;

# ---------------------------------------------------------------- poll
poll)
    [[ -n "$JOB" && -n "$SCRATCH" ]] \
        || die_usage "poll requires --job and --scratch-dir"
    normalize_nonnegative_integer --stall-threshold-sec "$STALL"
    STALL="$NORMALIZED_INTEGER"
    normalize_nonnegative_integer --wall-clock-ceiling-sec "$CEILING"
    CEILING="$NORMALIZED_INTEGER"
    require_jq
    require_job_id
    dir=$(job_dir)
    if [[ ! -d "$dir" ]]; then
        err "no job dir $dir"
        echo "Action: verify the job was started with this --scratch-dir and use its returned job_id." >&2
        exit 1
    fi
    ENGINE=$(cat "$dir/engine" 2>/dev/null || echo "")
    pid=$(cat "$dir/pid" 2>/dev/null || echo "")
    if emit_poll_terminal "$dir"; then
        exit 0
    else
        terminal_rc=$?
        [[ "$terminal_rc" -eq 2 ]] && exit 1
    fi

    now=$(date +%s)
    started=$(cat "$dir/started_epoch" 2>/dev/null || echo "$now")
    [[ "$started" =~ ^[0-9]+$ ]] || started="$now"
    elapsed=$(( now - started ))

    wrapper_state=0
    process_state "$pid" "$dir/pid_identity" || wrapper_state=$?
    if [[ "$wrapper_state" -eq 0 ]]; then
        if [[ "$elapsed" -gt "$CEILING" ]]; then
            jq -n --argjson e "$elapsed" \
                '{verdict:"wall_clock_exceeded", status:"running", elapsed_sec:$e}'
            exit 0
        fi
        # Codex emits streaming JSONL. Claude and omp print only a final
        # response, so an old/empty output file is not evidence that they
        # stalled; their wall-clock ceiling remains the watchdog.
        if [[ "$ENGINE" == "codex" && -f "$dir/out" ]]; then
            # GNU-first order: GNU -c errors on BSD and falls through to -f.
            out_mtime=$(stat -c %Y "$dir/out" 2>/dev/null || stat -f %m "$dir/out" 2>/dev/null || echo "$now")
            err_mtime=$(stat -c %Y "$dir/err" 2>/dev/null || stat -f %m "$dir/err" 2>/dev/null || echo "$out_mtime")
            [[ "$err_mtime" -gt "$out_mtime" ]] && out_mtime="$err_mtime"
            age=$(( now - out_mtime ))
            if [[ "$age" -gt "$STALL" ]]; then
                jq -n --argjson a "$age" \
                    '{verdict:"stalled_suspect", status:"running", output_age_sec:$a}'
                exit 0
            fi
        fi
        jq -n --argjson e "$elapsed" \
            '{verdict:"alive", status:"running", elapsed_sec:$e}'
        exit 0
    fi

    # Completion can commit between the initial terminal read and the wrapper
    # state observation. Decode again before acting on any non-live wrapper.
    if emit_poll_terminal "$dir"; then
        exit 0
    else
        terminal_rc=$?
        [[ "$terminal_rc" -eq 2 ]] && exit 1
    fi

    if [[ "$wrapper_state" -eq 2 ]]; then
        if [[ "$elapsed" -gt "$CEILING" ]]; then
            jq -n --argjson e "$elapsed" \
                '{verdict:"wall_clock_exceeded", status:"running", elapsed_sec:$e,
                  process_verification:"unverifiable"}'
        else
            jq -n --argjson e "$elapsed" \
                '{verdict:"alive", status:"running", elapsed_sec:$e,
                  process_verification:"unverifiable"}'
        fi
        exit 0
    fi

    group_state=0
    process_group_state "$dir" || group_state=$?
    if [[ "$group_state" -ne 1 ]]; then
        engine_state=alive
        [[ "$group_state" -eq 2 ]] && engine_state=unverifiable
        if [[ "$elapsed" -gt "$CEILING" ]]; then
            jq -n --argjson e "$elapsed" --arg es "$engine_state" \
                '{verdict:"wall_clock_exceeded", status:"running", elapsed_sec:$e,
                  wrapper_state:"dead", engine_state:$es}'
        else
            jq -n --argjson e "$elapsed" --arg es "$engine_state" \
                '{verdict:"alive", status:"running", elapsed_sec:$e,
                  wrapper_state:"dead", engine_state:$es}'
        fi
        exit 0
    fi

    # Both tracked processes are verified gone, but completion may have
    # committed during those observations. Re-decode before classifying the
    # missing terminal record, closing that check/use race.
    if emit_poll_terminal "$dir"; then
        exit 0
    else
        terminal_rc=$?
        [[ "$terminal_rc" -eq 2 ]] && exit 1
    fi
    # No writer won despite both tracked processes being verified gone. Seal
    # this synthetic failure with the same exclusive terminal claim so future
    # polls/stops cannot rewrite an already-observed terminal outcome.
    if publish_terminal_completion "$dir" 255; then
        emit_poll_terminal "$dir"
        exit $?
    fi
    # A completion or cancellation writer may have claimed between the
    # recheck above and our synthetic failure claim.
    if emit_poll_terminal "$dir"; then
        exit 0
    else
        terminal_rc=$?
        [[ "$terminal_rc" -eq 2 ]] && exit 1
    fi
    if [[ -d "$dir/terminal" && ! -f "$dir/terminal/ready" ]]; then
        jq -n '{verdict:"alive", status:"running", terminal_transition:"pending"}'
        exit 0
    fi

    tail_err=$(tail -5 "$dir/err" 2>/dev/null || true)
    jq -n --arg e "$tail_err" \
        '{verdict:"failed_terminal", status:"failed", error_tail:("process died and terminal failure could not be persisted; " + $e)}'
    ;;

# ---------------------------------------------------------------- stop
stop)
    require_jq
    [[ -n "$JOB" && -n "$SCRATCH" ]] \
        || die_usage "stop requires --job and --scratch-dir"
    require_job_id
    dir=$(job_dir)
    if [[ ! -d "$dir" ]]; then
        err "no job dir $dir"
        echo "Action: verify the job was started with this --scratch-dir and use its returned job_id." >&2
        exit 1
    fi
    if emit_stop_terminal "$dir"; then
        exit 0
    else
        terminal_rc=$?
        [[ "$terminal_rc" -eq 2 ]] && exit 1
    fi

    if claim_cancellation "$dir"; then
        :
    else
        claim_rc=$?
        if [[ "$claim_rc" -eq 2 ]] && emit_stop_terminal "$dir"; then
            exit 0
        fi
        emit_stop_failed "$dir" "terminal state is already being claimed"
        exit 1
    fi

    # Cancellation owns the terminal-state claim before signalling. Every
    # signal is identity-authenticated; every phase is condition-checked.
    terminate_child_processes "$dir" TERM
    terminate_wrapper_process "$dir" TERM
    if ! wait_for_targets_gone "$dir" 40; then
        terminate_child_processes "$dir" KILL
        terminate_wrapper_process "$dir" KILL
        if ! wait_for_targets_gone "$dir" 40; then
            release_terminal_claim "$dir"
            emit_stop_failed "$dir" "wrapper or engine remained alive or could not be verified gone after TERM and KILL"
            exit 1
        fi
    fi

    if ! publish_cancelled_claim "$dir"; then
        emit_stop_failed "$dir" "terminal cancellation record could not be persisted"
        exit 1
    fi
    jq -n --arg j "$JOB" '{verdict:"cancelled", status:"cancelled", job_id:$j}'
    ;;

*) die_usage "unknown subcommand '$SUB'" ;;
esac
