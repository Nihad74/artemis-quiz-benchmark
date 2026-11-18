/**
 * Track B, Phase 3: practice mode after the quiz while the statistics pages stay open (decisions D10, D15, D16 H3). Run
 * with k6.sh after Phase 2 of the same quiz; then freshness.mjs computes the statistics freshness from raw.json.gz.
 *
 * Every tutor of sessions.json (the seed has 5), one VU each, opens the point statistic page at the start: the page data
 * and the footer, as in Phase 2, and a STOMP connection over the plain websocket endpoint of Artemis
 * (/websocket/websocket) with a subscription to /topic/statistic/{quizId}, as the page does. The page then follows the
 * client of the measured commit:
 *   stored statistics: every message carries the whole quiz with its updated statistics; the page shows it without a
 *     request. The baseline sends one message per practice submission, after its single statistics worker has added the
 *     result (QuizStatisticService.updateStatisticsForNewResult);
 *   on-demand statistics: a message carries only the quiz id, at most one per second (debounce); the page reloads
 *     GET .../statistics/points. A message that arrives during a reload starts one more reload after it, instead of
 *     cancelling it as the client's switchMap does: the server answers the cancelled request anyway.
 * A tutor stops when the page shows every practice submission of the phase (unrated participants), or at the deadline.
 *
 * Practice: from PRACTICE_START_S on, SUBMISSIONS = min(PRACTICE_RATE * PRACTICE_SECONDS, STUDENTS) iterations start at
 * PRACTICE_RATE per second; iteration i is student i. The student loads the quiz for practice (GET for-student, as the
 * practice page does) and submits THINK_S later (POST submissions/practice), so that the submissions keep the fixed rate
 * (D10). Every student practises at most once: then each submission adds one unrated participant, which makes the
 * freshness measurable on both statistics models. The answers are lib/answers.mjs variant (index + 5), the same on every
 * commit (D19).
 *
 * Statistics freshness (glossary, D42) is an aggregate metric: for the n-th answered practice submission (in the order
 * the responses arrived), the time from that response until a tutor's page first shows at least n new unrated
 * participants. It does not follow one result: a count can become visible a few milliseconds before the n-th response
 * reaches k6, so values may be negative and are kept signed. k6 VUs share no memory, so the script records the times as
 * metric points (phase3_practice_answered, phase3_seen with tag tutor, phase3_subscribed, phase3_practice_sent) and
 * freshness.mjs pairs them from raw.json.gz and checks that the measurement is complete.
 *
 * Environment:
 *   SERVER    base URL of Artemis (k6.sh: http://artemis:8080)
 *   OUT       folder with manifest.json and sessions.json (login.mjs); summary.json and phase3.json are written there
 *   QUIZ      benchmark (default) or warmUp; the quiz must have ended (practice is open after the end of a course quiz)
 *   STUDENTS  students who may practise: the first N of sessions.json (default: all)
 *   PRACTICE_RATE     practice submissions per second (default 10)
 *   PRACTICE_SECONDS  length of the practice at that rate (default 60), shorter if STUDENTS limits SUBMISSIONS
 *   DRAIN_SECONDS  how long after the last planned submission the pages may take to show all of them (default 300)
 *
 * Request tag `type`: practice-load, practice-submit, statistics-open (page data at the start), statistics-footer,
 * statistics-reload (on-demand only). k6 thresholds: no failed request or check, every submission answered, no dropped
 * iteration (D38 rule 2), no POST sent late. A page that has not shown every submission at the deadline does not fail a
 * threshold: its missing values are censored at the deadline and count against the H3 bound (freshness.mjs, D42).
 */
import { check, fail, sleep } from 'k6';
import { SharedArray } from 'k6/data';
import exec from 'k6/execution';
import http from 'k6/http';
import { Counter, Trend } from 'k6/metrics';
import { clearInterval, clearTimeout, setInterval, setTimeout } from 'k6/timers';
import { WebSocket } from 'k6/websockets';
import { practiceSubmission } from './lib/answers.mjs';
import { cookieHeader, failedThresholds, frame, frames, params, statisticsMode, STOMP_HEARTBEAT_MS, trendLine, useSession, websocketUrl } from './lib/k6.js';

