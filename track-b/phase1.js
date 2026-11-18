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
 * Time to result (D17): after a successful submit, the student opens a STOMP connection over the plain websocket endpoint
 * (/websocket/websocket, JWT cookie) and subscribes to its result topic /user/topic/exercise/{quizId}/participation, as the
 * live quiz page stays subscribed. The subscription is sent at least 5 s before the due date. When the scheduled task has
 * evaluated the quiz, it sends every participant its result there (QuizSubmissionService.sendQuizResultToUser).
 * phase1_time_to_result is the time from the stored due date of the quiz (`run.due`, the scheduled evaluation start; the
 * evaluation started 1 to 3 ms after it in the pilots) until the student's result message reaches k6. The student waits at
 * most RESULT_WAIT_SECONDS after the due date. The real client is connected for the whole quiz; here the connection opens
 * after the submit, so the server holds fewer connections during the quiz than with browsers.
 *
 * Workload: a closed loop per student (D35). The opening time and the final submit time are fixed by the seed; each save
 * follows the response of the previous request plus a think time, so save arrival times depend on the server. The
 * achieved request rates are reported from the samples; this cohort schedule does not measure maximum throughput.
 *
 * Environment:
 *   SERVER    base URL of Artemis (k6.sh: http://artemis:8080)
 *   OUT       folder with manifest.json and sessions.json (login.mjs); summary.json and questions.json (ids and titles of
 *             the questions, for phase2.js) are written there
 *   QUIZ      benchmark (default) or warmUp (D38 rule 5)
 *   SEED      schedule seed (default 1)
 *   STUDENTS  the first N students of sessions.json take part (default: all; the warm-up uses 100)
 *   RESULT_WAIT_SECONDS  how long after the due date a student waits for its result (default 300)
 *
 * Requests carry the tag `type` (start-participation, save, submit; save also `save` 1 to 3). A run is valid only if all
 * thresholds hold (k6 exit status 0): no failed request or check, every student submitted before the due date (D38
 * rule 1), no dropped iteration (D38 rule 2), every student subscribed before the due date and received its result.
 */
import { check, fail, sleep } from 'k6';
import { SharedArray } from 'k6/data';
import exec from 'k6/execution';
import http from 'k6/http';
import { Counter, Trend } from 'k6/metrics';
import { clearInterval, clearTimeout, setInterval, setTimeout } from 'k6/timers';
import { WebSocket } from 'k6/websockets';
import { submission } from './lib/answers.mjs';
import { cookieHeader, failedThresholds, frame, frames, params, prng, STOMP_HEARTBEAT_MS, trendLine, useSession, websocketUrl } from './lib/k6.js';

const SERVER = __ENV.SERVER;
const OUT = __ENV.OUT;
const SEED = Number(__ENV.SEED ?? 1);
const RESULT_WAIT_MS = Number(__ENV.RESULT_WAIT_SECONDS ?? 300) * 1000;
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
const STUDENTS = Number(__ENV.STUDENTS ?? students.length);
if (!(STUDENTS >= 1 && STUDENTS <= students.length)) {
    throw new Error(`STUDENTS must be between 1 and ${students.length}, not ${__ENV.STUDENTS}`);
}

if (config.duration * 1000 < OPEN_WINDOW_MS + SAVES * THINK_MS[1] + SUBMIT_BEFORE_DUE_MS[1]) {
    throw new Error(`a ${config.duration} s quiz is too short for the Phase 1 schedule`);
}

const submittedInTime = new Counter('phase1_submitted_in_time');
const failedStudents = new Counter('phase1_failed_students');
// k6 capacity (D36 pilot): how late a VU wakes up for a planned request, and how often the planned time had already passed
// (then the server was slow, not k6).
const scheduleLag = new Trend('phase1_schedule_lag', true);
const behindSchedule = new Counter('phase1_behind_schedule');
const timeToResult = new Trend('phase1_time_to_result', true);
const resultsReceived = new Counter('phase1_results_received');
const subscribedLate = new Counter('phase1_result_subscribed_late');

const TYPES = ['start-participation', 'save', 'submit'];
export const options = {
    setupTimeout: '60s',
    scenarios: {
        phase1: {
            executor: 'per-vu-iterations',
            vus: STUDENTS,
            iterations: 1,
            // The schedule ends at the due date; the students then wait for their results.
            maxDuration: `${config.duration + RESULT_WAIT_MS / 1000 + 60}s`,
        },
    },
    summaryTrendStats: ['min', 'med', 'avg', 'p(90)', 'p(95)', 'p(99)', 'max', 'count'],
    thresholds: {
        checks: ['rate==1'],
        http_req_failed: ['rate==0'],
        dropped_iterations: ['count==0'],
        phase1_submitted_in_time: [`count==${STUDENTS}`],
        phase1_failed_students: ['count==0'],
        phase1_results_received: [`count==${STUDENTS}`],
        phase1_result_subscribed_late: ['count==0'],
        phase1_time_to_result: ['max>=0'],
        // Always-true thresholds make k6 keep these submetrics in the summary.
        ...Object.fromEntries(TYPES.map((type) => [`http_req_duration{type:${type}}`, ['max>=0']])),
        ...Object.fromEntries([1, 2, 3].map((save) => [`http_req_duration{type:save,save:${save}}`, ['max>=0']])),
        ...Object.fromEntries(['open', 'submit'].map((step) => [`phase1_schedule_lag{step:${step}}`, ['max>=0']])),
    },
};

/** Sleeps until `time` and records how late the VU woke up; if `time` has passed already, counts that instead. */
function sleepUntil(time, step) {
    const wait = time - Date.now();
    if (wait > 0) {
        sleep(wait / 1000);
        scheduleLag.add(Date.now() - time, { step });
    } else {
        behindSchedule.add(1, { step });
    }
}

export function setup() {
    useSession(SERVER, instructor);
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
    // The question ids of the instructor view, for phase2.js: read here, before Phase 1, so that Phase 2 sends no extra
    // request that would warm the server for the statistics pages.
    const questions = before
        .json('quizQuestions')
        .map(({ id, title }) => ({ id, title }))
        .sort((a, b) => Number(a.title.slice(1)) - Number(b.title.slice(1)));
    return { start, due: Date.parse(dueDate), questions };
}

export default function (run) {
    const index = exec.vu.idInTest - 1;
    const student = students[index];
    const random = prng(SEED * 1_000_003 + index);
    const between = ([low, high]) => low + random() * (high - low);
    const openAt = run.start + random() * OPEN_WINDOW_MS;
    const thinks = Array.from({ length: SAVES }, () => between(THINK_MS));
    const submitAt = run.due - between(SUBMIT_BEFORE_DUE_MS);
    useSession(SERVER, student);

    sleepUntil(openAt, 'open');
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

    sleepUntil(submitAt, 'submit');
    const submitted = http.post(`${live}?submit=true`, JSON.stringify(submission(questions, index + SAVES + 1)), params(student, { type: 'submit' }));
    const inTime = Date.now() <= run.due;
    if (check(submitted, { 'submit succeeds': (response) => response.status === 200, 'submit answered before the due date': () => inTime })) {
        submittedInTime.add(1);
        awaitResult(student, run.due);
    } else {
        failedStudents.add(1, { step: 'submit' });
    }
}

/** Subscribes to the student's result topic and records when the result arrives; the iteration ends with the socket. */
function awaitResult(student, due) {
    let heartbeat = null;
    let deadline = null;
    const ws = new WebSocket(websocketUrl(SERVER), null, { headers: { Cookie: cookieHeader(student) }, tags: { type: 'result-websocket' } });
    const close = () => {
        clearInterval(heartbeat);
        clearTimeout(deadline);
        ws.close();
    };
    deadline = setTimeout(close, due + RESULT_WAIT_MS - Date.now());
    ws.onopen = () => {
        ws.send(frame('CONNECT', { 'accept-version': '1.2', 'heart-beat': `${STOMP_HEARTBEAT_MS},${STOMP_HEARTBEAT_MS}`, host: 'artemis' }));
        heartbeat = setInterval(() => ws.send('\n'), STOMP_HEARTBEAT_MS);
    };
    ws.onmessage = (event) => {
        for (const { command } of frames(event.data)) {
            if (command === 'CONNECTED') {
                ws.send(frame('SUBSCRIBE', { id: 'result', destination: `/user/topic/exercise/${config.quizId}/participation` }));
                if (Date.now() >= due) {
                    subscribedLate.add(1);
                }
            } else if (command === 'MESSAGE') {
                timeToResult.add(Date.now() - due);
                resultsReceived.add(1);
                close();
            } else {
                check(null, { [`no STOMP ${command} frame on the result topic`]: () => false });
                close();
            }
        }
    };
    ws.onerror = (event) => {
        check(null, { 'result websocket has no error': () => false });
        console.error(`student ${student.login ?? ''}: websocket error ${event.error}`);
        close();
    };
}

export function handleSummary(data) {
    const failed = failedThresholds(data);
    const lag = (step) => {
        const values = data.metrics[`phase1_schedule_lag{step:${step}}`]?.values ?? {};
        return `schedule lag ${step}: p99=${values['p(99)']?.toFixed(1)} ms max=${values.max?.toFixed(1)} ms`;
    };
    const behind = data.metrics.phase1_behind_schedule?.values.count ?? 0;
    return {
        [`${OUT}/summary.json`]: JSON.stringify(data, null, 2),
        [`${OUT}/questions.json`]: `${JSON.stringify(data.setup_data?.questions ?? [])}\n`,
        stdout: `${[
            `Phase 1 (${QUIZ} quiz ${config.quizId}, ${STUDENTS} students, seed ${SEED})`,
            ...TYPES.map((type) => trendLine(data, `http_req_duration{type:${type}}`, type)),
            lag('open'),
            lag('submit'),
            `behind schedule: ${behind}`,
            trendLine(data, 'phase1_time_to_result', 'time to result (from the due date)'),
            `results received: ${data.metrics.phase1_results_received?.values.count ?? 0} of ${STUDENTS}`,
            failed.length ? `FAILED thresholds: ${failed.join(', ')}` : 'all thresholds hold',
        ].join('\n')}\n`,
    };
}
