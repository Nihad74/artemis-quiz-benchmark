#!/usr/bin/env python3
"""Track B results report (decision D21): one Markdown file from the output folders of run.sh.

Usage: python3 report.py --out results.md <run-set> [<run-set> ...]

A run set is one run.sh output folder (parameters.json, <repetition>-<side>/). The report lists, per run set, the
validity of every run with its reasons (judge.mjs, D38), the achieved workload (requests, rates, dropped iterations), the
request durations of the control workflow and Phases 1 to 3 (k6 summaries), the time to result and the evaluation
duration (D17), the initial and the repeated statistics reads of Phase 2, the statistics freshness of Phase 3
(freshness.json, censored values marked), the sampled maxima of the containers, and the written rows; then side A
against side B over the valid runs only. Every comparison value is first computed per run (median, p95, or p99 of that
run's requests) and then summarized over runs: the median of the per-run values and, with at least two valid runs per
side, a 95% percentile bootstrap interval over runs (D6, D38 rule 3); requests are never resampled. p99 is shown only if
every run has at least 100 observations (D38 rule 4).

A run has an outcome (judge.mjs, D44): valid, failed (the server failed the workload: evidence against the hypothesis,
never a latency sample), or invalid (the measurement cannot be trusted). A run set is a result set only if complete.json
matches the requested repetition and valid-run counts, with exactly that many valid runs per side and no failed or invalid
runs. At least five valid runs per side are required (D6); fewer form a complete pilot. Hypothesis verdicts (D16, D44)
are given only for a result set of the targeted pair (D37) at 2000 students. Other run sets show the same values as
an illustration, without a verdict. H3 reads statistics directly after the evaluation: the initial reads of Phase 2
(5 observations of the overview and the points page per run). Charts (SVG, charts.py) go to <out>-charts/ next to the
report: per run set side A against side B for the key metrics, and per comparison the medians across scales. They use
the same per-run values and intervals as the tables. Standard library only.
"""

import argparse
import csv
import json
import math
import os
import random
import re
import statistics
import subprocess
from datetime import datetime, timezone
from pathlib import Path

import charts

CONTROL_TYPES = ["control-start", "control-load", "control-submit"]
PHASE1_TYPES = ["start-participation", "save", "submit"]
PHASE2_TYPES = ["statistics-overview", "statistics-points", "statistics-question", "statistics-footer"]
PHASE3_TYPES = ["practice-load", "practice-submit", "statistics-open", "statistics-reload"]
READS = ["initial", "repeated"]
PAGES = ["overview", "points", "question"]
MIN_RUNS = 5  # D6
MIN_P99 = 100  # D38 rule 4
BOOTSTRAP = 10_000
VERDICT_STUDENTS = 2000  # D16
H3_PRACTICE_RATE = 10  # D42
PRACTICE_RATE_TOLERANCE = 0.05  # D43
# The comparison whose result set decides the hypothesis: H2 the end-to-end comparison (D45; the targeted pair
# 43bafcee17c -> f3463b75408 is dropped), H3 the targeted pair of D37.
HYPOTHESIS_PAIRS = {"H2": ("43bafcee17c", "8325896e0b4"), "H3": ("c136826e299", "24a062759c2")}
# Charts per run set: (metric name of the A/B table, panel label, bound of the hypothesis in D16 or None).
CHART_METRICS = [
    ("Phase 1 submit p95 (ms)", "Phase 1 submit p95 (ms) — H2", None),
    ("Phase 1 save p95 (ms)", "Phase 1 save p95 (ms)", None),
    ("Phase 1 start-participation p95 (ms)", "Phase 1 start participation p95 (ms)", None),
    ("Evaluation (s)", "Evaluation duration (s)", None),
    ("Time to result p95 (ms)", "Time to result p95 (ms)", None),
    ("Phase 2 statistics-overview initial p95 (ms)", "Statistics overview, initial reads p95 (ms) — H3", 1000),
    ("Phase 2 statistics-points initial p95 (ms)", "Statistics points, initial reads p95 (ms) — H3", 1000),
    ("Phase 2 statistics-question initial p95 (ms)", "Statistics question, initial reads p95 (ms) — H3", 1000),
    ("Phase 3 freshness p95 (ms, lower bound if censored)", "Statistics freshness p95 (ms; lower bound if censored) — H3", 2000),
    ("Phase 3 practice-submit p95 (ms)", "Phase 3 practice submit p95 (ms)", None),
    ("Control submit p95 (ms)", "Control workflow submit p95 (ms) — drift indicator", None),
]
# Charts across scales per comparison: a subset of CHART_METRICS.
SCALING_METRICS = ["Phase 1 submit p95 (ms)", "Evaluation (s)", "Time to result p95 (ms)",
                   "Phase 2 statistics-overview initial p95 (ms)", "Phase 3 freshness p95 (ms, lower bound if censored)"]
STATE_RANK = {"result set": 0, "complete pilot": 1, "incomplete": 2}
CHART_NOTE = ("Valid runs only. Dot: the value of one run; tick: median of the runs; bar: 95% bootstrap interval over "
              "runs (two runs or more); dashed line: bound of the hypothesis (D16).")


def commit_of(chain):
    """The commit of the measured image of a side (artemis-thesis:<commit>)."""
    return chain[-1].split(":")[-1] if chain else None


