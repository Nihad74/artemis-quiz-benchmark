/**
 * The results that the deterministic answers of lib/answers.mjs must produce on every compared commit (D19), computed
 * without a server, so that a run can be checked before it becomes the reference of its run set.
 *
 * Student i (0-based, manifest order) submits variant i + 4 in Phase 1 (phase1.js: index + SAVES + 1) and, if i is below
 * the number of practice submissions, practises once with variant i + 5 in Phase 3. A question Q<n> is answered correctly
 * if (variant + n - 1) is not divisible by 3, else every component is wrong: multiple choice (all or nothing),
 * drag-and-drop (all items shifted, proportional with penalty), and short answer (both spots wrong) then score 0. So a
 * question scores its full points or 0.
 */

import { isDeepStrictEqual } from 'node:util';
import { createRequest } from './quiz.mjs';

const SUBMIT_OFFSET = 4;
const PRACTICE_OFFSET = 5;

// Use the seed fixture, not the observed quiz or the code that sends the answers. The fixture lists the options in
// text order, the drag items in text order, the drops in x-coordinate order, and the spots in spot-number order.
const { quizQuestions: questions } = createRequest({}).exercise;
const MAX_POINTS = questions.reduce((sum, question) => sum + question.points, 0);
const VALUES = [0, 1, 2].map((variant) => {
    let total = 0;
    const answers = new Map(questions.map((question) => {
        const n = Number(question.title.slice(1));
        const correct = (variant + n - 1) % 3 !== 0;
        const scoreInPoints = correct ? question.points : 0;
        total += scoreInPoints;
        return [question.title, { scoreInPoints, selection: selection(question, correct) }];
    }));
    return { answers, total };
});

// Content keys and list order match the normalized selections in semantics.mjs.
function selection(question, correct) {
    switch (question.type) {
        case 'multiple-choice':
            return question.answerOptions.filter((option) => option.isCorrect === correct).map((option) => option.text);
        case 'drag-and-drop':
            return question.dragItems.map((item, slot) => {
                const location = question.dropLocations[(slot + (correct ? 0 : 1)) % question.dropLocations.length];
                return { item: item.text, drop: `${location.posX},${location.posY}` };
            });
        case 'short-answer':
            return question.spots.map(({ spotNr }, slot) => ({ spot: spotNr, text: correct ? question.solutions[slot].text : 'wrong' }));
        default:
            throw new Error(`unknown fixture question type: ${question.type}`);
    }
}

/**
 * The differences between a semantics.json (semantics.mjs --quiz benchmark) and the expected results; empty if it matches.
 * `logins` are the students of the manifest in order, `students` the number that took the quiz, `practices` the number of
 * practice submissions of Phase 3 (0 without Phase 3).
 */
export function expectedResultErrors(semantics, logins, students, practices) {
    const errors = [];
    if (semantics.quiz.maxPoints !== MAX_POINTS) {
        errors.push(`quiz: ${semantics.quiz.maxPoints} maximum points, expected ${MAX_POINTS}`);
    }
    if (Object.keys(semantics.students).length !== students) {
        errors.push(`${Object.keys(semantics.students).length} students in the semantics, expected ${students}`);
    }
    const counters = new Map();
    const count = (total, field) => {
        const entry = counters.get(total) ?? { rated: 0, unrated: 0 };
        entry[field]++;
        counters.set(total, entry);
    };
    for (let index = 0; index < students; index++) {
        const login = logins[index];
        const student = semantics.students[login];
        const { answers: expected, total } = VALUES[(index + SUBMIT_OFFSET) % VALUES.length];
        count(total, 'rated');
        if (index < practices) {
            count(VALUES[(index + PRACTICE_OFFSET) % VALUES.length].total, 'unrated');
        }
        if (!student) {
            errors.push(`${login}: missing`);
            continue;
        }
        if (student.submissionScoreInPoints !== total || Math.abs(student.score - (100 * total) / MAX_POINTS) > 1e-9) {
            errors.push(`${login}: ${student.submissionScoreInPoints} points (${student.score} %), expected ${total} points`);
        }
        const seen = new Set();
        const answers = Array.isArray(student.answers) ? student.answers : [];
        for (const answer of answers) {
            const question = answer?.question;
            const wanted = expected.get(question);
            if (!wanted) {
                errors.push(`${login}: unexpected answer for ${question}`);
                continue;
            }
            if (seen.has(question)) {
                errors.push(`${login} ${question}: duplicate answer`);
                continue;
            }
            seen.add(question);
            if (answer.scoreInPoints !== wanted.scoreInPoints) {
                errors.push(`${login} ${question}: ${answer.scoreInPoints} points, expected ${wanted.scoreInPoints}`);
            }
            if (!isDeepStrictEqual(answer.selection, wanted.selection)) {
                errors.push(`${login} ${question}: selection ${JSON.stringify(answer.selection)}, expected ${JSON.stringify(wanted.selection)}`);
            }
        }
        for (const question of expected.keys()) {
            if (!seen.has(question)) {
                errors.push(`${login} ${question}: missing answer`);
            }
        }
    }
    const statistic = semantics.statistics.points;
    if (statistic.participantsRated !== students) {
        errors.push(`point statistic: ${statistic.participantsRated} rated participants, expected ${students}`);
    }
    if ((statistic.participantsUnrated ?? 0) !== practices) {
        errors.push(`point statistic: ${statistic.participantsUnrated} unrated participants, expected ${practices}`);
    }
    const expectedCounters = [...counters].map(([total, { rated, unrated }]) => [total, rated, unrated]).sort((a, b) => a[0] - b[0]);
    const actualCounters = [...statistic.counters].sort((a, b) => a[0] - b[0]);
    if (JSON.stringify(actualCounters) !== JSON.stringify(expectedCounters)) {
        errors.push(`point statistic counters ${JSON.stringify(actualCounters)}, expected ${JSON.stringify(expectedCounters)}`);
    }
    return errors;
}
