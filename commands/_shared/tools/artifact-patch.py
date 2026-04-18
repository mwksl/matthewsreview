#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["jsonschema"]
# ///
"""artifact-patch.py — canonical writer for artifact.json (DESIGN §8.2, §21.2).

Modes (CLI flags; mutually exclusive):
  --init <seed>             create fresh artifact at --path
  --add-finding <finding>   append a new finding to findings[]
  --delete-finding FXXX     remove a finding by id (used by Phase 2 dedup)
  --apply-decisions <array> apply a batch of Phase-4 decision tuples in one
                            call (DESIGN §13.1, §21.2; Stage 2.5.B). Input
                            is a JSON array of {id, score_phase4, decision,
                            actionability, validation_result?, reason?,
                            confirmed_strength?, related_parent_finding_id?}.
                            The helper derives disposition per §13.1 and
                            writes validation_result only for confirmed-band
                            tuples. Per-tuple atomic write + halt on first
                            failure (preceding tuples stay committed).
  --set field=value         mutate a scalar field (repeatable). With
                            --finding-id, targets a finding; without,
                            targets top-level artifact fields.
  --set-json field=<json-or-@file>  mutate a structured (array/object)
                            field (repeatable). Same --finding-id
                            targeting as --set; separate whitelist of
                            allowed fields (arrays/objects only).
  --append-fix-attempt <json>  append an entry to a finding's fix_attempts[]
                               (requires --finding-id). Combinable with
                               --set in a single call (DESIGN §26 worked
                               example: set current_state=resolved and
                               append the attempt in one patch).

### --set semantics

Field allowlist (see SETTABLE_FINDING_FIELDS / SETTABLE_ARTIFACT_FIELDS):
non-listed fields are rejected with an error-as-prompt listing the
allowed names. Arrays and objects are never set via --set (use --init,
--add-finding, or mode-specific flags).

Value parsing: JSON-literal first, string fallback. So `--set x=null`,
`--set x=85`, `--set x=true` produce the JSON value; `--set x=foo`
produces the string "foo". A user who actually means the string "true"
passes `--set x='"true"'` (explicit JSON quotes).

Coupling rules (DESIGN §5.2.1, §21.2):
- `disposition` and `is_actionable` stay in lockstep. Setting disposition
  auto-derives is_actionable; setting both in the same call requires
  they agree.
- `current_state=resolved` iff `disposition=resolved`. The script checks
  the effective post-patch state in both directions and rejects any
  disagreement.
- State transitions follow the §5.3 whitelist. Invalid transitions exit
  with code 2 and list the valid next states.
- Setting `score_phase3` / `score_phase4` auto-appends the corresponding
  entry to `score_history` (which is otherwise append-only).

JSON arguments (seed, finding payload, etc.) accept three forms:
  inline     --init '{"schema_version":1,...}'
  file       --init @/path/to/seed.json
  stdin      --init -

Every write validates the full artifact against schema-v1.json and
goes through atomic tmp+rename. Non-zero exits emit error-as-prompt
blocks to stderr per DESIGN §8.6.
"""

import argparse
import copy
import difflib
import json
import os
import sys
import traceback
from datetime import datetime, timezone
from pathlib import Path

# _common.py lives next to this file. uv run --script prepends our dir to sys.path.
sys.path.insert(0, str(Path(__file__).parent))
import _common as c  # noqa: E402


# ----- Input parsing -----------------------------------------------------

def read_json_arg(value, flag_name):
    """Parse a JSON value from inline string, @<file>, or - (stdin).

    Returns the parsed value. On failure, emits an error-as-prompt and
    raises SystemExit with the usage code.
    """
    raw = None
    source = None
    try:
        if value == "-":
            raw = sys.stdin.read()
            source = "<stdin>"
        elif value.startswith("@"):
            path = value[1:]
            with open(path) as f:
                raw = f.read()
            source = path
        else:
            raw = value
            source = "<inline>"
        return json.loads(raw)
    except OSError as e:
        c.err_prompt(
            f"could not read {flag_name} from {source}: {e}",
            action=f"pass {flag_name} as inline JSON, @<file>, or - for stdin."
        )
        sys.exit(c.EXIT_USAGE)
    except json.JSONDecodeError as e:
        preview = (raw or "")[:80]
        c.err_prompt(
            f"{flag_name} value is not valid JSON: {e.msg} (line {e.lineno}, col {e.colno})",
            context=f"Input source: {source}; preview: {preview!r}",
            action=f"pass {flag_name} as a JSON value (inline, @<file>, or - for stdin)."
        )
        sys.exit(c.EXIT_USAGE)


# ----- Modes -------------------------------------------------------------

