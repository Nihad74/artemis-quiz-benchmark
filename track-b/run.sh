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
# Environment: REPETITIONS (5), WARMUP_STUDENTS (100), ROUNDS (20, Phase 2 rounds per tutor), WARMUP_ROUNDS (5), SEED (1),
# SETTLE_SECONDS (15), SAMPLE_SECONDS (5), ARTEMIS_PORT (18080), and the limits of compose.yml and lib/k6-limits.sh.
#
# One run, in <out-folder>/<repetition>-<side>/:
#  1. Restore the seed into fresh volumes. Start every image of the chain until it is healthy and stop it, then start the
#     measured image again: both sides measure a fresh server on an already migrated database (starts.txt).
#  2. Log in every user (login.mjs, D13). Warm-up on the warm-up quiz (D38 rule 5, warm-up/): Phase 1 with
#     WARMUP_STUDENTS students, wait for its evaluation, Phase 2 with WARMUP_ROUNDS rounds, then SETTLE_SECONDS.
#  3. Phase 1 on the benchmark quiz with all students (phase1/: summary.json, raw.json.gz, k6.log, questions.json), while
#     sampling every SAMPLE_SECONDS until the end of step 4: docker stats of every container of the project, PostgreSQL
#     lock waits and active connections (samples.jsonl), and the Prometheus metrics of Artemis (prometheus.txt.gz).
#  4. Wait for the evaluation by the scheduled task (D17 timer line with its timestamp: evaluation.txt), then at once
#     Phase 2 (phase2/: the tutors load the statistics pages, D10, D16 H3), then SETTLE_SECONDS, because idle PostgreSQL
#     backends publish their row counts up to 10 s late. pg_stat_user_tables before Phase 1 and after Phase 2
#     (pg-stat-*.csv: Phase 1, the evaluation, and Phase 2 together) and /proc/stat of the Docker VM (CPU steal).
#  5. D19 semantics of the benchmark quiz (semantics.json), compared with the first run (D38 rule 7).
#  6. Server log, tear down, delete the login cookies.
# run.json of each run records its validity (D38): all four k6 runs passed their thresholds (no failed or late request,
# no dropped iteration, every statistics page loaded and complete), both evaluations were logged, and the semantics equal
# those of the first run. It also records the statistics mode Phase 2 found and how long after the end of the evaluation
# Phase 2 started. runs.tsv lists all runs.
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
rounds="${ROUNDS:-20}"
warmup_rounds="${WARMUP_ROUNDS:-5}"
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
    --argjson rounds "$rounds" --argjson warmUpRounds "$warmup_rounds" \
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

# wait_for_evaluation <image> <quiz> <file>: the D17 timer line of the quiz with its log timestamp, at most 300 s.
wait_for_evaluation() {
    local deadline=$((SECONDS + 300))
    while ((SECONDS < deadline)); do
        if compose "$1" logs artemis 2>/dev/null | grep -m1 "calculateAllResults quiz=$2 " >"$3"; then
            return 0
        fi
        sleep 2
    done
    return 1
}

# phase_folders <folder> <manifest> <sessions>: phase1/ and phase2/ of a quiz with the inputs of the k6 scripts.
phase_folders() {
    mkdir -p "$1/phase1" "$1/phase2"
    cp "$2" "$3" "$1/phase1/" && cp "$2" "$3" "$1/phase2/"
}

