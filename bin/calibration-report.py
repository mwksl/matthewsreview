#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["jsonschema"]
# ///
"""calibration-report.py — aggregate review-history telemetry into a
gate/model calibration report (markdown to stdout).

Answers: are the Phase-3 gate and Phase-4 bands well-placed? Where do
tokens go? How reliable are the lenses?

Usage:
  calibration-report.py [reviews-root]     (default ~/.matthews-reviews,
                                            legacy ~/.adams-reviews fallback)

Per run directory (<root>/<slug>/<branch>/<rev_*>/):
  artifact.json  — findings[].{disposition, score_phase3, score_phase4}
  phases.jsonl   — rows with demote_rate (Phase 3)
  tokens.jsonl   — rows with {phase, tokens}
  trace.md       — structured lens transport anomaly events

Exit codes: 0 OK, 1 no runs found / bad root, 64 usage.
"""
import math
from fractions import Fraction
import json
import os
import re
import statistics
import subprocess
import sys
from pathlib import Path
import _common as c

DISPOSITIONS = [
    "below_gate", "pending_validation", "disproven", "uncertain",
    "confirmed_mechanical", "confirmed_manual", "confirmed_report",
    "pre_existing_report", "partial", "regression", "resolved",
]


def _fmt_boundary(value):
    return str(int(value)) if float(value).is_integer() else f"{value:g}"


def phase4_thresholds(artifact):
    return c.resolve_phase4_bands(artifact)


def band_specs(thresholds):
    low, medium, high = thresholds
    return [
        (0, low, f"<{_fmt_boundary(low)}"),
        (low, medium, f"{_fmt_boundary(low)}–<{_fmt_boundary(medium)}"),
        (medium, high, f"{_fmt_boundary(medium)}–<{_fmt_boundary(high)}"),
        (high, 101, f"{_fmt_boundary(high)}+"),
    ]


def band_of(score, specs):
    for lo, hi, label in specs:
        if lo <= score < hi:
            return label
    return "?"

_LENS_ANOMALY_TOKEN = re.compile(
    r"(?:^|[^A-Za-z0-9])(?:killed|resume(?:d)?|wall_clock_exceeded)(?:$|[^A-Za-z0-9])"
)


def count_lens_anomalies(trace):
    """Count event rows, excluding paths, prose, summaries, and Codex events."""
    return sum(
        1
        for line in trace.splitlines()
        if line.startswith("lens_") and _LENS_ANOMALY_TOKEN.search(line)
    )


def _warn(message):
    print(f"WARNING: {message}", file=sys.stderr)


