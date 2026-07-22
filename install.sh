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

# Derive the complete desired destination set directly from commands/*.md,
# using the generator's basename-without-.md naming rule. This catches a
# collision for a newly added command even when no generated directory exists
# for it in the currently published tree.
DESIRED_SKILLS=()
for cmd_file in "$THIS"/commands/*.md; do
    cmd="$(basename "$cmd_file" .md)"
    DESIRED_SKILLS+=("matthewsreview-$cmd")
done

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

# Validate every desired generated destination and the workflow front door
# before rebuilding dist/codex-skills or refreshing any live link. A single
# real-directory collision must leave every installed symlink target unchanged.
for root in "${ROOTS[@]}"; do
    mkdir -p "$root"
    for skill_name in "${DESIRED_SKILLS[@]}"; do
        assert_linkable "$root/$skill_name"
    done
    assert_linkable "$root/matthewsreview"
done

"$THIS/scripts/build-codex-skills.sh" "$THIS"

for root in "${ROOTS[@]}"; do
    prune_stale_links "$root"
    for skill_name in "${DESIRED_SKILLS[@]}"; do
        link_skill "$THIS/dist/codex-skills/$skill_name" "$skill_name" "$root"
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