def set_state(folder, parameters, runs):
    """'result set', 'complete pilot', or 'incomplete', with a sentence for the report."""
    complete = load(folder / "complete.json")
    counts = {side: {outcome: sum(run.side == side and run.outcome == outcome for run in runs) for outcome in ("valid", "failed", "invalid")} for side in "AB"}
    text = "; ".join(f"side {side}: {c['valid']} valid, {c['failed']} failed, {c['invalid']} invalid" for side, c in counts.items())
    repetitions = parameters.get("repetitions")
    complete_matches = (complete and type(repetitions) is int and repetitions > 0
                        and len(runs) == 2 * repetitions
                        and all(type(complete.get(key)) is int and complete[key] == repetitions
                                for key in ("repetitions", "validA", "validB"))
                        and all(c == {"valid": repetitions, "invalid": 0, "failed": 0} for c in counts.values()))
    if complete_matches and repetitions >= MIN_RUNS:
        return "result set", f"**Result set** (complete.json, {repetitions} repetitions): {text}."
    if complete_matches:
        return "complete pilot", (f"**Complete pilot** ({repetitions} repetition{'s' if repetitions != 1 else ''}, fewer than {MIN_RUNS}, D6): "
                                  f"{text}. For orientation only; no result set and no verdict.")
    return "incomplete", f"**Incomplete attempt:** {text}. Server failures remain evidence, not latency samples or completed result sets; no statistical verdict."


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


def finite_number(value):
    return type(value) in (int, float) and math.isfinite(value)


def time_to_result(summary):
    values = trend(summary, "phase1_time_to_result")
    return values if (values.get("count") or 0) > 0 and count(summary, "phase1_results_received") != 0 else {}


def h3_practice_count(parameters):
    """The expected POST count at the configured H3 rate, capped at one POST per student."""
    seconds, students = parameters.get("practiceSeconds"), parameters.get("students")
    if parameters.get("phase3") is not True or parameters.get("practiceRate") != H3_PRACTICE_RATE:
        return None
    if not finite_number(seconds) or seconds <= 0 or type(students) is not int or students < 1:
        return None
    return math.floor(min(seconds * H3_PRACTICE_RATE, students) + 0.5)


def has_h3_freshness(run, expected):
    """Check whether the run's freshness measurement supports the H3 workload."""
    phase, fresh = run.phase3_info, run.freshness or {}
    tutors = phase.get("tutors")
    rate, span = fresh.get("achievedPostRate"), fresh.get("postSpanMillis")
    if expected is None or expected < 2 or phase.get("rate") != H3_PRACTICE_RATE or phase.get("submissions") != expected:
        return False
    if fresh.get("complete") is not True or fresh.get("errors") != [] or fresh.get("captureErrors", []) != []:
        return False
    if any(fresh.get(key) != expected for key in ("expectedSubmissions", "practiceSent", "submissions")):
        return False
    if count(run.phase3, "phase3_practice_answered") != expected or type(tutors) is not int or tutors < 1:
        return False
    if fresh.get("tutors") != tutors or fresh.get("values") != expected * tutors:
        return False
    if not finite_number(rate) or not finite_number(span) or span <= 0 or not math.isclose(rate, (expected - 1) * 1000 / span):
        return False
    if abs(rate - H3_PRACTICE_RATE) > H3_PRACTICE_RATE * PRACTICE_RATE_TOLERANCE:
        return False
    return finite_number(fresh.get("p95Millis")) and type(fresh.get("p95Censored")) is bool


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
    def outcome(self):
        # run.json before D44 has only valid.
        return self.info.get("outcome") or ("valid" if self.info.get("valid") else "invalid")

    @property
    def valid(self):
        return self.outcome == "valid"

    def reasons(self):
        if "reasons" in self.info:
            return self.info["reasons"]
        # run.json before judge.mjs (pilots of 2026-11-17 and 2026-11-18).
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


def median_interval(values, rng):
    """(median, low, high) of the per-run values; low and high form a 95% percentile bootstrap interval over runs and
    are None with fewer than two runs. None without values."""
    if not values:
        return None
    median = statistics.median(values)
    if len(values) < 2:
        return median, None, None
    resampled = sorted(statistics.median(rng.choices(values, k=len(values))) for _ in range(BOOTSTRAP))
    return median, resampled[int(0.025 * BOOTSTRAP)], resampled[int(0.975 * BOOTSTRAP) - 1]


def median_with_interval(interval, count):
    """Table cell of a median_interval result over count runs."""
    if interval is None:
        return "no valid run"
    median, low, high = interval
    return f"{median:.1f} (n=1)" if low is None else f"{median:.1f} [{low:.1f}, {high:.1f}] (n={count})"


def slug(text):
    return re.sub(r"[^A-Za-z0-9]+", "-", text).strip("-")


def bootstrap_high(values, rng, statistic=statistics.median):
    """Upper limit of the 95% percentile bootstrap interval over runs, or None with fewer than two runs."""
    if len(values) < 2:
        return None
    return sorted(statistic(rng.choices(values, k=len(values))) for _ in range(BOOTSTRAP))[int(0.975 * BOOTSTRAP) - 1]


def ratio_interval(a, b, rng):
    """Median ratio B/A of per-run values and its 95% bootstrap interval, resampling the runs of each side apart."""
    if len(a) < 2 or len(b) < 2 or not statistics.median(a):
        return None
    ratios = sorted(statistics.median(rng.choices(b, k=len(b))) / statistics.median(rng.choices(a, k=len(a))) for _ in range(BOOTSTRAP))
    return statistics.median(b) / statistics.median(a), ratios[int(0.025 * BOOTSTRAP)], ratios[int(0.975 * BOOTSTRAP) - 1]


def phase2_metric(summary, type_, read):
    """A Phase 2 metric of one read; run sets before the read tag (2026-11-18) have only the untagged metric."""
    tagged = trend(summary, f"http_req_duration{{type:{type_},read:{read}}}")
    if tagged or read == "initial":
        return tagged
    return trend(summary, f"http_req_duration{{type:{type_}}}")


def summary_of(run, phase):
    return {0: run.control, 1: run.phase1, 2: run.phase2, 3: run.phase3}[phase]


def duration_row(name, label, values):
    n = values.get("count")
    if not n:
        return None
    p99 = values.get("p(99)") if n >= MIN_P99 else None
    return f"| {name} | {label} | {n:.0f} | {ms(values.get('med'))} | {ms(values.get('p(95)'))} | {ms(p99)} | {ms(values.get('max'))} |"


