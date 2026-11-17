/**
 * Track B, Phase 1: the live quiz (decisions D10, D13, D14, D38). Run with k6.sh, after login.mjs.
 *
 * The setup starts the quiz with start-now as the instructor (D13 step 4). Then every student, one VU each:
 * 1. opens the quiz at a random time in the first 30 s: the live quiz page loads the quiz and the student's submission
 *    with one request, start-participation, on every compared commit;
 * 2. saves three times, each after 5 to 15 s of think time;
 * 3. submits at a random time in the last 20 s, at least 5 s before the due date.
 * Every student sends the answers of lib/answers.mjs, variant (index + k) for save k and (index + 4) for the submission,
 * so that every compared commit must compute the same scores (D19, D38 rule 7). The schedule comes from a PRNG seeded
 * with SEED and the student index: every run with the same seed sends the same requests at the same offsets.
 *
 * Environment:
 *   SERVER    base URL of Artemis (k6.sh: http://artemis:8080)
 *   OUT       folder with manifest.json and sessions.json (login.mjs); summary.json is written there
 *   QUIZ      benchmark (default) or warmUp (D38 rule 5)
 *   SEED      schedule seed (default 1)
 *
 * Requests carry the tag `type` (start-participation, save, submit; save also `save` 1 to 3). A run is valid only if all
 * thresholds hold (k6 exit status 0): no failed request or check, every student submitted before the due date (D38
 * rule 1), no dropped iteration (D38 rule 2).
 */
import { check, fail, sleep } from 'k6';
import { SharedArray } from 'k6/data';
import exec from 'k6/execution';
import http from 'k6/http';
import { Counter } from 'k6/metrics';
import { submission } from './lib/answers.mjs';

const SERVER = __ENV.SERVER;
const OUT = __ENV.OUT;
const SEED = Number(__ENV.SEED ?? 1);
const QUIZ = __ENV.QUIZ ?? 'benchmark';
const OPEN_WINDOW_MS = 30_000;
const THINK_MS = [5_000, 15_000];
const SAVES = 3;
// Submissions fall between 20 s and 5 s before the due date.
const SUBMIT_BEFORE_DUE_MS = [5_000, 20_000];

// SharedArray parses each file once for all VUs; open() alone would parse it in every VU.
const config = new SharedArray('config', () => {
    const manifest = JSON.parse(open(`${OUT}/manifest.json`));
    const quizId = { benchmark: manifest.benchmarkQuiz, warmUp: manifest.warmUpQuiz }[QUIZ];
    if (quizId === undefined) {
        throw new Error(`QUIZ must be benchmark or warmUp, not ${QUIZ}`);
    }
    return [{ quizId, duration: manifest.benchmarkDuration }];
})[0];
const instructor = new SharedArray('instructor', () => [JSON.parse(open(`${OUT}/sessions.json`)).instructor])[0];
const students = new SharedArray('students', () => JSON.parse(open(`${OUT}/sessions.json`)).students);

if (config.duration * 1000 < OPEN_WINDOW_MS + SAVES * THINK_MS[1] + SUBMIT_BEFORE_DUE_MS[1]) {
    throw new Error(`a ${config.duration} s quiz is too short for the Phase 1 schedule`);
}

const submittedInTime = new Counter('phase1_submitted_in_time');
const failedStudents = new Counter('phase1_failed_students');

const TYPES = ['start-participation', 'save', 'submit'];
export const options = {
    setupTimeout: '60s',
    scenarios: {
        phase1: {
            executor: 'per-vu-iterations',
            vus: students.length,
            iterations: 1,
            // The schedule ends at the due date; the margin covers the last responses.
            maxDuration: `${config.duration + 60}s`,
        },
    },
    summaryTrendStats: ['min', 'med', 'avg', 'p(90)', 'p(95)', 'p(99)', 'max', 'count'],
    thresholds: {
        checks: ['rate==1'],
        http_req_failed: ['rate==0'],
        dropped_iterations: ['count==0'],
        phase1_submitted_in_time: [`count==${students.length}`],
        phase1_failed_students: ['count==0'],
        // Always-true thresholds make k6 keep these submetrics in the summary.
        ...Object.fromEntries(TYPES.map((type) => [`http_req_duration{type:${type}}`, ['max>=0']])),
        ...Object.fromEntries([1, 2, 3].map((save) => [`http_req_duration{type:save,save:${save}}`, ['max>=0']])),
    },
};

function params(session, tags, responseType = 'none') {
    const headers = { 'Content-Type': 'application/json', Accept: 'application/json' };
    if (session.xsrf !== null) {
        headers['X-XSRF-TOKEN'] = session.xsrf;
    }
    return { headers, tags, responseType };
}

