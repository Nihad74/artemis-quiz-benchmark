#!/usr/bin/env bash
# Track B run loop (D6, D13, D14, D17, D36, D38): REPETITIONS runs of side A and side B in balanced order (repetition 1
# A then B, repetition 2 B then A, ...), each from a fresh restore of the same seed (D2 same-data rule). Needs Bash 5.
#
# Usage: run.sh <seed-folder> <out-folder> <students> <A-images> <B-images>
#   out-folder   must not exist or be empty: a run set is never mixed with an earlier attempt
#   seed-folder  seed.dump, artemis-data.tgz, and manifest.json of the baseline seed (migration-check.sh output, D18)
#   students     the first N students of the manifest take the benchmark quiz
#   A-, B-images comma-separated image chains; every image restores onto the database of the one before (Liquibase
#                migrates forward), the last one is measured. End-to-end comparison:
#                  artemis-thesis:43bafcee17c  artemis-thesis:9.9.3,artemis-thesis:8325896e0b4
# Environment: REPETITIONS (5), WARMUP_STUDENTS (100), ROUNDS (21, Phase 2 rounds per tutor), WARMUP_ROUNDS (5), SEED (1),
# CONTROL (1; 0 drops the control workflow, D20), PHASE3 (1; 0 drops Phase 3, D10, D38 rule 6), PRACTICE_RATE (10
# practice submissions per second), PRACTICE_SECONDS (60), DRAIN_SECONDS (300, see phase3.js), SETTLE_SECONDS (15),
# SAMPLE_SECONDS (5), ARTEMIS_PORT (18080), and the limits of compose.yml and lib/k6-limits.sh.
#
# One run, in <out-folder>/<repetition>-<side>/:
#  1. Restore the seed into fresh volumes. Start every image of the chain until it is healthy and stop it, then start the
#     measured image again: both sides measure a fresh server on an already migrated database (starts.txt).
#  2. Log in every user (login.mjs, D13). Warm-up (D38 rule 5, warm-up/): the control workflow on the warm-up text
#     exercise and Phase 1 on the warm-up quiz with WARMUP_STUDENTS students, wait for its evaluation, Phase 2 with
#     WARMUP_ROUNDS rounds, Phase 3 with the warm-up students, then SETTLE_SECONDS.
#  3. The control workflow on the text exercise with all students (control/, D20), then SETTLE_SECONDS; pg_stat_user_tables
#     and /proc/stat before it (pg-stat-before-control.csv, proc-stat-before-control.txt).
#  4. Phase 1 on the benchmark quiz with all students (phase1/: summary.json, raw.json.gz, k6.log, questions.json). From
#     the start of step 3 until the end of step 6, sampling every SAMPLE_SECONDS: docker stats of every container of the
#     project, PostgreSQL lock waits and active connections (samples.jsonl), and the Prometheus metrics of Artemis
#     (prometheus.txt.gz).
#  5. Wait for the evaluation by the scheduled task (D17 timer line with its timestamp: evaluation.txt), then at once
#     Phase 2 (phase2/: the tutors load the statistics pages, D10, D16 H3), then SETTLE_SECONDS, because idle PostgreSQL
#     backends publish their row counts up to 10 s late. pg_stat_user_tables before Phase 1 and after Phase 2
#     (pg-stat-before.csv, pg-stat-after.csv: Phase 1, the evaluation, and Phase 2 together) and /proc/stat of the Docker
#     VM (CPU steal).
#  6. Phase 3 (phase3/: practice submissions at a fixed rate while the statistics pages stay open, D10, D15), then
#     SETTLE_SECONDS, pg-stat-after-phase3.csv and proc-stat-after-phase3.txt, and the statistics freshness
#     (freshness.mjs: phase3/freshness.json).
#  7. D19 semantics of the benchmark quiz (semantics.json). After Phase 3 they include the practice results (unrated
#     statistics); after the control workflow, the submitted texts.
#  8. Server log, tear down, delete the login cookies.
# judge.mjs then writes run.json with an outcome (D43, D44): valid (every check passed); failed (the measurement is
# trustworthy but the server failed the workload: failed requests or submissions, no evaluation, wrong results; evidence
# against the hypothesis, never a latency sample); or invalid (the measurement cannot be trusted: another image or other
# container settings than planned, a k6 or tool error, the load generator behind schedule, an incomplete freshness
# measurement). The reference of D19 is the first valid run. After the last run, judge.mjs writes complete.json only if
# no run is invalid; run.sh then exits 0, else 1. runs.tsv lists all runs.
#
# Frozen inputs (D44): every image of both chains is resolved to its id once, at the start, and every server start
# (migration and measurement) uses that id, never the tag. Compose reads no ambient configuration (lib/stack.sh). The
# effective settings (lib/settings.sh: run parameters, k6 limits, resolved compose configuration), the SHA-256 of the
# seed files, and the image ids go to parameters.json; each run records the settings of its running containers
# (containers.json), and judge.mjs compares them with parameters.json. With CAMPAIGN=<inputs.json> (night.sh), run.sh
# takes the image ids from that file and refuses to start if the tool revision, the seed hashes, or the settings differ.
set -euo pipefail
if ((BASH_VERSINFO[0] < 5)); then
    echo "run.sh needs Bash 5 or later (EPOCHREALTIME); this is $BASH_VERSION" >&2
    exit 2
