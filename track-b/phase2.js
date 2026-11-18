/**
 * Track B, Phase 2: the statistics pages at the quiz end (decisions D10, D14, D16 H3, D38 rule 4). Run with k6.sh as soon
 * as the quiz is evaluated; run.sh starts it when the D17 timer line appears.
 *
 * Every tutor of sessions.json (the seed has 5), one VU each, opens the statistics at a random time in the first 10 s
 * (D10) and loads round 1: the overview, the points page, and the page of every question in the order Q1 to Q10. Round 1
 * is the initial read directly after the evaluation (tag read=initial). At the end of the 10 s window all tutors start the
 * rounds 2 to ROUNDS together and without think time (tag read=repeated), so that 5 tutors load the server at the same
 * time for the rest of the phase (D38 rule 4). Opening a page sends the requests that the client of the measured commit
 * sends when the page opens, in parallel as a browser does:
 *   stored statistics (43bafcee17c, f3463b75408, c136826e299): GET quiz-exercises/{id} for the page and for the footer;
 *   on-demand statistics (24a062759c2, 8325896e0b4): GET quiz-exercises/{id}/statistics/overview, .../points, or
 *     .../questions/{questionId} for the page, and GET quiz-exercises/{id} for the footer.
 * The setup tells the two apart with one request to the points endpoint of the warm-up quiz, not of the measured quiz:
 * 404 means stored statistics. A fixed number of rounds sends the same number of requests of every type on both commits
 * (D19). The benchmark quiz needs at least 100 repeated observations of the overview and the points page (D38 rule 4):
 * 5 tutors and 21 rounds give 100, and 1000 of the question pages; the warm-up may use fewer rounds.
 *
 * Environment:
 *   SERVER    base URL of Artemis (k6.sh: http://artemis:8080)
 *   OUT       folder with manifest.json, sessions.json (login.mjs), and questions.json (phase1.js of the same quiz);
 *             summary.json and phase2.json (statistics mode, start time) are written there
 *   QUIZ      benchmark (default) or warmUp
 *   STUDENTS  students who took the quiz (default: all of sessions.json); the points page must count all of them
 *   ROUNDS    rounds per tutor, the initial one included (default 21)
 *   MAX_DURATION  k6 duration limit of the scenario (default 15m); a tutor who does not finish makes the run invalid
 *   SEED      seed of the start offsets (default 1)
 *
 * Request tags `type` (statistics-overview, statistics-points, statistics-question: the page data; statistics-footer)
 * and `read` (initial, repeated). Trend `phase2_page_duration` with tags `page` (overview, points, question) and `read`:
 * the time until all requests of a page are answered. Trend `phase2_first_request`: when each tutor sent its first
 * request, in ms after the end of the setup (phase2.json `start`). A run is valid only if all thresholds hold: no failed
 * request or check, every page of every round loaded, and the points page counts every student.
 */
import { check, fail, sleep } from 'k6';
import { SharedArray } from 'k6/data';
import exec from 'k6/execution';
import http from 'k6/http';
import { Counter, Trend } from 'k6/metrics';
import { failedThresholds, params, prng, statisticsMode, trendLine, useSession } from './lib/k6.js';

const SERVER = __ENV.SERVER;
const OUT = __ENV.OUT;
const QUIZ = __ENV.QUIZ ?? 'benchmark';
const ROUNDS = Number(__ENV.ROUNDS ?? 21);
const SEED = Number(__ENV.SEED ?? 1);
const OPEN_WINDOW_MS = 10_000;

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
    return [{ instructor: all.instructor, tutors: all.tutors, students: all.students.length }];
})[0];
const questions = new SharedArray('questions', () => JSON.parse(open(`${OUT}/questions.json`)));
const STUDENTS = Number(__ENV.STUDENTS ?? sessions.students);
const tutors = sessions.tutors;

if (questions.length === 0) {
    throw new Error(`${OUT}/questions.json lists no questions; phase1.js of this quiz writes it`);
}
if (!(Number.isInteger(ROUNDS) && ROUNDS >= 1)) {
    throw new Error(`ROUNDS must be a positive integer, not ${__ENV.ROUNDS}`);
}
const MIN_REPEATED = 100;
if (QUIZ === 'benchmark' && tutors.length * (ROUNDS - 1) < MIN_REPEATED) {
    throw new Error(`the benchmark quiz needs ${MIN_REPEATED} repeated reads per endpoint (D38 rule 4); ${tutors.length} tutors x ${ROUNDS - 1} repeated rounds give ${tutors.length * (ROUNDS - 1)}`);
}

const PAGES = ['overview', 'points', ...questions.map(() => 'question')];
const pageDuration = new Trend('phase2_page_duration', true);
const pagesLoaded = new Counter('phase2_pages_loaded');
const firstRequest = new Trend('phase2_first_request', true);
const READS = ['initial', 'repeated'];

