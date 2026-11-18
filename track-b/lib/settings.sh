# shellcheck shell=bash disable=SC2034,SC2154
# The effective settings of a Track B run set: the run parameters of run.sh, the k6 limits (lib/k6-limits.sh), and the
# resolved compose configuration. Sourced by run.sh, which records them in parameters.json (settings), and by night.sh,
# which freezes them in inputs.json; run.sh refuses to run a campaign whose frozen settings differ (D43, D44). Source
# lib/stack.sh and lib/k6-limits.sh first.
repetitions="${REPETITIONS:-5}"
warmup_students="${WARMUP_STUDENTS:-100}"
rounds="${ROUNDS:-21}"
warmup_rounds="${WARMUP_ROUNDS:-5}"
schedule_seed="${SEED:-1}"
settle="${SETTLE_SECONDS:-15}"
sample_every="${SAMPLE_SECONDS:-5}"
control="${CONTROL:-1}"
practice_rate="${PRACTICE_RATE:-10}"
practice_seconds="${PRACTICE_SECONDS:-60}"
drain="${DRAIN_SECONDS:-300}"
export ARTEMIS_PORT="${ARTEMIS_PORT:-18080}"

# settings_json: {run, k6, compose}. compose is `docker compose config` of compose.yml as compose_cli resolves it, without
# the server image (each run starts it by id). Phase 3 on or off is not part of it: it belongs to the comparison.
settings_json() {
    local config
    config="$(ARTEMIS_IMAGE=by-id compose_cli -p trackb-run -f "$here/compose.yml" config --format json)"
    jq -n --argjson config "$config" --argjson repetitions "$repetitions" --argjson warmUpStudents "$warmup_students" \
        --argjson rounds "$rounds" --argjson warmUpRounds "$warmup_rounds" --argjson scheduleSeed "$schedule_seed" \
        --argjson settleSeconds "$settle" --argjson sampleSeconds "$sample_every" --argjson control "$control" \
        --argjson practiceRate "$practice_rate" --argjson practiceSeconds "$practice_seconds" --argjson drainSeconds "$drain" \
        --arg artemisPort "$ARTEMIS_PORT" --arg k6Cpuset "$K6_CPUSET" --arg k6Memory "$K6_MEMORY" '
        {run: {repetitions: $repetitions, warmUpStudents: $warmUpStudents, rounds: $rounds, warmUpRounds: $warmUpRounds,
               scheduleSeed: $scheduleSeed, settleSeconds: $settleSeconds, sampleSeconds: $sampleSeconds, control: $control,
               practiceRate: $practiceRate, practiceSeconds: $practiceSeconds, drainSeconds: $drainSeconds,
               artemisPort: $artemisPort},
         k6: {cpuset: $k6Cpuset, memory: $k6Memory},
         compose: ($config | del(.services.artemis.image))}'
}