const SERVER = __ENV.SERVER;
const OUT = __ENV.OUT;
const QUIZ = __ENV.QUIZ ?? 'benchmark';
const RATE = Number(__ENV.PRACTICE_RATE ?? 10);
const SECONDS = Number(__ENV.PRACTICE_SECONDS ?? 60);
const DRAIN_SECONDS = Number(__ENV.DRAIN_SECONDS ?? 300);
// The tutors open their pages before the first practice request.
const PRACTICE_START_S = 5;
const THINK_S = 10;
const PRACTICE_VARIANT = 5;

const config = new SharedArray('config', () => {
    const manifest = JSON.parse(open(`${OUT}/manifest.json`));
    const quizId = { benchmark: manifest.benchmarkQuiz, warmUp: manifest.warmUpQuiz }[QUIZ];
    if (quizId === undefined) {
        throw new Error(`QUIZ must be benchmark or warmUp, not ${QUIZ}`);
    }
    return [{ quizId, warmUpQuiz: manifest.warmUpQuiz }];
})[0];
const sessions = new SharedArray('sessions', () => {
    const all = JSON.parse(open(`${OUT}/sessions.json`));
    return [{ instructor: all.instructor, tutors: all.tutors }];
})[0];
const students = new SharedArray('students', () => JSON.parse(open(`${OUT}/sessions.json`)).students);
const tutors = sessions.tutors;
const STUDENTS = Number(__ENV.STUDENTS ?? students.length);
if (!(STUDENTS >= 1 && STUDENTS <= students.length)) {
    throw new Error(`STUDENTS must be between 1 and ${students.length}, not ${__ENV.STUDENTS}`);
}
if (!(RATE > 0 && SECONDS > 0 && DRAIN_SECONDS > 0)) {
    throw new Error(`PRACTICE_RATE, PRACTICE_SECONDS, and DRAIN_SECONDS must be positive, not ${RATE}, ${SECONDS}, ${DRAIN_SECONDS}`);
}
const SUBMISSIONS = Math.min(Math.round(RATE * SECONDS), STUDENTS);
const PRACTICE_MS = Math.round((SUBMISSIONS / RATE) * 1000);
// From the start of the test: the last submission is planned at PRACTICE_START_S + PRACTICE_MS + THINK_S.
const DEADLINE_MS = PRACTICE_START_S * 1000 + PRACTICE_MS + THINK_S * 1000 + DRAIN_SECONDS * 1000;

const answered = new Counter('phase3_practice_answered');
const seen = new Trend('phase3_seen');
const messages = new Counter('phase3_messages');
const pagesComplete = new Counter('phase3_pages_complete');
const behindSchedule = new Counter('phase3_behind_schedule');
// Evidence for freshness.mjs: when each tutor sent its SUBSCRIBE (the server sends no receipt), and when each practice POST
// was sent (the arrival executor paces iteration starts, not POST starts).
const subscribed = new Counter('phase3_subscribed');
const practiceSent = new Counter('phase3_practice_sent');