def duration_rows(runs, phase, types, prefix="http_req_duration{type:", suffix="}"):
    lines = []
    for run in runs:
        summary = summary_of(run, phase)
        if summary is None:
            continue
        for type_ in types:
            if type_ == "submit" and not run.valid:
                continue
            row = duration_row(run.name, type_, trend(summary, f"{prefix}{type_}{suffix}"))
            if row:
                lines.append(row)
    return lines


def phase2_rows(runs, types):
    lines = []
    for run in runs:
        for type_ in types:
            for read in READS:
                row = duration_row(run.name, f"{type_} ({read})", phase2_metric(run.phase2, type_, read))
                if row:
                    lines.append(row)
    return lines


def workload_rows(run):
    """Achieved requests and rates per phase (D35, D38 rule 2): count over the k6 run time."""
    lines = []
    for label, summary in (("control", run.control), ("Phase 1", run.phase1), ("Phase 2", run.phase2), ("Phase 3", run.phase3)):
        if summary is None:
            continue
        requests = count(summary, "http_reqs") or 0
        seconds = (summary.get("state", {}).get("testRunDurationMs") or 0) / 1000
        rate = f"{requests / seconds:.1f}" if seconds else "–"
        dropped = count(summary, "dropped_iterations") or 0
        failed = count(summary, "http_req_failed", "passes") or 0
        lines.append(f"| {run.name} | {label} | {requests:.0f} | {seconds:.1f} | {rate} | {dropped:.0f} | {failed:.0f} |")
    return lines