def _finite_number(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return False
    if isinstance(value, int):
        return True
    return math.isfinite(value)


def _reject_json_constant(value):
    raise ValueError(f"non-standard numeric constant {value}")


def _read_jsonl(path):
    try:
        lines = path.read_bytes().splitlines()
    except OSError as exc:
        _warn(f"{path}: cannot read telemetry ({exc}); skipping file")
        return
    for line_number, raw_line in enumerate(lines, 1):
        try:
            line = raw_line.decode("utf-8")
        except UnicodeDecodeError as exc:
            _warn(
                f"{path}:{line_number}: invalid UTF-8 ({exc.reason}); "
                "skipping row"
            )
            continue
        try:
            row = json.loads(line, parse_constant=_reject_json_constant)
        except (json.JSONDecodeError, ValueError) as exc:
            detail = getattr(exc, "msg", str(exc))
            _warn(f"{path}:{line_number}: invalid JSON ({detail}); skipping row")
            continue
        if not isinstance(row, dict):
            _warn(
                f"{path}:{line_number}: expected a JSON object, got "
                f"{type(row).__name__}; skipping row"
            )
            continue
        yield line_number, row


def _last_demote_rate(path):
    demote = None
    if not path.exists():
        return demote
    for line_number, row in _read_jsonl(path):
        if "demote_rate" not in row or row["demote_rate"] is None:
            continue
        value = row["demote_rate"]
        if not _finite_number(value) or not 0 <= value <= 1:
            _warn(
                f"{path}:{line_number}: demote_rate must be a finite number "
                "from 0 through 1; skipping row"
            )
            continue
        demote = value
    return demote


def _token_totals(path):
    totals = {}
    if not path.exists():
        return totals
    for line_number, row in _read_jsonl(path):
        phase = row.get("phase")
        if not isinstance(phase, str) or not phase.strip():
            _warn(
                f"{path}:{line_number}: phase must be a non-empty string; "
                "skipping row"
            )
            continue
        if "tokens" not in row:
            _warn(f"{path}:{line_number}: tokens is required; skipping row")
            continue
        tokens = row["tokens"]
        if tokens is None:
            continue
        if isinstance(tokens, bool) or not isinstance(tokens, int) or tokens < 0:
            _warn(
                f"{path}:{line_number}: tokens must be a nonnegative integer "
                "or null; skipping row"
            )
            continue
        totals[phase] = totals.get(phase, 0) + tokens
    return totals


def _integer_median(values):
    """Exact median for nonnegative integer telemetry without float overflow."""
    ordered = sorted(values)
    middle = len(ordered) // 2
    if len(ordered) % 2:
        return ordered[middle]
    return Fraction(ordered[middle - 1] + ordered[middle], 2)


def _format_integer_median(value):
    if isinstance(value, Fraction):
        if value.denominator == 1:
            return f"{value.numerator:,}"
        whole, remainder = divmod(value.numerator, value.denominator)
        if value.denominator == 2 and remainder == 1:
            return f"{whole:,}.5"
    if isinstance(value, int):
        return f"{value:,}"
    return str(value)


def load_runs(root: Path):
    # Layout: <slug>/<branch (may contain slashes)>/<rev_*>/artifact.json —
    # depth varies, so anchor on rev_* directory names.
    for artifact_path in sorted(root.glob("*/**/artifact.json")):
        run_dir = artifact_path.parent
        if not run_dir.name.startswith("rev_"):
            continue
        try:
            artifact_text = artifact_path.read_bytes().decode("utf-8")
            artifact = json.loads(
                artifact_text,
                parse_constant=_reject_json_constant,
            )
        except OSError as exc:
            _warn(f"{artifact_path}: cannot read artifact ({exc}); skipping run")
            continue
        except UnicodeDecodeError as exc:
            _warn(
                f"{artifact_path}: invalid UTF-8 ({exc.reason}); skipping run"
            )
            continue
        except (json.JSONDecodeError, ValueError) as exc:
            detail = getattr(exc, "msg", str(exc))
            _warn(f"{artifact_path}: invalid JSON ({detail}); skipping run")
            continue
        errors = c.validate(artifact)
        if errors:
            shown = "; ".join(errors[:3])
            overflow = f"; +{len(errors) - 3} more" if len(errors) > 3 else ""
            _warn(
                f"{artifact_path}: invalid artifact; skipping run: "
                f"{shown}{overflow}"
            )
            continue
        demote = _last_demote_rate(run_dir / "phases.jsonl")
        tokens = _token_totals(run_dir / "tokens.jsonl")
        anomalies = 0
        trace_path = run_dir / "trace.md"
        if trace_path.exists():
            anomalies = count_lens_anomalies(
                trace_path.read_text(errors="replace")
            )
        yield run_dir, artifact, demote, tokens, anomalies


def _resolve_reviews_root(explicit):
    helper = Path(__file__).with_name("review-root.sh")
    command = [str(helper)]
    if explicit is not None:
        command.extend(["--path", explicit])
    try:
        result = subprocess.run(
            command,
            check=False,
            capture_output=True,
            text=True,
        )
    except OSError as exc:
        c.err_prompt(
            f"could not run canonical reviews-root resolver {helper}: {exc}",
            action="restore bin/review-root.sh and ensure it is executable, then retry.",
        )
        return None, c.EXIT_VALIDATION
    if result.stderr:
        sys.stderr.write(result.stderr)
    if result.returncode != c.EXIT_OK:
        exit_code = (
            c.EXIT_USAGE
            if result.returncode == c.EXIT_USAGE
            else c.EXIT_VALIDATION
        )
        return None, exit_code
    lines = result.stdout.splitlines()
    if len(lines) != 1 or not lines[0]:
        c.err_prompt(
            "canonical reviews-root resolver did not return exactly one path",
            context=f"stdout={result.stdout!r}",
            action="repair bin/review-root.sh before retrying calibration.",
        )
        return None, c.EXIT_VALIDATION
    return Path(lines[0]), c.EXIT_OK


def main(argv):
    if len(argv) > 2:
        c.err_prompt(
            "expected at most one reviews-root argument",
            action="run calibration-report.py [reviews-root].",
        )
        return c.EXIT_USAGE
    root, root_rc = _resolve_reviews_root(argv[1] if len(argv) == 2 else None)
    if root is None:
        return root_rc
    if not root.is_dir():
        c.err_prompt(
            f"reviews root not found: {root}",
            action="set MATTHEWS_REVIEW_REVIEWS_ROOT or pass the root explicitly: calibration-report.py <root>.",
        )
        return c.EXIT_VALIDATION

    runs = list(load_runs(root))
    if not runs:
        c.err_prompt(
            f"no runs found under {root}",
            action="point calibration-report.py at a reviews root containing rev_*/artifact.json files.",
        )
        return c.EXIT_VALIDATION

    out = [f"# Calibration report — {root}", "",
           f"Runs analyzed: **{len(runs)}**", ""]

    # --- per-run table -------------------------------------------------
    out += ["## Per-run summary", "",
            "| Run | Findings | Validated | Demote rate | Waste (disproven+uncertain) | Tokens | Anomalies |",
            "|---|---|---|---|---|---|---|"]
    demotes, wastes = [], []
    phase_token_series = {}
    total_anomalies = 0
    for run_dir, artifact, demote, tokens, anomalies in runs:
        findings = artifact.get("findings", [])
        validated = [f for f in findings if f.get("score_phase4") is not None]
        # Waste = (disproven + uncertain) / total findings — the share of the
        # whole review (detection through validation) spent on findings that
        # ended non-actionable. Matches the historical telemetry basis.
        waste_n = sum(1 for f in findings if f.get("disposition") in ("disproven", "uncertain"))
        waste = (waste_n / len(findings)) if findings else None
        if demote is not None:
            demotes.append(demote)
        if waste is not None:
            wastes.append(waste)
        for phase, t in tokens.items():
            phase_token_series.setdefault(phase, []).append(t)
        total_anomalies += anomalies
        rel = run_dir.relative_to(root)
        out.append(
            f"| `{rel}` "
            f"| {len(findings)} | {len(validated)} "
            f"| {f'{demote:.3f}' if demote is not None else '—'} "
            f"| {f'{waste:.1%}' if waste is not None else '—'} "
            f"| {sum(tokens.values()):,} | {anomalies} |"
        )
    out.append("")
    if demotes:
        out.append(f"Aggregate demote rate: median **{statistics.median(demotes):.3f}** "
                   f"(min {min(demotes):.3f}, max {max(demotes):.3f}, n={len(demotes)})")
    if wastes:
        out.append(f"Aggregate waste ratio: median **{statistics.median(wastes):.1%}** "
                   f"(min {min(wastes):.1%}, max {max(wastes):.1%}, n={len(wastes)})")
    out += [f"Total lens anomalies (killed/resume/wall_clock): **{total_anomalies}**", ""]

    # --- score band → disposition matrix -------------------------------
    out += ["## Score-band → disposition matrix (validated findings)", ""]
    matrices = {}
    for _, artifact, _, _, _ in runs:
        thresholds = phase4_thresholds(artifact)
        specs = band_specs(thresholds)
        group = matrices.setdefault(
            thresholds,
            {
                "runs": 0,
                "specs": specs,
                "matrix": {
                    label: {d: 0 for d in DISPOSITIONS}
                    for _, _, label in specs
                },
            },
        )
        group["runs"] += 1
        for f in artifact.get("findings", []):
            score = f.get("score_phase4")
            if score is None:
                continue
            disposition = f.get("disposition")
            if disposition in DISPOSITIONS:
                group["matrix"][band_of(score, specs)][disposition] += 1

    for thresholds, group in sorted(matrices.items()):
        out += [
            f"Phase 4 bands: **{' / '.join(_fmt_boundary(v) for v in thresholds)}** "
            f"({group['runs']} run{'s' if group['runs'] != 1 else ''})",
            "",
            "| Band | " + " | ".join(DISPOSITIONS) + " |",
            "|---|" + "---|" * len(DISPOSITIONS),
        ]
        for _, _, label in group["specs"]:
            row = group["matrix"][label]
            out.append(f"| {label} | " + " | ".join(str(row[d]) for d in DISPOSITIONS) + " |")
        out.append("")
    out += [
        "Reading: disproven/uncertain counts in higher score bands are",
        "validation spend on non-actionable findings; a high share suggests",
        "raising `gates.phase3_gate`. Compare separate tables when runs used",
        "different Phase 4 bands. Set values in",
        "`~/.matthews-reviews/config.json`.",
        "",
    ]

    # --- per-phase token medians ---------------------------------------
    out += ["## Per-phase token medians (sub-agent)", "",
            "| Phase | Runs | Median | Max |", "|---|---|---|---|"]
    token_summaries = [
        (phase, len(series), _integer_median(series), max(series))
        for phase, series in phase_token_series.items()
    ]
    for phase, count, median, maximum in sorted(
        token_summaries, key=lambda row: -row[2]
    ):
        out.append(
            f"| {phase} | {count} | "
            f"{_format_integer_median(median)} | {maximum:,} |"
        )
    out.append("")

    sys.stdout.write("\n".join(out))
    return c.EXIT_OK


if __name__ == "__main__":
    sys.exit(main(sys.argv))
