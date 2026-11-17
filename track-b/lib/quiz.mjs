/**
 * The Track B quiz (decision D10, Section 5.1 of the decisions): 10 questions, 4 multiple-choice, 3 drag-and-drop,
 * 3 short-answer. The answers of the students are in lib/answers.mjs.
 *
 * Every component has a content key that survives a migration and does not depend on database ids: the option text, the
 * drop location position, the drag item text, the spot number, the solution text. Drag items are text-only; the
 * background image of each drag-and-drop question exercises the file storage.
 */

import { HttpError } from './client.mjs';

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
 * The point statistic of a quiz as `client` sees it, and where it comes from: the statistics endpoint (on-demand statistics,
 * from 24a062759c2 on) or the statistic stored with the quiz (before; the endpoint answers 404 there).
 */
export async function pointStatistic(client, quizId) {
    try {
        const { data } = await client.get(`/api/quiz/quiz-exercises/${quizId}/statistics/points`);
        return { source: 'statistics endpoints', statistic: data.quizPointStatistic };
    } catch (error) {
        if (!(error instanceof HttpError) || error.status !== 404) throw error;
        const { data } = await client.get(`/api/quiz/quiz-exercises/${quizId}`);
        return { source: 'stored statistics', statistic: data.quizPointStatistic };
    }
}