def run_set_section(folder, label, rng, chart_dir):
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
    valid = {side: [run for run in side_runs[side] if run.valid] for side in "AB"}
    failed_runs = {side: [run for run in side_runs[side] if run.outcome == "failed"] for side in "AB"}
    state, state_text = set_state(folder, parameters, runs)
    out.append(f"- {state_text}")
    out.append("")

    out += ["### Runs", "", "Outcome (judge.mjs, D44): valid; **failed**: the server failed the workload, kept as evidence and excluded "
            "from the latency comparison; **invalid**: the measurement cannot be trusted.", "",
            "| Run | Measured | Outcome | Reasons | Statistics | Phase 2 first request after evaluation | Submissions in time | Failed requests (control / Phase 1 / 2 / 3) |", "|---|---|---|---|---|---|---|---|"]
    for run in runs:
        delay = run.info.get("phase2FirstRequestDelayMillis", run.info.get("phase2DelayMillis"))
        submitted = count(run.phase1, "phase1_submitted_in_time")
        in_time = "–" if submitted is None else f"{submitted:.0f} of {parameters.get('students')}"
        failed = [count(summary, "http_req_failed", "passes") for summary in (run.control, run.phase1, run.phase2, run.phase3)]
        out.append(f"| {run.name} | `{run.info.get('measured', '?')}` | {run.outcome if run.valid else f'**{run.outcome}**'} | {'; '.join(run.reasons()) or '–'} | "
                   f"{run.info.get('statisticsMode') or '–'} | {'–' if delay is None else f'{delay / 1000:.1f} s'} | "
                   f"{in_time} | "
                   f"{' / '.join('–' if value is None else f'{value:.0f}' for value in failed)} |")
    for run in runs:
        attempted = trend(run.phase1, "http_req_duration{type:submit}").get("count", 0)
        successful = count(run.phase1, "phase1_submitted_in_time")
        if attempted and successful == 0:
            out.append(f"**Failure evidence ({run.name}):** {attempted:.0f} submit attempts; none succeeded in time. "
                       "The request durations are not successful-submit latency samples. This evidence is retained independently of completion.")
    out.append("")
    out += ["", "Phase 2 first request: from the end of the evaluation (D17 log line) to the first statistics request of a tutor; "
            "run sets before 2026-11-18 show the end of the Phase 2 setup instead.", ""]

    out += ["### Achieved workload", "",
            "Requests of each k6 run, its run time, the achieved request rate, dropped iterations, and failed requests. Phase 1 "
            "is a closed loop per student (D35): the rates describe this cohort schedule, not the maximum throughput.", "",
            "| Run | Phase | Requests | Run time (s) | Requests per second | Dropped iterations | Failed |", "|---|---|---|---|---|---|---|"]
    for run in runs:
        out += workload_rows(run)
    out.append("")

    if any(run.control for run in runs):
        out += ["### Control workflow (D20): request duration (ms)", "",
                "Text exercise submission by the same students before the quiz: start the exercise, open the editor, submit "
                "twice. It touches no quiz code; a difference between the sides is unrelated drift (D2).", "",
                "| Run | Request | n | Median | p95 | p99 | Max |", "|---|---|---|---|---|---|---|"]
        out += duration_rows(runs, 0, CONTROL_TYPES)
        out.append("")

    out += ["### Phase 1: request duration (ms)", "",
            "Submit durations are shown only for valid runs. p99 only with at least 100 observations (D38 rule 4).", "",
            "| Run | Request | n | Median | p95 | p99 | Max |", "|---|---|---|---|---|---|---|"]
    out += duration_rows(runs, 1, PHASE1_TYPES)
    out.append("")

    out += ["### Evaluation and time to result (D17)", "",
            "Evaluation: the duration of `calculateAllResults` (timer log line). Time to result: from the stored due date of the "
            "quiz (the scheduled evaluation start) until a student's result message reaches k6 over the websocket; recorded "
            "since 2026-11-18. No latency statistics are shown when no results were received.", "",
            "| Run | Evaluation | Results received | Time to result median | p95 | p99 | Max |", "|---|---|---|---|---|---|---|"]
    for run in runs:
        millis = run.info.get("evaluationMillis")
        result = time_to_result(run.phase1)
        received = count(run.phase1, "phase1_results_received")
        n = result.get("count") or 0
        out.append(f"| {run.name} | {'not logged' if millis is None else f'{millis / 1000:.2f} s'} | "
                   f"{'–' if received is None else f'{received:.0f}'} | {ms(result.get('med'))} | {ms(result.get('p(95)'))} | "
                   f"{ms(result.get('p(99)') if n >= MIN_P99 else None)} | {ms(result.get('max'))} |")
    out.append("")

    if has_phase2:
        out += ["### Phase 2: statistics request duration (ms)", "",
                "initial: the first round of each tutor directly after the evaluation (5 requests per endpoint); repeated: the "
                "other rounds, all tutors at the same time (D38 rule 4). Run sets before 2026-11-18 had no such split; their "
                "values appear as repeated.", "",
                "| Run | Request | n | Median | p95 | p99 | Max |", "|---|---|---|---|---|---|---|"]
        out += phase2_rows(runs, PHASE2_TYPES)
        out += ["", "### Phase 2: page duration (ms)", "", "Time until the page data and the footer of a page are both answered.", "",
                "| Run | Page | n | Median | p95 | p99 | Max |", "|---|---|---|---|---|---|---|"]
        for run in runs:
            for page in PAGES:
                for read in READS:
                    values = trend(run.phase2, f"phase2_page_duration{{page:{page},read:{read}}}") or (trend(run.phase2, f"phase2_page_duration{{page:{page}}}") if read == "repeated" else {})
                    row = duration_row(run.name, f"{page} ({read})", values)
                    if row:
                        out.append(row)
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
                "An aggregate metric (D42): for the n-th answered practice submission, the time until a tutor's open point "
                "statistic shows at least n new unrated participants by the deadline; one value per tutor and submission "
                "(freshness.mjs). Values are signed: a count can appear before the n-th response reaches k6. A value a page "
                "never showed is censored at the deadline (a lower bound); `≥` marks a p95 among censored values. Drain: from "
                "the last response to the complete page, the slowest tutor. Websocket messages count only those received by "
                "the deadline. POST rate: the achieved rate of practice POSTs.", "",
                "| Run | Statistics | Practice POSTs (sent / answered / planned) | Values (censored) | Min | Median | p95 | p99 | Max | Drain | Websocket messages | POST rate | Measurement |",
                "|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
        for run in runs:
            fresh = run.freshness
            if fresh is None:
                continue
            drains = [value for value in fresh.get("drainMillis", {}).values() if value is not None]
            tutors = fresh.get("tutors")
            drain = "–" if not tutors or len(drains) < tutors else f"{max(drains):.0f}"
            censored = fresh.get("censored", fresh.get("missing", 0))
            p95 = f"{'≥' if fresh.get('p95Censored') else ''}{ms(fresh.get('p95Millis'))}"
            rate = fresh.get("achievedPostRate")
            measurement = "complete" if fresh.get("complete", True) else f"**incomplete:** {'; '.join(fresh['errors'])}"
            posts = " / ".join(str(fresh[key]) if fresh.get(key) is not None else "–" for key in ("practiceSent", "submissions", "expectedSubmissions"))
            messages = fresh.get("messagesPerTutor")
            out.append(f"| {run.name} | {run.phase3_info.get('mode') or '–'} | {posts} | {fresh.get('values', '–')} ({censored}) | "
                       f"{ms(fresh.get('minMillis'))} | {ms(fresh.get('medianMillis'))} | {p95} | {ms(fresh.get('p99Millis'))} | {ms(fresh.get('maxMillis'))} | {drain} | "
                       f"{'–' if messages is None else sum(messages.values())} | {'–' if rate is None else f'{rate:.2f}/s'} | {measurement} |")
        out.append("")

    out += ["### Server, database, and k6", "",
            "Sampled maxima: the highest value among the samples every 5 s per window (control workflow, Phases 1 and 2 up to "
            "the start of Phase 3, Phase 3); a short peak between two samples is not seen, and 0 sampled lock waits does not "
            "prove that no lock wait happened. Rows and CPU steal: from the snapshot before the window to the snapshot before the "
            "next one, each 15 s after the end of the window (window 1–2: Phase 1, the evaluation, and Phase 2).", "",
            "| Run | Window | Artemis CPU, memory | PostgreSQL CPU, memory | k6 CPU, memory | Lock waits | Active connections | CPU steal ticks | Rows ins / upd / del |",
            "|---|---|---|---|---|---|---|---|---|"]
    for run in runs:
        windows = run.windows()
        for window_label, window, pg, proc in windows:
            cells, locks, active = run.resources(limits, window)
            rows = run.rows(*pg)
            written = "–" if rows is None else f"{rows['n_tup_ins']} / {rows['n_tup_upd']} / {rows['n_tup_del']}"
            out.append(f"| {run.name} | {window_label} | {' | '.join(cells)} | {locks} | {active} | {run.steal(*proc)} | {written} |")
    out.append("")

    out += ["### Side A against side B (valid runs only)", "",
            "Each value is computed per run first (median, p95, or p99 of the run's requests), then summarized over the valid "
            "runs of each side: the median of the per-run values and, with at least two runs, the 95% bootstrap interval over "
            "runs in brackets (D6, D38 rule 3). p99 only if every run has at least 100 observations. Change: B against A, from "
            "the medians.", "",
            "| Metric | A | B | Change |", "|---|---|---|---|"]

    def stats_metrics(name, getter):
        """Median, p95, and eligible p99 of a request metric; getter(run) returns the k6 trend values of that run."""
        result = [(f"{name} median (ms)", lambda run: getter(run).get("med")), (f"{name} p95 (ms)", lambda run: getter(run).get("p(95)"))]
        if all((getter(run).get("count") or 0) >= MIN_P99 for run in valid["A"] + valid["B"]) and valid["A"] + valid["B"]:
            result.append((f"{name} p99 (ms)", lambda run: getter(run).get("p(99)")))
        return result

    metrics = []
    if any(run.control for run in runs):
        for type_ in CONTROL_TYPES:
            metrics += stats_metrics(f"Control {type_.removeprefix('control-')}", lambda run, t=type_: trend(run.control, f"http_req_duration{{type:{t}}}"))
    for type_ in PHASE1_TYPES:
        metrics += stats_metrics(f"Phase 1 {type_}", lambda run, t=type_: trend(run.phase1, f"http_req_duration{{type:{t}}}"))
    metrics.append(("Evaluation (s)", lambda run: None if run.info.get("evaluationMillis") is None else run.info["evaluationMillis"] / 1000))
    if any(time_to_result(run.phase1) for run in runs):
        metrics += stats_metrics("Time to result", lambda run: time_to_result(run.phase1))
    if has_phase2:
        has_initial = any(phase2_metric(run.phase2, "statistics-points", "initial") for run in runs)
        for type_ in PHASE2_TYPES:
            if has_initial:
                metrics += stats_metrics(f"Phase 2 {type_} initial", lambda run, t=type_: phase2_metric(run.phase2, t, "initial"))
            metrics += stats_metrics(f"Phase 2 {type_} repeated", lambda run, t=type_: phase2_metric(run.phase2, t, "repeated"))
    if has_phase3:
        metrics += stats_metrics("Phase 3 practice-submit", lambda run: trend(run.phase3, "http_req_duration{type:practice-submit}"))
        metrics.append(("Phase 3 freshness median (ms)", lambda run: (run.freshness or {}).get("medianMillis")))
        metrics.append(("Phase 3 freshness p95 (ms, lower bound if censored)", lambda run: (run.freshness or {}).get("p95Millis")))
        metrics.append(("Phase 3 rows written", lambda run: None if run.rows("pg-stat-after.csv", "pg-stat-after-phase3.csv") is None
                        else sum(run.rows("pg-stat-after.csv", "pg-stat-after-phase3.csv").values())))
    side_values = {}
    for name, value in metrics:
        per_side = {side: [v for v in (value(run) for run in valid[side]) if v is not None] for side in "AB"}
        intervals = {side: median_interval(per_side[side], rng) for side in "AB"}
        side_values[name] = {side: (per_side[side], intervals[side]) for side in "AB"}
        change = "–"
        if per_side["A"] and per_side["B"] and statistics.median(per_side["A"]):
            change = f"{(statistics.median(per_side['B']) / statistics.median(per_side['A']) - 1) * 100:+.1f}%"
        out.append(f"| {name} | {median_with_interval(intervals['A'], len(per_side['A']))} | "
                   f"{median_with_interval(intervals['B'], len(per_side['B']))} | {change} |")
    out.append("")
    sides = {"A": commit_of(parameters.get("sideA")), "B": commit_of(parameters.get("sideB"))}
    panels = []
    for name, panel_label, bound in CHART_METRICS:
        if name not in side_values or not any(side_values[name][side][0] for side in "AB"):
            continue
        panel = {"label": panel_label, "bound": bound}
        for side in "AB":
            values, interval = side_values[name][side]
            if interval:
                panel[side] = {"values": values, "median": interval[0], "low": interval[1], "high": interval[2]}
        panels.append(panel)
    if panels:
        state_label = set_state(folder, parameters, runs)[0]
        title = f"{label}: {parameters.get('students')} students, {state_label}"
        file = chart_dir / f"{slug(label)}-ab.svg"
        file.write_text(charts.interval_chart(title, sides, panels, CHART_NOTE))
        out += [f"![Side A against side B, {label}]({chart_dir.name}/{file.name})", ""]

    out += ["### Hypothesis checks (D16, D44, D45)", "",
            f"A verdict only for a result set of the comparison of the hypothesis at {VERDICT_STUDENTS} students (D16, D45): "
            f"H2 from the end-to-end comparison `43bafcee17c` → `8325896e0b4` (the complete refactoring against the relational "
            f"baseline; a difference between two versions, including unrelated drift, which the control workflow indicates), "
            f"H3 from the targeted pair `c136826e299` → `24a062759c2` (D37). Every other run set shows the values as an "
            "illustration, without a verdict. Server failures remain separate regression evidence, never completed latency "
            "samples. H2: ratio B/A "
            "of the per-run submit p95 over five valid runs per side, 95% bootstrap interval; holds "
            "if the upper limit is at most 1.10. H3 statistics: the initial reads of Phase 2, directly after the evaluation "
            "(D16; each tutor's first round, 5 observations of the overview and the points page and 50 of the question pages "
            "per run, so a per-run p95 of the overview is close to its maximum); upper limit of the 95% bootstrap interval of "
            "the per-run p95 on side B. The repeated reads are in the table above and are not part of H3. H3 freshness: "
            f"the same for the per-run freshness p95; a p95 among censored values counts as above the bound. Freshness "
            f"requires the configured rate of {H3_PRACTICE_RATE}/s, complete counts, and an achieved POST rate within "
            f"{PRACTICE_RATE_TOLERANCE:.0%} of that rate in every run on both sides.", "",
            "| Check | Value (side B unless stated) | Observations per run | Bound | Result |", "|---|---|---|---|---|"]
    students = parameters.get("students")
    a_commit, b_commit = commit_of(parameters.get("sideA")), commit_of(parameters.get("sideB"))

    def no_verdict(hypothesis):
        """Why this run set gives no verdict for the hypothesis, or None."""
        pair = HYPOTHESIS_PAIRS[hypothesis]
        reasons = []
        if (a_commit, b_commit) != pair:
            reasons.append(f"not the {hypothesis} pair")
        if students != VERDICT_STUDENTS:
            reasons.append(f"{students} students, not {VERDICT_STUDENTS}")
        if state != "result set":
            reasons.append(state)
        return f"no verdict ({', '.join(reasons)})" if reasons else None

    def result(hypothesis, holds, observations):
        """Statistical verdicts require the specified comparison, cohort and five valid per-run values."""
        verdict = no_verdict(hypothesis)
        if verdict:
            return verdict
        if observations < MIN_RUNS:
            return "untested: fewer than five valid per-run values"
        return "untested: missing data" if holds is None else ("holds" if holds else "**fails**")

    failures = "; ".join(f"side {side} failed {len(failed_runs[side])} of {len(side_runs[side])}" for side in "AB" if failed_runs[side])
    submit = {side: [v for v in (trend(run.phase1, "http_req_duration{type:submit}").get("p(95)") for run in valid[side]) if v is not None] for side in "AB"}
    ratio = ratio_interval(submit["A"], submit["B"], rng)
    value = f"{ratio[0]:.3f} [{ratio[1]:.3f}, {ratio[2]:.3f}]" if ratio else "fewer than two valid runs per side"
    if failures:
        value += f" ({failures})"
    submits = [trend(run.phase1, "http_req_duration{type:submit}").get("count") for run in valid["B"]]
    h2_result = result('H2', None if not ratio else ratio[2] <= 1.10, min(len(submit['A']), len(submit['B'])))
    # Structured copy of the hypothesis rows for the thesis tables: (hypothesis, check, value, bound, result).
    hypotheses = [("H2", "Live submit p95, ratio B/A, median [95% interval]", value, "≤ 1.10", h2_result)]
    out.append(f"| H2 submit p95 B/A | {value} | {', '.join(f'{c:.0f}' for c in submits if c) or '–'} | ≤ 1.10 | {h2_result} |")
    if has_phase2:
        for type_ in PHASE2_TYPES[:3]:
            values = [trend(run.phase2, f"http_req_duration{{type:{type_},read:initial}}").get("p(95)") for run in valid["B"]]
            values = [v for v in values if v is not None]
            counts = sorted({trend(run.phase2, f"http_req_duration{{type:{type_},read:initial}}").get("count") for run in valid["B"]} - {None})
            high = bootstrap_high(values, rng)
            cell = "no initial reads recorded" if not values else (f"{values[0]:.1f} (one run)" if high is None else f"{high:.1f}")
            h3_result = result('H3', None if high is None else high < 1000, len(values))
            hypotheses.append(("H3", f"{type_.removeprefix('statistics-').capitalize()} statistics, initial read p95 (ms), upper interval limit",
                               cell, "< 1000", h3_result))
            out.append(f"| H3 {type_} initial p95 (ms) | {cell} | {', '.join(f'{c:.0f}' for c in counts) or '–'} | < 1000 | {h3_result} |")
    if has_phase3 or parameters.get("phase3"):
        expected = h3_practice_count(parameters)
        candidate = [run.freshness for run in valid["B"] if run.freshness and finite_number(run.freshness.get("p95Millis"))]
        values = [fresh["p95Millis"] for fresh in candidate]
        censored = any(fresh.get("p95Censored") for fresh in candidate)
        high = bootstrap_high(values, rng)
        cell = ("–" if high is None else f"{high:.1f}") + (" (censored)" if censored else "")
        counts = sorted({fresh.get("values") for fresh in candidate} - {None})
        verdict = no_verdict("H3")
        if verdict is None:
            if parameters.get("practiceRate") != H3_PRACTICE_RATE:
                verdict = f"untested: configured practice rate is not {H3_PRACTICE_RATE}/s"
            elif not all(has_h3_freshness(run, expected) for side in "AB" for run in valid[side]):
                verdict = f"untested: incomplete {H3_PRACTICE_RATE}/s practice evidence"
            else:
                verdict = result("H3", None if high is None else (not censored and high < 2000), len(values))
        hypotheses.append(("H3", "Statistics freshness p95 (ms), upper interval limit", cell, "< 2000", verdict))
        out.append(f"| H3 freshness p95 (ms) | {cell} | {', '.join(str(c) for c in counts) or '–'} | < 2000 | {verdict} |")
    else:
        hypotheses.append(("H3", "Statistics freshness p95 (ms), upper interval limit", "Phase 3 not run", "< 2000", "untested (D38 rule 6)"))
        out.append("| H3 freshness p95 (ms) | Phase 3 not run | – | < 2000 | untested (D38 rule 6) |")
    out.append("")
    return out, runs, side_values, hypotheses


