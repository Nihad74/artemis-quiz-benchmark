#!/usr/bin/env python3
"""Track B results report (decision D21): one Markdown file from the output folders of run.sh.

Usage: python3 report.py --out results.md <run-set> [<run-set> ...]

A run set is one run.sh output folder (parameters.json, <repetition>-<side>/). The report lists, per run set, the
validity of every run (D38), the request durations of Phase 1 and Phase 2 (k6 summaries), the evaluation duration (D17),
the resources of the containers, and the written rows; then side A against side B over the valid runs only. With at
least two valid runs per side it adds a 95% bootstrap confidence interval of the median over runs (D6, D38 rule 3);
with fewer, the value of the single run. p99 is shown only with at least 100 observations (D38 rule 4).

Run sets with fewer than 5 runs per side are pilots (D6); the report says so. Standard library only.
"""

import argparse
import csv
import json
import os
import random
import re
import statistics
import subprocess
from datetime import datetime, timezone
from pathlib import Path

PHASE1_TYPES = ["start-participation", "save", "submit"]
PHASE2_TYPES = ["statistics-overview", "statistics-points", "statistics-question", "statistics-footer"]
PAGES = ["overview", "points", "question"]
MIN_RUNS = 5  # D6
MIN_P99 = 100  # D38 rule 4
BOOTSTRAP = 10_000


def load(path):
    return json.loads(path.read_text()) if path.exists() else None


def ms(value):
    return "–" if value is None else f"{value:.1f}"


def cpus(cpuset):
    """Number of CPUs in a cpuset such as "0-5" or "0-3,8"."""
    count = 0
    for part in str(cpuset).split(","):
        low, _, high = part.partition("-")
        count += int(high or low) - int(low) + 1
    return count


def gib(usage):
    """Used memory in GiB from a docker stats MemUsage such as "4.609GiB / 6GiB"."""
    match = re.match(r"([\d.]+)\s*([KMG]?i?B)", usage.split("/")[0].strip())
    if not match:
        return 0.0
    factor = {"B": 2**-30, "KiB": 2**-20, "MiB": 2**-10, "GiB": 1, "kB": 1e3 / 2**30, "MB": 1e6 / 2**30, "GB": 1e9 / 2**30}
    return float(match.group(1)) * factor[match.group(2)]


def trend(summary, metric):
    values = (summary or {}).get("metrics", {}).get(metric, {}).get("values")
    return values or {}


def count(summary, metric, key="count"):
    return (summary or {}).get("metrics", {}).get(metric, {}).get("values", {}).get(key)


class Run:
    def __init__(self, folder, parameters):
        self.folder = folder
        self.name = folder.name
        self.side = folder.name.split("-")[1]
        self.info = load(folder / "run.json") or {}
        self.phase1 = load(folder / "phase1" / "summary.json")
        self.phase2 = load(folder / "phase2" / "summary.json")
        self.parameters = parameters

    @property
    def valid(self):
        return bool(self.info.get("valid"))

    def reasons(self):
        reasons = [f"{key} {value}" for key, value in self.info.items() if key.endswith("Exit") and value != 0]
        if self.info.get("evaluated") is False:
            reasons.append("evaluation not logged")
        if self.info.get("semanticsEqual") is False:
            reasons.append("semantics differ from 1-A")
        return reasons

    def resources(self, limits):
        peaks = {}
        locks = active = 0
        samples = self.folder / "samples.jsonl"
        for line in samples.read_text().splitlines() if samples.exists() else []:
            sample = json.loads(line)
            locks = max(locks, sample.get("lockWaits", 0))
            active = max(active, sample.get("activeConnections", 0))
            for container in sample["containers"]:
                name = re.sub(r"^trackb-run-|-1$", "", container["Name"])
                cpu, mem = peaks.get(name, (0.0, 0.0))
                peaks[name] = (max(cpu, float(container["CPUPerc"].rstrip("%") or 0)), max(mem, gib(container["MemUsage"])))
        cells = []
        for name in ["artemis", "postgres", "k6"]:
            if name in peaks:
                cpu, mem = peaks[name]
                cells.append(f"{cpu:.0f}% of {limits.get(name, 0) * 100}%, {mem:.2f} GiB")
            else:
                cells.append("–")
        return cells, locks, active

    def rows(self):
        before, after = self.folder / "pg-stat-before.csv", self.folder / "pg-stat-after.csv"
        if not (before.exists() and after.exists()):
            return None
        old = {row["relname"]: row for row in csv.DictReader(before.open())}
        totals = {}
        for row in csv.DictReader(after.open()):
            for key in ["n_tup_ins", "n_tup_upd", "n_tup_del"]:
                totals[key] = totals.get(key, 0) + int(row[key]) - int(old.get(row["relname"], {key: 0})[key])
        return totals

    def steal(self):
        before, after = self.folder / "proc-stat-before.txt", self.folder / "proc-stat-after.txt"
        if not (before.exists() and after.exists()):
            return None
        first, last = (list(map(int, path.read_text().split()[1:])) for path in (before, after))
        return last[7] - first[7]


