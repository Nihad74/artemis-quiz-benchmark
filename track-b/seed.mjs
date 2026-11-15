#!/usr/bin/env node
/**
 * Track B seed (decision D18), run once against the relational baseline:
 *
 * - one course with one instructor and `--students` students;
 * - the evaluated quiz: every student loads it, starts the participation, saves once, and submits; the scheduled task
 *   evaluates it (D17). It carries answers, results, and statistics through the forward migration (D2, D19);
 * - the benchmark quiz: the same 10 questions, not started (D13); the load test starts it with start-now.
 *
 * Writes a manifest with the ids and logins. Usage:
 *   node seed.mjs --server http://localhost:18080 --students 20 --out manifest.json
 */
import { writeFileSync } from 'node:fs';
import { parseArgs } from 'node:util';
import { Client, forEachLimited, multipart } from './lib/client.mjs';
import { createRequest, submission } from './lib/quiz.mjs';

const { values: args } = parseArgs({
    options: {
        server: { type: 'string', default: 'http://localhost:18080' },
        students: { type: 'string', default: '20' },
        prefix: { type: 'string', default: 'tb' },
        password: { type: 'string', default: 'Password123!' },
        duration: { type: 'string', default: '60' },
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
const logins = Array.from({ length: students }, (_, index) => `${args.prefix}student${index + 1}`);
await forEachLimited(logins, PARALLEL, (login) => createUser(login, 'students'));
console.log(`course ${course.id}: 1 instructor, ${students} students`);

const teacher = await new Client(args.server).login(instructor, args.password);
async function createQuiz(title, releaseDate) {
    const { exercise, files } = createRequest({ title, releaseDate, duration: Number(args.duration) });
    const created = (await teacher.request('POST', `/api/quiz/courses/${course.id}/quiz-exercises`, { form: multipart({ exercise }, files) })).data;
    return created.quizExercise?.id ?? created.id;
}

const evaluatedQuiz = await createQuiz('Evaluated quiz', new Date(now + 864e5).toISOString());
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

// The scheduled task evaluates the quiz at its due date; the stored statistics then count every student.
const deadline = due + 120_000;
for (;;) {
    const points = (await teacher.get(`/api/quiz/quiz-exercises/${evaluatedQuiz}`)).data.quizPointStatistic;
    if (points?.participantsRated === students) {
        break;
    }
    if (Date.now() > deadline) {
        throw new Error(`quiz ${evaluatedQuiz} not evaluated 120 s after its due date: ${JSON.stringify(points?.participantsRated)} rated participants`);
    }
    await new Promise((resolve) => setTimeout(resolve, 2000));
}
console.log(`quiz ${evaluatedQuiz}: evaluated`);

const benchmarkQuiz = await createQuiz('Benchmark quiz', new Date(now + 365 * 864e5).toISOString());
console.log(`quiz ${benchmarkQuiz}: benchmark quiz, not started`);

const manifest = { server: args.server, courseId: course.id, instructor, students: logins, password: args.password, evaluatedQuiz, benchmarkQuiz, seededAt: new Date().toISOString() };
writeFileSync(args.out, JSON.stringify(manifest, null, 2) + '\n');
console.log(`wrote ${args.out}`);
