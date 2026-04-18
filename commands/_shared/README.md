# commands/_shared

This directory is consumed by the `/adams-review` and `/adams-review-fix` slash commands via the symlink `~/.claude/commands/_shared → ~/Projects/adams-review/commands/_shared`.

## Layout

- `schema-v1.json` — JSON Schema for `artifact.json`. See DESIGN §6.
- `tools/` — helper scripts invoked by the command orchestrator and (in a read-only subset) by sub-agents.
- Phase fragment files (`00-preflight.md`, …, `10-post-fix-and-commit.md`) and lens reference files (`lens-ux-reference.md`, `lens-security-reference.md`) are added in Stages 2 and 3.

## Helper scripts (`tools/`)

See DESIGN §8 for the full scripts contract and DESIGN §21 for algorithmic sketches. Stage 1 delivers:

| Script | Language | Purpose |
|---|---|---|
| `_common.py` | Python | Shared helpers: schema-validate, atomic write, error-as-prompt, path resolution |
| `artifact-patch.py` | Python | Finding-level mutations, state-transition whitelist, append-only guards |
| `artifact-render.py` | Python | `artifact.json` → `artifact.md` (DESIGN §7) |
| `artifact-validate.sh` | Bash | Thin wrapper around the Python validator |
| `artifact-read.sh` | Bash | `jq` wrapper: `--filter`, `--finding-id`, `--summary` |
| `artifact-publish.sh` | Bash | PR comment post/patch; local-mode no-op |
| `claude-md-paths.sh` | Bash | Walk-up `CLAUDE.md` finder |
| `staleness.sh` | Bash | `git diff` intersection classifier |
| `log-phase.sh` | Bash | `trace.md` + `phases.jsonl` appender |
| `log-tokens.sh` | Bash | `tokens.jsonl` appender |

Stage 2 adds `external-scrape.sh`; Stage 3 adds `group-fixes.py`.

## Conventions

- **Error-as-prompt** (DESIGN §8.6): non-zero exits emit specific, actionable stderr. No stack traces on expected errors.
- **Atomic writes** (DESIGN §24.4): writers go tmp-file → `rename` so the on-disk artifact is never in an invalid state.
- **Shebang**: Python helpers use `#!/usr/bin/env -S uv run --script` with a PEP 723 inline dep spec. Bash helpers use `#!/usr/bin/env bash` and `set -euo pipefail`.
- **Absolute paths**: scripts receive absolute paths as CLI args. No `cd` inside scripts; no assumptions about `$PWD`.
