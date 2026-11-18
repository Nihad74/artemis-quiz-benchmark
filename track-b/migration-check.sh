#!/usr/bin/env bash
# Forward-migration check for the Track B same-data rule (decisions D2, D19).
#
# Usage: migration-check.sh <output-folder> <students> <first-image> [<step-image> ...] <last-image>
# EVALUATED_DURATION (default 60) is the duration of the seeded evaluated quiz in seconds: every student must load, start,
# save, and submit within it, so thousands of students need more (2000 students: 300). SEED_COMMIT (default 43bafcee17c)
# is the commit the first image must be built from (label thesis.commit): seed.mjs only checks the version 9.9, which
# f3463b75408 reports as well.
#
# 1. Start the first image on an empty database; Liquibase creates the schema.
# 2. Seed it (seed.mjs): users, a course, an evaluated quiz with answers, results and statistics, and a benchmark quiz.
# 3. Record what instructors and students see (semantics.mjs) -> old.json.
# 4. Dump the database (pg_dump) and the file storage, as the Track B seed does (D18), and drop everything.
# 5. Restore both into fresh volumes. Start every step image until it is healthy, then the last image; each start runs
#    Liquibase forward. Step images follow the official migration path: Artemis 10.x refuses a database that has not
#    run release 9.9.3 (DatabaseMigration).
# 6. Record the semantics again -> new.json. The check passes if both are equal, except for where the statistics come
#    from (stored on the baseline, computed on demand from 24a062759c2 on).
#
# The output folder keeps the dump, the files, both semantics, the server logs, and the time each migrating start took.
# Exit status 1 if the semantics differ or a step fails.
set -euo pipefail

out="$(mkdir -p "$1" && cd "$1" && pwd)"
students="$2"
shift 2
images=("$@")
if ((${#images[@]} < 2)); then
    echo "need at least two images" >&2
    exit 2
fi
here="$(cd "$(dirname "$0")" && pwd)"
project="trackb-migration"
export ARTEMIS_PORT="${ARTEMIS_PORT:-18080}"
export JAVA_HEAP="${JAVA_HEAP:--Xms2g -Xmx2g}"

source "$here/lib/stack.sh"

first="${images[0]}"
seed_commit="${SEED_COMMIT:-43bafcee17c}"
label="$(docker image inspect "$first" --format '{{index .Config.Labels "thesis.commit"}}')"
if [[ "$label" != "$seed_commit" ]]; then
    echo "the seed runs on the relational baseline $seed_commit, but $first is built from ${label:-an unknown commit}" >&2
    exit 2
fi
compose "$first" down -v --remove-orphans >/dev/null 2>&1 || true
printf '%s\n' "${images[@]}" >"$out/images.txt"
: >"$out/migrating-start-seconds.txt"

log "start $first on an empty database"
compose "$first" up -d --wait --wait-timeout 900 >/dev/null 2>&1
log "seed $students students"
node "$here/seed.mjs" --server "http://localhost:$ARTEMIS_PORT" --students "$students" \
    --evaluated-duration "${EVALUATED_DURATION:-60}" --out "$out/manifest.json"
node "$here/semantics.mjs" --manifest "$out/manifest.json" --out "$out/old.json"

log "dump the database and the file storage"
compose "$first" stop artemis >/dev/null 2>&1
compose "$first" exec -T postgres pg_dump -U Artemis -d Artemis -Fc >"$out/seed.dump"
docker run --rm -v "${project}_artemis-data:/data:ro" -v "$out:/backup" alpine:3.24.3 tar czf /backup/artemis-data.tgz -C /data .

log "restore into fresh volumes"
restore_seed "$first" "$out"

for image in "${images[@]:1}"; do
    name="${image#*:}"
    log "start $image on the restored database (forward migration)"
    start=$(date +%s)
    if ! compose "$image" up -d --wait --wait-timeout 1800 artemis >/dev/null 2>&1; then
        compose "$image" logs artemis >"$out/server-$name.log" 2>&1
        log "FAIL: $image did not become healthy; log: $out/server-$name.log"
        exit 1
    fi
    echo "$image $(($(date +%s) - start))" >>"$out/migrating-start-seconds.txt"
    compose "$image" logs artemis >"$out/server-$name.log" 2>&1
    log "$image healthy after $(($(date +%s) - start)) s"
    compose "$image" stop artemis >/dev/null 2>&1
done

last="${images[-1]}"
compose "$last" up -d --wait --wait-timeout 900 artemis >/dev/null 2>&1
node "$here/semantics.mjs" --manifest "$out/manifest.json" --out "$out/new.json"
compose "$last" down -v >/dev/null 2>&1

if diff <(jq -S 'del(.statisticsSource)' "$out/old.json") <(jq -S 'del(.statisticsSource)' "$out/new.json") >"$out/semantics.diff"; then
    log "PASS: same questions, answers, scores and statistics after the migration ($(jq -r .statisticsSource "$out/old.json") -> $(jq -r .statisticsSource "$out/new.json"))"
else
    log "FAIL: the semantics differ, see $out/semantics.diff"
    exit 1
fi