fi

here="$(cd "$(dirname "$0")" && pwd)"
project="trackb-run"
source "$here/lib/stack.sh"
source "$here/lib/k6-limits.sh"
source "$here/lib/inputs.sh"
source "$here/lib/settings.sh"

seed="$(cd "$1" && pwd)"
if [[ -e "$2" && -n "$(ls -A "$2")" ]]; then
    echo "$2 is not empty; a run set starts in a new folder (move an earlier attempt aside)" >&2
    exit 2
fi
out="$(mkdir -p "$2" && cd "$2" && pwd)"
students="$3"
IFS=, read -ra side_a <<<"$4"
IFS=, read -ra side_b <<<"$5"
phase3="${PHASE3:-1}"
server="http://localhost:$ARTEMIS_PORT"
manifest="$seed/manifest.json"

if ((students > $(jq '.students | length' "$manifest"))); then
    echo "the seed has $(jq '.students | length' "$manifest") students, not $students" >&2
    exit 2
fi
# The settings as configured, before the warm-up cohort is capped to the scale (the campaign freezes the configuration).
settings="$(settings_json)"
((warmup_students <= students)) || warmup_students="$students"
warmup_quiz="$(jq .warmUpQuiz "$manifest")"
benchmark_quiz="$(jq .benchmarkQuiz "$manifest")"
if [[ "$control" == 1 ]] && ! jq -e '.warmUpTextExercise' "$manifest" >/dev/null; then
    echo "the seed has no warm-up text exercise for the control workflow (D20); seed again with seed.mjs from 2026-11-18 on, or set CONTROL=0" >&2
    exit 2
fi

