#!/usr/bin/env bash
# Runs the Track B result sets of one comparison (D40), for example in one night: every scale in turn, each a run.sh run
# set with REPETITIONS (default 5) runs per side. A complete run set (runs.tsv) is skipped, so a later night continues
# where an earlier one stopped; an interrupted run set is moved aside (<scale>.interrupted-<time>) and measured again from
# its first run.
#
# Usage: night.sh <comparison> [<students>...]
#   comparison  e2e (43bafcee17c against 9.9.3 -> 8325896e0b4), json-answers (43bafcee17c against f3463b75408, without
#               Phase 3), or stats-on-demand (c136826e299 against 24a062759c2); D37, D40
#   students    the scales, default 100 500 1000 2000
# Environment: SEED_FOLDER (default ~/Documents/thesis-benchmark-results/track-b/seed-2000-2026-11-18), RESULTS (default
# ~/Documents/thesis-benchmark-results/track-b/mac; run sets go to RESULTS/<comparison>/s<students>), and those of run.sh.
#
# Before the first run set it refuses to start if track-b/ has uncommitted changes or its revision differs from the run
# sets already in RESULTS (every night must measure with the same tools), if an image is missing, or if containers that
# are not part of Track B are running (they take CPU and memory from the measurement). It keeps the Mac awake with
# caffeinate; the lid must stay open, because closing it puts a MacBook to sleep anyway.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
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

case "$comparison" in
    e2e) side_a=artemis-thesis:43bafcee17c side_b=artemis-thesis:9.9.3,artemis-thesis:8325896e0b4 phase3=1 ;;
    json-answers) side_a=artemis-thesis:43bafcee17c side_b=artemis-thesis:f3463b75408 phase3=0 ;;
    stats-on-demand) side_a=artemis-thesis:c136826e299 side_b=artemis-thesis:24a062759c2 phase3=1 ;;
    *)
        echo "comparison must be e2e, json-answers, or stats-on-demand, not $comparison" >&2
        exit 2
        ;;
esac

if [[ -z "${NIGHT_AWAKE:-}" ]] && command -v caffeinate >/dev/null; then
    # -i: no idle sleep, -m: no disk sleep, -s: no system sleep on power.
    NIGHT_AWAKE=1 exec caffeinate -ims "$0" "$comparison" "${scales[@]}"
fi

revision="$(git -C "$here" rev-parse HEAD)"
if ! git -C "$here" diff --quiet HEAD -- .; then
    echo "track-b/ has uncommitted changes; commit them first, so that every run set records a commit" >&2
    exit 1
fi
mkdir -p "$results"
others="$(find "$results" -name parameters.json -not -path '*.interrupted-*' -exec jq -r .toolRevision {} + | sort -u | grep -vx "$revision" || true)"
if [[ -n "$others" ]]; then
    echo "run sets in $results were measured with other tool revisions:" >&2
    echo "$others" >&2
    echo "every night must use the same tools; check out that revision or use another RESULTS folder" >&2
    exit 1
fi
for image in ${side_a//,/ } ${side_b//,/ }; do
    docker image inspect "$image" >/dev/null 2>&1 || {
        echo "image $image is missing; build it with prepare.sh" >&2
        exit 1
    }
done
foreign="$(docker ps --format '{{.Names}}' | grep -v '^trackb-' || true)"
if [[ -n "$foreign" ]]; then
    echo "containers outside Track B are running; stop them before a measurement:" >&2
    echo "$foreign" >&2
    exit 1
fi

log "$comparison: scales ${scales[*]}, revision ${revision:0:11}, seed $seed"
for students in "${scales[@]}"; do
    out="$results/$comparison/s$students"
    if [[ -e "$out/runs.tsv" ]]; then
        log "$comparison s$students: complete, skipped"
        continue
    fi
    if [[ -e "$out" ]]; then
        aside="$out.interrupted-$(date -u +%Y%m%dT%H%M%SZ)"
        mv "$out" "$aside"
        log "$comparison s$students: interrupted run set moved to $aside"
    fi
    mkdir -p "$(dirname "$out")"
    log "$comparison s$students: start (log $out.log)"
    PHASE3="$phase3" "$here/run.sh" "$seed" "$out" "$students" "$side_a" "$side_b" >"$out.log" 2>&1
    log "$comparison s$students: $(jq -s '[.[] | select(.valid)] | length' "$out"/*-[AB]/run.json) of $(find "$out" -name run.json | wc -l | tr -d ' ') runs valid"
done
log "$comparison: done"