export const options = {
    setupTimeout: '60s',
    scenarios: {
        phase2: {
            executor: 'per-vu-iterations',
            vus: tutors.length,
            iterations: 1,
            maxDuration: __ENV.MAX_DURATION ?? '15m',
        },
    },
    summaryTrendStats: ['min', 'med', 'avg', 'p(90)', 'p(95)', 'p(99)', 'max', 'count'],
    thresholds: {
        checks: ['rate==1'],
        http_req_failed: ['rate==0'],
        dropped_iterations: ['count==0'],
        phase2_pages_loaded: [`count==${tutors.length * ROUNDS * PAGES.length}`],
        // Always-true thresholds make k6 keep these submetrics in the summary.
        ...Object.fromEntries(['overview', 'points', 'question', 'footer'].flatMap((type) => READS.map((read) => [`http_req_duration{type:statistics-${type},read:${read}}`, ['max>=0']]))),
        ...Object.fromEntries(['overview', 'points', 'question'].flatMap((page) => READS.map((read) => [`phase2_page_duration{page:${page},read:${read}}`, ['max>=0']]))),
        phase2_first_request: ['max>=0'],
    },
};

export function setup() {
    useSession(SERVER, sessions.instructor);
    try {
        return { mode: statisticsMode(SERVER, sessions.instructor, config.warmUpQuiz), start: Date.now() };
    } catch (error) {
        fail(error.message);
    }
}

/** The data request of a page: what the page component of the measured commit loads. */
function pageUrl(mode, page, question) {
    const quiz = `${SERVER}/api/quiz/quiz-exercises/${config.quizId}`;
    if (mode === 'stored') {
        return quiz;
    }
    return page === 'question' ? `${quiz}/statistics/questions/${question.id}` : `${quiz}/statistics/${page}`;
}

export default function (run) {
    const index = exec.vu.idInTest - 1;
    const tutor = tutors[index];
    useSession(SERVER, tutor);
    const wait = run.start + prng(SEED * 1_000_003 + index)() * OPEN_WINDOW_MS - Date.now();
    if (wait > 0) {
        sleep(wait / 1000);
    }
    firstRequest.add(Date.now() - run.start);
    loadRound(run, tutor, 'initial');
    const together = run.start + OPEN_WINDOW_MS - Date.now();
    if (together > 0) {
        sleep(together / 1000);
    }
    for (let round = 2; round <= ROUNDS; round++) {
        loadRound(run, tutor, 'repeated');
    }
}

/** One round: every page in order, each with its data and the footer in parallel. */
function loadRound(run, tutor, read) {
    const footer = `${SERVER}/api/quiz/quiz-exercises/${config.quizId}`;
    let questionIndex = 0;
    for (const page of PAGES) {
        const question = page === 'question' ? questions[questionIndex++] : null;
        const started = Date.now();
        const [data, footerResponse] = http.batch([
            ['GET', pageUrl(run.mode, page, question), null, params(tutor, { type: `statistics-${page}`, read }, page === 'points' ? 'text' : 'none')],
            ['GET', footer, null, params(tutor, { type: 'statistics-footer', read })],
        ]);
        pageDuration.add(Date.now() - started, { page, read });
        const checks = { 'statistics page answers 200': () => data.status === 200, 'statistics footer answers 200': () => footerResponse.status === 200 };
        if (page === 'points') {
            checks['points page counts every student'] = () => data.status === 200 && data.json('quizPointStatistic.participantsRated') === STUDENTS;
        }
        if (check(null, checks)) {
            pagesLoaded.add(1);
        }
    }
}

export function handleSummary(data) {
    const failed = failedThresholds(data);
    const setup = data.setup_data ?? {};
    return {
        [`${OUT}/summary.json`]: JSON.stringify(data, null, 2),
        [`${OUT}/phase2.json`]: `${JSON.stringify({ quiz: QUIZ, quizId: config.quizId, mode: setup.mode ?? null, start: setup.start ?? null, tutors: tutors.length, rounds: ROUNDS, questions: questions.length, students: STUDENTS })}\n`,
        stdout: `${[
            `Phase 2 (${QUIZ} quiz ${config.quizId}, ${setup.mode} statistics, ${tutors.length} tutors x ${ROUNDS} rounds, ${STUDENTS} students)`,
            ...['overview', 'points', 'question', 'footer'].flatMap((type) => READS.map((read) => trendLine(data, `http_req_duration{type:statistics-${type},read:${read}}`, `statistics-${type} ${read}`))),
            ...['overview', 'points', 'question'].map((page) => trendLine(data, `phase2_page_duration{page:${page},read:repeated}`, `page ${page} repeated`)),
            trendLine(data, 'phase2_first_request', 'first request after the setup'),
            failed.length ? `FAILED thresholds: ${failed.join(', ')}` : 'all thresholds hold',
        ].join('\n')}\n`,
    };
}
