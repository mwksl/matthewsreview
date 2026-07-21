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
# started_epoch,out,err,last_message,exit_code,cancelled,prompt.md}
#
# Subcommands:
#   start --engine <claude|codex|omp> --model <m> [--effort <e>]
#         (`<e>` = codex effort or omp thinking level)
#         --prompt-file <abs> --scratch-dir <abs> [--write]
#     → stdout {"job_id","pid","out_file"}
#   poll --job <id> --scratch-dir <abs>
#        [--stall-threshold-sec N (90)] [--wall-clock-ceiling-sec N (600)]
#     → stdout one verdict object (mirrors codex-poll.sh vocabulary):
#       {"verdict":"completed","status":"completed","raw_output":"...","tokens":N|null}
#       {"verdict":"failed_terminal","status":"failed","error_tail":"..."}
#       {"verdict":"alive","status":"running"}
#       {"verdict":"stalled_suspect","status":"running"}
#       {"verdict":"wall_clock_exceeded","status":"running"}
#   stop --job <id> --scratch-dir <abs>
#     → kills the job pid (TERM, then KILL after 2s), marks cancelled.
#
# Caller branches on `verdict` exactly as with codex-poll.sh:
#   alive | stalled_suspect → keep polling
#   completed               → consume raw_output/tokens
#   failed_terminal | wall_clock_exceeded → retry / drop per fragment policy
#
# Exit codes (bin/_common.py conventions): 0 OK, 1 validation, 5 missing-dep
# (engine CLI not on PATH), 64 usage.
set -u
umask 077

PROG=agent-dispatch.sh

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
    ps -o lstart= -p "$1" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

