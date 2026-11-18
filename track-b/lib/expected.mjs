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

const SUBMIT_OFFSET = 4;
const PRACTICE_OFFSET = 5;

function points(questions, variant) {
    return Object.fromEntries(questions.map((question) => {
        const n = Number(question.title.slice(1));
        return [question.title, (variant + n - 1) % 3 !== 0 ? question.points : 0];
    }));
}

/**
 * The differences between a semantics.json (semantics.mjs --quiz benchmark) and the expected results; empty if it matches.
 * `logins` are the students of the manifest in order, `students` the number that took the quiz, `practices` the number of
 * practice submissions of Phase 3 (0 without Phase 3).
 */
export function expectedResultErrors(semantics, logins, students, practices) {
    const errors = [];
    const questions = semantics.quiz.questions;
    const maxPoints = semantics.quiz.maxPoints;
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
        const expected = points(questions, index + SUBMIT_OFFSET);
        const total = Object.values(expected).reduce((sum, value) => sum + value, 0);
        count(total, 'rated');
        if (index < practices) {
            count(Object.values(points(questions, index + PRACTICE_OFFSET)).reduce((sum, value) => sum + value, 0), 'unrated');
        }
        if (!student) {
            errors.push(`${login}: missing`);
            continue;
        }
        if (student.submissionScoreInPoints !== total || Math.abs(student.score - (100 * total) / maxPoints) > 1e-9) {
            errors.push(`${login}: ${student.submissionScoreInPoints} points (${student.score} %), expected ${total} points`);
        }
        for (const answer of student.answers) {
            if (answer.scoreInPoints !== expected[answer.question]) {
                errors.push(`${login} ${answer.question}: ${answer.scoreInPoints} points, expected ${expected[answer.question]}`);
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
