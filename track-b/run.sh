#!/usr/bin/env bash
# Track B run loop (D6, D13, D14, D17, D36, D38): REPETITIONS runs of side A and side B, alternating (A, B, A, B, ...),
# each from a fresh restore of the same seed (D2 same-data rule).
#
# Usage: run.sh <seed-folder> <out-folder> <students> <A-images> <B-images>
#   seed-folder  seed.dump, artemis-data.tgz, and manifest.json of the baseline seed (migration-check.sh output, D18)
#   students     the first N students of the manifest take the benchmark quiz
#   A-, B-images comma-separated image chains; every image restores onto the database of the one before (Liquibase
#                migrates forward), the last one is measured. End-to-end comparison:
#                  artemis-thesis:43bafcee17c  artemis-thesis:9.9.3,artemis-thesis:8325896e0b4
# Environment: REPETITIONS (5), WARMUP_STUDENTS (100), SEED (1), SETTLE_SECONDS (15), SAMPLE_SECONDS (5), ARTEMIS_PORT
# (18080), and the limits of compose.yml and lib/k6-limits.sh.
#
# One run, in <out-folder>/<repetition>-<side>/:
#  1. Restore the seed into fresh volumes. Start every image of the chain until it is healthy and stop it, then start the
#     measured image again: both sides measure a fresh server on an already migrated database (starts.txt).
#  2. Log in every user (login.mjs, D13). Warm-up: Phase 1 with WARMUP_STUDENTS students on the warm-up quiz (D38 rule 5,
#     warm-up/); wait for its evaluation, then SETTLE_SECONDS.
#  3. Phase 1 on the benchmark quiz with all students (phase1/: summary.json, raw.json.gz, k6.log), while sampling every
#     SAMPLE_SECONDS: docker stats of both containers, PostgreSQL lock waits and active connections (samples.jsonl), and
#     the Prometheus metrics of Artemis (prometheus.txt.gz).
#  4. Wait for the evaluation by the scheduled task (D17 timer line: evaluation.txt), then SETTLE_SECONDS, because idle
#     PostgreSQL backends publish their row counts up to 10 s late. pg_stat_user_tables before Phase 1 and after the
#     evaluation (pg-stat-*.csv: Phase 1 and the evaluation together) and /proc/stat of the Docker VM (CPU steal).
#  5. D19 semantics of the benchmark quiz (semantics.json), compared with the first run (D38 rule 7).
#  6. Server log, tear down, delete the login cookies.
# run.json of each run records its validity (D38): both k6 runs passed their thresholds (no failed or late request, no
# dropped iteration), the evaluation was logged, and the semantics equal those of the first run. runs.tsv lists all runs.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
project="trackb-run"
source "$here/lib/stack.sh"
source "$here/lib/k6-limits.sh"

seed="$(cd "$1" && pwd)"
out="$(mkdir -p "$2" && cd "$2" && pwd)"
students="$3"
IFS=, read -ra side_a <<<"$4"
IFS=, read -ra side_b <<<"$5"
repetitions="${REPETITIONS:-5}"
warmup_students="${WARMUP_STUDENTS:-100}"
schedule_seed="${SEED:-1}"
settle="${SETTLE_SECONDS:-15}"
sample_every="${SAMPLE_SECONDS:-5}"
export ARTEMIS_PORT="${ARTEMIS_PORT:-18080}"
server="http://localhost:$ARTEMIS_PORT"
manifest="$seed/manifest.json"

if ((students > $(jq '.students | length' "$manifest"))); then
    echo "the seed has $(jq '.students | length' "$manifest") students, not $students" >&2
    exit 2
fi
((warmup_students <= students)) || warmup_students="$students"
warmup_quiz="$(jq .warmUpQuiz "$manifest")"
benchmark_quiz="$(jq .benchmarkQuiz "$manifest")"

"$here/check-host.sh" "$out/host.json"
compose "${side_a[-1]}" config --format json >"$out/compose.json"
jq -n --arg seed "$seed" --argjson students "$students" --argjson repetitions "$repetitions" \
    --argjson warmUpStudents "$warmup_students" --argjson scheduleSeed "$schedule_seed" --argjson settleSeconds "$settle" \
    --argjson sampleSeconds "$sample_every" --arg k6Cpuset "$K6_CPUSET" --arg k6Memory "$K6_MEMORY" \
    --arg toolRevision "$(git -C "$here" rev-parse HEAD)$(git -C "$here" diff --quiet HEAD -- . || echo '-dirty')" \
    --arg startedAt "$(date -u +%FT%TZ)" \
    '$ARGS.named + {sideA: $ARGS.positional[0] | split(","), sideB: $ARGS.positional[1] | split(",")}' \
    --args "$4" "$5" >"$out/parameters.json"

