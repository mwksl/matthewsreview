#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.10"
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
  trace.md       — anomaly grep (killed | resume | wall_clock_exceeded)

Exit codes: 0 OK, 1 no runs found / bad root, 64 usage.
"""
import json
import os
import re
import statistics
import sys
from pathlib import Path
import _common as c

DEFAULT_PHASE4_BANDS = (45, 60, 75)
DISPOSITIONS = [
    "below_gate", "pending_validation", "disproven", "uncertain",
    "confirmed_mechanical", "confirmed_manual", "confirmed_report",
    "pre_existing_report", "partial", "regression", "resolved",
]


def _fmt_boundary(value):
    return str(int(value)) if float(value).is_integer() else f"{value:g}"


def phase4_thresholds(artifact):
    raw = (artifact.get("gates") or {}).get("phase4_bands")
    if (
        isinstance(raw, list)
        and len(raw) == 3
        and all(isinstance(v, (int, float)) and not isinstance(v, bool) for v in raw)
        and 0 <= raw[0] < raw[1] < raw[2] <= 100
    ):
        return tuple(raw)
    return DEFAULT_PHASE4_BANDS


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


def load_runs(root: Path):
    # Layout: <slug>/<branch (may contain slashes)>/<rev_*>/artifact.json —
    # depth varies, so anchor on rev_* directory names.
    for artifact_path in sorted(root.glob("*/**/artifact.json")):
        run_dir = artifact_path.parent
        if not run_dir.name.startswith("rev_"):
            continue
        try:
            artifact = json.loads(artifact_path.read_text())
        except (OSError, json.JSONDecodeError):
            continue
        demote = None
        phases_path = run_dir / "phases.jsonl"
        if phases_path.exists():
            for line in phases_path.read_text().splitlines():
                try:
                    row = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if row.get("demote_rate") is not None:
                    demote = row["demote_rate"]  # last write wins
        tokens = {}
        tokens_path = run_dir / "tokens.jsonl"
        if tokens_path.exists():
            for line in tokens_path.read_text().splitlines():
                try:
                    row = json.loads(line)
                except json.JSONDecodeError:
                    continue
                t = row.get("tokens")
                if isinstance(t, (int, float)):
                    tokens[row.get("phase", "?")] = tokens.get(row.get("phase", "?"), 0) + t
        anomalies = 0
        trace_path = run_dir / "trace.md"
        if trace_path.exists():
            anomalies = len(re.findall(r"killed|resume|wall_clock_exceeded",
                                       trace_path.read_text(errors="replace")))
        yield run_dir, artifact, demote, tokens, anomalies


def main(argv):
    if len(argv) > 2:
        c.err_prompt(
            "expected at most one reviews-root argument",
            action="run calibration-report.py [reviews-root].",
        )
        return c.EXIT_USAGE
    if len(argv) == 2:
        root = Path(argv[1]).expanduser()
    else:
        configured_root = os.environ.get("MATTHEWS_REVIEW_REVIEWS_ROOT")
        if configured_root:
            root = Path(configured_root).expanduser()
        else:
            root = Path.home() / ".matthews-reviews"
            if not root.is_dir():
                root = Path.home() / ".adams-reviews"
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
    for phase in sorted(phase_token_series, key=lambda p: -statistics.median(phase_token_series[p])):
        series = phase_token_series[phase]
        out.append(f"| {phase} | {len(series)} | {int(statistics.median(series)):,} | {max(series):,} |")
    out.append("")

    sys.stdout.write("\n".join(out))
    return c.EXIT_OK


if __name__ == "__main__":
    sys.exit(main(sys.argv))