# Thesis tables: comparison names, the metrics of the table at 2000 students, and the metrics across scales. Keys are
# metric names of the A/B table; labels are for the thesis.
COMPARISON_NAMES = {("43bafcee17c", "8325896e0b4"): "End-to-end (H2)", ("c136826e299", "24a062759c2"): "On-demand statistics (H3)"}
THESIS_METRICS = [
    ("Phase 1 submit p95 (ms)", "Live submit p95 (ms)"),
    ("Phase 1 save p95 (ms)", "Live save p95 (ms)"),
    ("Phase 1 start-participation p95 (ms)", "Start participation p95 (ms)"),
    ("Evaluation (s)", "Evaluation duration (s)"),
    ("Time to result p95 (ms)", "Time to result p95 (ms)"),
    ("Phase 2 statistics-overview initial p95 (ms)", "Statistics overview, initial read p95 (ms)"),
    ("Phase 2 statistics-points initial p95 (ms)", "Statistics points, initial read p95 (ms)"),
    ("Phase 2 statistics-question initial p95 (ms)", "Statistics question, initial read p95 (ms)"),
    ("Phase 3 freshness p95 (ms, lower bound if censored)", "Statistics freshness p95 (ms)"),
    ("Phase 3 practice-submit p95 (ms)", "Practice submit p95 (ms)"),
    ("Phase 3 rows written", "Rows written in Phase 3"),
    ("Control submit p95 (ms)", "Control submit p95 (ms), drift indicator"),
]
THESIS_SCALE_METRICS = ["Phase 1 submit p95 (ms)", "Evaluation (s)", "Time to result p95 (ms)",
                        "Phase 2 statistics-overview initial p95 (ms)", "Phase 3 freshness p95 (ms, lower bound if censored)"]
