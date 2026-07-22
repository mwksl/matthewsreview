#!/usr/bin/env bash
# dep-check.sh — SessionStart hook: warn if the environment isn't ready.
# Soft warning only — never fails the session. Thin wrapper over
# bin/doctor.sh --quiet (WARN/FAIL lines only); the plugin runtime puts
# bin/ on $PATH so the bare name resolves.

# Claude Code supplies the active session metadata as SessionStart JSON on
# stdin. Persist the exact transcript path so token tallying never needs to
# scan sibling sessions in ~/.claude/projects/<cwd-slug>/.
hook_input=$(cat 2>/dev/null || true)
if [[ -n "${CLAUDE_ENV_FILE:-}" && -n "$hook_input" ]] \
   && command -v jq >/dev/null 2>&1; then
  session_id=$(printf '%s' "$hook_input" | jq -r '.session_id // empty' 2>/dev/null || true)
  transcript_path=$(printf '%s' "$hook_input" | jq -r '.transcript_path // empty' 2>/dev/null || true)
  if [[ -n "$session_id" ]]; then
    printf 'export MATTHEWS_REVIEW_SESSION_ID=%q\n' "$session_id" >> "$CLAUDE_ENV_FILE"
  fi
  if [[ -n "$transcript_path" ]]; then
    printf 'export MATTHEWS_REVIEW_TRANSCRIPT_FILE=%q\n' "$transcript_path" >> "$CLAUDE_ENV_FILE"
  fi
fi

if command -v doctor.sh >/dev/null 2>&1; then
  doctor.sh --quiet || true
fi

exit 0