# sample <image> <run-folder>: every SAMPLE_SECONDS (measured from the start of each sample) until <run-folder>/.stop
# exists. A sample takes about 2.5 s (docker stats waits for a second reading). The containers are looked up at every
# sample, so that the k6 container (k6.sh names it <project>-k6) is included while it runs.
sample() {
    local image="$1" dir="$2"
    # A failed sample must not end the sampling.
    set +e
    while [[ ! -e "$dir/.stop" ]]; do
        local time="$EPOCHREALTIME" containers stats activity
        containers="$(docker ps -q --filter "name=^${project}-" | tr '\n' ' ')"
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
    local measured="${images[-1]}" image start evaluated=true semantics_ok=true
    local warmup_phase1_exit=0 warmup_phase2_exit=0 phase1_exit=0 phase2_exit=0
    mkdir -p "$dir"

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

    node "$here/login.mjs" --manifest "$manifest" --server "$server" --students "$students" --out "$dir/sessions.json"
    phase_folders "$dir/warm-up" "$manifest" "$dir/sessions.json"
    phase_folders "$dir" "$manifest" "$dir/sessions.json"
    rm "$dir/sessions.json"

    log "run $repetition-$side: warm-up, $warmup_students students, $warmup_rounds statistics rounds"
    "$here/k6.sh" "$project" phase1.js "$dir/warm-up/phase1" -e QUIZ=warmUp -e STUDENTS="$warmup_students" -e SEED="$schedule_seed" \
        >"$dir/warm-up/phase1/k6.log" 2>&1 || warmup_phase1_exit=$?
    wait_for_evaluation "$measured" "$warmup_quiz" "$dir/warm-up/evaluation.txt" || evaluated=false
    cp "$dir/warm-up/phase1/questions.json" "$dir/warm-up/phase2/" 2>/dev/null || true
    "$here/k6.sh" "$project" phase2.js "$dir/warm-up/phase2" -e QUIZ=warmUp -e STUDENTS="$warmup_students" \
        -e ROUNDS="$warmup_rounds" -e SEED="$schedule_seed" >"$dir/warm-up/phase2/k6.log" 2>&1 || warmup_phase2_exit=$?
    sleep "$settle"

    log "run $repetition-$side: Phase 1, $students students"
    pg_stat "$measured" >"$dir/pg-stat-before.csv"
    compose "$measured" exec -T postgres head -1 /proc/stat >"$dir/proc-stat-before.txt"
    sample "$measured" "$dir" &
    sampler_pid=$!
    "$here/k6.sh" "$project" phase1.js "$dir/phase1" -e QUIZ=benchmark -e SEED="$schedule_seed" \
        >"$dir/phase1/k6.log" 2>&1 || phase1_exit=$?
    wait_for_evaluation "$measured" "$benchmark_quiz" "$dir/evaluation.txt" || evaluated=false
    log "run $repetition-$side: Phase 2, $rounds statistics rounds"
    cp "$dir/phase1/questions.json" "$dir/phase2/" 2>/dev/null || true
    "$here/k6.sh" "$project" phase2.js "$dir/phase2" -e QUIZ=benchmark -e STUDENTS="$students" -e ROUNDS="$rounds" \
        -e SEED="$schedule_seed" >"$dir/phase2/k6.log" 2>&1 || phase2_exit=$?
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
    find "$dir" -name sessions.json -delete

    # D38 rule 7: same answers, scores, and statistics as the first run; where the statistics come from and the dates of
    # the started quizzes may differ.
    local reference="$out/1-A/semantics.normalized.json"
    if [[ "$semantics_ok" == true ]]; then
        jq -S 'del(.statisticsSource, .benchmarkQuiz, .warmUpQuiz)' "$dir/semantics.json" >"$dir/semantics.normalized.json"
        if [[ -e "$reference" ]] && ! cmp -s "$reference" "$dir/semantics.normalized.json"; then
            semantics_ok=false
        fi
    fi
    # The end of the evaluation (timestamp of the D17 line) and the start of Phase 2 (phase2.json) come from the same
    # Docker VM clock.
    local evaluation_millis=null evaluation_end=null phase2_setup=null
    if [[ "$evaluated" == true ]]; then
        evaluation_millis="$(sed -E 's/.*durationMillis=([0-9]+).*/\1/' "$dir/evaluation.txt")"
        evaluation_end="$(node -e 'console.log(Date.parse(process.argv[1]))' "$(grep -m1 -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z' "$dir/evaluation.txt")")"
    fi
    [[ ! -e "$dir/phase2/phase2.json" ]] || phase2_setup="$(cat "$dir/phase2/phase2.json")"
    jq -n --argjson repetition "$repetition" --arg side "$side" --arg measured "$measured" \
        --argjson warmUpPhase1Exit "$warmup_phase1_exit" --argjson warmUpPhase2Exit "$warmup_phase2_exit" \
        --argjson phase1Exit "$phase1_exit" --argjson phase2Exit "$phase2_exit" --argjson evaluated "$evaluated" \
        --argjson evaluationMillis "$evaluation_millis" --argjson evaluationEnd "$evaluation_end" \
        --argjson phase2 "$phase2_setup" --argjson semanticsEqual "$semantics_ok" \
        '$ARGS.named + {
            statisticsMode: $phase2.mode,
            phase2DelayMillis: (if $phase2.start and $evaluationEnd then $phase2.start - $evaluationEnd else null end),
            valid: ($warmUpPhase1Exit == 0 and $warmUpPhase2Exit == 0 and $phase1Exit == 0 and $phase2Exit == 0
                and $evaluated and $semanticsEqual)
        } | del(.phase2)' >"$dir/run.json"
    log "run $repetition-$side: $(jq -c '{valid, warmUpPhase1Exit, warmUpPhase2Exit, phase1Exit, phase2Exit, evaluationMillis, statisticsMode, phase2DelayMillis, semanticsEqual}' "$dir/run.json")"
}

for repetition in $(seq "$repetitions"); do
    measure "$repetition" A "${side_a[@]}"
    measure "$repetition" B "${side_b[@]}"
done

{
    printf 'run\tmeasured\tvalid\tstart-participation p95 ms\tsave p95 ms\tsubmit p95 ms\tevaluation ms\tstatistics\toverview p95 ms\tpoints p95 ms\tquestion p95 ms\n'
    for run in $(seq "$repetitions"); do
        for side in A B; do
            dir="$out/$run-$side"
            phase1="$dir/phase1/summary.json"
            phase2="$dir/phase2/summary.json"
            [[ -e "$phase1" ]] || phase1=/dev/null
            [[ -e "$phase2" ]] || phase2=/dev/null
            jq -rn --arg run "$run-$side" --slurpfile r "$dir/run.json" --slurpfile p1 "$phase1" --slurpfile p2 "$phase2" '
                def p95($summary; $type): ($summary[0].metrics["http_req_duration{type:\($type)}"].values["p(95)"] // null)
                    | if . == null then "-" else (. * 10 | round / 10 | tostring) end;
                [$run, $r[0].measured, ($r[0].valid | tostring), p95($p1; "start-participation"), p95($p1; "save"),
                    p95($p1; "submit"), ($r[0].evaluationMillis // "-" | tostring), ($r[0].statisticsMode // "-"),
                    p95($p2; "statistics-overview"), p95($p2; "statistics-points"), p95($p2; "statistics-question")] | @tsv'
        done
    done
} >"$out/runs.tsv"
column -t -s $'\t' "$out/runs.tsv"
