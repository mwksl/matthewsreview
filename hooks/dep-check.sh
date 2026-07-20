#!/usr/bin/env bash
# dep-check.sh — SessionStart hook: warn if the environment isn't ready.
# Soft warning only — never fails the session. Thin wrapper over
# bin/doctor.sh --quiet (WARN/FAIL lines only); the plugin runtime puts
# bin/ on $PATH so the bare name resolves.

if command -v doctor.sh >/dev/null 2>&1; then
  doctor.sh --quiet || true
fi

exit 0