const TYPES = ['practice-load', 'practice-submit', 'statistics-open', 'statistics-footer', 'statistics-reload'];
export const options = {
    setupTimeout: '60s',
    scenarios: {
        pages: {
            executor: 'per-vu-iterations',
            exec: 'pages',
            vus: tutors.length,
            iterations: 1,
            maxDuration: `${Math.ceil(DEADLINE_MS / 1000) + 30}s`,
        },
        practice: {
            executor: 'constant-arrival-rate',
            exec: 'practice',
            rate: RATE,
            timeUnit: '1s',
            // Iterations start at 0, 1/RATE, ...; ending half an interval before SUBMISSIONS/RATE leaves no start at the
            // boundary, which would find every VU busy and count as dropped (pilot of 2026-11-18). One second of spare VUs
            // covers a late start; an iteration beyond SUBMISSIONS sends nothing.
            duration: `${PRACTICE_MS - Math.round(500 / RATE)}ms`,
            // An iteration lasts THINK_S plus two responses.
            preAllocatedVUs: Math.min(SUBMISSIONS, Math.ceil(RATE * (THINK_S + 5))) + Math.ceil(RATE),
            maxVUs: SUBMISSIONS + Math.ceil(RATE),
            startTime: `${PRACTICE_START_S}s`,
            gracefulStop: `${THINK_S + 60}s`,
        },
    },
    summaryTrendStats: ['min', 'med', 'avg', 'p(90)', 'p(95)', 'p(99)', 'max', 'count'],
    thresholds: {
        checks: ['rate==1'],
        http_req_failed: ['rate==0'],
        dropped_iterations: ['count==0'],
        phase3_practice_answered: [`count==${SUBMISSIONS}`],
        phase3_behind_schedule: ['count==0'],
        // Always-true thresholds make k6 keep these submetrics in the summary.
        ...Object.fromEntries(TYPES.map((type) => [`http_req_duration{type:${type}}`, ['max>=0']])),
    },
};

export function setup() {
    useSession(SERVER, sessions.instructor);
    let mode;
    try {
        mode = statisticsMode(SERVER, sessions.instructor, config.warmUpQuiz);
    } catch (error) {
        fail(error.message);
    }
    const quiz = http.get(`${SERVER}/api/quiz/quiz-exercises/${config.quizId}`, params(sessions.instructor, { type: 'setup' }, 'text'));
    if (quiz.status !== 200 || !(Date.parse(quiz.json('dueDate')) < Date.now())) {
        fail(`quiz ${config.quizId} has not ended (HTTP ${quiz.status}); practice opens after the end`);
    }
    return { mode, start: Date.now() };
}

/** Unrated participants of the point statistic in a page response or a stored-statistics message. */
function unrated(body) {
    return body?.quizPointStatistic?.participantsUnrated ?? 0;
}

export function pages(run) {
    const index = exec.scenario.iterationInTest;
    const tutor = tutors[index];
    const tags = { tutor: String(index) };
    useSession(SERVER, tutor);
    const quiz = `${SERVER}/api/quiz/quiz-exercises/${config.quizId}`;
    const dataUrl = run.mode === 'stored' ? quiz : `${quiz}/statistics/points`;

    const [opened, footer] = http.batch([
        ['GET', dataUrl, null, params(tutor, { type: 'statistics-open' }, 'text')],
        ['GET', quiz, null, params(tutor, { type: 'statistics-footer' })],
    ]);
    if (!check(null, { 'statistics page answers 200': () => opened.status === 200, 'statistics footer answers 200': () => footer.status === 200 })) {
        return;
    }
    const initial = unrated(opened.json());
    seen.add(0, tags);

    let done = false;
    let reloading = false;
    let reloadAgain = false;
    let heartbeat = null;
    const ws = new WebSocket(websocketUrl(SERVER), null, { headers: { Cookie: cookieHeader(tutor) }, tags: { type: 'statistics-websocket' } });
    const finish = (complete) => {
        if (done) {
            return;
        }
        done = true;
        clearInterval(heartbeat);
        clearTimeout(deadline);
        if (complete) {
            pagesComplete.add(1, tags);
        }
        ws.close();
    };
    const deadline = setTimeout(() => finish(false), run.start + DEADLINE_MS - Date.now());
    const observe = (count) => {
        const shown = count - initial;
        seen.add(shown, tags);
        if (shown >= SUBMISSIONS) {
            finish(true);
        }
    };
    const reload = async () => {
        if (reloading) {
            reloadAgain = true;
            return;
        }
        reloading = true;
        do {
            reloadAgain = false;
            const response = await http.asyncRequest('GET', dataUrl, null, params(tutor, { type: 'statistics-reload' }, 'text'));
            if (check(response, { 'statistics reload answers 200': (r) => r.status === 200 }) && !done) {
                observe(unrated(response.json()));
            }
        } while (reloadAgain && !done);
        reloading = false;
    };

    ws.onopen = () => {
        ws.send(frame('CONNECT', { 'accept-version': '1.2', 'heart-beat': `${STOMP_HEARTBEAT_MS},${STOMP_HEARTBEAT_MS}`, host: 'artemis' }));
        heartbeat = setInterval(() => ws.send('\n'), STOMP_HEARTBEAT_MS);
    };
    ws.onmessage = (event) => {
        for (const { command, body } of frames(event.data)) {
            if (command === 'CONNECTED') {
                ws.send(frame('SUBSCRIBE', { id: 'statistic', destination: `/topic/statistic/${config.quizId}` }));
                subscribed.add(1, tags);
            } else if (command === 'MESSAGE') {
                messages.add(1, tags);
                if (run.mode === 'stored') {
                    observe(unrated(JSON.parse(body)));
                } else {
                    reload();
                }
            } else {
                check(null, { [`no STOMP ${command} frame`]: () => false });
                finish(false);
            }
        }
    };
    ws.onerror = (event) => {
        check(null, { 'statistics websocket has no error': () => false });
        console.error(`tutor ${index}: websocket error ${event.error}`);
        finish(false);
    };
    ws.onclose = () => {
        if (!done) {
            check(null, { 'statistics websocket stays open': () => false });
            finish(false);
        }
    };
}

