#!/usr/bin/env node
/**
 * Validity of Track B runs (D19, D38, D42) and completion of a run set. Called by run.sh; no server needed.
 *
 *   node judge.mjs run <out> <run-folder>
 *     Writes <run-folder>/run.json from exits.json (k6 exit statuses and flags, written by run.sh) and the artifacts of the
 *     run. A run is valid only if
 *       - every k6 run passed its thresholds and both evaluations were logged (workload),
 *       - the Phase 3 freshness measurement is complete (phase3/freshness.json, if Phase 3 ran),
 *       - the running container uses the recorded image and the server reports the commit of its label (provenance),
 *       - the student scores and the point statistic equal the results that the deterministic answers must produce
 *         (lib/expected.mjs), independent of any other run,
 *       - and its semantics equal those of the reference run of the run set (D19, D38 rule 7).
 *     The reference is the first run, in run order, that passes all other checks: <out>/reference.json names it. A run
 *     before the reference exists cannot be valid without passing the same checks, so no run is compared with a failed
 *     or missing reference.
 *
 *   node judge.mjs complete <out> <repetitions>
 *     Writes <out>/complete.json (atomically) only if every side has <repetitions> valid runs; exit status 1 otherwise.
 */
import { existsSync, readdirSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
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

function judgeRun(out, dir) {
    const exits = read(`${dir}/exits.json`);
    const parameters = read(`${out}/parameters.json`);
    const manifest = read(`${parameters.seed}/manifest.json`);
    const reasons = [];

    const exitNames = Object.keys(exits).filter((key) => key.endsWith('Exit'));
    for (const name of exitNames) {
        if (exits[name] !== 0) {
            reasons.push(`${name} ${exits[name]}`);
        }
    }
    if (!exits.evaluated) {
        reasons.push('evaluation not logged');
    }

    const freshness = read(`${dir}/phase3/freshness.json`);
    if (exits.phase3Run && !freshness) {
        reasons.push('no freshness measurement');
    } else if (exits.phase3Run && !freshness.complete) {
        reasons.push(`freshness measurement incomplete: ${freshness.errors.join('; ')}`);
    }

    const images = read(`${dir}/images.json`) ?? [];
    const measuredImage = images.find((image) => image.image === exits.measured);
    const info = read(`${dir}/info.json`);
    if (!measuredImage || measuredImage.id !== exits.runningImageId) {
        reasons.push(`running image ${exits.runningImageId} is not ${exits.measured} (${measuredImage?.id})`);
    }
    if (!measuredImage?.head || !info?.commit?.startsWith(measuredImage.head)) {
        reasons.push(`server commit ${info?.commit} is not the image label ${measuredImage?.head}`);
    }

    const semantics = read(`${dir}/semantics.json`);
    const phase3 = read(`${dir}/phase3/phase3.json`);
    let expectedErrors = null;
    if (!semantics) {
        reasons.push('no semantics');
    } else {
        expectedErrors = expectedResultErrors(semantics, manifest.students, parameters.students, exits.phase3Run ? (phase3?.submissions ?? 0) : 0);
        if (expectedErrors.length) {
            reasons.push(`results differ from the expected results: ${expectedErrors.length} differences, first: ${expectedErrors[0]}`);
        }
    }

    // D19 reference: the first run that passes every check above.
    const name = dir.split('/').at(-1);
    let reference = read(`${out}/reference.json`);
    let semanticsEqual = null;
    if (reasons.length === 0) {
        if (!reference) {
            reference = { run: name };
            writeAtomic(`${out}/reference.json`, reference);
        }
        semanticsEqual = reference.run === name || normalized(semantics) === normalized(read(`${out}/${reference.run}/semantics.json`));
        if (!semanticsEqual) {
            reasons.push(`semantics differ from the reference run ${reference.run}`);
        }
    }

    const evaluation = existsSync(`${dir}/evaluation.txt`) ? readFileSync(`${dir}/evaluation.txt`, 'utf8') : '';
    const evaluationMillis = Number(evaluation.match(/durationMillis=(\d+)/)?.[1] ?? NaN);
    const evaluationEnd = Date.parse(evaluation.match(/\d{4}-\d{2}-\d{2}T[\d:.]+Z/)?.[0] ?? '');
    const phase2 = read(`${dir}/phase2/phase2.json`);
    const phase2Summary = read(`${dir}/phase2/summary.json`);
    const firstRequest = phase2Summary?.metrics?.phase2_first_request?.values?.min;
    const phase1 = read(`${dir}/phase1/summary.json`)?.metrics?.phase1_time_to_result?.values;
    const run = {
        ...exits,
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
        reasons,
        valid: reasons.length === 0,
    };
    writeAtomic(`${dir}/run.json`, run);
    console.log(JSON.stringify({ run: name, valid: run.valid, reasons }));
}

function judgeComplete(out, repetitions) {
    const runs = readdirSync(out)
        .filter((name) => /^\d+-[AB]$/.test(name))
        .map((name) => ({ name, side: name.split('-')[1], run: read(`${out}/${name}/run.json`) }));
    const valid = Object.fromEntries(['A', 'B'].map((side) => [side, runs.filter((entry) => entry.side === side && entry.run?.valid).length]));
    const complete = valid.A >= repetitions && valid.B >= repetitions;
    const state = { repetitions, validA: valid.A, validB: valid.B, runs: runs.length, invalid: runs.filter((entry) => !entry.run?.valid).map((entry) => entry.name) };
    console.log(JSON.stringify({ complete, ...state }));
    if (!complete) {
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
