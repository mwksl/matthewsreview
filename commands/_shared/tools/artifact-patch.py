#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["jsonschema"]
# ///
"""artifact-patch.py — canonical writer for artifact.json (DESIGN §8.2, §21.2).

Modes (CLI flags; mutually exclusive):
  --init <seed>             create fresh artifact at --path
  --add-finding <finding>   append a new finding to findings[]
  --set field=value         mutate a scalar field (repeatable). With
                            --finding-id, targets a finding; without,
                            targets top-level artifact fields.
  --append-fix-attempt <json>  append an entry to a finding's fix_attempts[]
                               (requires --finding-id). Combinable with
                               --set in a single call (DESIGN §26 worked
                               example: set current_state=resolved and
                               append the attempt in one patch).

Later modes added in subsequent commits: --dry-run.

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
import json
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

    c.atomic_write(args.path, seed)
    print(f"wrote {args.path}")
    return c.EXIT_OK


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


def _write_and_emit(path, artifact):
    """Common write tail: bump generated_at, validate, atomic write."""
    artifact["generated_at"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    errors = c.validate(artifact)
    if errors:
        shown = errors[:10]
        overflow = [f"  (+{len(errors) - 10} more)"] if len(errors) > 10 else []
        c.err_prompt(
            f"patched artifact is invalid ({len(errors)} schema violation(s))",
            context=["  " + e for e in shown] + overflow,
            action="this indicates a bug in the patch mode or a malformed input value."
        )
        return c.EXIT_VALIDATION
    c.atomic_write(path, artifact)
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
    return _write_and_emit(args.path, artifact)


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


def cmd_set_and_or_append(args):
    """Combined --set + --append-fix-attempt (DESIGN §26).

    Either or both can be present. Both operate on --finding-id when
    given (or top-level, for --set only). Order: --set first (so state
    transitions apply before the fix-attempt record lands), then
    append. One atomic write.
    """
    artifact = _load_or_fail(args.path)

    set_pairs = [parse_set_pair(p) for p in args.set] if args.set else []

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
        # --set only, top-level.
        if set_pairs:
            _apply_artifact_set(artifact, set_pairs)

    return _write_and_emit(args.path, artifact)


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
        "--append-fix-attempt",
        dest="append_fix_attempt",
        metavar="ATTEMPT_JSON",
        help="append an entry to finding.fix_attempts[] (requires --finding-id; inline JSON, @file, or -)"
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
    return p


def main():
    parser = build_parser()
    args = parser.parse_args()

    try:
        if args.init is not None:
            if args.set or args.append_fix_attempt:
                parser.error("--init cannot combine with --set or --append-fix-attempt")
            return cmd_init(args)
        if args.add_finding is not None:
            if args.set or args.append_fix_attempt:
                parser.error("--add-finding cannot combine with --set or --append-fix-attempt")
            return cmd_add_finding(args)
        if args.set or args.append_fix_attempt is not None:
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

    parser.error("no mode selected (use --init, --add-finding, --set, or --append-fix-attempt)")


if __name__ == "__main__":
    sys.exit(main())
