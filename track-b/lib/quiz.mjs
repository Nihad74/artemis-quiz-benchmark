/**
 * The Track B quiz (decision D10, Section 5.1 of the decisions): 10 questions, 4 multiple-choice, 3 drag-and-drop,
 * 3 short-answer, and the deterministic answers of every student.
 *
 * Every component has a content key that survives a migration and does not depend on database ids: the option text, the
 * drop location position, the drag item text, the spot number, the solution text. Drag items are text-only; the
 * background image of each drag-and-drop question exercises the file storage.
 */

// A valid 1x1 PNG; the server stores the file and only checks the extension.
export const PNG = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==', 'base64');

const KINDS = ['multiple-choice', 'drag-and-drop', 'short-answer', 'multiple-choice', 'drag-and-drop', 'short-answer', 'multiple-choice', 'drag-and-drop', 'short-answer', 'multiple-choice'];

/**
 * The create request (QuizExerciseCreateDTO) and its file parts.
 */
export function createRequest({ title, releaseDate, duration }) {
    let tempId = 1;
    const files = [];
    const quizQuestions = KINDS.map((type, index) => {
        const base = { type, title: `Q${index + 1}`, text: `Question ${index + 1}`, points: 2, randomizeOrder: false };
        if (type === 'multiple-choice') {
            return {
                ...base,
                scoringType: 'ALL_OR_NOTHING',
                singleChoice: false,
                answerOptions: ['A', 'B', 'C', 'D'].map((letter, option) => ({ text: `Q${index + 1}-${letter}`, isCorrect: option % 2 === 0 })),
            };
        }
        if (type === 'drag-and-drop') {
            const backgroundFilePath = `background${index}.png`;
            files.push({ name: 'files', filename: backgroundFilePath, type: 'image/png', bytes: PNG });
            const dropLocations = [0, 1, 2, 3].map((slot) => ({ tempID: tempId++, posX: 10 * (slot + 1), posY: 10 * (slot + 1), width: 10, height: 10 }));
            const dragItems = [0, 1, 2, 3].map((slot) => ({ tempID: tempId++, text: `Q${index + 1}-D${slot + 1}` }));
            return {
                ...base,
                scoringType: 'PROPORTIONAL_WITH_PENALTY',
                backgroundFilePath,
                dropLocations,
                dragItems,
                correctMappings: dragItems.map((item, slot) => ({ dragItemTempId: item.tempID, dropLocationTempId: dropLocations[slot].tempID })),
            };
        }
        const spots = [1, 2].map((spotNr) => ({ tempID: tempId++, spotNr, width: 10 }));
        const solutions = [1, 2].map((spotNr) => ({ tempID: tempId++, text: `q${index + 1}s${spotNr}` }));
        return {
            ...base,
            text: `Question ${index + 1}: [-spot 1] and [-spot 2]`,
            scoringType: 'PROPORTIONAL_WITHOUT_PENALTY',
            spots,
            solutions,
            correctMappings: spots.map((spot, slot) => ({ spotTempId: spot.tempID, solutionTempId: solutions[slot].tempID })),
            similarityValue: 100,
            matchLetterCase: true,
        };
    });
    const exercise = {
        title,
        releaseDate,
        mode: 'INDIVIDUAL',
        includedInOverallScore: 'INCLUDED_COMPLETELY',
        randomizeQuestionOrder: false,
        quizMode: 'SYNCHRONIZED',
        duration,
        quizQuestions,
    };
    return { exercise, files };
}

/**
 * The live submission a student sends: for question `q` (0-based) and variant `v` the answer is correct unless
 * `(v + q)` is divisible by 3. Students therefore fall into three groups with different scores, so the point statistic
 * has more than one counter. `quiz` is the quiz as a student loads it (ids of options, drop locations, drag items, spots).
 */
export function submission(quiz, variant) {
    const submittedAnswers = quiz.quizQuestions.map((question, index) => {
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