def median_with_interval(values, rng):
    """Median of the per-run values and, with at least two runs, a 95% percentile bootstrap interval over runs."""
    if not values:
        return "no valid run"
    median = statistics.median(values)
    if len(values) < 2:
        return f"{median:.1f} (n=1)"
    resampled = sorted(statistics.median(rng.choices(values, k=len(values))) for _ in range(BOOTSTRAP))
    low, high = resampled[int(0.025 * BOOTSTRAP)], resampled[int(0.975 * BOOTSTRAP) - 1]
    return f"{median:.1f} [{low:.1f}, {high:.1f}] (n={len(values)})"


def duration_rows(runs, phase, types, prefix="http_req_duration{type:", suffix="}"):
    lines = []
    for run in runs:
        summary = run.phase1 if phase == 1 else run.phase2
        if summary is None:
            continue
        for type_ in types:
            values = trend(summary, f"{prefix}{type_}{suffix}")
            n = values.get("count")
            if n is None:
                continue
            p99 = values.get("p(99)") if n >= MIN_P99 else None
            lines.append(f"| {run.name} | {type_} | {n:.0f} | {ms(values.get('med'))} | {ms(values.get('p(95)'))} | {ms(p99)} | {ms(values.get('max'))} |")
    return lines


def run_set_section(folder, label, rng):
    parameters = load(folder / "parameters.json") or {}
    compose = load(folder / "compose.json") or {}
    runs = [Run(path, parameters) for path in sorted(folder.glob("[0-9]*-[AB]"), key=lambda p: (int(p.name.split("-")[0]), p.name))]
    limits = {name: cpus(service.get("cpuset", 0)) for name, service in compose.get("services", {}).items() if service.get("cpuset")}
    if parameters.get("k6Cpuset"):
        limits["k6"] = cpus(parameters["k6Cpuset"])
    has_phase2 = any(run.phase2 for run in runs)
    side_runs = {side: [run for run in runs if run.side == side] for side in "AB"}
    out = [f"## {label}", ""]
    out.append(f"Folder `{folder}`. Students: {parameters.get('students')}. Repetitions: {parameters.get('repetitions')}. "
               f"Phase 2 rounds: {parameters.get('rounds', '– (no Phase 2)')}. Warm-up: {parameters.get('warmUpStudents')} students. "
               f"Schedule seed: {parameters.get('scheduleSeed')}. Tool revision `{str(parameters.get('toolRevision', ''))[:11]}`. "
               f"Started {parameters.get('startedAt')}.")
    out.append("")
    out.append(f"- Side A: `{' → '.join(parameters.get('sideA', []))}`")
    out.append(f"- Side B: `{' → '.join(parameters.get('sideB', []))}`")
    if min(len(side_runs["A"]), len(side_runs["B"])) < MIN_RUNS:
        out.append(f"- **Pilot:** fewer than {MIN_RUNS} runs per side (D6). The numbers are for orientation only; they are no result set.")
    out.append("")

    out += ["### Runs", "", "| Run | Measured | Valid | Reasons | Statistics | Phase 2 delay | Submissions in time | Failed requests (Phase 1 / Phase 2) |", "|---|---|---|---|---|---|---|---|"]
    for run in runs:
        delay = run.info.get("phase2DelayMillis")
        submitted = count(run.phase1, "phase1_submitted_in_time")
        in_time = "–" if submitted is None else f"{submitted:.0f} of {parameters.get('students')}"
        failed = [count(summary, "http_req_failed", "passes") for summary in (run.phase1, run.phase2)]
        out.append(f"| {run.name} | `{run.info.get('measured', '?')}` | {'yes' if run.valid else '**no**'} | {', '.join(run.reasons()) or '–'} | "
                   f"{run.info.get('statisticsMode') or '–'} | {'–' if delay is None else f'{delay / 1000:.1f} s'} | "
                   f"{in_time} | "
                   f"{' / '.join('–' if value is None else f'{value:.0f}' for value in failed)} |")
    out.append("")

    out += ["### Phase 1: request duration (ms)", "", "p99 only with at least 100 observations (D38 rule 4).", "",
            "| Run | Request | n | Median | p95 | p99 | Max |", "|---|---|---|---|---|---|---|"]
    out += duration_rows(runs, 1, PHASE1_TYPES)
    out.append("")

    out += ["### Evaluation (D17)", "", "| Run | Duration |", "|---|---|"]
    for run in runs:
        millis = run.info.get("evaluationMillis")
        out.append(f"| {run.name} | {'not logged' if millis is None else f'{millis / 1000:.2f} s'} |")
    out.append("")

    if has_phase2:
        out += ["### Phase 2: statistics request duration (ms)", "",
                "| Run | Request | n | Median | p95 | p99 | Max |", "|---|---|---|---|---|---|---|"]
        out += duration_rows(runs, 2, PHASE2_TYPES)
        out += ["", "### Phase 2: page duration (ms)", "", "Time until the page data and the footer of a page are both answered.", "",
                "| Run | Page | n | Median | p95 | p99 | Max |", "|---|---|---|---|---|---|---|"]
        out += duration_rows(runs, 2, PAGES, prefix="phase2_page_duration{page:")
        out += ["", "| Run | Phase 2 length |", "|---|---|"]
        for run in runs:
            length = (run.phase2 or {}).get("state", {}).get("testRunDurationMs")
            out.append(f"| {run.name} | {'–' if length is None else f'{length / 1000:.1f} s'} |")
        out.append("")

    out += ["### Server, database, and k6", "",
            "Peaks of the samples every 5 s from the start of Phase 1 to the end of the last phase. Rows: `pg_stat_user_tables` "
            "between the start of Phase 1 and 15 s after the last phase (all phases and the evaluation together).", "",
            "| Run | Artemis CPU, memory | PostgreSQL CPU, memory | k6 CPU, memory | Lock waits | Active connections | CPU steal ticks | Rows ins / upd / del |",
            "|---|---|---|---|---|---|---|---|"]
    for run in runs:
        cells, locks, active = run.resources(limits)
        rows = run.rows()
        written = "–" if rows is None else f"{rows['n_tup_ins']} / {rows['n_tup_upd']} / {rows['n_tup_del']}"
        out.append(f"| {run.name} | {' | '.join(cells)} | {locks} | {active} | {run.steal()} | {written} |")
    out.append("")

    out += ["### Side A against side B (valid runs only)", "",
            "Median over the valid runs of each side; with at least two runs the 95% bootstrap interval over runs in brackets "
            "(D38 rule 3). Change: B against A, from the medians.", "",
            "| Metric | A | B | Change |", "|---|---|---|---|"]
    valid = {side: [run for run in side_runs[side] if run.valid] for side in "AB"}
    metrics = [(f"Phase 1 {type_} p95 (ms)", lambda run, t=type_: trend(run.phase1, f"http_req_duration{{type:{t}}}").get("p(95)")) for type_ in PHASE1_TYPES]
    metrics.append(("Evaluation (s)", lambda run: None if run.info.get("evaluationMillis") is None else run.info["evaluationMillis"] / 1000))
    if has_phase2:
        metrics += [(f"Phase 2 {type_} p95 (ms)", lambda run, t=type_: trend(run.phase2, f"http_req_duration{{type:{t}}}").get("p(95)")) for type_ in PHASE2_TYPES]
    for name, value in metrics:
        per_side = {side: [v for v in (value(run) for run in valid[side]) if v is not None] for side in "AB"}
        change = "–"
        if per_side["A"] and per_side["B"] and statistics.median(per_side["A"]):
            change = f"{(statistics.median(per_side['B']) / statistics.median(per_side['A']) - 1) * 100:+.1f}%"
        out.append(f"| {name} | {median_with_interval(per_side['A'], rng)} | {median_with_interval(per_side['B'], rng)} | {change} |")
    out.append("")
    return out, runs


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("run_sets", nargs="+", type=Path)
    args = parser.parse_args()
    folders = [folder.resolve() for folder in args.run_sets]
    root = Path(os.path.commonpath(folders)) if len(folders) > 1 else folders[0].parent
    here = Path(__file__).resolve().parent
    revision = subprocess.run(["git", "-C", str(here), "rev-parse", "--short=11", "HEAD"], capture_output=True, text=True).stdout.strip()
    rng = random.Random(1)

    sections, overview = [], []
    for folder in folders:
        label = str(folder.relative_to(root)) if folder != root else folder.name
        lines, runs = run_set_section(folder, label, rng)
        sections += lines
        parameters = load(folder / "parameters.json") or {}
        overview.append(f"| {label} | {parameters.get('students')} | {'1 and 2' if any(run.phase2 for run in runs) else '1'} | "
                        f"{sum(run.valid for run in runs)} of {len(runs)} | `{str(parameters.get('toolRevision', ''))[:11]}` | {parameters.get('startedAt')} |")

    host = load(folders[-1] / "host.json") or {}
    header = [
        "# Quiz Module Benchmark: Track B Results",
        "",
        f"Generated by `thesis/benchmark/track_b/report.py` (revision `{revision}`) on "
        f"{datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M')} UTC from the run folders below. Do not edit by hand; run the "
        "script again after new runs. Setup and methods: `quiz-benchmark-track-b-setup.md`; decisions: `quiz-benchmark-decisions.md`.",
        "",
        f"Environment of the last run set: {host.get('cpuModel', '?')}, {host.get('engine', '?')}, {host.get('engineCpus', '?')} CPUs and "
        f"{(host.get('engineMemory') or 0) / 2**20:.0f} MiB for Docker. Results of different environments are never combined (D36).",
        "",
        "## Run sets",
        "",
        "| Run set | Students | Phases | Valid runs | Tool revision | Started |",
        "|---|---|---|---|---|---|",
        *overview,
        "",
    ]
    args.out.write_text("\n".join(header + sections))
    print(f"wrote {args.out}")


if __name__ == "__main__":
    main()