sampler_pid=""
cleanup() {
    [[ -z "$sampler_pid" ]] || kill "$sampler_pid" 2>/dev/null || true
    compose "${side_a[-1]}" down -v --remove-orphans >/dev/null 2>&1 || true
    find "$out" -name sessions.json -delete
}
trap cleanup EXIT

psql_at() {
    compose "$1" exec -T postgres psql -U Artemis -d Artemis -At -c "$2"
}

pg_stat() {
    psql_at "$1" "copy (select relname, n_tup_ins, n_tup_upd, n_tup_del from pg_stat_user_tables order by relname) to stdout with csv header"
}

# wait_for_evaluation <image> <quiz> <file>: the D17 timer line of the quiz, at most 300 s.
wait_for_evaluation() {
    local deadline=$((SECONDS + 300))
    while ((SECONDS < deadline)); do
        if compose "$1" logs artemis 2>/dev/null | grep -m1 -o "calculateAllResults quiz=$2 .*" >"$3"; then
            return 0
        fi
        sleep 2
    done
    return 1
}

# sample <image> <run-folder>: every SAMPLE_SECONDS (measured from the start of each sample) until <run-folder>/.stop
# exists. A sample takes about 2.5 s (docker stats waits for a second reading).
sample() {
    local image="$1" dir="$2" containers
    # A failed sample must not end the sampling.
    set +e
    containers="$(compose "$image" ps -q artemis postgres | tr '\n' ' ')"
    while [[ ! -e "$dir/.stop" ]]; do
        local time="$EPOCHREALTIME" stats activity
        # shellcheck disable=SC2086
        stats="$(docker stats --no-stream --format '{{json .}}' $containers | jq -sc .)"
        activity="$(psql_at "$image" "select count(*) filter (where wait_event_type = 'Lock'), count(*) filter (where state = 'active') from pg_stat_activity where datname = 'Artemis' and pid <> pg_backend_pid()")"
        jq -nc --argjson time "$time" --argjson containers "$stats" --argjson lockWaits "${activity%|*}" --argjson active "${activity#*|}" \
            '{time: $time, containers: $containers, lockWaits: $lockWaits, activeConnections: $active}' >>"$dir/samples.jsonl"
        {
            echo "# scrape $time"
            compose "$image" exec -T artemis wget -qO- http://127.0.0.1:8080/management/prometheus
        } >>"$dir/prometheus.txt"
        sleep "$(awk -v start="$time" -v now="$EPOCHREALTIME" -v every="$sample_every" 'BEGIN { left = every - (now - start); print (left > 0 ? left : 0) }')"
    done
}