THIN = "\u2009"  # thousands separator: a space in Markdown, \, in LaTeX


def number(value):
    """29 098 for large values, 15.4 from 1 on, 0.52 below 1."""
    if abs(value) >= 1000:
        return f"{value:,.0f}".replace(",", THIN)
    return f"{value:.1f}" if abs(value) >= 1 else f"{value:.2f}"


def interval_cell(interval):
    if not interval:
        return "–"
    median, low, high = interval
    return number(median) if low is None else f"{number(median)} [{number(low)}, {number(high)}]"


def change_cell(a, b):
    if not a or not b or not a[0]:
        return "–"
    return f"{(b[0] / a[0] - 1) * 100:+.1f}%".replace("-", "−")


def tex(text):
    """Markdown table text as LaTeX: special characters, bold, arrows, comparison signs, and thin spaces."""
    text = re.sub(r"`([^`]*)`", r"\1", text)
    for old, new in (("\\", r"\textbackslash{}"), ("&", r"\&"), ("%", r"\%"), ("_", r"\_"), ("#", r"\#")):
        text = text.replace(old, new)
    text = re.sub(r"\*\*([^*]+)\*\*", r"\\textbf{\1}", text)
    for old, new in (("≤", r"$\leq$"), ("<", r"$<$"), ("→", r"$\rightarrow$"), ("−", r"$-$"), ("–", "--"), (THIN, r"\,")):
        text = text.replace(old, new)
    return text