export function practice() {
    const index = exec.scenario.iterationInTest;
    if (index >= SUBMISSIONS) {
        return;
    }
    const student = students[index];
    const submitAt = Date.now() + THINK_S * 1000;
    http.cookieJar().clear(SERVER);
    useSession(SERVER, student);

    const loaded = http.get(`${SERVER}/api/quiz/quiz-exercises/${config.quizId}/for-student`, params(student, { type: 'practice-load' }, 'text'));
    const questions = loaded.status === 200 ? loaded.json('quizQuestions') : null;
    if (!check(loaded, { 'practice load returns the questions': () => Array.isArray(questions) && questions.length > 0 })) {
        return;
    }
    const wait = submitAt - Date.now();
    if (wait > 0) {
        sleep(wait / 1000);
    } else {
        behindSchedule.add(1);
    }
    practiceSent.add(1);
    const submitted = http.post(
        `${SERVER}/api/quiz/exercises/${config.quizId}/submissions/practice`,
        JSON.stringify(practiceSubmission(questions, index + PRACTICE_VARIANT)),
        params(student, { type: 'practice-submit' }),
    );
    if (check(submitted, { 'practice submission succeeds': (response) => response.status === 200 })) {
        answered.add(1);
    }
}

export function handleSummary(data) {
    const failed = failedThresholds(data);
    const setup = data.setup_data ?? {};
    const value = (metric, key = 'count') => data.metrics[metric]?.values[key] ?? 0;
    return {
        [`${OUT}/summary.json`]: JSON.stringify(data, null, 2),
        [`${OUT}/phase3.json`]: `${JSON.stringify({
            quiz: QUIZ,
            quizId: config.quizId,
            mode: setup.mode ?? null,
            start: setup.start ?? null,
            end: setup.start ? setup.start + data.state.testRunDurationMs : null,
            rate: RATE,
            submissions: SUBMISSIONS,
            tutors: tutors.length,
            thinkSeconds: THINK_S,
            practiceStartSeconds: PRACTICE_START_S,
            deadline: setup.start ? setup.start + DEADLINE_MS : null,
        })}\n`,
        stdout: `${[
            `Phase 3 (${QUIZ} quiz ${config.quizId}, ${setup.mode} statistics, ${SUBMISSIONS} practice submissions at ${RATE}/s, ${tutors.length} tutors)`,
            ...TYPES.map((type) => trendLine(data, `http_req_duration{type:${type}}`, type)),
            `answered ${value('phase3_practice_answered')} of ${SUBMISSIONS}; complete pages ${value('phase3_pages_complete')} of ${tutors.length}; websocket messages ${value('phase3_messages')}; behind schedule ${value('phase3_behind_schedule')}`,
            failed.length ? `FAILED thresholds: ${failed.join(', ')}` : 'all thresholds hold',
        ].join('\n')}\n`,
    };
}
