/**
 * The deterministic answers of every student to the Track B quiz (lib/quiz.mjs). No Node or browser APIs: the seed (Node)
 * and the load test (k6) import the same module, so both send the same answers on every compared commit.
 */

/**
 * The live submission a student sends: for question Q<n> and variant `v` the answer is correct unless `(v + n - 1)` is
 * divisible by 3. The three variant groups answer different questions wrongly and score 60 % or 70 %, so the point
 * statistic has two counters and every question statistic counts wrong answers.
 * `questions` are the questions as a student loads them (ids of options, drop locations, drag items, spots).
 * The question number comes from the title, so the order in which a commit returns the questions does not matter.
 */
export function submission(questions, variant) {
    const submittedAnswers = questions.map((question) => {
        const index = Number(question.title.slice(1)) - 1;
        const correct = (variant + index) % 3 !== 0;
        const quizQuestion = { id: question.id, type: question.type };
        if (question.type === 'multiple-choice') {
            const options = sortBy(question.answerOptions, (option) => option.text);
            return { type: question.type, quizQuestion, selectedOptions: options.filter((_, option) => (option % 2 === 0) === correct).map((option) => ({ id: option.id })) };
        }
        if (question.type === 'drag-and-drop') {
            const items = sortBy(question.dragItems, (item) => item.text);
            const locations = sortBy(question.dropLocations, (location) => location.posX);
            const shift = correct ? 0 : 1;
            return {
                type: question.type,
                quizQuestion,
                mappings: items.map((item, slot) => ({ dragItem: { id: item.id }, dropLocation: { id: locations[(slot + shift) % locations.length].id } })),
            };
        }
        const spots = sortBy(question.spots, (spot) => spot.spotNr);
        return {
            type: question.type,
            quizQuestion,
            submittedTexts: spots.map((spot) => ({ text: correct ? `q${index + 1}s${spot.spotNr}` : 'wrong', spot: { id: spot.id } })),
        };
    });
    return { submissionExerciseType: 'quiz', submittedAnswers };
}

function sortBy(list, key) {
    return [...list].sort((a, b) => (key(a) < key(b) ? -1 : key(a) > key(b) ? 1 : 0));
}
