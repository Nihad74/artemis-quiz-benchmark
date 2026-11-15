/**
 * Minimal Artemis REST client for the Track B scripts: one cookie jar per user (the JWT cookie and the XSRF token), JSON
 * and multipart bodies. Node 24 (global fetch, FormData, Blob); no dependencies.
 */

export class HttpError extends Error {
    constructor(method, path, status, body) {
        super(`${method} ${path}: HTTP ${status} ${typeof body === 'string' ? body.slice(0, 300) : JSON.stringify(body)?.slice(0, 300)}`);
        this.status = status;
        this.body = body;
    }
}

export class Client {
    constructor(baseUrl) {
        this.baseUrl = baseUrl.replace(/\/$/, '');
        this.cookies = new Map();
    }

    async request(method, path, { json, form, expect } = {}) {
        const headers = { Accept: 'application/json' };
        if (this.cookies.size) {
            headers.Cookie = [...this.cookies].map(([name, value]) => `${name}=${value}`).join('; ');
        }
        if (this.cookies.has('XSRF-TOKEN')) {
            headers['X-XSRF-TOKEN'] = decodeURIComponent(this.cookies.get('XSRF-TOKEN'));
        }
        let body;
        if (json !== undefined) {
            headers['Content-Type'] = 'application/json';
            body = JSON.stringify(json);
        } else if (form) {
            body = form;
        }
        const response = await fetch(this.baseUrl + path, { method, headers, body, redirect: 'manual' });
        for (const cookie of response.headers.getSetCookie()) {
            const [pair] = cookie.split(';');
            const index = pair.indexOf('=');
            this.cookies.set(pair.slice(0, index), pair.slice(index + 1));
        }
        const text = await response.text();
        let data = text;
        if ((response.headers.get('content-type') ?? '').includes('json') && text) {
            data = JSON.parse(text);
        }
        const ok = expect ? expect.includes(response.status) : response.ok;
        if (!ok) {
            throw new HttpError(method, path, response.status, data);
        }
        return { status: response.status, data, headers: response.headers };
    }

    get(path, options) {
        return this.request('GET', path, options);
    }

    post(path, json, options = {}) {
        return this.request('POST', path, { ...options, json });
    }

    put(path, json, options = {}) {
        return this.request('PUT', path, { ...options, json });
    }

    async login(username, password) {
        await this.request('GET', '/api/core/public/account', { expect: [200, 204, 401] });
        await this.post('/api/core/public/authenticate', { username, password, rememberMe: true });
        return this;
    }
}

/**
 * A multipart body: JSON parts and file parts. `files` is a list of { name, filename, type, bytes }.
 */
export function multipart(jsonParts, files = []) {
    const form = new FormData();
    for (const [name, value] of Object.entries(jsonParts)) {
        form.append(name, new Blob([JSON.stringify(value)], { type: 'application/json' }));
    }
    for (const file of files) {
        form.append(file.name, new Blob([file.bytes], { type: file.type }), file.filename);
    }
    return form;
}

/**
 * Runs `task` for every item with at most `limit` tasks at a time, in order of the items.
 */
export async function forEachLimited(items, limit, task) {
    let next = 0;
    const workers = Array.from({ length: Math.min(limit, items.length) }, async () => {
        while (next < items.length) {
            const index = next++;
            await task(items[index], index);
        }
    });
    await Promise.all(workers);
}
