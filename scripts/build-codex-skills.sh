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
restore_backup() {
    rm -rf "$TMP"
    if [[ -e "$BACKUP" || -L "$BACKUP" ]]; then
        if [[ ! -e "$OUT" && ! -L "$OUT" ]]; then
            mv "$BACKUP" "$OUT" 2>/dev/null || true
        else
            rm -rf "$BACKUP"
        fi
    fi
}
restore_publish() {
    status=$?
    trap - EXIT
    restore_backup
    exit "$status"
}
# Signals restore the backup explicitly, then re-raise with default
# disposition restored so the parent observes a genuine signal death
# (WIFSIGNALED). Going through restore_publish instead would convert
# the signal into a normal `exit 128+N` via its trailing exit. The
# trailing numeric exit here is an unreachable fallback.
signal_exit() {
    trap - HUP INT TERM EXIT
    restore_backup
    kill -s "$1" $$
    exit "$2"
}
trap restore_publish EXIT
trap 'signal_exit HUP 129' HUP
trap 'signal_exit INT 130' INT
trap 'signal_exit TERM 143' TERM
mkdir -p "$REPO/dist"
rm -rf "$TMP" "$BACKUP"
mkdir -p "$TMP"

for cmd_file in "$REPO"/commands/*.md; do
    if [[ ! -f "$cmd_file" || ! -r "$cmd_file" ]]; then
        printf 'ERROR: invalid command frontmatter: %s: not a readable file\n' \
            "$cmd_file" >&2
        exit 65
    fi

    first_line=$(awk 'NR == 1 { print; exit }' "$cmd_file")
    if [[ "$first_line" != "---" ]]; then
        printf 'ERROR: invalid command frontmatter: %s: line 1 must be ---\n' \
            "$cmd_file" >&2
        exit 65
    fi

    frontmatter_end=$(awk 'NR > 1 && $0 == "---" { print NR; exit }' "$cmd_file")
    if [[ -z "$frontmatter_end" ]]; then
        printf 'ERROR: invalid command frontmatter: %s: missing closing --- after line 1\n' \
            "$cmd_file" >&2
        exit 65
    fi

    desc=$(awk -v frontmatter_end="$frontmatter_end" '
        NR <= 1 { next }
        NR >= frontmatter_end { exit }
        /^description:/ {
            sub(/^description:[[:space:]]*/, "")
            print
            exit
        }
    ' "$cmd_file")
    if [[ -z "${desc//[[:space:]]/}" ]]; then
        printf 'ERROR: invalid command frontmatter: %s: description must be present and nonblank inside first frontmatter pair\n' \
            "$cmd_file" >&2
        exit 65
    fi

    cmd="$(basename "$cmd_file" .md)"
    skill_dir="$TMP/matthewsreview-$cmd"
    mkdir -p "$skill_dir"


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
        MREVIEW_FRAGMENT_PREFIX="$REPO/fragments/" awk \
            -v frontmatter_end="$frontmatter_end" '
            function replace_all(value, needle, replacement, pos, out) {
                out = ""
                while ((pos = index(value, needle)) > 0) {
                    out = out substr(value, 1, pos - 1) replacement
                    value = substr(value, pos + length(needle))
                }
                return out value
            }
            NR > frontmatter_end {
                marker = "__MREVIEW_FRAGMENT_ROOT__/"
                line = replace_all($0, "./fragments/", marker)
                line = replace_all(line, "fragments/", marker)
                line = replace_all(line, marker, ENVIRON["MREVIEW_FRAGMENT_PREFIX"])
                print line
            }
        ' "$cmd_file"
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
