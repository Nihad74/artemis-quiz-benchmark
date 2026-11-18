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
 * A value that a page never showed by the deadline of phase3.js is censored: it is counted at the deadline, a lower
 * bound, so it raises the percentiles instead of being dropped (D42: a complete run above the H3 bound is evidence
 * against H3). `p95Censored` says that the p95 lies among censored values and is only a lower bound.
 *
 * The measurement itself must be complete; otherwise the script exits with status 1 and lists the errors:
 *   - every practice submission answered, even if the response arrived after the page deadline;
 *   - every expected tutor (phase3.json) opened its page and subscribed before the first practice POST, and received
 *     at least one statistics message by the deadline when all POSTs succeeded;
 *   - every expected practice POST was sent, and multiple POSTs span enough time to measure the achieved rate
 *     (within 5 % of the planned rate).
 * `captureErrors` lists errors independent of a shortfall in server responses.
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

const captureErrors = [];
const responseErrors = [];
let phase = {};
try {
    phase = JSON.parse(readFileSync(`${folder}/phase3.json`, 'utf8')) ?? {};
} catch (error) {
    captureErrors.push(`cannot read phase3.json: ${error.message}`);
}
const validCount = (value) => Number.isSafeInteger(value) && value > 0;
const expectedSubmissions = validCount(phase.submissions) ? phase.submissions : null;
const tutors = validCount(phase.tutors) ? phase.tutors : null;
const deadline = validCount(phase.deadline) ? phase.deadline : null;
const plannedRate = Number.isFinite(phase.rate) && phase.rate > 0 ? phase.rate : null;
for (const [field, value] of Object.entries({ submissions: expectedSubmissions, tutors, deadline, rate: plannedRate })) {
    if (value === null) {
        captureErrors.push(`phase3.json: invalid ${field}`);
    }
}
const answered = [];
const sent = [];
const seen = new Map();
const subscribed = new Map();
const messages = new Map();
const METRICS = new Set(['phase3_practice_answered', 'phase3_practice_sent', 'phase3_seen', 'phase3_subscribed', 'phase3_messages']);
let raw = '';
try {
    raw = gunzipSync(readFileSync(`${folder}/raw.json.gz`)).toString('utf8');
} catch (error) {
    captureErrors.push(`cannot read raw.json.gz: ${error.message}`);
}
for (const line of raw.split('\n')) {
    if (!line.includes('"phase3_')) {
        continue;
    }
    let point;
    try {
        point = JSON.parse(line);
    } catch (error) {
        captureErrors.push(`invalid Phase 3 metric record: ${error.message}`);
        continue;
    }
    const { type, metric, data } = point ?? {};
    if (type !== 'Point' || !METRICS.has(metric)) {
        continue;
    }
    const time = typeof data?.time === 'string' ? Date.parse(data.time) : NaN;
    if (!Number.isFinite(time)) {
        captureErrors.push(`${metric}: invalid timestamp`);
        continue;
    }
    // k6 writes sub-millisecond timestamps, which Date.parse truncates.
    const afterDeadline = deadline !== null &&
        (time > deadline || (time === deadline && /\.\d{3}\d*[1-9]\d*(?:Z|[+-]\d{2}:\d{2})$/.test(data.time)));
    if ((metric === 'phase3_seen' || metric === 'phase3_messages' || metric === 'phase3_subscribed') &&
        (deadline === null || afterDeadline)) {
        continue;
    }
    if (metric === 'phase3_seen' ? !Number.isFinite(data.value) : data.value !== 1) {
        captureErrors.push(`${metric}: invalid value`);
        continue;
    }
    const tutor = data.tags?.tutor;
    if (metric !== 'phase3_practice_answered' && metric !== 'phase3_practice_sent' &&
        (typeof tutor !== 'string' || !/^(0|[1-9]\d*)$/.test(tutor) || Number(tutor) >= tutors)) {
        captureErrors.push(`${metric}: unexpected tutor ${tutor}`);
        continue;
    }
    if (metric === 'phase3_practice_answered') {
        answered.push(time);
    } else if (metric === 'phase3_practice_sent') {
        if (afterDeadline) {
            captureErrors.push(`${metric}: POST sent after the deadline`);
        }
        sent.push(time);
    } else if (metric === 'phase3_subscribed') {
        subscribed.set(tutor, Math.min(time, subscribed.get(tutor) ?? Infinity));
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

const answerShortfall = expectedSubmissions !== null && answered.length < expectedSubmissions;
if (expectedSubmissions !== null && answered.length !== expectedSubmissions) {
    (answerShortfall ? responseErrors : captureErrors).push(`${answered.length} of ${expectedSubmissions} practice submissions answered`);
}
if (expectedSubmissions !== null && sent.length !== expectedSubmissions) {
    captureErrors.push(`${sent.length} of ${expectedSubmissions} practice POSTs sent`);
}
const firstSent = sent[0] ?? Infinity;
for (let index = 0; index < tutors; index++) {
    const tutor = String(index);
    if (!seen.get(tutor)?.some(({ time, shown }) => shown === 0 && time < firstSent)) {
        captureErrors.push(`tutor ${tutor}: no initial page observation before the first practice POST`);
    }
    if (!subscribed.has(tutor)) {
        captureErrors.push(`tutor ${tutor}: never subscribed`);
    } else if (subscribed.get(tutor) >= firstSent) {
        captureErrors.push(`tutor ${tutor}: subscribed ${subscribed.get(tutor) - firstSent} ms after the first practice POST`);
    }
    if (answered.length > 0 && !messages.get(tutor)) {
        (answerShortfall ? responseErrors : captureErrors).push(`tutor ${tutor}: no statistics message by the deadline`);
    }
}
const postSpanMillis = sent.length > 1 ? sent.at(-1) - sent[0] : null;
const achievedRate = postSpanMillis > 0 ? ((sent.length - 1) * 1000) / postSpanMillis : null;
if (expectedSubmissions > 1 && !Number.isFinite(achievedRate)) {
    captureErrors.push('practice POSTs have no positive send span');
} else if (plannedRate !== null && achievedRate !== null && Math.abs(achievedRate - plannedRate) > RATE_TOLERANCE * plannedRate) {
    captureErrors.push(`practice POSTs sent at ${achievedRate.toFixed(2)}/s, planned ${plannedRate}/s`);
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
for (let index = 0; deadline !== null && index < tutors; index++) {
    const observations = (seen.get(String(index)) ?? []).sort((a, b) => a.time - b.time);
    let next = 0;
    for (let n = 1; n <= answered.length; n++) {
        while (next < observations.length && observations[next].shown < n) {
            next++;
        }
        if (next < observations.length) {
            values.push({ millis: observations[next].time - answered[n - 1], censored: false });
        } else {
            values.push({ millis: deadline - answered[n - 1], censored: true });
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
const errors = [...captureErrors, ...responseErrors];
const summary = {
    submissions: answered.length,
    expectedSubmissions,
    tutors,
    values: values.length,
    censored,
    medianMillis: values.length ? percentile(millis, 0.5) : null,
    p95Millis: values.length ? percentile(millis, 0.95) : null,
    p95Censored: values.slice(0, rank + 1).some((value) => value.censored),
    p99Millis: values.length >= MIN_P99 ? percentile(millis, 0.99) : null,
    minMillis: millis[0] ?? null,
    maxMillis: millis.at(-1) ?? null,
    drainMillis: drain,
    messagesPerTutor: Object.fromEntries(Array.from({ length: tutors }, (_, index) => [index, messages.get(String(index)) ?? 0])),
    practiceSent: sent.length,
    achievedPostRate: achievedRate,
    postSpanMillis,
    captureErrors,
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
