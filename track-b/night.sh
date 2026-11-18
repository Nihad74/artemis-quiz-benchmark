#!/usr/bin/env bash
# Runs the Track B result sets of one comparison (D40), for example in one night: every scale in turn, each a run.sh run
# set with 5 runs per side. A run set with complete.json (run.sh writes it only after 5 valid runs per side) is skipped,
# so a later night continues where an earlier one stopped. Any other folder of that scale (interrupted, or with an invalid
# run) is moved aside as <scale>.attempt-<time> and kept; the scale is measured again from its first run. Needs Bash 5.
#
# Usage: night.sh <comparison> [<students>...]
#   comparison  e2e (43bafcee17c against 9.9.3 -> 8325896e0b4), json-answers (43bafcee17c against f3463b75408, without
#               Phase 3), or stats-on-demand (c136826e299 against 24a062759c2); D37, D40
#   students    the scales, default 100 500 1000 2000
# Environment: SEED_FOLDER (default ~/Documents/thesis-benchmark-results/track-b/seed-2000-2026-11-18) and RESULTS
# (default ~/Documents/thesis-benchmark-results/track-b/mac; run sets go to RESULTS/<comparison>/s<students>). The settings
# of run.sh, compose.yml, and lib/k6-limits.sh cannot be overridden here: result sets use the defaults of the tool revision.
#
# The inputs of every night are frozen in RESULTS/inputs.json, written by the first night: the tool revision, the SHA-256
# of manifest.json, seed.dump, and artemis-data.tgz, the ids of all six server images, and the Docker engine (version,
# CPUs, memory). A later night refuses to start if any of them differs. It also refuses uncommitted changes in track-b/
# and running containers outside Track B (they take CPU and memory from the measurement). It keeps the Mac awake with
# caffeinate; the lid must stay open and the Mac on power.
set -euo pipefail
if ((BASH_VERSINFO[0] < 5)); then
    echo "night.sh needs Bash 5 or later; this is $BASH_VERSION" >&2
    exit 2
fi

here="$(cd "$(dirname "$0")" && pwd)"
source "$here/lib/inputs.sh"
log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*"; }

if (($# < 1)); then
    sed -n '2,13p' "$0" >&2
    exit 2
fi
comparison="$1"
shift
scales=("$@")
((${#scales[@]} > 0)) || scales=(100 500 1000 2000)
seed="${SEED_FOLDER:-$HOME/Documents/thesis-benchmark-results/track-b/seed-2000-2026-11-18}"
results="${RESULTS:-$HOME/Documents/thesis-benchmark-results/track-b/mac}"
all_images=(artemis-thesis:43bafcee17c artemis-thesis:9.9.3 artemis-thesis:8325896e0b4 artemis-thesis:f3463b75408
    artemis-thesis:c136826e299 artemis-thesis:24a062759c2)

case "$comparison" in
    e2e) side_a=artemis-thesis:43bafcee17c side_b=artemis-thesis:9.9.3,artemis-thesis:8325896e0b4 phase3=1 ;;
    json-answers) side_a=artemis-thesis:43bafcee17c side_b=artemis-thesis:f3463b75408 phase3=0 ;;
    stats-on-demand) side_a=artemis-thesis:c136826e299 side_b=artemis-thesis:24a062759c2 phase3=1 ;;
    *)
        echo "comparison must be e2e, json-answers, or stats-on-demand, not $comparison" >&2
        exit 2
        ;;
esac

# Pilot settings must not enter a result set.
overrides=()
for name in REPETITIONS WARMUP_STUDENTS ROUNDS WARMUP_ROUNDS SEED SETTLE_SECONDS SAMPLE_SECONDS CONTROL PHASE3 \
    PRACTICE_RATE PRACTICE_SECONDS DRAIN_SECONDS ARTEMIS_PORT ARTEMIS_CPUSET ARTEMIS_MEMORY POSTGRES_CPUSET \
    POSTGRES_MEMORY K6_CPUSET K6_MEMORY JAVA_HEAP ARTEMIS_DB_POOL_SIZE VM_RESERVE RESULT_WAIT_SECONDS; do
    [[ -z "${!name+x}" ]] || overrides+=("$name=${!name}")
done
if ((${#overrides[@]} > 0)); then
    echo "result sets use the default settings; unset ${overrides[*]}" >&2
    exit 1
fi

if [[ -z "${NIGHT_AWAKE:-}" ]] && command -v caffeinate >/dev/null; then
    # -i: no idle sleep, -m: no disk sleep, -s: no system sleep on power.
    NIGHT_AWAKE=1 exec caffeinate -ims "$0" "$comparison" "${scales[@]}"
fi

if ! git -C "$here" diff --quiet HEAD -- .; then
    echo "track-b/ has uncommitted changes; commit them first, so that every run set records a commit" >&2
    exit 1
fi
inputs="$(jq -n --arg toolRevision "$(git -C "$here" rev-parse HEAD)" --argjson seed "$(seed_hashes "$seed")" \
    --argjson images "$(image_ids "${all_images[@]}")" \
    --argjson engine "$(docker info --format '{{json .}}' | jq '{version: .ServerVersion, cpus: .NCPU, memory: .MemTotal}')" \
    '$ARGS.named')"
missing="$(jq -r '.images | to_entries[] | select(.value == "") | .key' <<<"$inputs")"
if [[ -n "$missing" ]]; then
    echo "images missing; build them with prepare.sh:" >&2
    echo "$missing" >&2
    exit 1
fi
mkdir -p "$results"
if [[ -e "$results/inputs.json" ]]; then
    if ! diff <(jq -S . "$results/inputs.json") <(jq -S . <<<"$inputs") >&2; then
        echo "the inputs differ from those of the earlier nights in $results/inputs.json (diff above: < earlier, > now)" >&2
        exit 1
    fi
else
    echo "$inputs" >"$results/inputs.json"
fi
foreign="$(docker ps --format '{{.Names}}' | grep -v '^trackb-' || true)"
if [[ -n "$foreign" ]]; then
    echo "containers outside Track B are running; stop them before a measurement:" >&2
    echo "$foreign" >&2
    exit 1
fi

log "$comparison: scales ${scales[*]}, revision $(jq -r '.toolRevision[:11]' <<<"$inputs"), seed $seed"
for students in "${scales[@]}"; do
    out="$results/$comparison/s$students"
    if [[ -e "$out/complete.json" ]]; then
        log "$comparison s$students: complete, skipped"
        continue
    fi
    if [[ -e "$out" ]]; then
        aside="$out.attempt-$(date -u +%Y%m%dT%H%M%SZ)"
        mv "$out" "$aside"
        [[ ! -e "$out.log" ]] || mv "$out.log" "$aside.log"
        log "$comparison s$students: earlier attempt moved to $aside"
    fi
    mkdir -p "$(dirname "$out")"
    log "$comparison s$students: start (log $out.log)"
    # An incomplete run set stays in place for the report and is moved aside by the next night.
    PHASE3="$phase3" "$here/run.sh" "$seed" "$out" "$students" "$side_a" "$side_b" >"$out.log" 2>&1 || true
    if [[ -e "$out/complete.json" ]]; then
        log "$comparison s$students: complete"
    else
        log "$comparison s$students: NOT complete ($(tail -1 "$out.log")); the next night measures it again"
    fi
done
log "$comparison: done"
