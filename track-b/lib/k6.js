/**
 * Helpers shared by the Track B k6 scripts (phase1.js, phase2.js). k6 runtime only.
 */
import http from 'k6/http';

/** Request parameters for a logged-in session: JSON headers, the XSRF token, the tags, and how k6 keeps the body. */
export function params(session, tags, responseType = 'none') {
    const headers = { 'Content-Type': 'application/json', Accept: 'application/json' };
    if (session.xsrf !== null) {
        headers['X-XSRF-TOKEN'] = session.xsrf;
    }
    return { headers, tags, responseType };
}

/** Puts the session cookies into this VU's jar, as a browser holds them; cookies the server sets later replace them. */
export function useSession(server, session) {
    const jar = http.cookieJar();
    for (const [name, value] of Object.entries(session.cookies)) {
        jar.set(server, name, value);
    }
}

/** mulberry32: a small seeded PRNG; returns a function that yields numbers in [0, 1). */
export function prng(seed) {
    let state = seed >>> 0;
    return () => {
        state = (state + 0x6d2b79f5) >>> 0;
        let t = state;
        t = Math.imul(t ^ (t >>> 15), t | 1);
        t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
        return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
}

/** The metrics whose thresholds failed; a run with any of them is invalid (D38). */
export function failedThresholds(data) {
    return Object.entries(data.metrics)
        .filter(([, metric]) => metric.thresholds && Object.values(metric.thresholds).some((threshold) => !threshold.ok))
        .map(([name]) => name);
}

/** One summary line of a trend metric, for example `save: n=300 med=33.3 ms p95=53.1 ms p99=56.1 ms`. */
export function trendLine(data, metric, label) {
    const values = data.metrics[metric]?.values ?? {};
    return `${label}: n=${values.count ?? 0} med=${values.med?.toFixed(1)} ms p95=${values['p(95)']?.toFixed(1)} ms p99=${values['p(99)']?.toFixed(1)} ms max=${values.max?.toFixed(1)} ms`;
}