process_matches() { # pid identity-file
    local candidate="$1" identity_file="$2" recorded current
    [[ "$candidate" =~ ^[0-9]+$ && -f "$identity_file" ]] || return 1
    recorded=$(cat "$identity_file" 2>/dev/null || echo "")
    current=$(process_identity "$candidate")
    [[ -n "$recorded" && "$current" == "$recorded" ]]
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

require_engine() { # validates engine + CLI presence
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
}

terminate_pid_tree() { # root-pid signal
    local root_pid="$1" signal_name="$2" child
    for child in $(ps -axo pid=,ppid= 2>/dev/null \
        | awk -v parent="$root_pid" '$2 == parent { print $1 }'); do
        terminate_pid_tree "$child" "$signal_name"
    done
    if kill -0 "$root_pid" 2>/dev/null; then
        kill "-$signal_name" "$root_pid" 2>/dev/null || true
    fi
}
terminate_child_processes() { # job-dir signal
    local job_dir="$1" signal_name="$2" child_pid child_pgid
    child_pid=$(cat "$job_dir/child_pid" 2>/dev/null || echo "")
    child_pgid=$(cat "$job_dir/child_pgid" 2>/dev/null || echo "")
    process_matches "$child_pid" "$job_dir/child_identity" || return 0
    if [[ "$child_pgid" =~ ^[0-9]+$ ]] && [[ "$child_pgid" -gt 1 ]]; then
        kill "-$signal_name" -- "-$child_pgid" 2>/dev/null || true
    else
        terminate_pid_tree "$child_pid" "$signal_name"
    fi
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
                args+=(--permission-mode acceptEdits)
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
                args+=(--approval-mode write)
            fi
            [[ -n "$MODEL" ]] && args+=(--model "$MODEL")
            [[ -n "$EFFORT" ]] && args+=(--thinking "$EFFORT")
            ;;
    esac

    (
        child_pid=""
        forward_signal() {
            trap - TERM INT HUP
            terminate_child_processes "$dir" TERM
            atomic_write "$dir/exit_code" 143
            exit 143
        }
        trap forward_signal TERM INT HUP

        if command -v setsid >/dev/null 2>&1; then
            if [[ "$prompt_mode" == "file-argument" ]]; then
                setsid "${args[@]}" "@$dir/prompt.md" > "$dir/out" 2> "$dir/err" &
            else
                setsid "${args[@]}" < "$dir/prompt.md" > "$dir/out" 2> "$dir/err" &
            fi
            child_pid=$!
            atomic_write "$dir/child_pgid" "$child_pid" || {
                terminate_pid_tree "$child_pid" TERM
                exit 1
            }
        else
            if [[ "$prompt_mode" == "file-argument" ]]; then
                "${args[@]}" "@$dir/prompt.md" > "$dir/out" 2> "$dir/err" &
            else
                "${args[@]}" < "$dir/prompt.md" > "$dir/out" 2> "$dir/err" &
            fi
            child_pid=$!
        fi
        atomic_write "$dir/child_pid" "$child_pid" || {
            terminate_pid_tree "$child_pid" TERM
            exit 1
        }
        child_identity=""
        identity_attempt=0
        while [[ -z "$child_identity" ]] && kill -0 "$child_pid" 2>/dev/null \
              && [[ "$identity_attempt" -lt 100 ]]; do
            child_identity=$(process_identity "$child_pid")
            [[ -n "$child_identity" ]] || sleep 0.05
            identity_attempt=$((identity_attempt + 1))
        done
        if kill -0 "$child_pid" 2>/dev/null && [[ -z "$child_identity" ]]; then
            terminate_pid_tree "$child_pid" TERM
            exit 1
        fi
        atomic_write "$dir/child_identity" "$child_identity" || {
            terminate_pid_tree "$child_pid" TERM
            exit 1
        }
        # The parent must not expose job_id until this sentinel exists.
        # stop can now safely authenticate and signal the actual engine.
        atomic_write "$dir/ready" 1 || {
            terminate_pid_tree "$child_pid" TERM
            exit 1
        }
        wait "$child_pid"
        code=$?
        trap - TERM INT HUP
        atomic_write "$dir/exit_code" "$code"
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
    while [[ -z "$pid_identity" ]] && kill -0 "$pid" 2>/dev/null \
          && [[ "$identity_attempt" -lt 100 ]]; do
        pid_identity=$(process_identity "$pid")
        [[ -n "$pid_identity" ]] || sleep 0.05
        identity_attempt=$((identity_attempt + 1))
    done
    if [[ -z "$pid_identity" ]] \
       || ! atomic_write "$dir/pid_identity" "$pid_identity"; then
        terminate_pid_tree "$pid" TERM
        err "cannot persist dispatch wrapper identity under: $dir"
        echo "Action: inspect process permissions and verify --scratch-dir remains writable." >&2
        exit 1
    fi

    ready_deadline=$(( $(date +%s) + 10 ))
    while [[ ! -f "$dir/ready" ]]; do
        if ! kill -0 "$pid" 2>/dev/null; then
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
    require_jq
    [[ -n "$JOB" && -n "$SCRATCH" ]] \
        || die_usage "poll requires --job and --scratch-dir"
    require_job_id
    dir=$(job_dir)
    if [[ ! -d "$dir" ]]; then
        err "no job dir $dir"
        echo "Action: verify the job was started with this --scratch-dir and use its returned job_id." >&2
        exit 1
    fi
    ENGINE=$(cat "$dir/engine" 2>/dev/null || echo "")
    pid=$(cat "$dir/pid" 2>/dev/null || echo "")
    if [[ -f "$dir/cancelled" ]]; then
        jq -n --arg j "$JOB" '{verdict:"cancelled", status:"cancelled", job_id:$j}'
        exit 0
    fi

    if [[ -f "$dir/exit_code" ]]; then
        code=$(tr -d '[:space:]' < "$dir/exit_code")
        if [[ "$code" == "0" ]]; then
            # Materialize raw output in a file. Passing a model response via
            # jq --arg exceeds ARG_MAX on realistic large reviews.
            raw_file="$dir/.poll-raw.$$"
            tokens="null"
            case "$ENGINE" in
                claude)
                    jq -r '.result // empty' "$dir/out" > "$raw_file" 2>/dev/null || true
                    [[ -s "$raw_file" ]] || cp "$dir/out" "$raw_file"
                    tokens=$(jq -r '
                        if .usage then
                          ((.usage.input_tokens // 0) + (.usage.output_tokens // 0)
                           + (.usage.cache_read_input_tokens // 0)
                           + (.usage.cache_creation_input_tokens // 0))
                        else null end' "$dir/out" 2>/dev/null || echo null)
                    [[ -z "$tokens" ]] && tokens=null
                    ;;
                codex)
                    if [[ -f "$dir/last_message" ]]; then
                        cp "$dir/last_message" "$raw_file"
                    else
                        jq -rs '[.[] | objects | (.msg // .) | select(.type? == "agent_message") | .message] | last // ""' \
                            "$dir/out" > "$raw_file" 2>/dev/null || true
                        [[ -s "$raw_file" ]] || cp "$dir/out" "$raw_file"
                    fi
                    # Real codex exec JSONL (verified on CLI 0.145.x): terminal
                    # {"type":"turn.completed","usage":{input_tokens,
                    # cached_input_tokens, output_tokens, ...}}. cached is a
                    # SUBSET of input — don't add it. Legacy token_count
                    # shape kept as fallback.
                    tokens=$(jq -rs '
                        ([.. | objects | select(.type? == "turn.completed") | .usage
                          | ((.input_tokens // 0) + (.output_tokens // 0))] | last)
                        // ([.. | objects | (.msg // .) | select(.type? == "token_count")
                          | (.payload.info.total_token_usage.total_tokens? // .payload.total_tokens? // empty)] | last)
                        // null' "$dir/out" 2>/dev/null || echo null)
                    [[ -z "$tokens" ]] && tokens=null
                    ;;
                omp|*)
                    cp "$dir/out" "$raw_file"
                    ;;
            esac
            jq -n --rawfile r "$raw_file" --argjson t "${tokens:-null}" \
                '{verdict:"completed", status:"completed", raw_output:$r, tokens:$t}'
            rm -f "$raw_file"
        else
            tail_err=$(tail -5 "$dir/err" 2>/dev/null || true)
            jq -n --arg c "$code" --arg e "$tail_err" \
                '{verdict:"failed_terminal", status:"failed", exit_code:($c|tonumber), error_tail:$e}'
        fi
        exit 0
    fi

    if process_matches "$pid" "$dir/pid_identity" && kill -0 "$pid" 2>/dev/null; then
        now=$(date +%s)
        started=$(cat "$dir/started_epoch" 2>/dev/null || echo "$now")
        elapsed=$(( now - started ))
        if [[ "$elapsed" -gt "$CEILING" ]]; then
            jq -n --argjson e "$elapsed" '{verdict:"wall_clock_exceeded", status:"running", elapsed_sec:$e}'
            exit 0
        fi
        # Codex emits streaming JSONL. Claude and omp print only a final
        # response, so an old/empty output file is not evidence that they
        # stalled; their wall-clock ceiling remains the watchdog.
        if [[ "$ENGINE" == "codex" && -f "$dir/out" ]]; then
            # GNU-first order (codex-poll.sh:184 precedent): GNU -c errors on
            # BSD and falls through to -f.
            out_mtime=$(stat -c %Y "$dir/out" 2>/dev/null || stat -f %m "$dir/out" 2>/dev/null || echo "$now")
            err_mtime=$(stat -c %Y "$dir/err" 2>/dev/null || stat -f %m "$dir/err" 2>/dev/null || echo "$out_mtime")
            [[ "$err_mtime" -gt "$out_mtime" ]] && out_mtime="$err_mtime"
            age=$(( now - out_mtime ))
            if [[ "$age" -gt "$STALL" ]]; then
                jq -n --argjson a "$age" '{verdict:"stalled_suspect", status:"running", output_age_sec:$a}'
                exit 0
            fi
        fi
        jq -n --argjson e "$elapsed" '{verdict:"alive", status:"running", elapsed_sec:$e}'
        exit 0
    fi

    tail_err=$(tail -5 "$dir/err" 2>/dev/null || true)
    jq -n --arg e "$tail_err" \
        '{verdict:"failed_terminal", status:"failed", error_tail:("process died without exit record; " + $e)}'
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
    if [[ -f "$dir/exit_code" ]]; then
        jq -n --arg j "$JOB" \
            '{verdict:"already_finished", status:"completed", job_id:$j, stop_noop:true}'
        exit 0
    fi
    pid=$(cat "$dir/pid" 2>/dev/null || echo "")
    atomic_write "$dir/cancelled" "$(date +%s)"
    terminate_child_processes "$dir" TERM
    if process_matches "$pid" "$dir/pid_identity" && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
    fi
    sleep 2
    terminate_child_processes "$dir" KILL
    if process_matches "$pid" "$dir/pid_identity" && kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null || true
    fi
    jq -n --arg j "$JOB" '{verdict:"cancelled", status:"cancelled", job_id:$j}'
    ;;

*) die_usage "unknown subcommand '$SUB'" ;;
esac