def thesis_tables(comparisons):
    """The combined thesis tables from the result sets only (pilots never enter them): key metrics at 2000 students per
    comparison, the hypothesis verdicts, and the medians across scales. Returns (Markdown lines, LaTeX text)."""
    named = {}
    for (side_a, side_b), entries in comparisons.items():
        pair = (commit_of(list(side_a)), commit_of(list(side_b)))
        scales = {}
        for entry in sorted(entries, key=lambda e: e["started"]):
            if entry["state"] == "result set":
                scales[entry["students"]] = entry
        if scales:
            named[COMPARISON_NAMES.get(pair, f"{pair[0]} → {pair[1]}")] = (pair, scales)
    md = ["## Thesis tables", "",
          "Generated from result sets only (5 valid runs per side, D6); pilots and incomplete sets never enter these tables. "
          f"The same tables in LaTeX (booktabs): the file `*-thesis.tex` next to this report.", ""]
    if not named:
        md += ["No result set yet.", ""]
        return md, "% Track B thesis tables: no result set yet.\n"
    revisions = sorted({entry["revision"] for _, scales in named.values() for entry in scales.values()})
    method = (f"Median of the per-run values over the valid runs, 95% percentile bootstrap interval over runs in brackets "
              f"(10000 resamples). Change: B against A, from the medians. Local Mac (D36); tool revision "
              f"{', '.join(r[:11] for r in revisions)}.")
    groups, verdicts, scaling = [], [], []
    for name, (pair, scales) in named.items():
        if VERDICT_STUDENTS in scales:
            values = scales[VERDICT_STUDENTS]["values"]
            rows = []
            for key, label in THESIS_METRICS:
                sides = values.get(key)
                if sides and (sides["A"][1] or sides["B"][1]):
                    rows.append([label, interval_cell(sides["A"][1]), interval_cell(sides["B"][1]), change_cell(sides["A"][1], sides["B"][1])])
            groups.append((f"{name}: A = {pair[0]}, B = {pair[1]}", rows))
            for hypothesis, check, value, bound, result in scales[VERDICT_STUDENTS]["hypotheses"]:
                if not result.startswith("no verdict"):
                    verdicts.append([hypothesis, name, check, value, bound, result])
        sizes = sorted(scales)
        if len(sizes) > 1:
            rows = []
            for key in THESIS_SCALE_METRICS:
                label = dict(THESIS_METRICS)[key]
                cells = []
                for students in sizes:
                    sides = scales[students]["values"].get(key)
                    a, b = (sides["A"][1], sides["B"][1]) if sides else (None, None)
                    cells.append(f"{number(a[0])} → {number(b[0])}" if a and b else "–")
                if any(cell != "–" for cell in cells):
                    rows.append([label, *cells])
            scaling.append((f"{name}: A → B", sizes, rows))

    def md_table(header, rows):
        return ["| " + " | ".join(header) + " |", "|" + "---|" * len(header),
                *("| " + " | ".join(cell.replace(THIN, " ") for cell in row) + " |" for row in rows), ""]

    def tex_table(caption, label, spec, header, row_groups):
        lines = [r"\begin{table}[htbp]", r"\centering", r"\small", f"\\caption{{{tex(caption)}}}", f"\\label{{{label}}}",
                 f"\\begin{{tabular}}{{{spec}}}", r"\toprule", " & ".join(tex(cell) for cell in header) + r" \\", r"\midrule"]
        for index, (title, rows) in enumerate(row_groups):
            if title:
                if index:
                    lines.append(r"\midrule")
                lines.append(f"\\multicolumn{{{len(header)}}}{{l}}{{\\textit{{{tex(title)}}}}} \\\\")
            lines += [" & ".join(tex(cell) for cell in row) + r" \\" for row in rows]
        return lines + [r"\bottomrule", r"\end{tabular}", r"\end{table}", ""]

    header = ["Metric", "A", "B", "Change"]
    caption = f"Track B at {VERDICT_STUDENTS} students, both comparisons. {method}"
    md.append(f"### Table 1: key metrics at {VERDICT_STUDENTS} students")
    md += ["", method, ""]
    for title, rows in groups:
        md += [f"**{title}**", "", *md_table(header, rows)]
    out = ["% Track B thesis tables, generated by track-b/report.py; do not edit. Needs \\usepackage{booktabs}.", ""]
    if groups:
        out += tex_table(caption, "tab:trackb-2000", "lrrr", header, groups)
    vheader = ["Hypothesis", "Comparison", "Check", "Value", "Bound", "Result"]
    vcaption = (f"Track B hypothesis checks at {VERDICT_STUDENTS} students (D16, D44, D45). H2: median ratio B/A of the per-run "
                "submit p95 with its 95% bootstrap interval. H3: upper limit of the 95% bootstrap interval of the per-run p95 on "
                "side B. The bounds are proposals for the supervisor.")
    md += ["### Table 2: hypothesis checks", "", vcaption, ""]
    md += md_table(vheader, verdicts) if verdicts else ["No verdict yet.", ""]
    if verdicts:
        out += tex_table(vcaption, "tab:trackb-hypotheses", "lllrll", vheader, [(None, verdicts)])
    for index, (title, sizes, rows) in enumerate(scaling):
        sheader = ["Metric", *(f"{s} students" for s in sizes)]
        scaption = f"Track B across scales, {title} (medians over 5 valid runs per side)."
        md += [f"### Table {3 + index}: {title} across scales", "", scaption, "", *md_table(sheader, rows)]
        out += tex_table(scaption, f"tab:trackb-scales-{slug(title.split(':')[0]).lower()}", "l" + "r" * len(sizes), sheader, [(None, rows)])
    return md, "\n".join(out)


