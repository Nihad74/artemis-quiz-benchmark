#!/usr/bin/env node
/**
 * Validity of Track B runs (D19, D38, D42, D43, D44) and completion of a run set. Called by run.sh; no server needed.
 *
 *   node judge.mjs run <out> <run-folder>
 *     Writes <run-folder>/run.json from exits.json (k6 exit statuses and flags, written by run.sh) and the artifacts of the
 *     run, with an outcome:
 *       invalid  the measurement cannot be trusted: the running container is not the image id frozen in parameters.json,
 *                its settings differ from the frozen compose configuration, the server reports another commit, the
 *                evaluation logs could not be read, a k6 run
 *                ended with an error (exit status other than 0 and 99) or without a summary, a load-generator threshold
 *                failed (dropped iterations, practice POSTs behind schedule), a threshold this file does not know failed,
 *                the freshness capture failed independently of rejected practice POSTs, or the semantics could not be recorded;
 *       failed   the measurement is trustworthy, but the server failed the workload: a server-outcome threshold failed
 *                (failed requests or checks, submissions not answered in time, results not received, pages not loaded,
 *                practice submissions not answered), the evaluation was not logged, or the results differ from the
 *                expected results or from the reference. Evidence against the hypothesis (D38 rule 1, D44), never a
 *                latency sample;
 *       valid    every check passed.
 *     The expected results come from the deterministic answers (lib/expected.mjs), independent of any other run. The
 *     reference of D19 is the first valid run in run order (<out>/reference.json), so no run is compared with a failed
 *     or missing reference.
 *
 *   node judge.mjs complete <out> <repetitions>
 *     Writes <out>/complete.json (atomically) only with <repetitions> valid runs per side. A failed server run is
 *     recorded separately in failure.json and never counts towards completion. Exit status 1 otherwise. A campaign
 *     result set needs at least five valid runs per side; night.sh and report.py check that independently.
 */