def cmd_init(args):
    """Create a fresh artifact from a seed doc (§8.2)."""
    seed = read_json_arg(args.init, "--init")

    if not isinstance(seed, dict):
        c.err_prompt(
            f"--init expects a JSON object, got {type(seed).__name__}",
            action="the seed must be a top-level artifact object (DESIGN §6)."
        )
        return c.EXIT_USAGE

    # Server-authoritative defaults: fill only when absent so callers can
    # pin these fields explicitly (useful for deterministic tests).
    seed.setdefault("schema_version", 1)
    seed.setdefault("generated_at", datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))

    errors = c.validate(seed)
    if errors:
        shown = errors[:10]
        overflow = [f"  (+{len(errors) - 10} more)"] if len(errors) > 10 else []
        c.err_prompt(
            f"init seed is invalid ({len(errors)} schema violation(s))",
            context=["  " + e for e in shown] + overflow,
            action="fix the seed to satisfy schema-v1.json (DESIGN §6), then re-run."
        )
        return c.EXIT_VALIDATION

    # If the target file exists, load its content for the dry-run diff
    # base. A failed load doesn't fail the init — we just show the full
    # new doc as an all-additions diff.
    before = None
    if args.dry_run and os.path.exists(args.path):
        try:
            before = c.read_json(args.path)
        except (OSError, json.JSONDecodeError):
            before = None

    return _write_and_emit(args.path, seed, dry_run=args.dry_run, before=before)


def _load_or_fail(path):
    """Read the artifact at `path`, or emit an error-as-prompt and exit."""
    try:
        return c.read_json(path)
    except FileNotFoundError:
        c.err_prompt(
            f"artifact not found at {path}",
            action="run `artifact-patch.py --init ...` first, or pass the correct --path."
        )
        sys.exit(c.EXIT_VALIDATION)
    except json.JSONDecodeError as e:
        c.err_prompt(
            f"artifact at {path} is not valid JSON: {e.msg} (line {e.lineno}, col {e.colno})",
            action="the on-disk file is corrupted — restore from git or re-run --init."
        )
        sys.exit(c.EXIT_VALIDATION)


