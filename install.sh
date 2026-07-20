#!/usr/bin/env bash
# install.sh — matthewsreview harness installers.
#
#   ./install.sh --codex   Build Codex skills and symlink them into the
#                          Codex user-skill locations (~/.agents/skills,
#                          and ~/.codex/skills when that directory exists).
#                          Also links the workflow front-door skill.
#
# Claude Code and Oh My Pi install via their marketplace flows
# (see README §Install); no install.sh step needed there.
#
# Re-run after moving or updating this repo: generated skills bake
# MREVIEW_ROOT as an absolute path.
set -u
set -e

THIS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "${1:-}" in
    --codex) ;;
    *)
        echo "Usage: ./install.sh --codex" >&2
        echo "  Claude Code: /plugin marketplace add mwksl/matthewsreview && /plugin install matthewsreview@matthewsreview" >&2
        echo "  Oh My Pi:    omp plugin marketplace add mwksl/matthewsreview && omp plugin install matthewsreview@matthewsreview" >&2
        exit 64
        ;;
esac

"$THIS/scripts/build-codex-skills.sh" "$THIS"

link_skill() { # src-dir name target-root
    local src="$1" name="$2" root="$3"
    mkdir -p "$root"
    local dest="$root/$name"
    if [[ -L "$dest" || -e "$dest" ]]; then rm -rf "$dest"; fi
    ln -s "$src" "$dest"
    printf 'linked %s -> %s\n' "$dest" "$src"
}

ROOTS=("$HOME/.agents/skills")
[[ -d "$HOME/.codex/skills" ]] && ROOTS+=("$HOME/.codex/skills")

for root in "${ROOTS[@]}"; do
    for skill_dir in "$THIS"/dist/codex-skills/matthewsreview-*; do
        link_skill "$skill_dir" "$(basename "$skill_dir")" "$root"
    done
    link_skill "$THIS/skills/matthewsreview" "matthewsreview" "$root"
done

cat <<DONE

Codex skills installed. In a Codex session:
  \$matthewsreview-review --full        # review the current branch
  \$matthewsreview-fix                  # apply auto-fixable findings
  /skills                               # browse all installed skills

Run \$matthewsreview (no suffix) for workflow guidance.
Re-run ./install.sh --codex after moving or updating this repo.
DONE
