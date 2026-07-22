#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["jsonschema"]
# ///
"""sync-degraded.py — atomically reconcile artifact.degraded from phases.jsonl.

The three existing degradation counters are summed across every JSON object in
--phases-log. Missing or explicit-null counters contribute zero for parity
with the prior jq `// 0` aggregation; present non-null counters must be
non-negative integers. A positive aggregate replaces artifact.degraded with
the canonical three-counter object; an all-zero aggregate removes the optional
field. The full artifact is schema-validated before one atomic tmp+rename.
Malformed JSONL, invalid counters, unreadable/non-UTF-8 input, or schema failure
leaves the artifact untouched and emits an error-as-prompt block on stderr.

Usage:
  sync-degraded.py --artifact <artifact.json> --phases-log <phases.jsonl>

Stdout:
  degradation-sync: lens_dispatch_failures=<N> candidate_drop_failures=<N> finalization_failures=<N>

Exits: 0 success; 1 invalid/unreadable input or schema failure; 4 write failure;
64 usage error.
"""

import json
import sys
from pathlib import Path

import _common as c


COUNTERS = (
    "lens_dispatch_failures",
    "candidate_drop_failures",
    "finalization_failures",
)

_LOAD_FAILED = object()


def _reject_nonstandard_constant(value):
    raise ValueError(f"non-standard JSON constant {value}")


def load_artifact(path: Path):
    try:
        with path.open(encoding="utf-8") as artifact_file:
            return json.load(
                artifact_file,
                parse_constant=_reject_nonstandard_constant,
            )
    except FileNotFoundError:
        c.err_prompt(
            f"artifact not found at {path}",
            action="run artifact-patch.py --init first, then retry degradation sync.",
        )
    except json.JSONDecodeError as exc:
        c.err_prompt(
            f"artifact is not valid JSON at {path}: line {exc.lineno} column {exc.colno}: {exc.msg}",
            action="restore or regenerate the artifact before retrying degradation sync.",
        )
    except UnicodeError as exc:
        c.err_prompt(
            f"artifact is not valid UTF-8 at {path}: {exc}",
            action="restore or regenerate a UTF-8 JSON artifact before retrying degradation sync.",
        )
    except ValueError as exc:
        c.err_prompt(
            f"artifact is not strict JSON at {path}: {exc}",
            action="replace non-standard JSON constants, then retry degradation sync.",
        )
    except OSError as exc:
        c.err_prompt(
            f"could not read artifact at {path}: {exc}",
            action="verify the artifact path and permissions, then retry.",
        )
    return _LOAD_FAILED


def aggregate_phases(path: Path):
    totals = {name: 0 for name in COUNTERS}
    try:
        with path.open(encoding="utf-8") as phases:
            for line_number, raw_line in enumerate(phases, start=1):
                if not raw_line.strip():
                    continue
                try:
                    record = json.loads(
                        raw_line,
                        parse_constant=_reject_nonstandard_constant,
                    )
                except json.JSONDecodeError as exc:
                    c.err_prompt(
                        f"phases log is not valid JSONL at {path}:{line_number}: column {exc.colno}: {exc.msg}",
                        action="repair or regenerate phases.jsonl before retrying degradation sync.",
                    )
                    return None
                except ValueError as exc:
                    c.err_prompt(
                        f"phases log is not strict JSON at {path}:{line_number}: {exc}",
                        action="replace non-standard JSON constants, then retry degradation sync.",
                    )
                    return None
                if not isinstance(record, dict):
                    c.err_prompt(
                        f"phases log row at {path}:{line_number} must be a JSON object",
                        action="replace the row with an object emitted by log-phase.sh --record.",
                    )
                    return None
                for name in COUNTERS:
                    value = record.get(name, 0)
                    if value is None:
                        value = 0
                    if (
                        not isinstance(value, int)
                        or isinstance(value, bool)
                        or value < 0
                    ):
                        c.err_prompt(
                            f"phases log counter {name} at {path}:{line_number} must be a non-negative integer (got {value!r})",
                            action="repair the structured phase row, then retry degradation sync.",
                        )
                        return None
                    totals[name] += value
    except FileNotFoundError:
        c.err_prompt(
            f"phases log not found at {path}",
            action="pass the review's phases.jsonl path after Phase 6 logging has begun.",
        )
        return None
    except UnicodeError as exc:
        c.err_prompt(
            f"phases log is not valid UTF-8 at {path}: {exc}",
            action="restore or regenerate a UTF-8 phases.jsonl before retrying degradation sync.",
        )
        return None
    except OSError as exc:
        c.err_prompt(
            f"could not read phases log at {path}: {exc}",
            action="verify the phases log path and permissions, then retry.",
        )
        return None
    return totals


def main():
    parser = c.PromptArgumentParser(
        description="Atomically reconcile artifact.degraded from phases.jsonl."
    )
    parser.add_argument("--artifact", required=True, type=Path)
    parser.add_argument("--phases-log", required=True, type=Path)
    args = parser.parse_args()

    artifact = load_artifact(args.artifact)
    if artifact is _LOAD_FAILED:
        return c.EXIT_VALIDATION
    if not isinstance(artifact, dict):
        c.err_prompt(
            f"artifact root at {args.artifact} must be a JSON object",
            action="restore or regenerate a schema-valid artifact before retrying degradation sync.",
        )
        return c.EXIT_VALIDATION

    totals = aggregate_phases(args.phases_log)
    if totals is None:
        return c.EXIT_VALIDATION

    if sum(totals.values()) > 0:
        artifact["degraded"] = totals
    else:
        artifact.pop("degraded", None)

    errors = c.validate(artifact)
    if errors:
        shown = errors[:10]
        overflow = [f"  (+{len(errors) - 10} more)"] if len(errors) > 10 else []
        c.err_prompt(
            f"degradation sync would produce an invalid artifact ({len(errors)} schema violation(s))",
            context=["  " + error for error in shown] + overflow,
            action="fix the artifact or phases log; no changes were written.",
        )
        return c.EXIT_VALIDATION

    try:
        c.atomic_write(args.artifact, artifact)
    except OSError as exc:
        c.err_prompt(
            f"could not atomically write artifact at {args.artifact}: {exc}",
            action="verify the artifact directory is writable, then retry degradation sync.",
        )
        return c.EXIT_UNEXPECTED

    print(
        "degradation-sync: "
        + " ".join(f"{name}={totals[name]}" for name in COUNTERS)
    )
    return c.EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