/** Puts the session cookies into this VU's jar, as a browser holds them; cookies the server sets later replace them. */
function useSession(session) {
    const jar = http.cookieJar();
    for (const [name, value] of Object.entries(session.cookies)) {
        jar.set(SERVER, name, value);
    }
}

function sleepUntil(time) {
    const wait = time - Date.now();
    if (wait > 0) {
        sleep(wait / 1000);
    }
}

/** mulberry32: a small seeded PRNG, one stream per student. */
function prng(seed) {
    let state = seed >>> 0;
    return () => {
        state = (state + 0x6d2b79f5) >>> 0;
        let t = state;
        t = Math.imul(t ^ (t >>> 15), t | 1);
        t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
        return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
}

export function setup() {
    useSession(instructor);
    const quizUrl = `${SERVER}/api/quiz/quiz-exercises/${config.quizId}`;
    const before = http.get(quizUrl, params(instructor, { type: 'setup' }, 'text'));
    if (before.status !== 200) {
        fail(`GET quiz ${config.quizId}: HTTP ${before.status}`);
    }
    if (before.json('duration') !== config.duration || before.json('quizMode') !== 'SYNCHRONIZED') {
        fail(`quiz ${config.quizId} is not a synchronized ${config.duration} s quiz`);
    }
    const started = http.put(`${quizUrl}/start-now`, null, params(instructor, { type: 'setup' }));
    if (started.status !== 200) {
        fail(`start-now of quiz ${config.quizId}: HTTP ${started.status}`);
    }
    const start = Date.now();
    const dueDate = http.get(quizUrl, params(instructor, { type: 'setup' }, 'text')).json('dueDate');
    if (!dueDate) {
        fail(`quiz ${config.quizId} has no due date after start-now`);
    }
    return { start, due: Date.parse(dueDate) };
}

export default function (run) {
    const index = exec.vu.idInTest - 1;
    const student = students[index];
    const random = prng(SEED * 1_000_003 + index);
    const between = ([low, high]) => low + random() * (high - low);
    const openAt = run.start + random() * OPEN_WINDOW_MS;
    const thinks = Array.from({ length: SAVES }, () => between(THINK_MS));
    const submitAt = run.due - between(SUBMIT_BEFORE_DUE_MS);
    useSession(student);

    sleepUntil(openAt);
    const opened = http.post(`${SERVER}/api/quiz/quiz-exercises/${config.quizId}/start-participation`, null, params(student, { type: 'start-participation' }, 'text'));
    const questions = opened.status === 200 ? opened.json('exercise.quizQuestions') : null;
    if (!check(opened, { 'start-participation returns the questions': () => Array.isArray(questions) && questions.length > 0 })) {
        failedStudents.add(1, { step: 'start-participation' });
        return;
    }

    const live = `${SERVER}/api/quiz/exercises/${config.quizId}/submissions/live`;
    for (let save = 1; save <= SAVES; save++) {
        sleep(thinks[save - 1] / 1000);
        const saved = http.post(`${live}?submit=false`, JSON.stringify(submission(questions, index + save)), params(student, { type: 'save', save: String(save) }));
        check(saved, { 'save succeeds': (response) => response.status === 200 });
    }

    sleepUntil(submitAt);
    const submitted = http.post(`${live}?submit=true`, JSON.stringify(submission(questions, index + SAVES + 1)), params(student, { type: 'submit' }));
    const inTime = Date.now() <= run.due;
    if (check(submitted, { 'submit succeeds': (response) => response.status === 200, 'submit answered before the due date': () => inTime })) {
        submittedInTime.add(1);
    } else {
        failedStudents.add(1, { step: 'submit' });
    }
}

export function handleSummary(data) {
    const failed = Object.entries(data.metrics)
        .filter(([, metric]) => metric.thresholds && Object.values(metric.thresholds).some((threshold) => !threshold.ok))
        .map(([name]) => name);
    const line = (type) => {
        const values = data.metrics[`http_req_duration{type:${type}}`]?.values ?? {};
        return `${type}: n=${values.count ?? 0} med=${values.med?.toFixed(1)} ms p95=${values['p(95)']?.toFixed(1)} ms p99=${values['p(99)']?.toFixed(1)} ms`;
    };
    return {
        [`${OUT}/summary.json`]: JSON.stringify(data, null, 2),
        stdout: `${[`Phase 1 (${QUIZ} quiz ${config.quizId}, ${students.length} students, seed ${SEED})`, ...TYPES.map(line), failed.length ? `FAILED thresholds: ${failed.join(', ')}` : 'all thresholds hold'].join('\n')}\n`,
    };
}
