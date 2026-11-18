/**
 * Track B control workflow (decision D20): a text exercise submission by the same students, as a short phase before the
 * quiz. It touches no quiz code, so a difference between the compared commits here is unrelated drift (D2). Run with
 * k6.sh after login.mjs.
 *
 * Every student, one VU each, follows the text exercise of the course page and the text editor (the same requests at
 * all five Track B commits):
 * 1. at a random time in the first 20 s: start the exercise (POST exercises/{id}/participations), then open the editor
 *    (GET text/participations/{participationId}/text-editor), which returns the participation with its submission;
 * 2. after 10 to 20 s of writing: submit (PUT text/exercises/{id}/text-submissions);
 * 3. after another 10 to 20 s: submit the revised text again.
 * The editor saves only when the student submits or leaves the page, so the schedule has no autosave. The texts depend
 * only on the student and the version, so both commits store the same texts (D19). The schedule comes from a PRNG seeded
 * with SEED and the student index, as in Phase 1.
 *
 * Environment:
 *   SERVER    base URL of Artemis (k6.sh: http://artemis:8080)
 *   OUT       folder with manifest.json and sessions.json (login.mjs); summary.json and control.json are written there
 *   EXERCISE  benchmark (default: the text exercise of the manifest) or warmUp (the warm-up text exercise, D38 rule 5)
 *   SEED      schedule seed (default 1)
 *   STUDENTS  the first N students of sessions.json take part (default: all)
 *
 * Request tag `type`: control-start, control-load, control-submit (with `submit` 1 or 2). A run is valid only if all
 * thresholds hold: no failed request or check, every student submitted twice, no dropped iteration.
 */
import { check, sleep } from 'k6';
import { SharedArray } from 'k6/data';
import exec from 'k6/execution';
import http from 'k6/http';
import { Counter } from 'k6/metrics';
import { failedThresholds, params, prng, trendLine, useSession } from './lib/k6.js';

const SERVER = __ENV.SERVER;
const OUT = __ENV.OUT;
const EXERCISE = __ENV.EXERCISE ?? 'benchmark';
const SEED = Number(__ENV.SEED ?? 1);
const OPEN_WINDOW_MS = 20_000;
const THINK_MS = [10_000, 20_000];
const SUBMITS = 2;

const config = new SharedArray('config', () => {
    const manifest = JSON.parse(open(`${OUT}/manifest.json`));
    const exerciseId = { benchmark: manifest.textExercise, warmUp: manifest.warmUpTextExercise }[EXERCISE];
    if (exerciseId === undefined) {
        throw new Error(`EXERCISE must be benchmark or warmUp, and the manifest must have that text exercise (warmUpTextExercise: seed.mjs from 2026-11-18 on), not ${EXERCISE}`);
    }
    return [{ exerciseId }];
})[0];
const students = new SharedArray('students', () => JSON.parse(open(`${OUT}/sessions.json`)).students);
const STUDENTS = Number(__ENV.STUDENTS ?? students.length);
if (!(STUDENTS >= 1 && STUDENTS <= students.length)) {
    throw new Error(`STUDENTS must be between 1 and ${students.length}, not ${__ENV.STUDENTS}`);
}

const studentsComplete = new Counter('control_students_complete');
const TYPES = ['control-start', 'control-load', 'control-submit'];
export const options = {
    setupTimeout: '60s',
    scenarios: {
        control: {
            executor: 'per-vu-iterations',
            vus: STUDENTS,
            iterations: 1,
            maxDuration: `${(OPEN_WINDOW_MS + SUBMITS * THINK_MS[1]) / 1000 + 60}s`,
        },
    },
    summaryTrendStats: ['min', 'med', 'avg', 'p(90)', 'p(95)', 'p(99)', 'max', 'count'],
    thresholds: {
        checks: ['rate==1'],
        http_req_failed: ['rate==0'],
        dropped_iterations: ['count==0'],
        control_students_complete: [`count==${STUDENTS}`],
        // Always-true thresholds make k6 keep these submetrics in the summary.
        ...Object.fromEntries(TYPES.map((type) => [`http_req_duration{type:${type}}`, ['max>=0']])),
    },
};

export function setup() {
    return { start: Date.now() };
}

/** The answer of a student in a version: about 600 characters, the same on every commit. */
function answer(index, version) {
    const sentence = `Student ${index + 1} explains the control workflow in version ${version}. `;
    return sentence.repeat(Math.ceil(600 / sentence.length));
}

export default function (run) {
    const index = exec.vu.idInTest - 1;
    const student = students[index];
    const random = prng(SEED * 1_000_003 + index);
    const openAt = run.start + random() * OPEN_WINDOW_MS;
    const thinks = Array.from({ length: SUBMITS }, () => THINK_MS[0] + random() * (THINK_MS[1] - THINK_MS[0]));
    useSession(SERVER, student);
    const wait = openAt - Date.now();
    if (wait > 0) {
        sleep(wait / 1000);
    }

    const started = http.post(`${SERVER}/api/exercise/exercises/${config.exerciseId}/participations`, null, params(student, { type: 'control-start' }, 'text'));
    const participationId = started.status === 201 || started.status === 200 ? started.json('id') : null;
    if (!check(started, { 'control start returns the participation': () => Number.isInteger(participationId) })) {
        return;
    }
    const loaded = http.get(`${SERVER}/api/text/participations/${participationId}/text-editor`, params(student, { type: 'control-load' }, 'text'));
    let submission = loaded.status === 200 ? (loaded.json('submissions') ?? [])[0] : null;
    if (!check(loaded, { 'control editor returns the submission': () => Number.isInteger(submission?.id) })) {
        return;
    }

    for (let version = 1; version <= SUBMITS; version++) {
        sleep(thinks[version - 1] / 1000);
        const body = { id: submission.id, text: answer(index, version), language: 'ENGLISH', submitted: submission.submitted ?? false };
        const saved = http.put(`${SERVER}/api/text/exercises/${config.exerciseId}/text-submissions`, JSON.stringify(body), params(student, { type: 'control-submit', submit: String(version) }, 'text'));
        if (!check(saved, { 'control submit succeeds': (response) => response.status === 200 })) {
            return;
        }
        submission = saved.json();
    }
    studentsComplete.add(1);
}

export function handleSummary(data) {
    const failed = failedThresholds(data);
    const setup = data.setup_data ?? {};
    return {
        [`${OUT}/summary.json`]: JSON.stringify(data, null, 2),
        [`${OUT}/control.json`]: `${JSON.stringify({ exercise: EXERCISE, exerciseId: config.exerciseId, students: STUDENTS, start: setup.start ?? null, end: setup.start ? setup.start + data.state.testRunDurationMs : null })}\n`,
        stdout: `${[
            `Control workflow (${EXERCISE} text exercise ${config.exerciseId}, ${STUDENTS} students, seed ${SEED})`,
            ...TYPES.map((type) => trendLine(data, `http_req_duration{type:${type}}`, type)),
            `students complete: ${data.metrics.control_students_complete?.values.count ?? 0} of ${STUDENTS}`,
            failed.length ? `FAILED thresholds: ${failed.join(', ')}` : 'all thresholds hold',
        ].join('\n')}\n`,
    };
}
