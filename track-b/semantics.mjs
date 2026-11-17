#!/usr/bin/env node
/**
 * Decision D19 for Track B: what instructors, tutors and students see of the seeded data, normalized to content so that two
 * commits (or one database before and after the forward migration) can be compared with `diff`:
 *
 * - the questions of the evaluated quiz with their solutions (instructor view);
 * - every student's stored answers and scores, as the student sees them after the quiz (start-participation);
 * - the statistics: the stored statistics of the quiz (relational baseline) or the statistics endpoints (on-demand
 *   statistics, from 24a062759c2 on), whichever the server offers;
 * - the rated participants in the point statistic as each tutor sees it: the tutors read the statistics in Phase 2;
 * - the text exercise of the control workflow and the warm-up and benchmark quizzes, which must still be unstarted.
 *
 * Components are keyed by content (option text, drop location position, drag item text, spot number), never by id.
 * Read-only for the evaluated quiz. Logs in every user once; rate limiting is off (compose.yml). Usage:
 *   node semantics.mjs --manifest manifest.json [--server URL] --out semantics.json
 */
import { readFileSync, writeFileSync } from 'node:fs';
import { parseArgs } from 'node:util';
import { Client, forEachLimited } from './lib/client.mjs';
import { pointStatistic } from './lib/quiz.mjs';

const { values: args } = parseArgs({ options: { manifest: { type: 'string' }, server: { type: 'string' }, out: { type: 'string' } } });
const manifest = JSON.parse(readFileSync(args.manifest, 'utf8'));
const server = args.server ?? manifest.server;
const quizId = manifest.evaluatedQuiz;

const teacher = await new Client(server).login(manifest.instructor, manifest.password);
const quiz = (await teacher.get(`/api/quiz/quiz-exercises/${quizId}`)).data;
const questions = [...quiz.quizQuestions].sort((a, b) => Number(a.title.slice(1)) - Number(b.title.slice(1)));

// id -> content key, per component type (ids are unique only per type on the baseline).
const keys = { option: new Map(), drop: new Map(), item: new Map(), spot: new Map(), solution: new Map() };
for (const question of questions) {
    for (const option of question.answerOptions ?? []) keys.option.set(option.id, option.text);
    for (const location of question.dropLocations ?? []) keys.drop.set(location.id, `${location.posX},${location.posY}`);
    for (const item of question.dragItems ?? []) keys.item.set(item.id, item.text);
    for (const spot of question.spots ?? []) keys.spot.set(spot.id, spot.spotNr);
    for (const solution of question.solutions ?? []) keys.solution.set(solution.id, solution.text);
}
const id = (value, field) => value?.[field]?.id ?? value?.[`${field}Id`];
const sorted = (list) => [...list].sort((a, b) => JSON.stringify(a).localeCompare(JSON.stringify(b)));

function definition(question) {
    const common = { title: question.title, type: question.type, points: question.points, scoringType: question.scoringType, invalid: question.invalid ?? false };
    if (question.type === 'multiple-choice') {
        return { ...common, singleChoice: question.singleChoice, options: sorted(question.answerOptions.map((option) => ({ text: option.text, correct: option.isCorrect, invalid: option.invalid ?? false }))) };
    }
    if (question.type === 'drag-and-drop') {
        // Mappings carry nested components on some commits and indexes into the component lists on others.
        const mappings = question.correctMappings.map((mapping) => ({
            item: keys.item.get(id(mapping, 'dragItem')) ?? question.dragItems[mapping.dragItemIndex]?.text,
            drop: keys.drop.get(id(mapping, 'dropLocation')) ?? `${question.dropLocations[mapping.dropLocationIndex]?.posX},${question.dropLocations[mapping.dropLocationIndex]?.posY}`,
        }));
        return {
            ...common,
            hasBackground: Boolean(question.backgroundFilePath),
            drops: sorted(question.dropLocations.map((location) => [location.posX, location.posY, location.width, location.height])),
            items: sorted(question.dragItems.map((item) => item.text)),
            correct: sorted(mappings),
        };
    }
    const mappings = question.correctMappings.map((mapping) => ({
        spot: keys.spot.get(id(mapping, 'spot')) ?? question.spots[mapping.shortAnswerSpotIndex]?.spotNr,
        solution: keys.solution.get(id(mapping, 'solution')) ?? question.solutions[mapping.shortAnswerSolutionIndex]?.text,
    }));
    return {
        ...common,
        text: question.text,
        similarityValue: question.similarityValue,
        matchLetterCase: question.matchLetterCase,
        spots: sorted(question.spots.map((spot) => [spot.spotNr, spot.width])),
        correct: sorted(mappings),
    };
}

