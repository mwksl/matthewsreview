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

PROG=agent-dispatch.sh

usage() { cat >&2 <<USAGE
Usage:
  $PROG start --engine <claude|codex|omp> --model <m> [--effort <codex-effort|omp-thinking>] --prompt-file <abs> --scratch-dir <abs> [--write]
  $PROG poll  --job <id> --scratch-dir <abs> [--stall-threshold-sec N] [--wall-clock-ceiling-sec N]
  $PROG stop  --job <id> --scratch-dir <abs>
USAGE
exit 64
}

err() { echo "ERROR: $1" >&2; }
require_value() {
    [[ $# -ge 2 ]] || { err "$1 requires a value"; usage; }
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
    printf '%s\n' "$value" > "$tmp"
    mv "$tmp" "$path"
}

SUB="${1:-}"
[[ $# -ge 1 ]] || usage
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
        *) err "unknown argument: $1"; usage ;;
    esac
done

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

case "$SUB" in

# ---------------------------------------------------------------- start
start)
    require_jq
    [[ -n "$ENGINE" && -n "$PROMPT_FILE" && -n "$SCRATCH" ]] || usage
    if [[ ! -f "$PROMPT_FILE" ]]; then
        err "prompt file not found: $PROMPT_FILE"
        echo "Action: verify --prompt-file points to a readable prompt created before dispatch." >&2
        exit 1
    fi
    require_engine

    job_id="ad_$(date +%Y%m%dT%H%M%SZ)_$$_$RANDOM"
    dir="$SCRATCH/$job_id"
    mkdir -p "$dir"
    cp "$PROMPT_FILE" "$dir/prompt.md"
    printf '%s' "$ENGINE" > "$dir/engine"
    printf '%s' "$MODEL" > "$dir/model"
    printf '%s' "$EFFORT" > "$dir/effort"
    date +%s > "$dir/started_epoch"

    prompt_mode=stdin
    case "$ENGINE" in
        claude)
            args=(claude -p --output-format json)
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
            [[ -n "$MODEL" ]] && args+=(--model "$MODEL")
            [[ -n "$EFFORT" ]] && args+=(--thinking "$EFFORT")
            ;;
    esac

    (
        child_pid=""
        forward_signal() {
            trap - TERM INT HUP
            if [[ -n "$child_pid" ]] && kill -0 "$child_pid" 2>/dev/null; then
                kill "$child_pid" 2>/dev/null || true
            fi
            atomic_write "$dir/exit_code" 143
            exit 143
        }
        trap forward_signal TERM INT HUP

        if [[ "$prompt_mode" == "file-argument" ]]; then
            "${args[@]}" "@$dir/prompt.md" > "$dir/out" 2> "$dir/err" &
        else
            "${args[@]}" < "$dir/prompt.md" > "$dir/out" 2> "$dir/err" &
        fi
        child_pid=$!
        atomic_write "$dir/child_pid" "$child_pid"
        wait "$child_pid"
        code=$?
        trap - TERM INT HUP
        atomic_write "$dir/exit_code" "$code"
        exit "$code"
    ) >/dev/null 2>&1 &
    pid=$!
    atomic_write "$dir/pid" "$pid"

    jq -n --arg j "$job_id" --argjson p "$pid" --arg o "$dir/out" \
        '{job_id:$j, pid:$p, out_file:$o}'
    ;;

# ---------------------------------------------------------------- poll
poll)
    require_jq
    [[ -n "$JOB" && -n "$SCRATCH" ]] || usage
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
            # extract raw_output + tokens per engine
            raw="" tokens="null"
            case "$ENGINE" in
                claude)
                    raw=$(jq -r '.result // empty' "$dir/out" 2>/dev/null)
                    [[ -z "$raw" ]] && raw=$(cat "$dir/out")
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
                        raw=$(cat "$dir/last_message")
                    else
                        raw=$(jq -rs '[.[] | objects | (.msg // .) | select(.type? == "agent_message") | .message] | last // ""' "$dir/out" 2>/dev/null)
                        [[ -z "$raw" ]] && raw=$(cat "$dir/out")
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
                    raw=$(cat "$dir/out")
                    ;;
            esac
            jq -n --arg r "$raw" --argjson t "${tokens:-null}" \
                '{verdict:"completed", status:"completed", raw_output:$r, tokens:$t}'
        else
            tail_err=$(tail -5 "$dir/err" 2>/dev/null || true)
            jq -n --arg c "$code" --arg e "$tail_err" \
                '{verdict:"failed_terminal", status:"failed", exit_code:($c|tonumber), error_tail:$e}'
        fi
        exit 0
    fi

    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        now=$(date +%s)
        started=$(cat "$dir/started_epoch" 2>/dev/null || echo "$now")
        elapsed=$(( now - started ))
        if [[ "$elapsed" -gt "$CEILING" ]]; then
            jq -n --argjson e "$elapsed" '{verdict:"wall_clock_exceeded", status:"running", elapsed_sec:$e}'
            exit 0
        fi
        if [[ -f "$dir/out" ]]; then
            # GNU-first order (codex-poll.sh:184 precedent): GNU -c errors on
            # BSD and falls through to -f; BSD -f would "succeed" with
            # filesystem-info garbage on GNU if tried first.
            mtime=$(stat -c %Y "$dir/out" 2>/dev/null || stat -f %m "$dir/out" 2>/dev/null || echo "$now")
            age=$(( now - mtime ))
            if [[ "$age" -gt "$STALL" ]]; then
                jq -n --argjson a "$age" '{verdict:"stalled_suspect", status:"running", out_mtime_age_sec:$a}'
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
    [[ -n "$JOB" && -n "$SCRATCH" ]] || usage
    dir=$(job_dir)
    if [[ ! -d "$dir" ]]; then
        err "no job dir $dir"
        echo "Action: verify the job was started with this --scratch-dir and use its returned job_id." >&2
        exit 1
    fi
    pid=$(cat "$dir/pid" 2>/dev/null || echo "")
    child_pid=$(cat "$dir/child_pid" 2>/dev/null || echo "")
    atomic_write "$dir/cancelled" "$(date +%s)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
    fi
    if [[ -n "$child_pid" ]] && kill -0 "$child_pid" 2>/dev/null; then
        kill "$child_pid" 2>/dev/null || true
    fi
    sleep 2
    if [[ -n "$child_pid" ]] && kill -0 "$child_pid" 2>/dev/null; then
        kill -9 "$child_pid" 2>/dev/null || true
    fi
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        kill -9 "$pid" 2>/dev/null || true
    fi
    jq -n --arg j "$JOB" '{verdict:"cancelled", status:"cancelled", job_id:$j}'
    ;;

*) usage ;;
esac
