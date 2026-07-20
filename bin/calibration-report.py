#!/usr/bin/env python3
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
import re
import statistics
import sys
from pathlib import Path

BANDS = [(0, 45, "0-44"), (45, 60, "45-59"), (60, 75, "60-74"), (75, 101, "75+")]
DISPOSITIONS = [
    "below_gate", "disproven", "uncertain", "confirmed_mechanical",
    "confirmed_manual", "confirmed_report", "pre_existing_report", "resolved",
]


def band_of(score):
    for lo, hi, label in BANDS:
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
        print("usage: calibration-report.py [reviews-root]", file=sys.stderr)
        return 64
    if len(argv) == 2:
        root = Path(argv[1]).expanduser()
    else:
        root = Path.home() / ".matthews-reviews"
        if not root.is_dir():
            root = Path.home() / ".adams-reviews"
    if not root.is_dir():
        print(f"ERROR: reviews root not found: {root}", file=sys.stderr)
        print("Action: pass the root explicitly: calibration-report.py <root>", file=sys.stderr)
        return 1

    runs = list(load_runs(root))
    if not runs:
        print(f"ERROR: no runs found under {root}", file=sys.stderr)
        return 1

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
    out += ["## Score-band → disposition matrix (validated findings)", "",
            "| Band | " + " | ".join(DISPOSITIONS) + " |",
            "|---|" + "---|" * len(DISPOSITIONS)]
    matrix = {label: {d: 0 for d in DISPOSITIONS} for _, _, label in BANDS}
    for _, artifact, _, _, _ in runs:
        for f in artifact.get("findings", []):
            s = f.get("score_phase4")
            if s is None:
                continue
            d = f.get("disposition")
            if d in DISPOSITIONS:
                matrix[band_of(s)][d] += 1
    for _, _, label in BANDS:
        row = matrix[label]
        out.append(f"| {label} | " + " | ".join(str(row[d]) for d in DISPOSITIONS) + " |")
    out += ["",
            "Reading: disproven/uncertain counts at or above the Phase-3 gate band",
            "(45+) are validation-spend on non-actionable findings — a high share",
            "suggests raising `gates.phase3_gate`; confirmed_* below the gate band",
            "suggests lowering it. Set values in `~/.matthews-reviews/config.json`.", ""]

    # --- per-phase token medians ---------------------------------------
    out += ["## Per-phase token medians (sub-agent)", "",
            "| Phase | Runs | Median | Max |", "|---|---|---|---|"]
    for phase in sorted(phase_token_series, key=lambda p: -statistics.median(phase_token_series[p])):
        series = phase_token_series[phase]
        out.append(f"| {phase} | {len(series)} | {int(statistics.median(series)):,} | {max(series):,} |")
    out.append("")

    sys.stdout.write("\n".join(out))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
