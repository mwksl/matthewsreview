#!/usr/bin/env bash
# build-codex-skills.sh — generate Codex skills from commands/*.md.
#
# Emits dist/codex-skills/matthewsreview-<cmd>/SKILL.md per command:
#   codex frontmatter (name + description from the command's frontmatter)
#   + bootstrap preamble (MREVIEW_ROOT baked as an absolute path, prelude
#     read instruction, argument-arrival note)
#   + the command body with its Claude Code frontmatter stripped.
#
# Usage: scripts/build-codex-skills.sh [repo-root]   (default: script's repo)
set -u
set -e

THIS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${1:-$(cd "$THIS/.." && pwd)}"
OUT="$REPO/dist/codex-skills"

rm -rf "$OUT"
mkdir -p "$OUT"

for cmd_file in "$REPO"/commands/*.md; do
    cmd="$(basename "$cmd_file" .md)"
    skill_dir="$OUT/matthewsreview-$cmd"
    mkdir -p "$skill_dir"

    # Extract description from frontmatter (between first pair of ---)
    desc=$(awk '/^---$/{n++; next} n==1 && /^description:/{sub(/^description: */,""); print; exit}' "$cmd_file")
    # Strip frontmatter block from body
    body=$(awk '/^---$/{n++; next} n>=2' "$cmd_file")

    {
        printf -- '---\n'
        printf 'name: matthewsreview-%s\n' "$cmd"
        # quote description: command descriptions may contain colons
        printf 'description: "%s"\n' "$(printf '%s' "$desc" | sed 's/"/\\"/g')"
        printf -- '---\n\n'
        cat <<PREAMBLE
> **Bootstrap (Codex invocation).** \`MREVIEW_ROOT=$REPO\`
>
> Before anything else, read \`\$MREVIEW_ROOT/fragments/_prelude-shared.md\`
> — it defines the Dispatch Protocol (how DISPATCH/ASK map onto Codex)
> and the model-plan contract. Helper scripts run as
> \`"\$MREVIEW_ROOT/bin/<helper>"\` (they are NOT on \$PATH). Your
> \`harness_id\` is \`codex\`.
>
> Arguments arrive as free text in the user's invocation message
> (e.g. "\$matthewsreview-$cmd --full --models utility=claude:haiku").
> Parse them per the §Argument handling section below; ask the user
> when anything is ambiguous.
>
> ---

PREAMBLE
        printf '%s\n' "$body"
    } > "$skill_dir/SKILL.md"

    printf 'built %s\n' "$skill_dir/SKILL.md"
done
