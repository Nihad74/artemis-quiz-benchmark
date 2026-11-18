#!/usr/bin/env bash
# Runs the Track B result sets of one comparison (D40), for example in one night: every scale in turn, each a run.sh run
# set with 5 runs per side. A scale is skipped only if its run set belongs to this campaign and is finished: its
# parameters.json names the campaign file (inputs.json, by SHA-256), the sides and Phase 3 of the comparison, the scale,
# and 5 repetitions, and its complete.json counts 5 judged runs per side and no invalid run. A judged run is valid or a
# failure of the server (judge.mjs, D44): a server failure is evidence against the hypothesis and is not measured again.
# Any other folder of that scale (a pilot, an interrupted set, a set with an invalid run) is moved aside as
# <scale>.attempt-<time> and kept; the scale is measured again from its first run. Needs Bash 5.
#
# Usage: night.sh <comparison> [<students>...]
#   comparison  e2e (43bafcee17c against 9.9.3 -> 8325896e0b4), json-answers (43bafcee17c against f3463b75408, without
#               Phase 3), or stats-on-demand (c136826e299 against 24a062759c2); D37, D40
#   students    the scales, default 100 500 1000 2000
# Environment: SEED_FOLDER (default ~/Documents/thesis-benchmark-results/track-b/seed-2000-2026-11-18), RESULTS (default
# ~/Documents/thesis-benchmark-results/track-b/mac; run sets go to RESULTS/<comparison>/s<students>), NIGHT_CHECK=1 (only
# check the inputs and print the state of each scale; measure nothing). The settings of run.sh, compose.yml, and
# lib/k6-limits.sh cannot be overridden here: result sets use the defaults of the tool revision.
# Exit status: 0 only if every requested scale is finished; 1 if a scale remains incomplete or the inputs differ.
#
# The inputs of every night are frozen in RESULTS/inputs.json, written by the first night: the tool revision, the SHA-256
# of manifest.json, seed.dump, and artemis-data.tgz, the ids of all six server images, the effective settings
# (lib/settings.sh: run parameters, k6 limits, resolved compose configuration), and the Docker engine (version, CPUs,
# memory). A later night refuses to start if any of them differs, and run.sh (CAMPAIGN) starts the servers by the frozen
# ids and refuses settings that differ. night.sh also refuses uncommitted changes in track-b/ and running containers
# outside Track B (they take CPU and memory from the measurement). It keeps the Mac awake with caffeinate; the lid must
# stay open and the Mac on power.
set -euo pipefail
if ((BASH_VERSINFO[0] < 5)); then
    echo "night.sh needs Bash 5 or later; this is $BASH_VERSION" >&2
    exit 2
fi

here="$(cd "$(dirname "$0")" && pwd)"
source "$here/lib/inputs.sh"
source "$here/lib/stack.sh"
source "$here/lib/k6-limits.sh"

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

if [[ -z "${NIGHT_AWAKE:-}${NIGHT_CHECK:-}" ]] && command -v caffeinate >/dev/null; then
    # -i: no idle sleep, -m: no disk sleep, -s: no system sleep on power.
    NIGHT_AWAKE=1 exec caffeinate -ims "$0" "$comparison" "${scales[@]}"
fi

if ! git -C "$here" diff --quiet HEAD -- .; then
    echo "track-b/ has uncommitted changes; commit them first, so that every run set records a commit" >&2
    exit 1
fi
# Only now: the overrides are refused above, so lib/settings.sh yields the defaults.
source "$here/lib/settings.sh"
inputs="$(campaign_inputs "$here" "$seed" "${all_images[@]}")"
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
    [[ -n "${NIGHT_CHECK:-}" ]] || echo "$inputs" >"$results/inputs.json"
fi
campaign="$results/inputs.json"
campaign_hash="$( [[ -e "$campaign" ]] && sha256 "$campaign" || echo none)"

# finished <out> <students>: the run set in <out> is a finished run set of this campaign (see the header).
finished() {
    [[ -e "$1/complete.json" && -e "$1/parameters.json" ]] || return 1
    jq -es --arg campaign "$campaign_hash" --arg a "$side_a" --arg b "$side_b" --argjson phase3 "$phase3" \
        --argjson students "$2" '
        .[0] as $p | .[1] as $c
        | $p.campaign.sha256 == $campaign and ($p.sideA | join(",")) == $a and ($p.sideB | join(",")) == $b
          and ($p.phase3 == ($phase3 == 1)) and $p.students == $students and $p.repetitions == 5
          and $c.repetitions == 5 and ($c.invalid | length) == 0
          and $c.validA + $c.failedA >= 5 and $c.validB + $c.failedB >= 5' \
        "$1/parameters.json" "$1/complete.json" >/dev/null 2>&1
}

incomplete=()
if [[ -n "${NIGHT_CHECK:-}" ]]; then
    for students in "${scales[@]}"; do
        if finished "$results/$comparison/s$students" "$students"; then
            log "$comparison s$students: finished"
        else
            log "$comparison s$students: not finished"
            incomplete+=("s$students")
        fi
    done
    ((${#incomplete[@]} == 0)) || exit 1
    exit 0
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
    if finished "$out" "$students"; then
        log "$comparison s$students: finished in this campaign, skipped"
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
    # An unfinished run set stays in place for the report and is moved aside by the next night.
    CAMPAIGN="$campaign" PHASE3="$phase3" "$here/run.sh" "$seed" "$out" "$students" "$side_a" "$side_b" >"$out.log" 2>&1 || true
    if finished "$out" "$students"; then
        log "$comparison s$students: finished ($(jq -c '{validA, failedA, validB, failedB}' "$out/complete.json"))"
    else
        log "$comparison s$students: NOT finished ($(tail -1 "$out.log")); the next night measures it again"
        incomplete+=("s$students")
    fi
done
if ((${#incomplete[@]} > 0)); then
    log "$comparison: done; not finished: ${incomplete[*]}"
    exit 1
fi
log "$comparison: done; every scale finished"