"$here/check-host.sh" "$out/host.json"
seed_hash_json="$(seed_hashes "$seed")"
tool_revision="$(git -C "$here" rev-parse HEAD)$(git -C "$here" diff --quiet HEAD -- . || echo '-dirty')"
declare -A image_id=()
campaign_json=null
if [[ -n "${CAMPAIGN:-}" ]]; then
    # A campaign run set uses exactly the frozen inputs of night.sh.
    problems=()
    [[ "$tool_revision" == "$(jq -r .toolRevision "$CAMPAIGN")" ]] || problems+=("tool revision $tool_revision")
    jq -e --argjson seed "$seed_hash_json" '.seed == $seed' "$CAMPAIGN" >/dev/null || problems+=("seed hashes")
    jq -e --argjson settings "$settings" '.settings == $settings' "$CAMPAIGN" >/dev/null || problems+=("settings")
    for image in "${side_a[@]}" "${side_b[@]}"; do
        image_id[$image]="$(jq -r --arg image "$image" '.images[$image] // ""' "$CAMPAIGN")"
        [[ -n "${image_id[$image]}" ]] || problems+=("no frozen id for $image")
    done
    if ((${#problems[@]} > 0)); then
        printf 'the inputs differ from the campaign %s: %s\n' "$CAMPAIGN" "${problems[*]}" >&2
        exit 2
    fi
    campaign_json="$(jq -n --arg file "$(cd "$(dirname "$CAMPAIGN")" && pwd)/$(basename "$CAMPAIGN")" --arg sha256 "$(sha256 "$CAMPAIGN")" '$ARGS.named')"
else
    for image in "${side_a[@]}" "${side_b[@]}"; do
        image_id[$image]="$(docker image inspect "$image" --format '{{.Id}}' 2>/dev/null || true)"
        if [[ -z "${image_id[$image]}" ]]; then
            echo "image $image is missing" >&2
            exit 2
        fi
    done
fi
images_json="$(for image in "${!image_id[@]}"; do jq -n --arg k "$image" --arg v "${image_id[$image]}" '{($k): $v}'; done | jq -s add)"
compose "${image_id[${side_a[-1]}]}" config --format json >"$out/compose.json"
jq -n --arg seed "$seed" --argjson students "$students" --argjson repetitions "$repetitions" \
    --argjson warmUpStudents "$warmup_students" --argjson scheduleSeed "$schedule_seed" --argjson settleSeconds "$settle" \
    --argjson rounds "$rounds" --argjson warmUpRounds "$warmup_rounds" --argjson phase3 "$([[ "$phase3" == 1 ]] && echo true || echo false)" \
    --argjson control "$([[ "$control" == 1 ]] && echo true || echo false)" \
    --argjson practiceRate "$practice_rate" --argjson practiceSeconds "$practice_seconds" --argjson drainSeconds "$drain" \
    --argjson sampleSeconds "$sample_every" --arg k6Cpuset "$K6_CPUSET" --arg k6Memory "$K6_MEMORY" \
    --arg toolRevision "$tool_revision" \
    --arg startedAt "$(date -u +%FT%TZ)" --arg order "balanced: odd repetitions A then B, even repetitions B then A" \
    --argjson seedHashes "$seed_hash_json" --argjson images "$images_json" --argjson settings "$settings" \
    --argjson campaign "$campaign_json" \
    '$ARGS.named + {sideA: $ARGS.positional[0] | split(","), sideB: $ARGS.positional[1] | split(",")}' \
    --args "$4" "$5" >"$out/parameters.json"

sampler_pid=""
cleanup() {
    [[ -z "$sampler_pid" ]] || kill "$sampler_pid" 2>/dev/null || true
    compose "${image_id[${side_a[-1]}]}" down -v --remove-orphans >/dev/null 2>&1 || true
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

# phase_folders <folder> <manifest> <sessions>: control/ and phase1/ to phase3/ with the inputs of the k6 scripts.
phase_folders() {
    local phase
    for phase in control phase1 phase2 phase3; do
        mkdir -p "$1/$phase"
        cp "$2" "$3" "$1/$phase/"
    done
}

# run_phase3 <phase3-folder> <quiz> <students> <k6-exit-variable> <freshness-exit-variable>: Phase 3 and its statistics
# freshness (freshness.json); stores the exit statuses of k6 and of freshness.mjs in the caller's variables.
run_phase3() {
    local folder="$1" k6_status=0 freshness_status=0
    "$here/k6.sh" "$project" phase3.js "$folder" -e QUIZ="$2" -e STUDENTS="$3" -e PRACTICE_RATE="$practice_rate" \
        -e PRACTICE_SECONDS="$practice_seconds" -e DRAIN_SECONDS="$drain" >"$folder/k6.log" 2>&1 || k6_status=$?
    node "$here/freshness.mjs" "$folder" >>"$folder/k6.log" 2>&1 || freshness_status=$?
    printf -v "$4" '%s' "$k6_status"
    printf -v "$5" '%s' "$freshness_status"
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

# container_facts <image-id>: the settings of the running Artemis and PostgreSQL containers (containers.json): image id,
# CPU set, memory limits, and environment, for judge.mjs to compare with the frozen compose configuration.
container_facts() {
    local service
    for service in artemis postgres; do
        docker inspect "$(compose "$1" ps -q "$service")" | jq -c --arg service "$service" '.[0] | {service: $service,
            image: .Image, cpuset: .HostConfig.CpusetCpus, memory: .HostConfig.Memory, memorySwap: .HostConfig.MemorySwap,
            env: (.Config.Env | map(capture("^(?<key>[^=]*)=(?<value>.*)$")) | from_entries)}'
    done | jq -s .
}

# measure <repetition> <side> <images...>: the images are tags; every server starts by the frozen id (image_id).
measure() {
    local repetition="$1" side="$2"
    shift 2
    local images=("$@") dir="$out/$repetition-$side"
    local measured="${images[-1]}" image start evaluated=true semantics_exit=0
    local measured_id="${image_id[${images[-1]}]}"
    local warmup_control_exit=0 warmup_phase1_exit=0 warmup_phase2_exit=0 warmup_phase3_exit=0 warmup_freshness_exit=0
    local control_exit=0 phase1_exit=0 phase2_exit=0 phase3_exit=0 freshness_exit=0
    mkdir -p "$dir"

    log "run $repetition-$side: restore, start ${images[*]}"
    restore_seed "${image_id[${images[0]}]}" "$seed"
    : >"$dir/starts.txt"
    for image in "${images[@]}"; do
        start=$SECONDS
        compose "${image_id[$image]}" up -d --wait --wait-timeout 1800 artemis >/dev/null 2>&1
        echo "migrate $image ${image_id[$image]} $((SECONDS - start))" >>"$dir/starts.txt"
        compose "${image_id[$image]}" stop artemis >/dev/null 2>&1
    done
    start=$SECONDS
    compose "$measured_id" up -d --wait --wait-timeout 1800 artemis >/dev/null 2>&1
    echo "measure $measured $measured_id $((SECONDS - start))" >>"$dir/starts.txt"
    for image in "${images[@]}"; do
        docker image inspect "${image_id[$image]}" --format '{{json .}}' | jq -c --arg image "$image" \
            '{image: $image, id: .Id, commit: .Config.Labels["thesis.commit"], head: .Config.Labels["thesis.head"]}'
    done | jq -s . >"$dir/images.json"
    container_facts "$measured_id" >"$dir/containers.json"
    local running_image
    running_image="$(jq -r '.[] | select(.service == "artemis") | .image' "$dir/containers.json")"
    curl -sf "$server/management/info" | jq '{version: .build.version, commit: .git.commit.id.full}' >"$dir/info.json"

    node "$here/login.mjs" --manifest "$manifest" --server "$server" --students "$students" --out "$dir/sessions.json"
    phase_folders "$dir/warm-up" "$manifest" "$dir/sessions.json"
    phase_folders "$dir" "$manifest" "$dir/sessions.json"
    rm "$dir/sessions.json"

    log "run $repetition-$side: warm-up, $warmup_students students, $warmup_rounds statistics rounds, control: $control, Phase 3: $phase3"
    if [[ "$control" == 1 ]]; then
        "$here/k6.sh" "$project" control.js "$dir/warm-up/control" -e EXERCISE=warmUp -e STUDENTS="$warmup_students" \
            -e SEED="$schedule_seed" >"$dir/warm-up/control/k6.log" 2>&1 || warmup_control_exit=$?
    fi
    "$here/k6.sh" "$project" phase1.js "$dir/warm-up/phase1" -e QUIZ=warmUp -e STUDENTS="$warmup_students" -e SEED="$schedule_seed" \
        >"$dir/warm-up/phase1/k6.log" 2>&1 || warmup_phase1_exit=$?
    wait_for_evaluation "$measured_id" "$warmup_quiz" "$dir/warm-up/evaluation.txt" || evaluated=false
    cp "$dir/warm-up/phase1/questions.json" "$dir/warm-up/phase2/" 2>/dev/null || true
    "$here/k6.sh" "$project" phase2.js "$dir/warm-up/phase2" -e QUIZ=warmUp -e STUDENTS="$warmup_students" \
        -e ROUNDS="$warmup_rounds" -e SEED="$schedule_seed" >"$dir/warm-up/phase2/k6.log" 2>&1 || warmup_phase2_exit=$?
    if [[ "$phase3" == 1 ]]; then
        run_phase3 "$dir/warm-up/phase3" warmUp "$warmup_students" warmup_phase3_exit warmup_freshness_exit
    fi
    sleep "$settle"

    # Errors of single samples (for example a container that exits during docker stats) go to sampler.log.
    sample "$measured_id" "$dir" 2>>"$dir/sampler.log" &
    sampler_pid=$!
    if [[ "$control" == 1 ]]; then
        log "run $repetition-$side: control workflow, $students students"
        pg_stat "$measured_id" >"$dir/pg-stat-before-control.csv"
        compose "$measured_id" exec -T postgres head -1 /proc/stat >"$dir/proc-stat-before-control.txt"
        "$here/k6.sh" "$project" control.js "$dir/control" -e EXERCISE=benchmark -e SEED="$schedule_seed" \
            >"$dir/control/k6.log" 2>&1 || control_exit=$?
        sleep "$settle"
    fi
    log "run $repetition-$side: Phase 1, $students students"
    pg_stat "$measured_id" >"$dir/pg-stat-before.csv"
    compose "$measured_id" exec -T postgres head -1 /proc/stat >"$dir/proc-stat-before.txt"
    "$here/k6.sh" "$project" phase1.js "$dir/phase1" -e QUIZ=benchmark -e SEED="$schedule_seed" \
        >"$dir/phase1/k6.log" 2>&1 || phase1_exit=$?
    wait_for_evaluation "$measured_id" "$benchmark_quiz" "$dir/evaluation.txt" || evaluated=false
    log "run $repetition-$side: Phase 2, $rounds statistics rounds"
    cp "$dir/phase1/questions.json" "$dir/phase2/" 2>/dev/null || true
    "$here/k6.sh" "$project" phase2.js "$dir/phase2" -e QUIZ=benchmark -e STUDENTS="$students" -e ROUNDS="$rounds" \
        -e SEED="$schedule_seed" >"$dir/phase2/k6.log" 2>&1 || phase2_exit=$?
    sleep "$settle"
    pg_stat "$measured_id" >"$dir/pg-stat-after.csv"
    compose "$measured_id" exec -T postgres head -1 /proc/stat >"$dir/proc-stat-after.txt"
    if [[ "$phase3" == 1 ]]; then
        log "run $repetition-$side: Phase 3, $practice_rate practice submissions per second for at most $practice_seconds s"
        run_phase3 "$dir/phase3" benchmark "$students" phase3_exit freshness_exit
        sleep "$settle"
        pg_stat "$measured_id" >"$dir/pg-stat-after-phase3.csv"
        compose "$measured_id" exec -T postgres head -1 /proc/stat >"$dir/proc-stat-after-phase3.txt"
    fi
    touch "$dir/.stop"
    wait "$sampler_pid" || true
    sampler_pid=""
    rm "$dir/.stop"
    [[ ! -e "$dir/prometheus.txt" ]] || gzip "$dir/prometheus.txt"

    log "run $repetition-$side: semantics"
    node "$here/semantics.mjs" --manifest "$manifest" --server "$server" --quiz benchmark --students "$students" \
        --out "$dir/semantics.json" || semantics_exit=$?
    compose "$measured_id" logs artemis >"$dir/server.log" 2>&1
    compose "$measured_id" down -v >/dev/null 2>&1
    find "$dir" -name sessions.json -delete

    jq -n --argjson repetition "$repetition" --arg side "$side" --arg measured "$measured" --arg runningImageId "$running_image" \
        --argjson warmUpControlExit "$warmup_control_exit" --argjson controlExit "$control_exit" \
        --argjson warmUpPhase1Exit "$warmup_phase1_exit" --argjson warmUpPhase2Exit "$warmup_phase2_exit" \
        --argjson warmUpPhase3Exit "$warmup_phase3_exit" --argjson warmUpFreshnessExit "$warmup_freshness_exit" \
        --argjson phase1Exit "$phase1_exit" --argjson phase2Exit "$phase2_exit" --argjson phase3Exit "$phase3_exit" \
        --argjson freshnessExit "$freshness_exit" --argjson semanticsExit "$semantics_exit" --argjson evaluated "$evaluated" \
        --argjson phase3Run "$([[ "$phase3" == 1 ]] && echo true || echo false)" \
        --argjson controlRun "$([[ "$control" == 1 ]] && echo true || echo false)" \
        '$ARGS.named' >"$dir/exits.json"
    log "run $repetition-$side: $(node "$here/judge.mjs" run "$out" "$dir")"
}

# Balanced order: repetition 1 runs A then B, repetition 2 B then A, and so on.
for repetition in $(seq "$repetitions"); do
    if ((repetition % 2 == 1)); then
        measure "$repetition" A "${side_a[@]}"
        measure "$repetition" B "${side_b[@]}"
    else
        measure "$repetition" B "${side_b[@]}"
        measure "$repetition" A "${side_a[@]}"
    fi
done

{
    printf 'run\tmeasured\toutcome\tcontrol-submit p95 ms\tstart-participation p95 ms\tsave p95 ms\tsubmit p95 ms\tevaluation ms\tstatistics\toverview p95 ms\tpoints p95 ms\tquestion p95 ms\tpractice-submit p95 ms\tfreshness p95 ms\n'
    for run in $(seq "$repetitions"); do
        for side in A B; do
            dir="$out/$run-$side"
            control_summary="$dir/control/summary.json"
            phase1="$dir/phase1/summary.json"
            phase2="$dir/phase2/summary.json"
            phase3="$dir/phase3/summary.json"
            [[ -e "$control_summary" ]] || control_summary=/dev/null
            [[ -e "$phase1" ]] || phase1=/dev/null
            [[ -e "$phase2" ]] || phase2=/dev/null
            [[ -e "$phase3" ]] || phase3=/dev/null
            jq -rn --arg run "$run-$side" --slurpfile r "$dir/run.json" --slurpfile c "$control_summary" --slurpfile p1 "$phase1" \
                --slurpfile p2 "$phase2" --slurpfile p3 "$phase3" '
                def round1: if . == null then "-" else (. * 10 | round / 10 | tostring) end;
                def p95($summary; $type): $summary[0].metrics["http_req_duration{type:\($type)}"].values["p(95)"] // null | round1;
                [$run, $r[0].measured, ($r[0].outcome // ($r[0].valid | tostring)), p95($c; "control-submit"), p95($p1; "start-participation"), p95($p1; "save"),
                    p95($p1; "submit"), ($r[0].evaluationMillis // "-" | tostring), ($r[0].statisticsMode // "-"),
                    p95($p2; "statistics-overview,read:repeated"), p95($p2; "statistics-points,read:repeated"), p95($p2; "statistics-question,read:repeated"),
                    p95($p3; "practice-submit"), ($r[0].freshnessP95Millis | round1)] | @tsv'
        done
    done
} >"$out/runs.tsv"
column -t -s $'\t' "$out/runs.tsv"
node "$here/judge.mjs" complete "$out" "$repetitions"
