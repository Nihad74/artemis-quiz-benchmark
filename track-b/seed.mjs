#!/usr/bin/env node
/**
 * Track B seed (decision D18), run once against the relational baseline:
 *
 * - one course with one instructor, `--tutors` tutors, and `--students` students. The instructor starts the quizzes; the
 *   tutors open the statistics pages in Phase 2 (D10; tutors may read the statistics on every compared commit);
 * - a text exercise, open for submissions for a year: the control workflow (D20);
 * - the evaluated quiz: every student loads it, starts the participation, saves once, and submits; the scheduled task
 *   evaluates it (D17). It carries answers, results, and statistics through the forward migration (D2, D19);
 * - the warm-up quiz (D38 rule 5) and the benchmark quiz: the same 10 questions, not started (D13), `--benchmark-duration`
 *   seconds long (Section 5.1). The load test starts them with start-now.
 *
 * Writes a manifest with the ids and logins. Usage:
 *   node seed.mjs --server http://localhost:18080 --students 20 --out manifest.json
 */
import { writeFileSync } from 'node:fs';
import { parseArgs } from 'node:util';
import { Client, forEachLimited, multipart } from './lib/client.mjs';
import { createRequest, pointStatistic, submission } from './lib/quiz.mjs';

const { values: args } = parseArgs({
    options: {
        server: { type: 'string', default: 'http://localhost:18080' },
        students: { type: 'string', default: '20' },
        tutors: { type: 'string', default: '5' },
        prefix: { type: 'string', default: 'tb' },
        password: { type: 'string', default: 'Password123!' },
        // The evaluated quiz only has to end soon; the seed waits for its evaluation.
        'evaluated-duration': { type: 'string', default: '60' },
        'benchmark-duration': { type: 'string', default: '120' },
        out: { type: 'string', default: 'manifest.json' },
    },
});
const students = Number(args.students);
const PARALLEL = 8;

// The internal admin of compose.yml.
const admin = await new Client(args.server).login('artemis_admin', 'thesis-track-b-local-admin');
const now = Date.now();
const course = (
    await admin.request('POST', '/api/core/admin/courses', {
        form: multipart({
            course: {
                title: 'Track B course',
                shortName: `${args.prefix}course`,
                startDate: new Date(now - 864e5).toISOString(),
                endDate: new Date(now + 365 * 864e5).toISOString(),
                courseInformationSharingConfiguration: 'COMMUNICATION_AND_MESSAGING',
                complaintsEnabled: false,
                requestMoreFeedbackEnabled: false,
                maxComplaints: 0,
                maxTeamComplaints: 0,
                maxComplaintTimeDays: 0,
                maxRequestMoreFeedbackTimeDays: 0,
                maxComplaintTextLimit: 2000,
                maxComplaintResponseTextLimit: 2000,
                enrollmentEnabled: false,
                accuracyOfScores: 1,
                onlineCourse: false,
                timeZone: 'Europe/Berlin',
            },
        }),
    })
).data;

async function createUser(login, group) {
    await admin.post('/api/core/admin/users', { activated: true, login, email: `${login}@thesis.local`, firstName: 'Bench', lastName: login, langKey: 'en', password: args.password, groups: [] });
    await admin.post(`/api/core/courses/${course.id}/${group}/${login}`);
}

const instructor = `${args.prefix}instructor`;
await createUser(instructor, 'instructors');
const tutors = Array.from({ length: Number(args.tutors) }, (_, index) => `${args.prefix}tutor${index + 1}`);
await forEachLimited(tutors, PARALLEL, (login) => createUser(login, 'tutors'));
const logins = Array.from({ length: students }, (_, index) => `${args.prefix}student${index + 1}`);
await forEachLimited(logins, PARALLEL, (login) => createUser(login, 'students'));
console.log(`course ${course.id}: 1 instructor, ${tutors.length} tutors, ${students} students`);

const teacher = await new Client(args.server).login(instructor, args.password);
const textExercise = (
    await teacher.post('/api/text/text-exercises', {
        title: 'Control text exercise',
        courseId: course.id,
        maxPoints: 10,
        includedInOverallScore: 'INCLUDED_COMPLETELY',
        mode: 'INDIVIDUAL',
        releaseDate: new Date(now - 864e5).toISOString(),
        dueDate: new Date(now + 365 * 864e5).toISOString(),
    })
).data.id;
console.log(`text exercise ${textExercise}: open until ${new Date(now + 365 * 864e5).toISOString()}`);

async function createQuiz(title, releaseDate, duration) {
    const { exercise, files } = createRequest({ title, releaseDate, duration: Number(duration) });
    const created = (await teacher.request('POST', `/api/quiz/courses/${course.id}/quiz-exercises`, { form: multipart({ exercise }, files) })).data;
    return created.quizExercise?.id ?? created.id;
}

const evaluatedQuiz = await createQuiz('Evaluated quiz', new Date(now + 864e5).toISOString(), args['evaluated-duration']);
await teacher.put(`/api/quiz/quiz-exercises/${evaluatedQuiz}/start-now`);
await forEachLimited(logins, PARALLEL, async (login, index) => {
    const client = await new Client(args.server).login(login, args.password);
    const quiz = (await client.get(`/api/quiz/quiz-exercises/${evaluatedQuiz}/for-student`)).data;
    await client.post(`/api/quiz/quiz-exercises/${evaluatedQuiz}/start-participation`);
    await client.post(`/api/quiz/exercises/${evaluatedQuiz}/submissions/live?submit=false`, submission(quiz, index + 1));
    await client.post(`/api/quiz/exercises/${evaluatedQuiz}/submissions/live?submit=true`, submission(quiz, index + 2));
});
const due = new Date((await teacher.get(`/api/quiz/quiz-exercises/${evaluatedQuiz}`)).data.dueDate).getTime();
console.log(`quiz ${evaluatedQuiz}: ${students} submissions, due ${new Date(due).toISOString()}`);

// The scheduled task evaluates the quiz at its due date; the point statistic then counts every student.
const deadline = due + 120_000;
for (;;) {
    const { statistic } = await pointStatistic(teacher, evaluatedQuiz);
    if (statistic?.participantsRated === students) {
        break;
    }
    if (Date.now() > deadline) {
        throw new Error(`quiz ${evaluatedQuiz} not evaluated 120 s after its due date: ${JSON.stringify(statistic?.participantsRated)} rated participants`);
    }
    await new Promise((resolve) => setTimeout(resolve, 2000));
}
console.log(`quiz ${evaluatedQuiz}: evaluated`);

const notStarted = new Date(now + 365 * 864e5).toISOString();
const warmUpQuiz = await createQuiz('Warm-up quiz', notStarted, args['benchmark-duration']);
const benchmarkQuiz = await createQuiz('Benchmark quiz', notStarted, args['benchmark-duration']);
console.log(`quizzes ${warmUpQuiz} (warm-up) and ${benchmarkQuiz} (benchmark): ${args['benchmark-duration']} s, not started`);

const manifest = {
    server: args.server,
    courseId: course.id,
    instructor,
    tutors,
    students: logins,
    password: args.password,
    textExercise,
    evaluatedQuiz,
    warmUpQuiz,
    benchmarkQuiz,
    benchmarkDuration: Number(args['benchmark-duration']),
    seededAt: new Date().toISOString(),
};
writeFileSync(args.out, JSON.stringify(manifest, null, 2) + '\n');
console.log(`wrote ${args.out}`);
