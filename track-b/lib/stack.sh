# shellcheck shell=bash disable=SC2154
# Shared shell functions of the Track B scripts. Source it after setting `here` (the track_b folder) and `project` (the
# compose project name).

# compose <image> <docker compose arguments...>: docker compose for the server image <image>.
compose() {
    local image="$1"
    shift
    ARTEMIS_IMAGE="$image" docker compose -p "$project" -f "$here/compose.yml" "$@"
}

log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*"; }

# restore_seed <image> <seed-folder>: fresh volumes with the database dump (seed.dump) and the file storage
# (artemis-data.tgz) of the seed folder; PostgreSQL runs afterwards, Artemis does not.
restore_seed() {
    local image="$1" seed="$2"
    compose "$image" down -v --remove-orphans >/dev/null 2>&1 || true
    compose "$image" create >/dev/null 2>&1
    compose "$image" up -d --wait postgres >/dev/null 2>&1
    compose "$image" exec -T postgres pg_restore -U Artemis -d Artemis --no-owner --exit-on-error <"$seed/seed.dump"
    docker run --rm -v "${project}_artemis-data:/data" -v "$seed:/backup:ro" alpine:3.24.3 \
        sh -c 'tar xzf /backup/artemis-data.tgz -C /data && chown -R 1337:1337 /data'
}