def _write_and_emit(path, artifact, dry_run=False, before=None, silent=False):
    """Common write tail: bump generated_at, validate, then either write or print a diff.

    With dry_run=True:
      - Invalid result: exit EXIT_DRY_RUN_INVALID (3) with error-as-prompt.
      - Valid result: print unified diff to stdout, log "(dry-run: no write)"
        to stderr, exit EXIT_OK.
    With dry_run=False:
      - Invalid result: exit EXIT_VALIDATION (1) (post-patch invariant break
        shouldn't normally happen if the mode's pre-checks are correct).
      - Valid result: atomic tmp+rename, log "wrote <path>" to stdout unless
        silent=True (used by --apply-decisions batch loop so the orchestrator
        sees one summary line, not N per-tuple lines).
    """
    artifact["generated_at"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    errors = c.validate(artifact)
    if errors:
        shown = errors[:10]
        overflow = [f"  (+{len(errors) - 10} more)"] if len(errors) > 10 else []
        c.err_prompt(
            f"patched artifact is invalid ({len(errors)} schema violation(s))",
            context=["  " + e for e in shown] + overflow,
            action=("--dry-run caught this before writing; fix the input."
                    if dry_run
                    else "this indicates a bug in the patch mode or a malformed input value.")
        )
        return c.EXIT_DRY_RUN_INVALID if dry_run else c.EXIT_VALIDATION

    if dry_run:
        before_lines = (
            json.dumps(before, indent=2, sort_keys=True).splitlines(keepends=True)
            if before is not None
            else []
        )
        after_lines = json.dumps(artifact, indent=2, sort_keys=True).splitlines(keepends=True)
        diff = difflib.unified_diff(
            before_lines, after_lines,
            fromfile=f"{path} (before)",
            tofile=f"{path} (after)",
        )
        sys.stdout.writelines(diff)
        sys.stdout.flush()
        if before_lines == after_lines:
            print("(dry-run: no changes)", file=sys.stderr)
        else:
            print("(dry-run: no write)", file=sys.stderr)
        return c.EXIT_OK

    c.atomic_write(path, artifact)
    if not silent:
        print(f"wrote {path}")
    return c.EXIT_OK


# ----- --set allowlist + value parsing ----------------------------------

SETTABLE_FINDING_FIELDS = frozenset({
    "impact_type",
    "origin",
    "origin_confidence",
    "actionability",
    "validation_lane",
    "current_state",
    "disposition",
    "is_actionable",
    "reason",
    "confirmed_strength",
    "score_phase3",
    "score_phase4",
    "introduced_in_sha",
    "suggested_follow_up",
    "related_parent_finding_id",
})

SETTABLE_ARTIFACT_FIELDS = frozenset({
    "comment_id",
    "trivial_mode",
    "pr_state",
    "pr_number",
})

# ----- --set-json: structured (array/object) fields ---------------------
#
# Separate whitelist from --set (which is scalar-only). --set-json accepts
# values as inline JSON, @<file> for file-read, or - for stdin. Same
# --finding-id targeting: with --finding-id, matches FINDING fields; without,
# matches ARTIFACT fields. fix_attempts is intentionally not here — that's
# append-only via --append-fix-attempt.

JSON_SETTABLE_FINDING_FIELDS = frozenset({
    "sources",
    "source_families",
    "validation_result",
    # score_history is intentionally NOT here — it's append-only, driven
    # automatically by --set score_phase3/score_phase4 (see
    # _apply_finding_set). Bypassing that would let callers overwrite
    # history, which defeats the audit trail.
})

JSON_SETTABLE_ARTIFACT_FIELDS = frozenset({
    "cross_cutting_groups",
    "subagent_tokens",
    "metrics",
    "reviewer_sources",
})


def parse_set_pair(pair):
    """Parse one '--set K=V' pair into (key, value).

    Value uses JSON-literal-first parsing (so null/true/false/numbers
    become native Python types) with string fallback for bare words.
    Raises SystemExit(EXIT_USAGE) on malformed pair.
    """
    if "=" not in pair:
        c.err_prompt(
            f"--set expects 'field=value', got '{pair}'",
            action="use --set field=value; use --set twice (or more) for multiple fields."
        )
        sys.exit(c.EXIT_USAGE)
    key, _, raw = pair.partition("=")
    key = key.strip()
    if not key:
        c.err_prompt(
            f"--set has empty field name in '{pair}'",
            action="use --set field=value."
        )
        sys.exit(c.EXIT_USAGE)
    try:
        value = json.loads(raw)
    except json.JSONDecodeError:
        value = raw
    return key, value


def cmd_add_finding(args):
    """Append a new finding to findings[] (§8.2)."""
    finding = read_json_arg(args.add_finding, "--add-finding")

    if not isinstance(finding, dict):
        c.err_prompt(
            f"--add-finding expects a JSON object, got {type(finding).__name__}",
            action="pass a finding object matching DESIGN §6."
        )
        return c.EXIT_USAGE

    artifact = _load_or_fail(args.path)
    before = copy.deepcopy(artifact) if args.dry_run else None

    existing_ids = {f.get("id") for f in artifact.get("findings", [])}
    new_id = finding.get("id")
    if new_id in existing_ids:
        c.err_prompt(
            f"finding id '{new_id}' already exists in {args.path}",
            valid_values=f"existing ids: {sorted(existing_ids)}",
            action="use --set to mutate an existing finding, or pick a fresh id."
        )
        return c.EXIT_VALIDATION

    artifact.setdefault("findings", []).append(finding)
    return _write_and_emit(args.path, artifact, dry_run=args.dry_run, before=before)


def _find_finding(artifact, finding_id):
    """Return the finding dict for `finding_id`, or emit + sys.exit on miss."""
    for f in artifact.get("findings", []):
        if f.get("id") == finding_id:
            return f
    existing = [f.get("id") for f in artifact.get("findings", [])]
    c.err_prompt(
        f"no finding with id '{finding_id}' in {artifact.get('review_id', '(unknown review)')}",
        valid_values=f"existing ids: {existing}" if existing else "no findings in this artifact",
        did_you_mean=c.suggest(finding_id, existing),
        action="check --finding-id, or add the finding with --add-finding first."
    )
    sys.exit(c.EXIT_VALIDATION)


def _apply_finding_set(finding, pairs):
    """Apply --set pairs to a finding in-place, enforcing coupling rules.

    Returns (applied_keys_set, transition_error_or_None). On coupling or
    transition failures, emits error-as-prompt and sys.exit with the
    appropriate code; on other schema problems, returns normally and the
    downstream schema validation catches them.
    """
    pair_map = {k: v for k, v in pairs}
    applied_keys = set()

    # Reject non-settable fields up front.
    bad_keys = [k for k in pair_map if k not in SETTABLE_FINDING_FIELDS]
    if bad_keys:
        c.err_prompt(
            f"--set cannot touch finding field(s): {bad_keys}",
            valid_values=sorted(SETTABLE_FINDING_FIELDS),
            did_you_mean=c.suggest(bad_keys[0], SETTABLE_FINDING_FIELDS),
            action="immutable fields (id, file, claim, sources, line_range) cannot be patched; append-only fields use --append-fix-attempt or dedicated flags."
        )
        sys.exit(c.EXIT_VALIDATION)

    # 1) State transition check (§5.3).
    if "current_state" in pair_map:
        before = finding.get("current_state")
        requested = pair_map["current_state"]
        if requested != before:
            allowed = c.transitions_from(before)
            if requested not in allowed:
                if requested not in c.CURRENT_STATE_VALUES:
                    # True typo — suggest the closest real enum and then
                    # a valid transition target from the current state.
                    did_you_mean = c.suggest(requested, c.CURRENT_STATE_VALUES)
                else:
                    # Not a typo — just not a valid next state. Skip the
                    # "did you mean" line since the bad value is spelled
                    # correctly; the valid-values line already points the
                    # caller at the allowed targets.
                    did_you_mean = None
                c.err_prompt(
                    f"invalid transition from '{before}' to '{requested}' for finding {finding.get('id')}",
                    valid_values=(sorted(allowed) or ["(none — terminal state)"]),
                    did_you_mean=did_you_mean,
                    action=("a finding must be attempted (Phase 8) before it can be resolved"
                            if before == "open" and requested == "resolved"
                            else "see DESIGN §5.3 for the valid state transitions.")
                )
                sys.exit(c.EXIT_INVALID_TRANSITION)

    # 2) Disposition / is_actionable coupling (§21.2).
    if "disposition" in pair_map:
        derived = c.derive_is_actionable(pair_map["disposition"])
        if "is_actionable" in pair_map:
            if pair_map["is_actionable"] != derived:
                c.err_prompt(
                    f"is_actionable={pair_map['is_actionable']} contradicts disposition='{pair_map['disposition']}' (derived: {derived})",
                    context=f"is_actionable is derived: true iff disposition ∈ {{confirmed_auto, partial, regression}}. See DESIGN §5.2.1.",
                    action="omit --set is_actionable; the script will derive it from disposition."
                )
                sys.exit(c.EXIT_VALIDATION)
        else:
            pair_map["is_actionable"] = derived
    elif "is_actionable" in pair_map:
        current_disp = finding.get("disposition")
        derived = c.derive_is_actionable(current_disp)
        if pair_map["is_actionable"] != derived:
            c.err_prompt(
                f"is_actionable={pair_map['is_actionable']} contradicts existing disposition='{current_disp}' (derived: {derived})",
                context="to change is_actionable, --set disposition instead; the script will derive is_actionable from it.",
                action="pick a compatible disposition (see DESIGN §5.2.1 table)."
            )
            sys.exit(c.EXIT_VALIDATION)

    # 3) current_state ↔ disposition=resolved coupling (§5.2.1 invariants).
    effective_state = pair_map.get("current_state", finding.get("current_state"))
    effective_disp = pair_map.get("disposition", finding.get("disposition"))
    if (effective_state == "resolved") != (effective_disp == "resolved"):
        c.err_prompt(
            f"current_state='{effective_state}' and disposition='{effective_disp}' disagree (resolved coupling)",
            context="DESIGN §5.2.1: current_state=='resolved' ⇔ disposition=='resolved'. Set both, or neither.",
            action="use --set current_state=resolved --set disposition=resolved in the same call."
        )
        sys.exit(c.EXIT_VALIDATION)

    # 4) Apply scalar sets.
    for key, value in pair_map.items():
        finding[key] = value
        applied_keys.add(key)

    # 5) score sync: score_phase3/4 mirrors into score_history append-only.
    hist = finding.setdefault("score_history", [])
    if "score_phase3" in pair_map and pair_map["score_phase3"] is not None:
        hist.append({"phase": "phase_3", "score": pair_map["score_phase3"]})
    if "score_phase4" in pair_map and pair_map["score_phase4"] is not None:
        hist.append({"phase": "phase_4", "score": pair_map["score_phase4"]})

    return applied_keys


def _apply_artifact_set(artifact, pairs):
    """Apply --set pairs to the top-level artifact (no --finding-id case)."""
    pair_map = {k: v for k, v in pairs}
    bad_keys = [k for k in pair_map if k not in SETTABLE_ARTIFACT_FIELDS]
    if bad_keys:
        c.err_prompt(
            f"--set cannot touch top-level field(s): {bad_keys}",
            valid_values=sorted(SETTABLE_ARTIFACT_FIELDS),
            did_you_mean=c.suggest(bad_keys[0], SETTABLE_ARTIFACT_FIELDS),
            action="finding-level fields require --finding-id; immutable fields cannot be patched."
        )
        sys.exit(c.EXIT_VALIDATION)
    for key, value in pair_map.items():
        artifact[key] = value
    return set(pair_map.keys())


def parse_set_json_pair(pair):
    """Parse one '--set-json K=V' pair into (key, parsed_value).

    Value parsing: inline JSON, @<file> for file-read, or '-' for stdin.
    Raises SystemExit on malformed pair or unparseable JSON.
    """
    if "=" not in pair:
        c.err_prompt(
            f"--set-json expects 'field=<json-or-@file>', got '{pair}'",
            action="use --set-json field=<inline-json>, field=@<path>, or field=-"
        )
        sys.exit(c.EXIT_USAGE)
    key, _, raw = pair.partition("=")
    key = key.strip()
    if not key:
        c.err_prompt(
            f"--set-json has empty field name in '{pair}'",
            action="use --set-json field=value."
        )
        sys.exit(c.EXIT_USAGE)

    value = read_json_arg(raw, f"--set-json {key}")
    return key, value


def _apply_finding_set_json(finding, pairs):
    """Apply --set-json pairs to a finding in-place."""
    pair_map = {k: v for k, v in pairs}
    bad_keys = [k for k in pair_map if k not in JSON_SETTABLE_FINDING_FIELDS]
    if bad_keys:
        c.err_prompt(
            f"--set-json cannot touch finding field(s): {bad_keys}",
            valid_values=sorted(JSON_SETTABLE_FINDING_FIELDS),
            did_you_mean=c.suggest(bad_keys[0], JSON_SETTABLE_FINDING_FIELDS),
            action="scalar fields use --set; fix_attempts is append-only via --append-fix-attempt; immutable fields (id/file/claim/line_range) cannot be patched."
        )
        sys.exit(c.EXIT_VALIDATION)
    for key, value in pair_map.items():
        finding[key] = value
    return set(pair_map.keys())


def _apply_artifact_set_json(artifact, pairs):
    """Apply --set-json pairs to the top-level artifact."""
    pair_map = {k: v for k, v in pairs}
    bad_keys = [k for k in pair_map if k not in JSON_SETTABLE_ARTIFACT_FIELDS]
    if bad_keys:
        c.err_prompt(
            f"--set-json cannot touch top-level field(s): {bad_keys}",
            valid_values=sorted(JSON_SETTABLE_ARTIFACT_FIELDS),
            did_you_mean=c.suggest(bad_keys[0], JSON_SETTABLE_ARTIFACT_FIELDS),
            action="finding-level fields require --finding-id; immutable fields cannot be patched."
        )
        sys.exit(c.EXIT_VALIDATION)
    for key, value in pair_map.items():
        artifact[key] = value
    return set(pair_map.keys())


def cmd_delete_finding(args):
    """Remove a finding by id (used by Phase 2 dedup)."""
    finding_id = args.delete_finding
    artifact = _load_or_fail(args.path)
    before = copy.deepcopy(artifact) if args.dry_run else None

    findings = artifact.get("findings", [])
    existing_ids = [f.get("id") for f in findings]
    if finding_id not in existing_ids:
        c.err_prompt(
            f"no finding with id '{finding_id}' to delete in {artifact.get('review_id', '(unknown review)')}",
            valid_values=f"existing ids: {existing_ids}" if existing_ids else "no findings in this artifact",
            did_you_mean=c.suggest(finding_id, existing_ids),
            action="check the id spelling; use --add-finding to add, --set to mutate."
        )
        return c.EXIT_VALIDATION

    artifact["findings"] = [f for f in findings if f.get("id") != finding_id]
    return _write_and_emit(args.path, artifact, dry_run=args.dry_run, before=before)


# ----- --apply-decisions: Phase-4 batch application (DESIGN §13.1, §21.2) ---
#
# Input is a JSON array of decision tuples. Each tuple has one finding's Phase-4
# outcome: score_phase4 (number or null), optional decision/actionability,
# optional validation_result (written only for confirmed-band dispositions),
# optional reason / confirmed_strength / related_parent_finding_id.
#
# Derivation table (§13.1 Phase 4):
#   score_phase4 == null → disposition=uncertain (parse-failure fallback,
#                          see 05-validation step 4.4 prose)
#   score_phase4 < 45    → disposition=disproven
#   score_phase4 45-59   → disposition=uncertain
#   score_phase4 >= 60   → needs actionability:
#                            auto_fixable → confirmed_auto
#                            manual       → confirmed_manual
#                            report_only  → confirmed_report
#                          confirmed_strength: moderate (60-74) / strong (75+)
#
# The score-wins-over-decision rule from 05-validation applies implicitly:
# we derive disposition from score + actionability, ignoring the tuple's
# `decision` field (which exists so the JSON is auditable but isn't
# authoritative). A validator returning decision=disproven, score=70 with
# actionability=auto_fixable routes to confirmed_auto.
#
# per-tuple atomic writes + first-failure-halts (plan §5.2): if tuple N
# is invalid, tuples 0..N-1 have been written to disk; caller re-invokes
# with the remainder.

ALLOWED_DECISION_TUPLE_KEYS = frozenset({
    "id",
    "score_phase4",
    "decision",                    # audit-only; derivation uses score + actionability
    "actionability",
    "validation_result",
    "reason",
    "confirmed_strength",          # tuple override for the derived strength
    "related_parent_finding_id",
})

CONFIRMED_BAND = frozenset({"confirmed_auto", "confirmed_manual", "confirmed_report"})

_ACTIONABILITY_TO_DISPOSITION = {
    "auto_fixable": "confirmed_auto",
    "manual": "confirmed_manual",
    "report_only": "confirmed_report",
}


def _derive_phase4_disposition(tup, idx):
    """Derive {disposition, confirmed_strength} per DESIGN §13.1 Phase 4.

    On invalid input (bad score type, missing actionability for confirmed
    band, unknown actionability), emits error-as-prompt and sys.exits with
    EXIT_VALIDATION — caller's batch loop halts there.
    """
    fid = tup.get("id") or f"tuple #{idx}"
    score = tup.get("score_phase4")

    if score is None:
        return {"disposition": "uncertain", "confirmed_strength": None}

    if not isinstance(score, (int, float)) or isinstance(score, bool):
        c.err_prompt(
            f"--apply-decisions tuple #{idx} ({fid}): score_phase4 must be number or null, got {type(score).__name__}",
            action="pass score_phase4 as an integer 0-100 or null (for parse-failure fallback)."
        )
        sys.exit(c.EXIT_VALIDATION)

    if score < 45:
        return {"disposition": "disproven", "confirmed_strength": None}
    if score < 60:
        return {"disposition": "uncertain", "confirmed_strength": None}

    # Confirmed band — needs actionability.
    actionability = tup.get("actionability")
    if actionability is None:
        c.err_prompt(
            f"--apply-decisions tuple #{idx} ({fid}): score_phase4={score} is in the confirmed band (>=60) but no actionability provided",
            valid_values=sorted(_ACTIONABILITY_TO_DISPOSITION.keys()),
            action="add actionability to the tuple (auto_fixable/manual/report_only); the validator owns that classification."
        )
        sys.exit(c.EXIT_VALIDATION)
    if actionability not in _ACTIONABILITY_TO_DISPOSITION:
        c.err_prompt(
            f"--apply-decisions tuple #{idx} ({fid}): unknown actionability '{actionability}'",
            valid_values=sorted(_ACTIONABILITY_TO_DISPOSITION.keys()),
            did_you_mean=c.suggest(actionability, _ACTIONABILITY_TO_DISPOSITION.keys()),
            action="see DESIGN §5.2 / schema-v1.json for the actionability enum."
        )
        sys.exit(c.EXIT_VALIDATION)

    return {
        "disposition": _ACTIONABILITY_TO_DISPOSITION[actionability],
        "confirmed_strength": "strong" if score >= 75 else "moderate",
    }


def cmd_apply_decisions(args):
    """Apply a batch of Phase-4 decision tuples (§13.1, §21.2; Stage 2.5.B)."""
    decisions = read_json_arg(args.apply_decisions, "--apply-decisions")

    if not isinstance(decisions, list):
        c.err_prompt(
            f"--apply-decisions expects a JSON array, got {type(decisions).__name__}",
            action="pass an array of decision tuples; see artifact-patch.py docstring for the shape."
        )
        return c.EXIT_USAGE

    counts = {"confirmed_auto": 0, "confirmed_manual": 0, "confirmed_report": 0,
              "uncertain": 0, "disproven": 0}

    for idx, tup in enumerate(decisions):
        if not isinstance(tup, dict):
            c.err_prompt(
                f"--apply-decisions tuple #{idx}: must be a JSON object, got {type(tup).__name__}",
                action="each array element is {id, score_phase4, ...}; see the docstring."
            )
            return c.EXIT_VALIDATION

        fid = tup.get("id")
        if not fid:
            c.err_prompt(
                f"--apply-decisions tuple #{idx}: 'id' is required",
                action="every tuple must name the finding it applies to."
            )
            return c.EXIT_VALIDATION

        bad_keys = [k for k in tup.keys() if k not in ALLOWED_DECISION_TUPLE_KEYS]
        if bad_keys:
            c.err_prompt(
                f"--apply-decisions tuple #{idx} ({fid}): unknown keys {sorted(bad_keys)}",
                valid_values=sorted(ALLOWED_DECISION_TUPLE_KEYS),
                action="remove unknown keys; disposition/is_actionable are derived by the helper, not supplied."
            )
            return c.EXIT_VALIDATION

        derived = _derive_phase4_disposition(tup, idx)

        # Load fresh per-tuple so preceding tuples' writes are visible on the
        # next iteration's base state. Matches the "per-tuple atomic writes"
        # semantics documented in the plan (Stage 2.5.B §5.2).
        artifact = _load_or_fail(args.path)
        finding = _find_finding(artifact, fid)

        # Build --set pairs. _apply_finding_set handles the is_actionable
        # derivation and the current_state↔disposition coupling checks for us.
        set_pairs = [("disposition", derived["disposition"])]
        if "score_phase4" in tup:
            set_pairs.append(("score_phase4", tup["score_phase4"]))
        # actionability: write only when non-null — schema requires a concrete
        # enum value. A tuple passing `actionability: null` (valid for
        # disproven/uncertain where it's not needed) leaves the finding's
        # Phase-1-assigned actionability in place.
        if tup.get("actionability") is not None:
            set_pairs.append(("actionability", tup["actionability"]))

        # confirmed_strength: tuple override beats derived. `null` from the
        # tuple counts as an explicit override (e.g., downgrading from a
        # prior-phase classification); use a sentinel check.
        if "confirmed_strength" in tup:
            set_pairs.append(("confirmed_strength", tup["confirmed_strength"]))
        else:
            set_pairs.append(("confirmed_strength", derived["confirmed_strength"]))

        # reason: if the tuple provides one use it, else fill a disposition-
        # appropriate default. Matches the prose in 05-validation step 4.4.
        if "reason" in tup:
            set_pairs.append(("reason", tup["reason"]))
        else:
            default_reason = {
                "disproven": "disproven by Phase 4",
                "uncertain": "uncertain (Phase 4 inconclusive)",
            }.get(derived["disposition"])  # None for confirmed band, which is correct
            set_pairs.append(("reason", default_reason))

        if "related_parent_finding_id" in tup:
            set_pairs.append(("related_parent_finding_id", tup["related_parent_finding_id"]))

        _apply_finding_set(finding, set_pairs)

        # validation_result: write only when the resolved disposition lands in
        # the confirmed band. Schema requires nested non-null for the stored
        # object, and disproven/uncertain validators don't produce the
        # fix_proposal / verification_context sections.
        vr = tup.get("validation_result")
        if vr is not None and derived["disposition"] in CONFIRMED_BAND:
            _apply_finding_set_json(finding, [("validation_result", vr)])

        rc = _write_and_emit(args.path, artifact, silent=True)
        if rc != c.EXIT_OK:
            # _write_and_emit already emitted an error-as-prompt for invalid
            # post-patch state. Halt the batch; preceding tuples persisted.
            return rc

        counts[derived["disposition"]] += 1

    total = sum(counts.values())
    print(
        f"applied {total} decisions "
        f"(confirmed_auto={counts['confirmed_auto']}, "
        f"confirmed_manual={counts['confirmed_manual']}, "
        f"confirmed_report={counts['confirmed_report']}, "
        f"uncertain={counts['uncertain']}, "
        f"disproven={counts['disproven']})"
    )
    return c.EXIT_OK


def cmd_set_and_or_append(args):
    """Combined --set / --set-json / --append-fix-attempt (DESIGN §26).

    Any combination can be present. All operate on --finding-id when
    given (or top-level, for --set and --set-json). Order within one
    call: --set first (scalar transitions + coupling), then --set-json
    (structured fields), then --append-fix-attempt. One atomic write.
    """
    artifact = _load_or_fail(args.path)
    before = copy.deepcopy(artifact) if args.dry_run else None

    set_pairs = [parse_set_pair(p) for p in args.set] if args.set else []
    set_json_pairs = [parse_set_json_pair(p) for p in args.set_json] if args.set_json else []

    if args.append_fix_attempt is not None and not args.finding_id:
        c.err_prompt(
            "--append-fix-attempt requires --finding-id",
            action="fix_attempts is a per-finding list; pass --finding-id <id>."
        )
        return c.EXIT_USAGE

    if args.finding_id:
        finding = _find_finding(artifact, args.finding_id)
        if set_pairs:
            _apply_finding_set(finding, set_pairs)
        if set_json_pairs:
            _apply_finding_set_json(finding, set_json_pairs)
        if args.append_fix_attempt is not None:
            attempt = read_json_arg(args.append_fix_attempt, "--append-fix-attempt")
            if not isinstance(attempt, dict):
                c.err_prompt(
                    f"--append-fix-attempt expects a JSON object, got {type(attempt).__name__}",
                    action="pass a fix_attempt object matching DESIGN §6."
                )
                return c.EXIT_USAGE
            finding.setdefault("fix_attempts", []).append(attempt)
    else:
        # Top-level: --set and/or --set-json only.
        if set_pairs:
            _apply_artifact_set(artifact, set_pairs)
        if set_json_pairs:
            _apply_artifact_set_json(artifact, set_json_pairs)

    return _write_and_emit(args.path, artifact, dry_run=args.dry_run, before=before)


# ----- CLI ---------------------------------------------------------------

def build_parser():
    p = argparse.ArgumentParser(
        prog="artifact-patch.py",
        description="Canonical writer for artifact.json (DESIGN §8.2, §21.2)."
    )
    p.add_argument(
        "--path",
        required=True,
        help="target artifact.json path (absolute recommended)"
    )
    p.add_argument(
        "--finding-id",
        metavar="FXXX",
        help="target finding for --set / --append-fix-attempt; omit for top-level --set"
    )
    p.add_argument(
        "--set",
        dest="set",
        action="append",
        default=[],
        metavar="FIELD=VALUE",
        help="repeatable: set a scalar field to a JSON-parseable value (null/true/85/foo)"
    )
    p.add_argument(
        "--set-json",
        dest="set_json",
        action="append",
        default=[],
        metavar="FIELD=<json-or-@file>",
        help="repeatable: set an array/object field (whitelisted). Value is inline JSON, @<file>, or - for stdin."
    )
    p.add_argument(
        "--append-fix-attempt",
        dest="append_fix_attempt",
        metavar="ATTEMPT_JSON",
        help="append an entry to finding.fix_attempts[] (requires --finding-id; inline JSON, @file, or -)"
    )
    p.add_argument(
        "--dry-run",
        dest="dry_run",
        action="store_true",
        help="validate the patch in memory and print a unified diff to stdout; no write"
    )
    mode = p.add_mutually_exclusive_group(required=False)
    mode.add_argument(
        "--init",
        metavar="SEED_JSON",
        help="create fresh artifact from seed (inline JSON, @file, or -)"
    )
    mode.add_argument(
        "--add-finding",
        metavar="FINDING_JSON",
        help="append a new finding to findings[] (inline JSON, @file, or -)"
    )
    mode.add_argument(
        "--delete-finding",
        metavar="FXXX",
        help="remove a finding by id (used by Phase 2 dedup)"
    )
    mode.add_argument(
        "--apply-decisions",
        dest="apply_decisions",
        metavar="DECISIONS_JSON",
        help="apply a batch of Phase-4 decision tuples (inline JSON array, @file, or -); see docstring"
    )
    return p


def main():
    parser = build_parser()
    args = parser.parse_args()

    try:
        if args.init is not None:
            if args.set or args.set_json or args.append_fix_attempt:
                parser.error("--init cannot combine with --set / --set-json / --append-fix-attempt")
            return cmd_init(args)
        if args.add_finding is not None:
            if args.set or args.set_json or args.append_fix_attempt:
                parser.error("--add-finding cannot combine with --set / --set-json / --append-fix-attempt")
            return cmd_add_finding(args)
        if args.delete_finding is not None:
            if args.set or args.set_json or args.append_fix_attempt:
                parser.error("--delete-finding cannot combine with --set / --set-json / --append-fix-attempt")
            return cmd_delete_finding(args)
        if args.apply_decisions is not None:
            if args.set or args.set_json or args.append_fix_attempt or args.finding_id:
                parser.error("--apply-decisions cannot combine with --set / --set-json / --append-fix-attempt / --finding-id (tuples carry their own finding ids)")
            if args.dry_run:
                parser.error("--apply-decisions does not currently support --dry-run (batches write per tuple; run on a throwaway path or validate tuples upstream)")
            return cmd_apply_decisions(args)
        if args.set or args.set_json or args.append_fix_attempt is not None:
            return cmd_set_and_or_append(args)
    except SystemExit:
        raise
    except Exception as e:
        c.err_prompt(
            f"unexpected error: {type(e).__name__}: {e}",
            action="this is a bug; full traceback follows below."
        )
        traceback.print_exc(file=sys.stderr)
        return c.EXIT_UNEXPECTED

    parser.error("no mode selected (use --init, --add-finding, --delete-finding, --apply-decisions, --set, --set-json, or --append-fix-attempt)")


if __name__ == "__main__":
    sys.exit(main())
