#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["jsonschema"]
# ///
"""artifact-patch.py — canonical writer for artifact.json (DESIGN §8.2, §21.2).

Modes (CLI flags; mutually exclusive):
  --init <seed>         create fresh artifact at --path

Later modes added in subsequent commits: --add-finding, --set,
--append-fix-attempt, --dry-run.

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
    mode = p.add_mutually_exclusive_group(required=True)
    mode.add_argument(
        "--init",
        metavar="SEED_JSON",
        help="create fresh artifact from seed (inline JSON, @file, or -)"
    )
    return p


def main():
    parser = build_parser()
    args = parser.parse_args()

    try:
        if args.init is not None:
            return cmd_init(args)
    except SystemExit:
        raise
    except Exception as e:
        c.err_prompt(
            f"unexpected error: {type(e).__name__}: {e}",
            action="this is a bug; full traceback follows below."
        )
        traceback.print_exc(file=sys.stderr)
        return c.EXIT_UNEXPECTED

    # Unreachable: argparse requires a mode.
    parser.error("no mode selected")


if __name__ == "__main__":
    sys.exit(main())
