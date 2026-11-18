#!/usr/bin/env node
/**
 * Statistics freshness of a Phase 3 run (glossary, D15, D42), from the k6 samples of phase3.js (raw.json.gz) and the
 * expected counts in phase3.json.
 *
 * Freshness is an aggregate metric: for the n-th answered practice submission (phase3_practice_answered, in the order the
 * responses arrived), the time until a tutor's page first shows at least n new unrated participants (phase3_seen, tag
 * tutor). One value per tutor and submission. It does not follow one result: a count can become visible before the n-th
 * response reaches k6, so values are signed. All times come from the k6 process, so one clock.
 *
 * A value that a page never showed before the deadline of phase3.js is censored: it is counted at the deadline, a lower
 * bound, so it raises the percentiles instead of being dropped (D42: a complete run above the H3 bound is evidence
 * against H3). `p95Censored` says that the p95 lies among censored values and is only a lower bound.
 *
 * The measurement itself must be complete; otherwise the script exits with status 1 and lists the errors:
 *   - every practice submission answered;
 *   - every expected tutor (phase3.json) subscribed before the first practice POST was sent and received at least one
 *     statistics message (the server acknowledges no SUBSCRIBE; a lost subscription shows up as a page without messages);
 *   - the practice POSTs were sent at the planned rate (within 5 %; the arrival executor paces iteration starts, the POST
 *     follows 10 s later).
 *
 * Usage: node freshness.mjs <phase3-folder>
 * Writes <phase3-folder>/freshness.json and prints one summary line. p99 only with at least 100 values (D38 rule 4).
 */
import { readFileSync, writeFileSync } from 'node:fs';
import { gunzipSync } from 'node:zlib';

const folder = process.argv[2];
if (!folder) {
    console.error('usage: node freshness.mjs <phase3-folder>');
    process.exit(2);
}
const MIN_P99 = 100;
const RATE_TOLERANCE = 0.05;

const phase = JSON.parse(readFileSync(`${folder}/phase3.json`, 'utf8'));
const answered = [];
const sent = [];
const seen = new Map();
const subscribed = new Map();
const messages = new Map();
const METRICS = new Set(['phase3_practice_answered', 'phase3_practice_sent', 'phase3_seen', 'phase3_subscribed', 'phase3_messages']);
for (const line of gunzipSync(readFileSync(`${folder}/raw.json.gz`)).toString('utf8').split('\n')) {
    if (!line.includes('"phase3_')) {
        continue;
    }
    const { type, metric, data } = JSON.parse(line);
    if (type !== 'Point' || !METRICS.has(metric)) {
        continue;
    }
    const time = Date.parse(data.time);
    const tutor = data.tags?.tutor;
    if (metric === 'phase3_practice_answered') {
        answered.push(time);
    } else if (metric === 'phase3_practice_sent') {
        sent.push(time);
    } else if (metric === 'phase3_subscribed') {
        subscribed.set(tutor, time);
    } else if (metric === 'phase3_messages') {
        messages.set(tutor, (messages.get(tutor) ?? 0) + 1);
    } else {
        if (!seen.has(tutor)) {
            seen.set(tutor, []);
        }
        seen.get(tutor).push({ time, shown: data.value });
    }
}
answered.sort((a, b) => a - b);
sent.sort((a, b) => a - b);

const errors = [];
if (answered.length !== phase.submissions) {
    errors.push(`${answered.length} of ${phase.submissions} practice submissions answered`);
}
const firstSent = sent[0] ?? Infinity;
for (let index = 0; index < phase.tutors; index++) {
    const tutor = String(index);
    if (!seen.has(tutor)) {
        errors.push(`tutor ${tutor}: no page observation`);
    }
    if (!subscribed.has(tutor)) {
        errors.push(`tutor ${tutor}: never subscribed`);
    } else if (subscribed.get(tutor) >= firstSent) {
        errors.push(`tutor ${tutor}: subscribed ${subscribed.get(tutor) - firstSent} ms after the first practice POST`);
    }
    if (!messages.get(tutor)) {
        errors.push(`tutor ${tutor}: no statistics message`);
    }
}
const postSpanMillis = sent.length > 1 ? sent.at(-1) - sent[0] : null;
const achievedRate = postSpanMillis ? ((sent.length - 1) * 1000) / postSpanMillis : null;
if (achievedRate !== null && Math.abs(achievedRate / phase.rate - 1) > RATE_TOLERANCE) {
    errors.push(`practice POSTs sent at ${achievedRate.toFixed(2)}/s, planned ${phase.rate}/s`);
}

/** k6's percentile: linear interpolation between the closest ranks. */
function percentile(sorted, p) {
    const position = (sorted.length - 1) * p;
    const low = Math.floor(position);
    return sorted[low] + (sorted[Math.min(low + 1, sorted.length - 1)] - sorted[low]) * (position - low);
}

const values = [];
let censored = 0;
const drain = {};
for (let index = 0; index < phase.tutors; index++) {
    const observations = (seen.get(String(index)) ?? []).sort((a, b) => a.time - b.time);
    let next = 0;
    for (let n = 1; n <= answered.length; n++) {
        while (next < observations.length && observations[next].shown < n) {
            next++;
        }
        if (next < observations.length) {
            values.push({ millis: observations[next].time - answered[n - 1], censored: false });
        } else {
            values.push({ millis: phase.deadline - answered[n - 1], censored: true });
            censored++;
        }
    }
    const complete = observations.find(({ shown }) => shown >= answered.length);
    drain[index] = complete && answered.length ? complete.time - answered.at(-1) : null;
}
values.sort((a, b) => a.millis - b.millis);
const millis = values.map((value) => value.millis);
// The p95 is a lower bound if a censored value is at or below its interpolation rank.
const rank = Math.ceil((values.length - 1) * 0.95);
const summary = {
    submissions: answered.length,
    expectedSubmissions: phase.submissions,
    tutors: phase.tutors,
    values: values.length,
    censored,
    medianMillis: values.length ? percentile(millis, 0.5) : null,
    p95Millis: values.length ? percentile(millis, 0.95) : null,
    p95Censored: values.slice(0, rank + 1).some((value) => value.censored),
    p99Millis: values.length >= MIN_P99 ? percentile(millis, 0.99) : null,
    minMillis: millis[0] ?? null,
    maxMillis: millis.at(-1) ?? null,
    drainMillis: drain,
    messagesPerTutor: Object.fromEntries([...Array(phase.tutors).keys()].map((index) => [index, messages.get(String(index)) ?? 0])),
    practiceSent: sent.length,
    achievedPostRate: achievedRate,
    postSpanMillis,
    errors,
    complete: errors.length === 0,
};
writeFileSync(`${folder}/freshness.json`, `${JSON.stringify(summary, null, 2)}\n`);
const fmt = (value) => (value === null ? '–' : `${value.toFixed(0)} ms`);
console.log(
    `freshness: ${summary.values} values (${summary.submissions} submissions x ${summary.tutors} tutors, ${censored} censored at the deadline) ` +
        `med=${fmt(summary.medianMillis)} p95=${summary.p95Censored ? '>=' : ''}${fmt(summary.p95Millis)} p99=${fmt(summary.p99Millis)} max=${fmt(summary.maxMillis)}; ` +
        `POSTs ${sent.length} at ${achievedRate?.toFixed(2) ?? '–'}/s`,
);
if (errors.length) {
    console.error(`freshness measurement incomplete:\n  ${errors.join('\n  ')}`);
    process.exit(1);
}