import { existsSync, readdirSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { expectedResultErrors } from './lib/expected.mjs';

const read = (path) => (existsSync(path) ? JSON.parse(readFileSync(path, 'utf8')) : null);
const writeAtomic = (path, value) => {
    writeFileSync(`${path}.tmp`, `${JSON.stringify(value, null, 2)}\n`);
    renameSync(`${path}.tmp`, path);
};

/** JSON with sorted keys, so that equal semantics compare equal as text. */
function canonical(value) {
    if (Array.isArray(value)) {
        return `[${value.map(canonical).join(',')}]`;
    }
    if (value && typeof value === 'object') {
        return `{${Object.keys(value)
            .sort()
            .map((key) => `${JSON.stringify(key)}:${canonical(value[key])}`)
            .join(',')}}`;
    }
    return JSON.stringify(value);
}

/** What D38 rule 7 compares: everything but the statistics source and the dates of the started quizzes. */
function normalized(semantics) {
    const { statisticsSource, benchmarkQuiz, warmUpQuiz, ...rest } = semantics;
    return canonical(rest);
}

/** k6 thresholds whose failure means the server did not serve the workload. Any other failed threshold makes the run invalid. */
const SERVER_THRESHOLDS = new Set([
    'checks',
    'http_req_failed',
    'control_students_complete',
    'phase1_submitted_in_time',
    'phase1_failed_students',
    'phase1_results_received',
    'phase2_pages_loaded',
    'phase3_practice_answered',
]);
const K6_RUNS = {
    warmUpControlExit: 'warm-up/control',
    controlExit: 'control',
    warmUpPhase1Exit: 'warm-up/phase1',
    phase1Exit: 'phase1',
    warmUpPhase2Exit: 'warm-up/phase2',
    phase2Exit: 'phase2',
    warmUpPhase3Exit: 'warm-up/phase3',
    phase3Exit: 'phase3',
};

/** Names of the metrics with a failed threshold in a k6 summary. */
function failedThresholds(summary) {
    return Object.entries(summary?.metrics ?? {})
        .filter(([, metric]) => Object.values(metric.thresholds ?? {}).some((threshold) => threshold.ok === false))
        .map(([name]) => name);
}

/** Differences between the running containers (containers.json) and the frozen compose configuration. */
function containerDifferences(containers, compose, plannedId) {
    const differences = [];
    for (const service of ['artemis', 'postgres']) {
        const planned = compose?.services?.[service];
        const running = containers?.find((container) => container.service === service);
        if (!planned || !running) {
            differences.push(`${service}: no ${planned ? 'container facts' : 'frozen configuration'}`);
            continue;
        }
        if (service === 'artemis' && running.image !== plannedId) {
            differences.push(`artemis image ${running.image}, planned ${plannedId}`);
        }
        if (running.cpuset !== planned.cpuset) {
            differences.push(`${service} CPU set ${running.cpuset}, planned ${planned.cpuset}`);
        }
        if (String(running.memory) !== String(planned.mem_limit) || String(running.memorySwap) !== String(planned.memswap_limit)) {
            differences.push(`${service} memory ${running.memory}/${running.memorySwap}, planned ${planned.mem_limit}/${planned.memswap_limit}`);
        }
        for (const [key, value] of Object.entries(planned.environment ?? {})) {
            if ((running.env ?? {})[key] !== String(value ?? '')) {
                differences.push(`${service} ${key}=${running.env?.[key]}, planned ${value}`);
            }
        }
    }
    return differences;
}

function judgeRun(out, dir) {
    const exits = read(`${dir}/exits.json`);
    const parameters = read(`${out}/parameters.json`);
    const manifest = read(`${parameters.seed}/manifest.json`);
    const measurement = [];
    const server = [];

    const summaries = {};
    const unansweredPractice = new Set();
    for (const [name, folder] of Object.entries(K6_RUNS)) {
        if (folder.endsWith('control') && !exits.controlRun || folder.endsWith('phase3') && !exits.phase3Run) {
            continue;
        }
        const status = exits[name];
        if (status === undefined) {
            measurement.push(`no exit status for ${folder}`);
            continue;
        }
        const summary = read(`${dir}/${folder}/summary.json`);
        summaries[folder] = summary;
        if (!summary || (status !== 0 && status !== 99)) {
            measurement.push(`${name} ${status}${summary ? '' : ' without summary'}`);
            continue;
        }
        const failed = failedThresholds(summary);
        if (status === 0) {
            if (failed.length) {
                measurement.push(`${name} reports success despite failed thresholds: ${failed.join(', ')}`);
            }
            continue;
        }
        const serverFailed = failed.filter((metric) => SERVER_THRESHOLDS.has(metric.split('{')[0]));
        const otherFailed = failed.filter((metric) => !serverFailed.includes(metric));
        if (serverFailed.length) {
            server.push(`${name}: ${serverFailed.join(', ')}`);
        }
        if (serverFailed.includes('phase3_practice_answered') && !otherFailed.length) {
            unansweredPractice.add(folder);
        }
        if (otherFailed.length || !failed.length) {
            measurement.push(`${name}: ${otherFailed.length ? otherFailed.join(', ') : 'no failed threshold recorded'}`);
        }
    }
    for (const name of ['semanticsExit', 'serverLogExit']) {
        if (exits[name]) {
            measurement.push(`${name} ${exits[name]}`);
        }
    }
    const evaluations = [exits.warmUpEvaluationExit, exits.evaluationExit];
    // Older run records only have the combined evaluation flag.
    if ((evaluations.every((status) => status === undefined) && !exits.evaluated) || evaluations.includes(1)) {
        server.push('evaluation not logged');
    }
    if (evaluations.some((status) => status !== undefined && status !== 0 && status !== 1)) {
        measurement.push('could not read the evaluation log');
    }

    const freshness = read(`${dir}/phase3/freshness.json`);
    if (exits.phase3Run) {
        for (const [folder, result, status] of [
            ['phase3', freshness, exits.freshnessExit],
            ['warm-up/phase3', read(`${dir}/warm-up/phase3/freshness.json`), exits.warmUpFreshnessExit],
        ]) {
            if (!result) {
                measurement.push(`${folder}: no freshness measurement`);
            } else if (!result.complete) {
                // Rejected POSTs make freshness unmeasurable without invalidating a captured server failure.
                const rejected = unansweredPractice.has(folder) && status === 1 && result.captureErrors?.length === 0
                    && result.submissions < result.expectedSubmissions;
                if (!rejected) {
                    measurement.push(`${folder}: freshness measurement incomplete: ${result.errors.join('; ')}`);
                }
            } else if (status !== 0) {
                measurement.push(`${folder}: freshness exit ${status}`);
            }
        }
    }

    // Provenance against the inputs frozen at the start of the run set (D44), not against a later look at a tag.
    const plannedId = parameters.images?.[exits.measured];
    const images = read(`${dir}/images.json`) ?? [];
    const measuredImage = images.find((image) => image.image === exits.measured);
    const info = read(`${dir}/info.json`);
    if (!plannedId) {
        measurement.push(`no frozen image id for ${exits.measured} in parameters.json`);
    } else if (exits.runningImageId !== plannedId || measuredImage?.id !== plannedId) {
        measurement.push(`running image ${exits.runningImageId} is not the frozen id ${plannedId} of ${exits.measured}`);
    }
    const expectedCommit = exits.measured.match(/^artemis-thesis:([^-]+)(?:-|$)/)?.[1];
    if (expectedCommit && measuredImage?.commit !== expectedCommit) {
        measurement.push(`measured base commit ${measuredImage?.commit}, planned ${expectedCommit}`);
    }
    if (!measuredImage?.head || !info?.commit?.startsWith(measuredImage.head)) {
        measurement.push(`server commit ${info?.commit} is not the image label ${measuredImage?.head}`);
    }
    const differences = containerDifferences(read(`${dir}/containers.json`), parameters.settings?.compose, plannedId);
    if (differences.length) {
        measurement.push(`containers differ from the frozen settings: ${differences.join('; ')}`);
    }

    const semantics = read(`${dir}/semantics.json`);
    const phase3 = read(`${dir}/phase3/phase3.json`);
    let expectedErrors = null;
    if (!semantics) {
        measurement.push('no semantics');
    } else {
        expectedErrors = expectedResultErrors(semantics, manifest.students, parameters.students, exits.phase3Run ? (phase3?.submissions ?? 0) : 0);
        if (expectedErrors.length) {
            server.push(`results differ from the expected results: ${expectedErrors.length} differences, first: ${expectedErrors[0]}`);
        }
    }

    // D19 reference: the first run that passes every check above.
    const name = dir.split('/').at(-1);
    let reference = read(`${out}/reference.json`);
    let semanticsEqual = null;
    if (measurement.length === 0 && server.length === 0) {
        if (!reference) {
            reference = { run: name };
            writeAtomic(`${out}/reference.json`, reference);
        }
        semanticsEqual = reference.run === name || normalized(semantics) === normalized(read(`${out}/${reference.run}/semantics.json`));
        if (!semanticsEqual) {
            server.push(`semantics differ from the reference run ${reference.run}`);
        }
    }
    const outcome = measurement.length ? 'invalid' : server.length ? 'failed' : 'valid';
    const reasons = [...measurement, ...server];

    const evaluation = existsSync(`${dir}/evaluation.txt`) ? readFileSync(`${dir}/evaluation.txt`, 'utf8') : '';
    const evaluationMillis = Number(evaluation.match(/durationMillis=(\d+)/)?.[1] ?? NaN);
    const evaluationEnd = Date.parse(evaluation.match(/\d{4}-\d{2}-\d{2}T[\d:.]+Z/)?.[0] ?? '');
    const phase2 = read(`${dir}/phase2/phase2.json`);
    const firstRequest = summaries.phase2?.metrics?.phase2_first_request?.values?.min;
    const resultTrend = summaries.phase1?.metrics?.phase1_time_to_result?.values;
    const phase1 = resultTrend?.count > 0 ? resultTrend : null;
    const run = {
        ...exits,
        plannedImageId: plannedId ?? null,
        evaluationMillis: Number.isFinite(evaluationMillis) ? evaluationMillis : null,
        evaluationEnd: Number.isFinite(evaluationEnd) ? evaluationEnd : null,
        statisticsMode: phase2?.mode ?? null,
        phase2DelayMillis: phase2?.start && Number.isFinite(evaluationEnd) ? phase2.start - evaluationEnd : null,
        phase2FirstRequestDelayMillis: phase2?.start && Number.isFinite(evaluationEnd) && firstRequest !== undefined ? phase2.start + firstRequest - evaluationEnd : null,
        timeToResultMedianMillis: phase1?.med ?? null,
        timeToResultP95Millis: phase1?.['p(95)'] ?? null,
        freshnessMedianMillis: freshness?.medianMillis ?? null,
        freshnessP95Millis: freshness?.p95Millis ?? null,
        freshnessP95Censored: freshness?.p95Censored ?? null,
        expectedResults: expectedErrors === null ? null : expectedErrors.length === 0,
        reference: reference?.run ?? null,
        semanticsEqual,
        measurementReasons: measurement,
        serverReasons: server,
        reasons,
        outcome,
        valid: outcome === 'valid',
    };
    writeAtomic(`${dir}/run.json`, run);
    console.log(JSON.stringify({ run: name, outcome, reasons }));
}

function judgeComplete(out, repetitions) {
    const runs = readdirSync(out)
        .filter((name) => /^\d+-[AB]$/.test(name))
        .map((name) => ({ name, side: name.split('-')[1], run: read(`${out}/${name}/run.json`) }));
    const count = (side, outcome) => runs.filter((entry) => entry.side === side && (entry.run?.outcome ?? 'invalid') === outcome
        && (outcome !== 'valid' || entry.run.valid === true)).length;
    const state = {
        repetitions,
        validA: count('A', 'valid'),
        failedA: count('A', 'failed'),
        validB: count('B', 'valid'),
        failedB: count('B', 'failed'),
        runs: runs.length,
        invalid: runs.filter((entry) => (entry.run?.outcome ?? 'invalid') === 'invalid').map((entry) => entry.name),
    };
    const complete = Number.isInteger(repetitions) && repetitions > 0 &&
        state.invalid.length === 0 && state.failedA === 0 && state.failedB === 0 &&
        state.validA === repetitions && state.validB === repetitions;
    console.log(JSON.stringify({ complete, ...state }));
    if (!complete) {
        rmSync(`${out}/complete.json`, { force: true });
        if (state.failedA || state.failedB) {
            writeAtomic(`${out}/failure.json`, {
                ...state,
                evidence: runs.filter((entry) => entry.run?.outcome === 'failed')
                    .map((entry) => ({ run: entry.name, reasons: entry.run.serverReasons })),
            });
        }
        process.exit(1);
    }
    writeAtomic(`${out}/complete.json`, { ...state, completedAt: new Date().toISOString() });
}

const [mode, out, arg] = process.argv.slice(2);
if (mode === 'run' && out && arg) {
    judgeRun(out, arg.replace(/\/$/, ''));
} else if (mode === 'complete' && out && arg) {
    judgeComplete(out, Number(arg));
} else {
    console.error('usage: node judge.mjs run <out> <run-folder> | complete <out> <repetitions>');
    process.exit(2);
}
