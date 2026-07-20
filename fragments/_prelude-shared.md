# Shared prelude — applies to every `/matthewsreview:*` command

These rules apply across every phase of every matthewsreview command that
dispatches sub-agents or invokes helper scripts.

## 1. After every sub-agent returns

Before branching on its content — immediately, in order:

1. **Extract the token count.** The Agent tool result exposes a
   structured `usage` field when available; otherwise parse
   `<usage>total_tokens: N</usage>` from the sub-agent's output text.
   On parse failure, log with tokens value `null` (i.e. `--tokens null`).
2. **Call `log-tokens.sh`** with the phase, agent_role, agent_id,
   model, finding_id (when applicable), and the tokens value. This
   is the invariant: every sub-agent's cost is accounted
   even when its output fails to parse.
3. **Parse the sub-agent's structured output** per the dispatching
   fragment's schema. Light repair (strip code fences, extract JSON
   block) is OK. One retry allowed on parse failure with a prompt
   addendum. Drop-with-note on second failure.

## 2. Model plan & role resolution

Model choice is never a literal in command/fragment prose. Every
sub-agent dispatches through a named **role**; the role's engine/model
come from the `model_plan` resolved at Phase 0 step 0.14b (review)
or load time (fix/add/walkthrough/promote) and stored in the artifact.

Roles (→ default tier → default model): `deep_lens`, `deep_validate`,
`cross_cutting`, `fix`, `post_fix_review`, `reconcile` → deep →
claude:opus. `light_lens`, `light_validate` → light → claude:sonnet.
`classifier`, `normalizer`, `dedup`, `scoring`, `fix_hint`, `briefer`,
`drafter` → utility → claude:sonnet. Codex lanes: `ensemble_detect`,
`codex_detect`, `codex_validate`, `codex_crosscut` → codex::high.

Before any phase that dispatches sub-agents, materialize the roles it
uses as working-context strings (one jq read, in-prompt thereafter —
AGENTS.md Rule 11):

```bash
role_str() { printf '%s' "$model_plan_json" | jq -r --arg r "$1" \
  '.roles[$r] | "\(.engine):\(.model)\(if .effort then ":" + .effort else "" end)"'; }
role_deep_validate=$(role_str deep_validate)   # e.g. claude:opus
role_light_lens=$(role_str light_lens)         # ...materialize only what you dispatch
```

Dispatch sites then pass the resolved model for the harness (Claude
Code: the Agent tool's `model:` param = the model segment of
`role_<name>`; see the Dispatch Protocol below for omp/Codex), and
token logging passes the full role string:

```bash
log-tokens.sh ... --model "$role_deep_validate" ...
```

A fragment that says "role `deep_validate`" means: dispatch with the
model the plan resolved for that role, log tokens with the role
string. The defaults reproduce the pre-v1.0 hardcoded models exactly.

**Materialize at resolution time.** The model-plan resolution step
(Phase 0 step 0.14b / fix-loader 7.2b / loader 2b) materializes ALL 19
role strings into working context right after `model_plan_json` is
captured — `role_deep_lens`, `role_deep_validate`,
`role_cross_cutting`, `role_fix`, `role_post_fix_review`,
`role_reconcile`, `role_light_lens`, `role_light_validate`,
`role_classifier`, `role_normalizer`, `role_dedup`, `role_scoring`,
`role_fix_hint`, `role_briefer`, `role_drafter`, `role_ensemble_detect`,
`role_codex_detect`, `role_codex_validate`, `role_codex_crosscut` — so
every fragment reads `role_<name>` without re-querying.

## 3. Helper-script errors — error-as-prompt

Helper-script errors follow the error-as-prompt convention:
ERROR → context → Valid values → Did you mean → Action. When a helper
exits non-zero, parse the stderr, adjust your inputs per the guidance,
retry ONCE. Only escalate to the user if the second retry also fails.