# measure <repetition> <side> <images...>
measure() {
    local repetition="$1" side="$2"
    shift 2
    local images=("$@") dir="$out/$repetition-$side"
    local measured="${images[-1]}" image start warmup_exit=0 phase1_exit=0 evaluated=true semantics_ok=true
    mkdir -p "$dir/warm-up" "$dir/phase1"

    log "run $repetition-$side: restore, start ${images[*]}"
    restore_seed "${images[0]}" "$seed"
    : >"$dir/starts.txt"
    for image in "${images[@]}"; do
        start=$SECONDS
        compose "$image" up -d --wait --wait-timeout 1800 artemis >/dev/null 2>&1
        echo "migrate $image $((SECONDS - start))" >>"$dir/starts.txt"
        compose "$image" stop artemis >/dev/null 2>&1
    done
    start=$SECONDS
    compose "$measured" up -d --wait --wait-timeout 1800 artemis >/dev/null 2>&1
    echo "measure $measured $((SECONDS - start))" >>"$dir/starts.txt"
    for image in "${images[@]}"; do
        docker image inspect "$image" --format '{{json .}}' | jq -c --arg image "$image" \
            '{image: $image, id: .Id, commit: .Config.Labels["thesis.commit"], head: .Config.Labels["thesis.head"]}'
    done | jq -s . >"$dir/images.json"
    curl -sf "$server/management/info" | jq '{version: .build.version, commit: .git.commit.id.full}' >"$dir/info.json"

    cp "$manifest" "$dir/warm-up/" && cp "$manifest" "$dir/phase1/"
    node "$here/login.mjs" --manifest "$manifest" --server "$server" --students "$students" --out "$dir/phase1/sessions.json"
    cp "$dir/phase1/sessions.json" "$dir/warm-up/"

    log "run $repetition-$side: warm-up, $warmup_students students"
    "$here/k6.sh" "$project" phase1.js "$dir/warm-up" -e QUIZ=warmUp -e STUDENTS="$warmup_students" -e SEED="$schedule_seed" \
        >"$dir/warm-up/k6.log" 2>&1 || warmup_exit=$?
    wait_for_evaluation "$measured" "$warmup_quiz" "$dir/warm-up/evaluation.txt" || evaluated=false
    sleep "$settle"

    log "run $repetition-$side: Phase 1, $students students"
    pg_stat "$measured" >"$dir/pg-stat-before.csv"
    compose "$measured" exec -T postgres head -1 /proc/stat >"$dir/proc-stat-before.txt"
    sample "$measured" "$dir" &
    sampler_pid=$!
    "$here/k6.sh" "$project" phase1.js "$dir/phase1" -e QUIZ=benchmark -e SEED="$schedule_seed" \
        >"$dir/phase1/k6.log" 2>&1 || phase1_exit=$?
    wait_for_evaluation "$measured" "$benchmark_quiz" "$dir/evaluation.txt" || evaluated=false
    sleep "$settle"
    touch "$dir/.stop"
    wait "$sampler_pid" || true
    sampler_pid=""
    rm "$dir/.stop"
    [[ ! -e "$dir/prometheus.txt" ]] || gzip "$dir/prometheus.txt"
    pg_stat "$measured" >"$dir/pg-stat-after.csv"
    compose "$measured" exec -T postgres head -1 /proc/stat >"$dir/proc-stat-after.txt"

    log "run $repetition-$side: semantics"
    node "$here/semantics.mjs" --manifest "$manifest" --server "$server" --quiz benchmark --students "$students" \
        --out "$dir/semantics.json" || semantics_ok=false
    compose "$measured" logs artemis >"$dir/server.log" 2>&1
    compose "$measured" down -v >/dev/null 2>&1
    rm -f "$dir/warm-up/sessions.json" "$dir/phase1/sessions.json"

    # D38 rule 7: same answers, scores, and statistics as the first run; where the statistics come from and the dates of
    # the started quizzes may differ.
    local reference="$out/1-A/semantics.normalized.json"
    if [[ "$semantics_ok" == true ]]; then
        jq -S 'del(.statisticsSource, .benchmarkQuiz, .warmUpQuiz)' "$dir/semantics.json" >"$dir/semantics.normalized.json"
        if [[ -e "$reference" ]] && ! cmp -s "$reference" "$dir/semantics.normalized.json"; then
            semantics_ok=false
        fi
    fi
    local evaluation_millis=null
    [[ "$evaluated" == true ]] && evaluation_millis="$(sed -E 's/.*durationMillis=([0-9]+).*/\1/' "$dir/evaluation.txt")"
    jq -n --argjson repetition "$repetition" --arg side "$side" --arg measured "$measured" \
        --argjson warmUpExit "$warmup_exit" --argjson phase1Exit "$phase1_exit" --argjson evaluated "$evaluated" \
        --argjson evaluationMillis "$evaluation_millis" --argjson semanticsEqual "$semantics_ok" \
        '$ARGS.named + {valid: ($warmUpExit == 0 and $phase1Exit == 0 and $evaluated and $semanticsEqual)}' >"$dir/run.json"
    log "run $repetition-$side: $(jq -c '{valid, warmUpExit, phase1Exit, evaluationMillis, semanticsEqual}' "$dir/run.json")"
}

for repetition in $(seq "$repetitions"); do
    measure "$repetition" A "${side_a[@]}"
    measure "$repetition" B "${side_b[@]}"
done

{
    printf 'run\tmeasured\tvalid\tstart-participation p95 ms\tsave p95 ms\tsubmit p95 ms\tevaluation ms\n'
    for run in $(seq "$repetitions"); do
        for side in A B; do
            dir="$out/$run-$side"
            summary="$dir/phase1/summary.json"
            [[ -e "$summary" ]] || summary=/dev/null
            jq -rn --arg run "$run-$side" --slurpfile r "$dir/run.json" --slurpfile s "$summary" '
                def p95($type): ($s[0].metrics["http_req_duration{type:\($type)}"].values["p(95)"] // null)
                    | if . == null then "-" else (. * 10 | round / 10 | tostring) end;
                [$run, $r[0].measured, ($r[0].valid | tostring), p95("start-participation"), p95("save"), p95("submit"),
                    ($r[0].evaluationMillis // "-" | tostring)] | @tsv'
        done
    done
} >"$out/runs.tsv"
column -t -s $'\t' "$out/runs.tsv"
