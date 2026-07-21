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
shopt -s nullglob

THIS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $# -ne 1 || "${1:-}" != "--codex" ]]; then
    echo "ERROR: invalid installer invocation." >&2
    echo "Usage: ./install.sh --codex" >&2
    echo "  Claude Code: /plugin marketplace add mwksl/matthewsreview && /plugin install matthewsreview@matthewsreview" >&2
    echo "  Oh My Pi:    omp plugin marketplace add mwksl/matthewsreview && omp plugin install matthewsreview@matthewsreview" >&2
    echo "Action: pass exactly --codex, with no additional arguments." >&2
    exit 64
fi

"$THIS/scripts/build-codex-skills.sh" "$THIS"

link_skill() { # src-dir name target-root
    local src="$1" name="$2" root="$3"
    mkdir -p "$root"
    local dest="$root/$name"
    if [[ -L "$dest" ]]; then
        rm "$dest"
    elif [[ -e "$dest" ]]; then
        printf 'ERROR: refusing to replace existing skill directory: %s\n' "$dest" >&2
        printf 'Action: move it aside, then rerun ./install.sh --codex.\n' >&2
        return 1
    fi
    ln -s "$src" "$dest"
    printf 'linked %s -> %s\n' "$dest" "$src"
}

assert_linkable() { # destination
    local dest="$1"
    if [[ -e "$dest" && ! -L "$dest" ]]; then
        printf 'ERROR: refusing to replace existing skill directory: %s\n' "$dest" >&2
        printf 'Action: move it aside, then rerun ./install.sh --codex.\n' >&2
        return 1
    fi
}

ROOTS=("$HOME/.agents/skills")
[[ -d "$HOME/.codex/skills" ]] && ROOTS+=("$HOME/.codex/skills")

prune_stale_links() { # target-root
    local root="$1" dest target
    for dest in "$root"/matthewsreview-*; do
        [[ -L "$dest" ]] || continue
        target=$(readlink "$dest")
        case "$target" in
            */dist/codex-skills/matthewsreview-*)
                rm "$dest"
                printf 'removed generated link %s\n' "$dest"
                ;;
        esac
    done
}

# Validate every destination before removing or refreshing any live link. A
# single real-directory collision must leave the previous installation whole.
for root in "${ROOTS[@]}"; do
    mkdir -p "$root"
    for skill_dir in "$THIS"/dist/codex-skills/matthewsreview-*; do
        assert_linkable "$root/$(basename "$skill_dir")"
    done
    assert_linkable "$root/matthewsreview"
done

for root in "${ROOTS[@]}"; do
    prune_stale_links "$root"
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
