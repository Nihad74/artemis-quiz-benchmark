#!/usr/bin/env node
/**
 * Statistics freshness of a Phase 3 run (glossary, D15, D16 H3), from the k6 samples of phase3.js (raw.json.gz):
 * for the n-th answered practice submission (phase3_practice_answered, in the order the responses arrived), the time
 * until a tutor's page first shows at least n new unrated participants (phase3_seen, tag tutor). One value per tutor and
 * submission. All times come from the k6 process, so one clock.
 *
 * Usage: node freshness.mjs <phase3-folder>
 * Writes <phase3-folder>/freshness.json: the number of values, the values missing because a page never showed the
 * submission, median, p95, p99 (k6 interpolation; p99 only with at least 100 values, D38 rule 4), min, max, and per tutor
 * the time from the last response to the complete page (drain). Prints one summary line.
 */
import { readFileSync, writeFileSync } from 'node:fs';
import { gunzipSync } from 'node:zlib';

const folder = process.argv[2];
if (!folder) {
    console.error('usage: node freshness.mjs <phase3-folder>');
    process.exit(2);
}
const MIN_P99 = 100;

const answered = [];
const seen = new Map();
for (const line of gunzipSync(readFileSync(`${folder}/raw.json.gz`)).toString('utf8').split('\n')) {
    if (!line.includes('"phase3_practice_answered"') && !line.includes('"phase3_seen"')) {
        continue;
    }
    const { type, metric, data } = JSON.parse(line);
    if (type !== 'Point') {
        continue;
    }
    const time = Date.parse(data.time);
    if (metric === 'phase3_practice_answered') {
        answered.push(time);
    } else {
        const tutor = data.tags.tutor;
        if (!seen.has(tutor)) {
            seen.set(tutor, []);
        }
        seen.get(tutor).push({ time, shown: data.value });
    }
}
answered.sort((a, b) => a - b);

/** k6's percentile: linear interpolation between the closest ranks. */
function percentile(sorted, p) {
    const position = (sorted.length - 1) * p;
    const low = Math.floor(position);
    return sorted[low] + (sorted[Math.min(low + 1, sorted.length - 1)] - sorted[low]) * (position - low);
}

const values = [];
let missing = 0;
const drain = {};
for (const [tutor, observations] of [...seen.entries()].sort(([a], [b]) => Number(a) - Number(b))) {
    observations.sort((a, b) => a.time - b.time);
    let next = 0;
    for (let n = 1; n <= answered.length; n++) {
        while (next < observations.length && observations[next].shown < n) {
            next++;
        }
        if (next === observations.length) {
            missing += answered.length - n + 1;
            break;
        }
        values.push(observations[next].time - answered[n - 1]);
    }
    const complete = observations.find(({ shown }) => shown >= answered.length);
    drain[tutor] = complete && answered.length ? complete.time - answered[answered.length - 1] : null;
}
values.sort((a, b) => a - b);

const summary = {
    submissions: answered.length,
    tutors: seen.size,
    values: values.length,
    missing,
    medianMillis: values.length ? percentile(values, 0.5) : null,
    p95Millis: values.length ? percentile(values, 0.95) : null,
    p99Millis: values.length >= MIN_P99 ? percentile(values, 0.99) : null,
    minMillis: values[0] ?? null,
    maxMillis: values.at(-1) ?? null,
    drainMillis: drain,
};
writeFileSync(`${folder}/freshness.json`, `${JSON.stringify(summary, null, 2)}\n`);
const fmt = (value) => (value === null ? '–' : `${value.toFixed(0)} ms`);
console.log(
    `freshness: ${summary.values} values (${summary.submissions} submissions x ${summary.tutors} tutors, ${missing} missing) ` +
        `med=${fmt(summary.medianMillis)} p95=${fmt(summary.p95Millis)} p99=${fmt(summary.p99Millis)} max=${fmt(summary.maxMillis)}`,
);
