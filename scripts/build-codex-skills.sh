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
REPO="$(cd "${1:-$THIS/..}" && pwd)"
OUT="$REPO/dist/codex-skills"
TMP="$REPO/dist/.codex-skills.tmp.$$"
BACKUP="$REPO/dist/.codex-skills.backup.$$"
restore_publish() {
    status=$?
    trap - EXIT
    rm -rf "$TMP"
    if [[ -e "$BACKUP" || -L "$BACKUP" ]]; then
        if [[ ! -e "$OUT" && ! -L "$OUT" ]]; then
            mv "$BACKUP" "$OUT" 2>/dev/null || true
        else
            rm -rf "$BACKUP"
        fi
    fi
    exit "$status"
}
signal_exit() {
    trap - HUP INT TERM
    exit "$1"
}
trap restore_publish EXIT
trap 'signal_exit 129' HUP
trap 'signal_exit 130' INT
trap 'signal_exit 143' TERM
mkdir -p "$REPO/dist"
rm -rf "$TMP" "$BACKUP"
mkdir -p "$TMP"

for cmd_file in "$REPO"/commands/*.md; do
    cmd="$(basename "$cmd_file" .md)"
    skill_dir="$TMP/matthewsreview-$cmd"
    mkdir -p "$skill_dir"

    # Extract description from frontmatter (between first pair of ---)
    desc=$(awk '/^---$/{n++; next} n==1 && /^description:/{sub(/^description: */,""); print; exit}' "$cmd_file")
    # Strip frontmatter block from body
    body=$(awk '/^---$/ && n < 2 {n++; next} n == 2 {print}' "$cmd_file")
    # A generated skill runs from the repository being reviewed. Bake every
    # phase/lens fragment path so Codex never resolves it against that cwd.
    # Protect ./fragments first; a direct replacement would leave ./<abs>.
    fragment_prefix="$REPO/fragments/"
    body="${body//.\/fragments\//__MREVIEW_FRAGMENT_ROOT__/}"
    body="${body//fragments\//__MREVIEW_FRAGMENT_ROOT__/}"
    body="${body//__MREVIEW_FRAGMENT_ROOT__\//$fragment_prefix}"

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
> Any \`fragments/...\` or \`./fragments/...\` path mentioned by this
> command or by a loaded fragment is relative to \`\$MREVIEW_ROOT\`,
> never to the repository being reviewed. Resolve it to
> \`\$MREVIEW_ROOT/fragments/...\` before every Read.
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

    printf 'built %s\n' "$OUT/matthewsreview-$cmd/SKILL.md"
done

# Publish only after every skill is complete. Move the prior tree aside so a
# failed replacement can restore every installed symlink target.
if [[ -e "$OUT" || -L "$OUT" ]]; then
    mv "$OUT" "$BACKUP"
fi
if ! mv "$TMP" "$OUT"; then
    if [[ -e "$BACKUP" || -L "$BACKUP" ]]; then
        if mv "$BACKUP" "$OUT" 2>/dev/null; then
            BACKUP=""
        else
            printf 'ERROR: publish failed; previous tree preserved at %s\n' "$BACKUP" >&2
            # Do not let the EXIT trap delete the only complete tree.
            BACKUP=""
        fi
    fi
    exit 1
fi
rm -rf "$BACKUP"
trap - EXIT HUP INT TERM
