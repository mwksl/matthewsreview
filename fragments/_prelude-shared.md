# Shared prelude — applies to every `/matthewsreview:*` command

These rules apply across every phase of every matthewsreview command that
dispatches sub-agents or invokes helper scripts.

## 1. After every sub-agent returns

Before branching on its content — immediately, in order:

1. **Extract the token count.** The Agent tool result exposes a
   structured `usage` field when available; otherwise parse
   `<usage>total_tokens: N</usage>` from the sub-agent's output text.
   On parse failure, log with tokens value `null` (i.e. `--tokens null`).
   On **omp** (eval-bridge dispatch), when the result exposes no usage
   field, log `--tokens null` — do not estimate. On **Codex**,
   `agent-dispatch.sh poll` emits the token count parsed from the
   engine's own usage events (codex JSONL `token_count` / claude `-p`
   JSON usage); `null` when the engine reports none.
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

## 3. Dispatch Protocol — DISPATCH / ASK primitives

Commands and fragments never name harness tools (`Agent`,
`AskUserQuestion`, `task`, `eval`, `ask`). They use two primitives;
you map them to your harness once, here.

### 3.1. Identify your harness

Set `harness_id` from your tool inventory:

| You have… | `harness_id` | Harness |
|---|---|---|
| an `Agent` (or `Task`) tool with `subagent_type` + `model` params | `claude-code` | Claude Code |
| `task` + `eval` tools (eval bridge with `agent()` / `parallel()`) | `omp` | Oh My Pi |
| neither, but a shell | `codex` | Codex CLI (skill invocation) |

### 3.2. Resolve helper locations (skip when `claude-code`)

On Claude Code the plugin runtime puts `bin/` on `$PATH` — helpers
invoke bare (`repo-slug.sh ...`), which also keeps the command's
`allowed-tools` grants matching. On other harnesses, resolve the
plugin root ONCE at the start of the command:

```bash
MREVIEW_ROOT="${MREVIEW_ROOT:-}"
if [[ -n "$MREVIEW_ROOT" ]]; then
    # Generated Codex skills bake this path without requiring a trailing slash.
    MREVIEW_ROOT="${MREVIEW_ROOT%/}/"
elif command -v repo-slug.sh >/dev/null 2>&1; then
    # Claude Code (and explicit user PATH setups) invoke helpers by bare name.
    MREVIEW_ROOT=""
else
    for cand in \
        $(ls -dt "$HOME"/.claude/plugins/cache/matthewsreview/matthewsreview/*/ 2>/dev/null | head -1) \
        $(ls -dt "$HOME"/.omp/plugins/cache/plugins/*matthewsreview*/ 2>/dev/null | head -1); do
        if [[ -n "$cand" && -x "$cand/bin/repo-slug.sh" ]]; then
            MREVIEW_ROOT="${cand%/}/"
            break
        fi
    done
fi
if [[ -z "$MREVIEW_ROOT" ]] && ! command -v repo-slug.sh >/dev/null 2>&1; then
    echo "matthewsreview install not found; see README §Install"
    exit 1
fi
# Helpers use the resolved root when set, otherwise their PATH name.
MRB="${MREVIEW_ROOT:+${MREVIEW_ROOT}bin/}"
```

A generated Codex skill bakes `MREVIEW_ROOT=<abs path>` into its
preamble — that value wins over the probe when present.

### 3.3. DISPATCH(role, prompt, [finding_id])

One sub-agent run with the model the plan resolved for `role`.

- **claude-code**: `Agent` tool-use, `subagent_type: general-purpose`,
  `model:` = the model segment of `role_<name>` (e.g. `opus` from
  `claude:opus`). A `codex:*` role goes through the ensemble adapter's
  companion path (Phase 1.5) or `agent-dispatch.sh start --engine codex`
  elsewhere.
- **omp**: one eval cell — `agent(prompt, { model: "<model segment>",
  label: "<role>" })`. When `.effort` is present for an `omp:` role it
  is the omp thinking level; append it to the selector
  (`<model segment>:<effort>`, e.g. `openai-codex/gpt-5.6-sol:max`).
  A `codex:*` role uses `agent-dispatch.sh start --engine codex` + the
  shared poll loop. Token accounting: if the result exposes no usage,
  log `--tokens null`.
- **codex**: write the prompt to `$scratch/<role>-<id>.md`, then
  `"${MRB}agent-dispatch.sh" start --engine <engine> --model <model>
  [--effort <effort>] --prompt-file … --scratch-dir …`, then the shared
  poll loop (`agent-dispatch.sh poll`) until `completed`.

### 3.4. Parallel fan-out

"Dispatch N in parallel" maps to one batch per harness — never N
sequential dispatches:

- **claude-code**: N `Agent` tool-use blocks in ONE orchestrator turn.
- **omp**: ONE eval cell using `parallel([() => agent(p1, …),
  () => agent(p2, …), …])`.
- **codex**: launch all N `agent-dispatch.sh start` calls, then poll
  each job to completion (the poll loop handles them in any order).

Fragments' anti-serialization callouts apply to whichever batch shape
you use: Phase wall-clock is `max(durations)`, never `sum(durations)`.

### 3.5. ASK(question, options[, multi])

Interactive user gate.

- **claude-code**: `AskUserQuestion` with the listed options (and a
  follow-up `AskUserQuestion` for free-form captures).
- **omp**: `ask` tool — `questions: [{ id, question, options:
  [{label, description}], multi? }]`; free-form captures use the
  automatic "Other (type your own)" option, no follow-up needed.
- **codex**: print the question as a numbered-options list in chat and
  stop; the user's reply selects the option. Free-form captures ask for
  the text directly. Keep one ASK per turn.

## 4. Helper-script errors — error-as-prompt

Helper-script errors follow the error-as-prompt convention:
ERROR → context → Valid values → Did you mean → Action. When a helper
exits non-zero, parse the stderr, adjust your inputs per the guidance,
retry ONCE. Only escalate to the user if the second retry also fails.