function answer(submitted) {
    const questionId = submitted.quizQuestion?.id ?? submitted.quizQuestionId;
    const title = questions.find((question) => question.id === questionId)?.title;
    const selection =
        submitted.type === 'multiple-choice'
            ? sorted((submitted.selectedOptions ?? []).map((option) => keys.option.get(option.id ?? option)))
            : submitted.type === 'drag-and-drop'
              ? sorted((submitted.mappings ?? []).map((mapping) => ({ item: keys.item.get(id(mapping, 'dragItem')), drop: keys.drop.get(id(mapping, 'dropLocation')) })))
              : sorted((submitted.submittedTexts ?? []).map((text) => ({ spot: keys.spot.get(id(text, 'spot')), text: text.text })));
    return { question: title, selection, scoreInPoints: submitted.scoreInPoints ?? null };
}

const students = {};
await forEachLimited(manifest.students, 8, async (login) => {
    const client = await new Client(server).login(login, manifest.password);
    const participation = (await client.post(`/api/quiz/quiz-exercises/${quizId}/start-participation`)).data;
    const submission = participation.submissions?.[0] ?? {};
    const results = participation.results ?? submission.results ?? [];
    const rated = results.filter((result) => result.rated !== false).sort((a, b) => b.id - a.id)[0];
    students[login] = {
        score: rated?.score ?? null,
        submissionScoreInPoints: submission.scoreInPoints ?? null,
        answers: sorted((submission.submittedAnswers ?? []).map(answer)),
    };
});

async function statistics() {
    const counter = (list, field, map) =>
        sorted((list ?? []).map((entry) => ({ key: map.get(id(entry, field)), rated: entry.ratedCounter, unrated: entry.unRatedCounter })));
    const question = (title, statistic) => ({
        question: title,
        participantsRated: statistic.participantsRated,
        participantsUnrated: statistic.participantsUnrated,
        ratedCorrect: statistic.ratedCorrectCounter,
        unratedCorrect: statistic.unRatedCorrectCounter,
        counters: [
            ...counter(statistic.answerCounters, 'answer', keys.option),
            ...counter(statistic.dropLocationCounters, 'dropLocation', keys.drop),
            ...counter(statistic.shortAnswerSpotCounters, 'spot', keys.spot),
        ],
    });
    const points = (statistic) => ({
        participantsRated: statistic.participantsRated,
        participantsUnrated: statistic.participantsUnrated,
        // Counters that count nobody carry no information; the on-demand endpoints omit them.
        counters: sorted((statistic.pointCounters ?? []).filter((entry) => entry.ratedCounter || entry.unRatedCounter).map((entry) => [entry.points, entry.ratedCounter, entry.unRatedCounter])),
    });
    const { source, statistic: pointCounts } = await pointStatistic(teacher, quizId);
    if (source === 'stored statistics') {
        return { source, points: points(pointCounts), questions: questions.map((entry) => question(entry.title, entry.quizQuestionStatistic)) };
    }
    const perQuestion = [];
    for (const entry of questions) {
        perQuestion.push(question(entry.title, (await teacher.get(`/api/quiz/quiz-exercises/${quizId}/statistics/questions/${entry.id}`)).data.quizQuestionStatistic));
    }
    return { source, points: points(pointCounts), questions: perQuestion };
}

const tutors = {};
await forEachLimited(manifest.tutors, 8, async (login) => {
    const client = await new Client(server).login(login, manifest.password);
    tutors[login] = { pointStatisticParticipantsRated: (await pointStatistic(client, quizId)).statistic.participantsRated };
});

// Dates as instants: the JSON format of a date can change between versions, the instant must not.
const instant = (value) => (value ? new Date(value).toISOString() : null);
async function unstartedQuiz(id) {
    const { data } = await teacher.get(`/api/quiz/quiz-exercises/${id}`);
    return { title: data.title, quizMode: data.quizMode, duration: data.duration, questions: data.quizQuestions.length, releaseDate: instant(data.releaseDate), dueDate: instant(data.dueDate) };
}
const textExercise = (await teacher.get(`/api/text/text-exercises/${manifest.textExercise}`)).data;

const statistic = await statistics();
const result = {
    quiz: { title: quiz.title, quizMode: quiz.quizMode, duration: quiz.duration, maxPoints: quiz.maxPoints, questions: questions.map(definition) },
    students: Object.fromEntries(Object.entries(students).sort(([a], [b]) => a.localeCompare(b))),
    statisticsSource: statistic.source,
    statistics: { points: statistic.points, questions: statistic.questions },
    tutors: Object.fromEntries(Object.entries(tutors).sort(([a], [b]) => a.localeCompare(b))),
    textExercise: {
        title: textExercise.title,
        maxPoints: textExercise.maxPoints,
        mode: textExercise.mode,
        includedInOverallScore: textExercise.includedInOverallScore,
        releaseDate: instant(textExercise.releaseDate),
        dueDate: instant(textExercise.dueDate),
    },
    warmUpQuiz: await unstartedQuiz(manifest.warmUpQuiz),
    benchmarkQuiz: await unstartedQuiz(manifest.benchmarkQuiz),
};
writeFileSync(args.out, JSON.stringify(result, null, 2) + '\n');
console.log(`wrote ${args.out} (${Object.keys(students).length} students, ${Object.keys(tutors).length} tutors, ${statistic.source})`);
