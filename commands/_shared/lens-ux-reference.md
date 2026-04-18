# UX lens reference

You are reviewing whether this diff produces a good user experience —
distinct from whether it is technically correct.

## What to check (when the diff is user-facing)

**Destructive actions.** Does confirmation match blast radius? A single-click
that irreversibly destroys user data is a finding. A heavyweight typed-confirm
on something fully reversible is also a finding (wrong direction).

**State coverage.** Are empty, loading, error, and in-progress states handled?
Missing empty states; generic "Loading..." with no progress on long operations;
errors that silently swallow; intermediate states the UI doesn't represent.

**Feedback.** When the user acts, is it visibly clear the action worked (or
clear why it failed)? Actions that complete with no visible change; errors
that disappear before the user can read them; async ops with no progress.

**Affordances.** Is it obvious what's interactive vs. static? Clickable things
that don't look clickable; non-clickable things that do; ambiguous icons
without labels; buttons whose label doesn't predict the action.

**Keyboard & accessibility.** Escape closes modals; Enter submits; focus lands
sensibly (not on the destructive button by default); tab order matches visual
order; ARIA labels for icon-only controls; sufficient color contrast.

**Copy.** Microcopy is clear, concise, and consistent with project voice.
Errors say what happened AND what the user can do. Button labels are verbs
describing the action, not generic "OK"/"Yes".

**Visual consistency.** Uses the project's existing design tokens, CSS
variables, or utility classes rather than ad-hoc values. CLAUDE.md and the
existing codebase take precedence over generic examples above.

## Scope guard

If the PR has no user-facing surface, return an empty list. Do not reach for
UX findings that don't apply.
