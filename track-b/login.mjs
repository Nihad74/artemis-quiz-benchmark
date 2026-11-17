#!/usr/bin/env node
/**
 * Logs in the users of a Track B run before its measurement window (D13) and writes their session cookies for the load
 * test. k6 loads the file once into shared memory; logging in inside k6 would copy every session into every VU.
 *
 * Usage: node login.mjs --manifest manifest.json --server URL [--students N] --out sessions.json
 *   --students  the first N students of the manifest (default: all)
 * Writes { instructor, tutors, students }, each a session { login, cookies, xsrf }: the cookies the server set at the
 * login (name -> value) and the XSRF token (null if the server sets none).
 */
import { readFileSync, writeFileSync } from 'node:fs';
import { parseArgs } from 'node:util';
import { Client, forEachLimited } from './lib/client.mjs';

const { values: args } = parseArgs({
    options: { manifest: { type: 'string' }, server: { type: 'string' }, students: { type: 'string' }, out: { type: 'string' }, parallel: { type: 'string', default: '16' } },
});
const manifest = JSON.parse(readFileSync(args.manifest, 'utf8'));
const server = args.server ?? manifest.server;
const students = manifest.students.slice(0, args.students === undefined ? undefined : Number(args.students));
if (args.students !== undefined && students.length !== Number(args.students)) {
    throw new Error(`the manifest has ${manifest.students.length} students, not ${args.students}`);
}

async function session(login) {
    const client = await new Client(server).login(login, manifest.password);
    const xsrf = client.cookies.get('XSRF-TOKEN');
    return { login, cookies: Object.fromEntries(client.cookies), xsrf: xsrf === undefined ? null : decodeURIComponent(xsrf) };
}

async function sessions(logins) {
    const result = new Array(logins.length);
    await forEachLimited(logins, Number(args.parallel), async (login, index) => {
        result[index] = await session(login);
    });
    return result;
}

const started = Date.now();
const output = { instructor: await session(manifest.instructor), tutors: await sessions(manifest.tutors), students: await sessions(students) };
writeFileSync(args.out, JSON.stringify(output) + '\n');
console.log(`logged in 1 instructor, ${output.tutors.length} tutors, ${output.students.length} students in ${((Date.now() - started) / 1000).toFixed(1)} s`);
