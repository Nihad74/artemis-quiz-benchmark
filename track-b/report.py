#!/usr/bin/env python3
"""Track B results report (decision D21): one Markdown file from the output folders of run.sh.

Usage: python3 report.py --out results.md <run-set> [<run-set> ...]

A run set is one run.sh output folder (parameters.json, <repetition>-<side>/). The report lists, per run set, the
validity of every run (D38), the request durations of Phases 1 to 3 (k6 summaries), the evaluation duration (D17), the
statistics freshness of Phase 3 (freshness.json), the resources of the containers, and the written rows; then side A
against side B over the valid runs only. With at least two valid runs per side it adds a 95% bootstrap confidence
interval of the median over runs (D6, D38 rule 3); with fewer, the value of the single run. p99 is shown only with at
least 100 observations (D38 rule 4).

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

CONTROL_TYPES = ["control-start", "control-load", "control-submit"]
PHASE1_TYPES = ["start-participation", "save", "submit"]
PHASE2_TYPES = ["statistics-overview", "statistics-points", "statistics-question", "statistics-footer"]
PHASE3_TYPES = ["practice-load", "practice-submit", "statistics-open", "statistics-reload"]
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
        self.control = load(folder / "control" / "summary.json")
        self.control_info = load(folder / "control" / "control.json") or {}
        self.phase1 = load(folder / "phase1" / "summary.json")
        self.phase2 = load(folder / "phase2" / "summary.json")
        self.phase3 = load(folder / "phase3" / "summary.json")
        self.phase3_info = load(folder / "phase3" / "phase3.json") or {}
        self.freshness = load(folder / "phase3" / "freshness.json")
        self.parameters = parameters

    def windows(self):
        """The sample windows (s) with their snapshot files: the control workflow and Phase 3 if they ran, Phases 1 and 2."""
        control_start, control_end = self.control_info.get("start"), self.control_info.get("end")
        phase3_start = self.phase3_info.get("start")
        low = control_end / 1000 if control_start and control_end else float("-inf")
        high = phase3_start / 1000 if phase3_start else float("inf")
        result = []
        if control_start and control_end:
            result.append(("control", (control_start / 1000, low), ("pg-stat-before-control.csv", "pg-stat-before.csv"), ("proc-stat-before-control.txt", "proc-stat-before.txt")))
        result.append(("1–2", (low, high), ("pg-stat-before.csv", "pg-stat-after.csv"), ("proc-stat-before.txt", "proc-stat-after.txt")))
        if phase3_start:
            result.append(("3", (high, float("inf")), ("pg-stat-after.csv", "pg-stat-after-phase3.csv"), ("proc-stat-after.txt", "proc-stat-after-phase3.txt")))
        return result

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

    def resources(self, limits, window):
        peaks = {}
        locks = active = 0
        samples = self.folder / "samples.jsonl"
        for line in samples.read_text().splitlines() if samples.exists() else []:
            sample = json.loads(line)
            if not window[0] <= sample["time"] < window[1]:
                continue
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

    def rows(self, before="pg-stat-before.csv", after="pg-stat-after.csv"):
        before, after = self.folder / before, self.folder / after
        if not (before.exists() and after.exists()):
            return None
        old = {row["relname"]: row for row in csv.DictReader(before.open())}
        totals = {}
        for row in csv.DictReader(after.open()):
            for key in ["n_tup_ins", "n_tup_upd", "n_tup_del"]:
                totals[key] = totals.get(key, 0) + int(row[key]) - int(old.get(row["relname"], {key: 0})[key])
        return totals

    def steal(self, before="proc-stat-before.txt", after="proc-stat-after.txt"):
        before, after = self.folder / before, self.folder / after
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
        summary = {0: run.control, 1: run.phase1, 2: run.phase2, 3: run.phase3}[phase]
        if summary is None:
            continue
        for type_ in types:
            values = trend(summary, f"{prefix}{type_}{suffix}")
            n = values.get("count")
            if not n:
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
    has_phase3 = any(run.phase3 for run in runs)
    side_runs = {side: [run for run in runs if run.side == side] for side in "AB"}
    out = [f"## {label}", ""]
    phase3 = (f"{parameters.get('practiceRate')} practice submissions per second for at most {parameters.get('practiceSeconds')} s"
              if parameters.get("phase3") else "– (not run)")
    out.append(f"Folder `{folder}`. Students: {parameters.get('students')}. Repetitions: {parameters.get('repetitions')}. "
               f"Phase 2 rounds: {parameters.get('rounds', '– (no Phase 2)')}. Phase 3: {phase3}. "
               f"Warm-up: {parameters.get('warmUpStudents')} students. "
               f"Schedule seed: {parameters.get('scheduleSeed')}. Tool revision `{str(parameters.get('toolRevision', ''))[:11]}`. "
               f"Started {parameters.get('startedAt')}.")
    out.append("")
    out.append(f"- Side A: `{' → '.join(parameters.get('sideA', []))}`")
    out.append(f"- Side B: `{' → '.join(parameters.get('sideB', []))}`")
    if min(len(side_runs["A"]), len(side_runs["B"])) < MIN_RUNS:
        out.append(f"- **Pilot:** fewer than {MIN_RUNS} runs per side (D6). The numbers are for orientation only; they are no result set.")
    out.append("")

    out += ["### Runs", "", "| Run | Measured | Valid | Reasons | Statistics | Phase 2 delay | Submissions in time | Failed requests (control / Phase 1 / 2 / 3) |", "|---|---|---|---|---|---|---|---|"]
    for run in runs:
        delay = run.info.get("phase2DelayMillis")
        submitted = count(run.phase1, "phase1_submitted_in_time")
        in_time = "–" if submitted is None else f"{submitted:.0f} of {parameters.get('students')}"
        failed = [count(summary, "http_req_failed", "passes") for summary in (run.control, run.phase1, run.phase2, run.phase3)]
        out.append(f"| {run.name} | `{run.info.get('measured', '?')}` | {'yes' if run.valid else '**no**'} | {', '.join(run.reasons()) or '–'} | "
                   f"{run.info.get('statisticsMode') or '–'} | {'–' if delay is None else f'{delay / 1000:.1f} s'} | "
                   f"{in_time} | "
                   f"{' / '.join('–' if value is None else f'{value:.0f}' for value in failed)} |")
    out.append("")

    if any(run.control for run in runs):
        out += ["### Control workflow (D20): request duration (ms)", "",
                "Text exercise submission by the same students before the quiz: start the exercise, open the editor, submit "
                "twice. It touches no quiz code; a difference between the sides is unrelated drift (D2).", "",
                "| Run | Request | n | Median | p95 | p99 | Max |", "|---|---|---|---|---|---|---|"]
        out += duration_rows(runs, 0, CONTROL_TYPES)
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

    if has_phase3:
        out += ["### Phase 3: request duration (ms)", "",
                "statistics-open: the page data when a tutor opens the point statistic; statistics-reload: the reloads after "
                "each notification (on-demand statistics only; stored statistics come with the websocket message).", "",
                "| Run | Request | n | Median | p95 | p99 | Max |", "|---|---|---|---|---|---|---|"]
        out += duration_rows(runs, 3, PHASE3_TYPES)
        out += ["", "### Phase 3: statistics freshness (ms)", "",
                "For the n-th answered practice submission, the time until a tutor's open point statistic shows at least n new "
                "unrated participants; one value per tutor and submission (freshness.mjs). Drain: from the last response to "
                "the complete page, the slowest tutor.", "",
                "| Run | Statistics | Submissions | Values (missing) | Median | p95 | p99 | Max | Drain | Websocket messages | Phase 3 length |",
                "|---|---|---|---|---|---|---|---|---|---|---|"]
        for run in runs:
            fresh = run.freshness
            if fresh is None:
                continue
            drains = [value for value in fresh["drainMillis"].values() if value is not None]
            drain = "–" if len(drains) < fresh["tutors"] or not drains else f"{max(drains):.0f}"
            length = (run.phase3 or {}).get("state", {}).get("testRunDurationMs")
            out.append(f"| {run.name} | {run.phase3_info.get('mode') or '–'} | {fresh['submissions']} | {fresh['values']} ({fresh['missing']}) | "
                       f"{ms(fresh['medianMillis'])} | {ms(fresh['p95Millis'])} | {ms(fresh['p99Millis'])} | {ms(fresh['maxMillis'])} | {drain} | "
                       f"{count(run.phase3, 'phase3_messages') or 0:.0f} | {'–' if length is None else f'{length / 1000:.1f} s'} |")
        out.append("")

    out += ["### Server, database, and k6", "",
            "Peaks of the samples every 5 s per window: the control workflow (from its start to its end), Phases 1 and 2 (to the "
            "start of Phase 3), and Phase 3 (to the end of the samples). Rows and CPU steal: from the snapshot before the window "
            "to the snapshot before the next one, each 15 s after the end of the window (window 1–2: Phase 1, the evaluation, "
            "and Phase 2).", "",
            "| Run | Window | Artemis CPU, memory | PostgreSQL CPU, memory | k6 CPU, memory | Lock waits | Active connections | CPU steal ticks | Rows ins / upd / del |",
            "|---|---|---|---|---|---|---|---|---|"]
    for run in runs:
        windows = run.windows()
        for label, window, pg, proc in windows:
            cells, locks, active = run.resources(limits, window)
            rows = run.rows(*pg)
            written = "–" if rows is None else f"{rows['n_tup_ins']} / {rows['n_tup_upd']} / {rows['n_tup_del']}"
            out.append(f"| {run.name} | {label} | {' | '.join(cells)} | {locks} | {active} | {run.steal(*proc)} | {written} |")
    out.append("")

    out += ["### Side A against side B (valid runs only)", "",
            "Median over the valid runs of each side; with at least two runs the 95% bootstrap interval over runs in brackets "
            "(D38 rule 3). Change: B against A, from the medians.", "",
            "| Metric | A | B | Change |", "|---|---|---|---|"]
    valid = {side: [run for run in side_runs[side] if run.valid] for side in "AB"}
    metrics = []
    if any(run.control for run in runs):
        metrics += [(f"Control {type_.removeprefix('control-')} p95 (ms)", lambda run, t=type_: trend(run.control, f"http_req_duration{{type:{t}}}").get("p(95)")) for type_ in CONTROL_TYPES]
    metrics += [(f"Phase 1 {type_} p95 (ms)", lambda run, t=type_: trend(run.phase1, f"http_req_duration{{type:{t}}}").get("p(95)")) for type_ in PHASE1_TYPES]
    metrics.append(("Evaluation (s)", lambda run: None if run.info.get("evaluationMillis") is None else run.info["evaluationMillis"] / 1000))
    if has_phase2:
        metrics += [(f"Phase 2 {type_} p95 (ms)", lambda run, t=type_: trend(run.phase2, f"http_req_duration{{type:{t}}}").get("p(95)")) for type_ in PHASE2_TYPES]
    if has_phase3:
        metrics.append(("Phase 3 practice-submit p95 (ms)", lambda run: trend(run.phase3, "http_req_duration{type:practice-submit}").get("p(95)")))
        metrics.append(("Phase 3 freshness median (ms)", lambda run: (run.freshness or {}).get("medianMillis")))
        metrics.append(("Phase 3 freshness p95 (ms)", lambda run: (run.freshness or {}).get("p95Millis")))
        metrics.append(("Phase 3 rows written", lambda run: None if run.rows("pg-stat-after.csv", "pg-stat-after-phase3.csv") is None
                        else sum(run.rows("pg-stat-after.csv", "pg-stat-after-phase3.csv").values())))
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
        phases = "1, 2, and 3" if any(run.phase3 for run in runs) else "1 and 2" if any(run.phase2 for run in runs) else "1"
        phases = f"control, {phases}" if any(run.control for run in runs) else phases
        overview.append(f"| {label} | {parameters.get('students')} | {phases} | "
                        f"{sum(run.valid for run in runs)} of {len(runs)} | `{str(parameters.get('toolRevision', ''))[:11]}` | {parameters.get('startedAt')} |")

    host = load(folders[-1] / "host.json") or {}
    header = [
        "# Quiz Module Benchmark: Track B Results",
        "",
        f"Generated by `track-b/report.py` of `github.com/Nihad74/artemis-quiz-benchmark` (revision `{revision}`) on "
        f"{datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M')} UTC from the run folders below. Do not edit by hand; run the "
        "script again after new runs. Setup and methods: `quiz-benchmark-track-b-setup.md`; decisions: `quiz-benchmark-decisions.md`.",
        "",
        f"Environment (D36: every run set runs on the local Mac): {host.get('cpuModel', '?')}, {host.get('engine', '?')}, "
        f"{host.get('engineCpus', '?')} CPUs and {(host.get('engineMemory') or 0) / 2**20:.0f} MiB for Docker.",
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