def scaling_section(comparisons, chart_dir):
    """One chart per comparison measured at two or more scales: the median and interval of each side per scale. At a
    scale with several run sets, the best state wins (result set, complete pilot, incomplete), then the latest start."""
    out = []
    for (side_a, side_b), sets in comparisons.items():
        chosen = {}
        for entry in sorted(sets, key=lambda e: (-STATE_RANK.get(e["state"], 3), e["started"])):
            chosen[entry["students"]] = entry
        if len(chosen) < 2:
            continue
        scales = sorted(chosen)
        labels = dict((name, label) for name, label, _ in CHART_METRICS)
        bounds = dict((name, bound) for name, _, bound in CHART_METRICS)
        panels = []
        for name in SCALING_METRICS:
            panel = {"label": labels[name], "bound": bounds[name], "A": {}, "B": {}}
            for students, entry in chosen.items():
                for side in "AB":
                    interval = entry["values"].get(name, {}).get(side, ([], None))[1]
                    if interval:
                        panel[side][students] = interval
            if panel["A"] or panel["B"]:
                panels.append(panel)
        if not panels:
            continue
        sides = {"A": commit_of(list(side_a)), "B": commit_of(list(side_b))}
        pilot = any(entry["state"] != "result set" for entry in chosen.values())
        title = f"{sides['A']} → {sides['B']} across scales{' (includes pilots)' if pilot else ''}"
        file = chart_dir / f"scaling-{slug(sides['A'])}-{slug(sides['B'])}.svg"
        file.write_text(charts.scaling_chart(title, sides, scales, panels,
                                             "Valid runs only. Dot: median of the per-run values; whisker: 95% bootstrap "
                                             "interval over runs (two runs or more); dashed line: bound of the hypothesis (D16)."))
        out += [f"## Across scales: `{' → '.join(side_a)}` against `{' → '.join(side_b)}`", "",
                "Run set per scale (the best state, then the latest): "
                + "; ".join(f"{s} students: {chosen[s]['label']} ({chosen[s]['state']})" for s in scales)
                + ". Pilots are for orientation only (D6).", "",
                f"![Across scales, {sides['A']} against {sides['B']}]({chart_dir.name}/{file.name})", ""]
    return out


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
    # The charts of this report only: earlier SVGs in the folder are removed, so none outlives its run set.
    chart_dir = args.out.with_name(f"{args.out.stem}-charts")
    chart_dir.mkdir(parents=True, exist_ok=True)
    for old in chart_dir.glob("*.svg"):
        old.unlink()

    sections, overview, comparisons = [], [], {}
    for folder in folders:
        label = str(folder.relative_to(root)) if folder != root else folder.name
        lines, runs, side_values, hypotheses = run_set_section(folder, label, rng, chart_dir)
        sections += lines
        parameters = load(folder / "parameters.json") or {}
        phases = "1, 2, and 3" if any(run.phase3 for run in runs) else "1 and 2" if any(run.phase2 for run in runs) else "1"
        phases = f"control, {phases}" if any(run.control for run in runs) else phases
        counts = {side: {o: sum(run.side == side and run.outcome == o for run in runs) for o in ("valid", "failed", "invalid")} for side in "AB"}
        state, _ = set_state(folder, parameters, runs)
        cells = " | ".join(f"{c['valid']} / {c['failed']} / {c['invalid']}" for c in counts.values())
        overview.append(f"| {label} | {parameters.get('students')} | {phases} | {cells} | {state} | "
                        f"`{str(parameters.get('toolRevision', ''))[:11]}` | {parameters.get('startedAt')} |")
        if type(parameters.get("students")) is int:
            key = (tuple(parameters.get("sideA") or []), tuple(parameters.get("sideB") or []))
            comparisons.setdefault(key, []).append({"label": label, "students": parameters["students"], "state": state,
                                                    "started": parameters.get("startedAt") or "", "values": side_values,
                                                    "hypotheses": hypotheses,
                                                    "revision": str(parameters.get("toolRevision", ""))})
    scaling = scaling_section(comparisons, chart_dir)
    thesis_md, thesis_tex = thesis_tables(comparisons)
    args.out.with_name(f"{args.out.stem}-thesis.tex").write_text(thesis_tex)
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
        "| Run set | Students | Phases | Runs A: valid / failed / invalid | Runs B: valid / failed / invalid | State | Tool revision | Started |",
        "|---|---|---|---|---|---|---|---|",
        *overview,
        "",
        *thesis_md,
        *scaling,
    ]
    args.out.write_text("\n".join(header + sections))
    print(f"wrote {args.out}")


if __name__ == "__main__":
    main()
