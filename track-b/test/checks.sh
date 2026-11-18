#!/usr/bin/env bash
# Regression checks of the Track B run outcomes, completion, frozen inputs, report verdicts, and freshness measurement.
# No server is started; the checks use fixtures and saved pilots: the pilot of 2026-11-17 at 2000 students (run 1-A
# missed one submission) and the final pilots of 2026-11-18 (the f3463b75408 run failed the workload). Needs Bash 5,
# Node 24, jq, Python 3, Docker (image ids, compose config), and the pilot folders under RESULTS_ROOT (default
# ~/Documents/thesis-benchmark-results/track-b). The night.sh and run.sh campaign checks need a committed track-b/.
#
# Usage: test/checks.sh
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
root="${RESULTS_ROOT:-$HOME/Documents/thesis-benchmark-results/track-b}"
pilot="$root/pilot-mac-2026-11-17"
final="$root/pilot-mac-2026-11-18-final"
seed="$root/seed-2000-2026-11-18"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0
pass() { printf 'ok   %s\n' "$1"; }
fail() {
    printf 'FAIL %s\n' "$1"
    failures=$((failures + 1))
}
expect() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (got '$2', expected '$3')"; fi; }
exists() { [[ -e "$1" ]] && echo yes || echo no; }
committed() { git -C "$here" diff --quiet HEAD -- .; }

# The frozen compose settings of the fixtures, and running containers that match them.
settings='{"compose":{"services":{"artemis":{"cpuset":"0-5","mem_limit":"100","memswap_limit":"100","environment":{"POOL":"100"}},
    "postgres":{"cpuset":"6-9","mem_limit":"50","memswap_limit":"50","environment":{"POSTGRES_USER":"Artemis"}}}}}'
containers='[{"service":"artemis","image":"sha256:abc","cpuset":"0-5","memory":100,"memorySwap":100,"env":{"POOL":"100","PATH":"/bin"}},
    {"service":"postgres","image":"sha256:pg","cpuset":"6-9","memory":50,"memorySwap":50,"env":{"POSTGRES_USER":"Artemis"}}]'

# A run folder for judge.mjs: valid workload and provenance, with the semantics of a pilot run.
make_run() {
    local out="$1" name="$2" semantics="$3" exit_status="${4:-0}"
    mkdir -p "$out/$name"
    cp "$semantics" "$out/$name/semantics.json"
    echo '[{"image":"artemis-thesis:x","id":"sha256:abc","commit":"x","head":"83f5370b5d7"}]' >"$out/$name/images.json"
    echo '{"version":"9.9","commit":"83f5370b5d7cee936e6e961d4a5420743144c2b8"}' >"$out/$name/info.json"
    echo "$containers" >"$out/$name/containers.json"
    echo '2026-11-17T15:50:00.000Z INFO Thesis benchmark: calculateAllResults quiz=4 participations=2000 durationMillis=1000' >"$out/$name/evaluation.txt"
    jq -n --arg side "${name#*-}" --argjson phase1Exit "$exit_status" '{repetition: 1, side: $side, measured: "artemis-thesis:x",
        runningImageId: "sha256:abc", warmUpPhase1Exit: 0, warmUpPhase2Exit: 0, phase1Exit: $phase1Exit, phase2Exit: 0, semanticsExit: 0,
        evaluated: true, phase3Run: false, controlRun: false}' >"$out/$name/exits.json"
    local phase
    for phase in warm-up/phase1 warm-up/phase2 phase1 phase2; do
        mkdir -p "$out/$name/$phase"
        echo '{"metrics":{}}' >"$out/$name/$phase/summary.json"
    done
}

new_set() {
    mkdir -p "$1"
    jq -n --arg seed "${2:-$pilot/seed-2000}" --argjson settings "$settings" \
        '{seed: $seed, students: 2000, images: {"artemis-thesis:x": "sha256:abc"}, settings: $settings}' >"$1/parameters.json"
}

# with_threshold <run-folder> <phase> <metric>: a k6 summary of <phase> in which the threshold of <metric> failed.
with_threshold() {
    mkdir -p "$1/$2"
    jq -n --arg metric "$3" '{metrics: {($metric): {thresholds: {"count==0": {ok: false}}}, checks: {thresholds: {"rate==1": {ok: true}}}}}' >"$1/$2/summary.json"
}

judge() { node "$here/judge.mjs" run "$1" "$1/$2" >/dev/null; }
field() { jq -r "$3" "$1/$2/run.json"; }

good="$pilot/s2000/1-B/semantics.json"
bad="$pilot/s2000/1-A/semantics.json"

# 1. A failed first run never becomes the reference; the first valid run does.
out="$work/reference"
new_set "$out"
make_run "$out" 1-A "$bad" 99
with_threshold "$out/1-A" phase1 phase1_submitted_in_time
make_run "$out" 1-B "$good"
judge "$out" 1-A
expect "failed 1-A is not valid" "$(field "$out" 1-A .outcome)" failed
expect "failed 1-A sets no reference" "$(exists "$out/reference.json")" no
expect "failed 1-A is not compared" "$(field "$out" 1-A .semanticsEqual)" null
judge "$out" 1-B
expect "valid 1-B becomes the reference" "$(jq -r .run "$out/reference.json")" 1-B
expect "valid 1-B is valid" "$(field "$out" 1-B .outcome)" valid

# 2. Wrong results fail the independent check even with passing thresholds: a server failure, never the reference.
out="$work/expected"
new_set "$out"
make_run "$out" 1-A "$bad" 0
judge "$out" 1-A
expect "wrong scores with passing k6 are a server failure" "$(field "$out" 1-A '[.expectedResults, .outcome] | join(" ")')" "false failed"
expect "wrong scores set no reference" "$(exists "$out/reference.json")" no
out="$work/missing-answers"
new_set "$out"
jq '.students.tbstudent1.answers = []' "$good" >"$work/answers.json"
make_run "$out" 1-A "$work/answers.json"
judge "$out" 1-A
expect "missing stored answers disqualify a run despite correct scores" \
    "$(field "$out" 1-A '[.outcome, .expectedResults] | join(" ")')" "failed false"
jq '.students.tbstudent1.answers[0].selection = []' "$good" >"$work/answers.json"
make_run "$out" 1-B "$work/answers.json"
judge "$out" 1-B
expect "a wrong stored selection disqualifies a run despite correct scores" \
    "$(field "$out" 1-B '[.outcome, .expectedResults] | join(" ")')" "failed false"

# 3. A later run must equal the reference.
out="$work/compare"
new_set "$out"
make_run "$out" 1-A "$good"
judge "$out" 1-A
jq '.textExercise.submittedTexts = ["changed"]' "$good" >"$work/changed.json"
make_run "$out" 1-B "$work/changed.json"
judge "$out" 1-B
expect "semantics unlike the reference are not valid" "$(field "$out" 1-B '[.semanticsEqual, .outcome] | join(" ")')" "false failed"

# 4. Provenance against the frozen inputs (D44): the running container, the planned id, and the container settings.
out="$work/provenance"
new_set "$out"
make_run "$out" 1-A "$good"
jq '.runningImageId = "sha256:other"' "$out/1-A/exits.json" >"$work/exits.json" && mv "$work/exits.json" "$out/1-A/exits.json"
judge "$out" 1-A
expect "another running image is invalid" "$(field "$out" 1-A .outcome)" invalid
out="$work/planned"
new_set "$out"
jq '.images["artemis-thesis:x"] = "sha256:def"' "$out/parameters.json" >"$work/p.json" && mv "$work/p.json" "$out/parameters.json"
make_run "$out" 1-A "$good"
judge "$out" 1-A
expect "a run of another image than the frozen id is invalid, even if the tag now points to it" "$(field "$out" 1-A .outcome)" invalid
out="$work/wrong-base"
new_set "$out"
make_run "$out" 1-A "$good"
jq '.[0].commit = "wrong"' "$out/1-A/images.json" >"$work/image.json" && mv "$work/image.json" "$out/1-A/images.json"
judge "$out" 1-A
expect "matching IDs with the wrong Artemis base label are invalid" \
    "$(field "$out" 1-A '[.outcome, any(.measurementReasons[]; contains("measured base commit"))] | join(" ")')" "invalid true"
out="$work/settings"
new_set "$out"
make_run "$out" 1-A "$good"
jq '(.[] | select(.service == "artemis") | .env.POOL) = "12" | (.[] | select(.service == "postgres") | .memory) = 25' \
    "$out/1-A/containers.json" >"$work/c.json" && mv "$work/c.json" "$out/1-A/containers.json"
judge "$out" 1-A
expect "a container with other settings than the frozen ones is invalid" \
    "$(field "$out" 1-A '[.outcome, (.reasons[0] | test("POOL=12") and test("postgres memory 25"))] | join(" ")')" "invalid true"

# 5. Load-generator problems and unknown thresholds make a run invalid, not a server failure.
out="$work/generator"
new_set "$out"
make_run "$out" 1-A "$good" 99
with_threshold "$out/1-A" phase1 dropped_iterations
judge "$out" 1-A
expect "dropped iterations make the run invalid" "$(field "$out" 1-A .outcome)" invalid
make_run "$out" 1-B "$good" 1
judge "$out" 1-B
expect "a k6 error (exit 1) makes the run invalid" "$(field "$out" 1-B .outcome)" invalid
out="$work/log-reading"
new_set "$out"
make_run "$out" 1-A "$good"
jq '.evaluated = false | .warmUpEvaluationExit = 0 | .evaluationExit = 2' "$out/1-A/exits.json" >"$work/exits.json"
mv "$work/exits.json" "$out/1-A/exits.json"
judge "$out" 1-A
expect "a log read error is invalid, not server failure evidence" \
    "$(field "$out" 1-A '[.outcome, (.serverReasons | length)] | join(" ")')" "invalid 0"
make_run "$out" 1-B "$good"
rm "$out/1-B/phase2/summary.json"
judge "$out" 1-B
expect "a successful phase exit cannot replace its missing summary" "$(field "$out" 1-B .outcome)" invalid

(
    source "$here/lib/stack.sh"
    compose() { awk 'BEGIN { print "calculateAllResults quiz=5 durationMillis=1"; for (i=0;i<20000;i++) print "more logs" }'; }
    status=0
    wait_for_evaluation "sha256:abc" 5 "$work/evaluation.txt" || status=$?
    if grep -qFx 'calculateAllResults quiz=5 durationMillis=1' "$work/evaluation.txt"; then
        printf '/match' >"$work/evaluation-content"
    fi
    printf '%s\n' "$status" >"$work/evaluation-status"
    compose() { return 9; }
    status=0
    wait_for_evaluation "sha256:abc" 5 "$work/evaluation.txt" >/dev/null || status=$?
    printf '%s\n' "$status" >"$work/evaluation-read-error"
)
expect "evaluation log reader saves the timer match and handles a full pipe" \
    "$(cat "$work/evaluation-status")$(cat "$work/evaluation-content" 2>/dev/null || true)" 0/match
expect "evaluation log reader distinguishes a Compose error" "$(cat "$work/evaluation-read-error")" 2

# 6. Only valid runs count towards completion. Server failures stay separate as failure.json.
out="$work/complete"
new_set "$out"
make_run "$out" 1-A "$good"
make_run "$out" 1-B "$bad" 99
with_threshold "$out/1-B" phase1 phase1_submitted_in_time
judge "$out" 1-A
judge "$out" 1-B
status=0
node "$here/judge.mjs" complete "$out" 2 >/dev/null || status=$?
expect "an under-replicated set is not complete" "$status/$(exists "$out/complete.json")" 1/no
status=0
node "$here/judge.mjs" complete "$out" 1 >/dev/null || status=$?
expect "a server failure cannot complete a valid-run set" "$status/$(exists "$out/complete.json")/$(exists "$out/failure.json")" 1/no/yes
make_run "$out" 2-A "$good" 1
judge "$out" 2-A
echo '{"repetitions":1,"validA":1,"validB":1}' >"$out/complete.json"
status=0
node "$here/judge.mjs" complete "$out" 1 >/dev/null || status=$?
expect "a set with an invalid run is not complete" "$status/$(exists "$out/complete.json")" 1/no

# 7. A complete Phase 3 run above the H3 bound stays valid (D42); an incomplete freshness measurement is invalid.
phase3_pilot="$root/pilot-mac-2026-11-18-control/s2000/1-B"
out="$work/h3"
new_set "$out" "$seed"
for name in 1-A 1-B; do
    make_run "$out" "$name" "$phase3_pilot/semantics.json"
    jq '.phase3Run = true | .phase3Exit = 0 | .freshnessExit = 0 | .warmUpPhase3Exit = 0 | .warmUpFreshnessExit = 0' "$out/$name/exits.json" >"$work/exits.json"
    mv "$work/exits.json" "$out/$name/exits.json"
    mkdir -p "$out/$name/phase3" "$out/$name/warm-up/phase3"
    for phase in phase3 warm-up/phase3; do
        echo '{"metrics":{}}' >"$out/$name/$phase/summary.json"
    done
    echo '{"complete":true}' >"$out/$name/warm-up/phase3/freshness.json"
    cp "$phase3_pilot/phase3/phase3.json" "$out/$name/phase3/"
done
echo '{"complete":true,"errors":[],"p95Millis":3500,"p95Censored":true}' >"$out/1-A/phase3/freshness.json"
echo '{"complete":false,"errors":["tutor 3 never subscribed"]}' >"$out/1-B/phase3/freshness.json"
judge "$out" 1-A
judge "$out" 1-B
expect "a complete run above the H3 bound stays valid" "$(field "$out" 1-A .outcome)" valid
expect "an incomplete freshness measurement is invalid" "$(field "$out" 1-B .outcome)" invalid
jq '.phase3Exit = 99 | .freshnessExit = 1' "$out/1-B/exits.json" >"$work/exits.json" && mv "$work/exits.json" "$out/1-B/exits.json"
with_threshold "$out/1-B" phase3 phase3_practice_answered
echo '{"complete":false,"submissions":599,"expectedSubmissions":600,"captureErrors":[],"errors":["599 of 600 practice submissions answered"]}' >"$out/1-B/phase3/freshness.json"
judge "$out" 1-B
status=0
node "$here/judge.mjs" complete "$out" 1 >/dev/null || status=$?
expect "rejected practice POSTs preserve server failure evidence despite the missing freshness" \
    "$status/$(field "$out" 1-B .outcome)/$(exists "$out/failure.json")/$(exists "$out/complete.json")" 1/failed/yes/no
jq '.captureErrors = ["tutor never subscribed"]' "$out/1-B/phase3/freshness.json" >"$work/fresh.json"
mv "$work/fresh.json" "$out/1-B/phase3/freshness.json"
judge "$out" 1-B
expect "an independent capture error remains invalid despite rejected POSTs" "$(field "$out" 1-B .outcome)" invalid

# 8. Replay the saved f3463b75408 workload failure (the dropped H2 pair, D45): the judge still classifies a collapse as a
#    server failure whose latencies cannot complete a result set. The historical pilot lacks container facts, so the
#    fixture supplies matching synthetic facts. Only outcome classification is replayed; this is no new provenance.
replay="$work/replay"
mkdir -p "$replay"
jq --argjson settings "$settings" '.settings = $settings | .repetitions = 5 | .images[.sideA[-1]] = "sha256:abc" | .images[.sideB[-1]] = "sha256:abc"' \
    "$final/json-answers/s2000/parameters.json" >"$replay/parameters.json"
for name in 1-A 1-B; do
    mkdir -p "$replay/$name"
    (cd "$final/json-answers/s2000/$name" && cp -R exits.json images.json info.json semantics.json phase1 phase2 control warm-up "$replay/$name/" &&
        { [[ ! -e evaluation.txt ]] || cp evaluation.txt "$replay/$name/"; })
    jq '.runningImageId = "sha256:abc"' "$replay/$name/exits.json" >"$work/exits.json" && mv "$work/exits.json" "$replay/$name/exits.json"
    jq --arg image "$(jq -r .measured "$replay/$name/exits.json")" 'map(if .image == $image then .id = "sha256:abc" else . end)' \
        "$replay/$name/images.json" >"$work/i.json" && mv "$work/i.json" "$replay/$name/images.json"
    echo "$containers" >"$replay/$name/containers.json"
    judge "$replay" "$name"
done
expect "the baseline run of the pair is valid" "$(field "$replay" 1-A .outcome)" valid
expect "the f3463b75408 collapse is a server failure, not an invalid measurement" "$(field "$replay" 1-B .outcome)" failed
expect "its reasons name the failed submissions and the missing evaluation" \
    "$(field "$replay" 1-B '[(.reasons | map(select(test("phase1_submitted_in_time") or test("evaluation not logged"))) | length)] | .[0]')" 2
expect "no websocket samples means no result latency" "$(field "$replay" 1-B .timeToResultP95Millis)" null
for repetition in 2 3 4 5; do
    for side in A B; do ln -s "$replay/1-$side" "$replay/$repetition-$side"; done
done
status=0
node "$here/judge.mjs" complete "$replay" 5 >/dev/null || status=$?
expect "five server failures remain evidence, never five valid runs" "$status/$(exists "$replay/complete.json")/$(exists "$replay/failure.json")" 1/no/yes
python3 "$here/report.py" --out "$work/replay.md" "$replay" >/dev/null
expect "failure evidence gets no latency verdict" \
    "$(grep -c '^| H2 submit p95 B/A .*side B failed 5 of 5.*no verdict (.*incomplete)' "$work/replay.md")" 1

# 9. Report verdicts only for a result set of the comparison of the hypothesis at 2000 students (D16, D37, D44, D45).
stats="$final/stats-on-demand/s2000"
fake_set() {
    local out="$1" students="$2" repetitions="$3" repetition side
    mkdir -p "$out"
    jq --argjson students "$students" --argjson repetitions "$repetitions" '.students = $students | .repetitions = $repetitions' \
        "$stats/parameters.json" >"$out/parameters.json"
    for repetition in $(seq "$repetitions"); do
        for side in A B; do
            for file in run.json phase1/summary.json phase2/summary.json phase3/summary.json phase3/phase3.json phase3/freshness.json; do
                mkdir -p "$(dirname "$out/$repetition-$side/$file")"
                cp "$stats/1-$side/$file" "$out/$repetition-$side/$file"
            done
        done
    done
    jq -n --argjson r "$repetitions" '{repetitions: $r, validA: $r, failedA: 0, validB: $r, failedB: 0, invalid: []}' >"$out/complete.json"
}
fake_set "$work/s100" 100 2
python3 "$here/report.py" --out "$work/s100.md" "$work/s100" >/dev/null
expect "no verdict for two runs per side at 100 students" \
    "$(grep '^| H[23] ' "$work/s100.md" | grep -vc 'no verdict (\(not the H2 pair, \)\?100 students, not 2000, complete pilot)')" 0
fake_set "$work/s2000" 2000 5
python3 "$here/report.py" --out "$work/s2000.md" "$work/s2000" >/dev/null
expect "the H3 pair gives verdicts from a 2000-student result set" \
    "$(grep '^| H3 ' "$work/s2000.md" | grep -c '| holds |$')" 4
expect "H3 reads the initial reads, 5 overview observations per run" \
    "$(grep -c '^| H3 statistics-overview initial p95 (ms) | [0-9.]* | 5 | < 1000 | holds |' "$work/s2000.md")" 1
expect "the H3 pair gives no H2 verdict" "$(grep -c '^| H2 .*no verdict (not the H2 pair)' "$work/s2000.md")" 1
expect "the report draws the A/B chart of a run set under the run set's name and links it" \
    "$(python3 -c 'import sys, xml.etree.ElementTree as E; E.parse(sys.argv[1]); print("svg")' "$work/s2000-charts/s2000-ab.svg" 2>/dev/null)/$(grep -c '](s2000-charts/s2000-ab.svg)' "$work/s2000.md")" svg/1
jq '.sideA = ["artemis-thesis:43bafcee17c"] | .sideB = ["artemis-thesis:9.9.3", "artemis-thesis:8325896e0b4"]' \
    "$work/s2000/parameters.json" >"$work/e2e-parameters.json"
cp "$work/s2000/parameters.json" "$work/h3-parameters.json"
mv "$work/e2e-parameters.json" "$work/s2000/parameters.json"
python3 "$here/report.py" --out "$work/e2e.md" "$work/s2000" >/dev/null
expect "the end-to-end comparison decides H2 and gives no H3 verdict (D45)" \
    "$(grep -c '^| H2 .*no verdict' "$work/e2e.md")/$(grep -c '^| H3 .*no verdict (not the H3 pair)' "$work/e2e.md")" 0/4
mv "$work/h3-parameters.json" "$work/s2000/parameters.json"
jq '.practiceRate = 5' "$work/s2000/parameters.json" >"$work/report-parameters.json"
mv "$work/report-parameters.json" "$work/s2000/parameters.json"
python3 "$here/report.py" --out "$work/wrong-rate.md" "$work/s2000" >/dev/null
expect "H3 freshness gives no verdict for a five-POSTs-per-second run set" \
    "$(grep -c '^| H3 freshness .*| holds |$' "$work/wrong-rate.md" || true)" 0
jq '.practiceRate = 10' "$work/s2000/parameters.json" >"$work/report-parameters.json"
mv "$work/report-parameters.json" "$work/s2000/parameters.json"
fresh="$work/s2000/1-B/phase3/freshness.json"
cp "$fresh" "$work/complete-freshness.json"
jq '.achievedPostRate = null' "$work/complete-freshness.json" >"$fresh"
python3 "$here/report.py" --out "$work/unknown-rate.md" "$work/s2000" >/dev/null
expect "H3 freshness gives no verdict with missing rate evidence in a valid run" \
    "$(grep -c '^| H3 freshness .*| holds |$' "$work/unknown-rate.md" || true)" 0
cp "$work/complete-freshness.json" "$fresh"
for repetition in 1 2 3 4 5; do
    summary="$work/s2000/$repetition-B/phase2/summary.json"
    jq '.metrics["http_req_duration{type:statistics-overview,read:initial}"].values["p(95)"] = 1500
        | .metrics["http_req_duration{type:statistics-overview,read:repeated}"].values["p(95)"] = 1' "$summary" >"$work/summary.json"
    mv "$work/summary.json" "$summary"
done
python3 "$here/report.py" --out "$work/initial-slow.md" "$work/s2000" >/dev/null
expect "slow initial reads fail H3 even when repeated reads are fast" \
    "$(grep -c '^| H3 statistics-overview initial p95 (ms) | 1500.0 | 5 | < 1000 | \*\*fails\*\* |' "$work/initial-slow.md")" 1
for repetition in 1 2 3 4 5; do
    summary="$work/s2000/$repetition-B/phase2/summary.json"
    jq 'del(.metrics["http_req_duration{type:statistics-overview,read:initial}"])' "$summary" >"$work/summary.json"
    mv "$work/summary.json" "$summary"
done
python3 "$here/report.py" --out "$work/no-initial.md" "$work/s2000" >/dev/null
expect "missing initial reads cannot be replaced with repeated reads for H3" \
    "$(grep -c '^| H3 statistics-overview initial p95 .*untested: fewer than five' "$work/no-initial.md")" 1

# 10. Compose reads no ambient environment files; exported settings are recorded and frozen instead.
printf 'ARTEMIS_DB_POOL_SIZE=12\nPOSTGRES_MEMORY=2g\n' >"$work/ambient.env"
pool="$(COMPOSE_ENV_FILES="$work/ambient.env" bash -c 'here="$1"; source "$here/lib/stack.sh"; source "$here/lib/k6-limits.sh"; source "$here/lib/settings.sh"
    settings_json | jq -c "[.compose.services.artemis.environment.SPRING_DATASOURCE_HIKARI_MAXIMUMPOOLSIZE, .compose.services.postgres.mem_limit]"' _ "$here")"
expect "COMPOSE_ENV_FILES does not change the pool or the PostgreSQL memory" "$pool" '["100","3221225472"]'

# 11. run.sh refuses a used output folder, a seed without its hashes, and inputs that differ from the campaign.
mkdir -p "$work/used" && touch "$work/used/old"
status=0
"$here/run.sh" "$seed" "$work/used" 10 a b >/dev/null 2>&1 || status=$?
expect "run.sh refuses a non-empty output folder" "$status" 2
mkdir -p "$work/noseed"
cp "$seed/manifest.json" "$seed/artemis-data.tgz" "$work/noseed/"
status=0
message="$("$here/run.sh" "$work/noseed" "$work/noseed-out" 10 artemis-thesis:43bafcee17c artemis-thesis:8325896e0b4 2>&1 >/dev/null)" || status=$?
expect "run.sh refuses a seed without seed.dump" "$((status != 0))/$(grep -c 'seed file missing' <<<"$message")" 1/1
images=(artemis-thesis:43bafcee17c artemis-thesis:9.9.3 artemis-thesis:8325896e0b4
    artemis-thesis:c136826e299 artemis-thesis:24a062759c2)
campaign_inputs_of() {
    bash -c 'here="$1"; shift; source "$here/lib/inputs.sh"; source "$here/lib/stack.sh"; source "$here/lib/k6-limits.sh"
        source "$here/lib/settings.sh"; campaign_inputs "$here" "$@"' _ "$here" "$@"
}
campaign_inputs_of "$seed" "${images[@]}" >"$work/inputs.json"
jq '.settings.compose.services.artemis.environment.SPRING_DATASOURCE_HIKARI_MAXIMUMPOOLSIZE = "12"' "$work/inputs.json" >"$work/inputs-other.json"
status=0
message="$(CAMPAIGN="$work/inputs-other.json" "$here/run.sh" "$seed" "$work/campaign-out" 10 artemis-thesis:43bafcee17c artemis-thesis:8325896e0b4 2>&1 >/dev/null)" || status=$?
expect "run.sh refuses settings that differ from the campaign" "$status/$(grep -c 'differ from the campaign.*settings' <<<"$message")" 2/1

# Docker is read-only in preflight and retry tests, even if those checks regress.
mkdir -p "$work/bin"
cat >"$work/bin/docker" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
    'ps --format') exit 0 ;;
    'image inspect')
        if [[ "$3" == "${RETAGGED_IMAGE:-}" ]]; then
            shift 3
            exec "$REAL_DOCKER" image inspect artemis-thesis:8325896e0b4 "$@"
        fi
        ;;
    'compose --env-file') [[ " $* " == *' config '* ]] || exit 93 ;;
    'info --format') ;;
    *) exit 93 ;;
esac
exec "$REAL_DOCKER" "$@"
SH
chmod +x "$work/bin/docker"
docker_bin="$(command -v docker)"
jq '.images["artemis-thesis:43bafcee17c"] = .images["artemis-thesis:8325896e0b4"]' "$work/inputs.json" >"$work/inputs-wrong-base.json"
status=0
message="$(PATH="$work/bin:$PATH" REAL_DOCKER="$docker_bin" CAMPAIGN="$work/inputs-wrong-base.json" \
    "$here/run.sh" "$seed" "$work/wrong-base-out" 10 artemis-thesis:43bafcee17c artemis-thesis:8325896e0b4 2>&1 >/dev/null)" || status=$?
expect "run.sh rejects a frozen image from the wrong base before starting it" \
    "$status/$(grep -c 'thesis.commit is 8325896e0b4, expected 43bafcee17c' <<<"$message" || true)" 2/1
status=0
message="$(PATH="$work/bin:$PATH" REAL_DOCKER="$docker_bin" RETAGGED_IMAGE=artemis-thesis:9.9.3 \
    "$here/migration-check.sh" "$work/wrong-migration" 10 artemis-thesis:43bafcee17c artemis-thesis:9.9.3 artemis-thesis:8325896e0b4 2>&1 >/dev/null)" || status=$?
expect "migration-check.sh rejects a migration image from the wrong base" \
    "$status/$(grep -c 'thesis.commit is 8325896e0b4, expected 9.9.3' <<<"$message" || true)" 2/1

# 12. night.sh: pilot settings refused; a copied pilot is not a finished scale; only a finished campaign set is skipped.
status=0
ROUNDS=1 NIGHT_CHECK=1 RESULTS="$work/night" "$here/night.sh" e2e 100 >/dev/null 2>&1 || status=$?
expect "night.sh refuses a settings override" "$status" 1
if committed; then
    mkdir -p "$work/night/e2e"
    cp "$work/inputs.json" "$work/night/inputs.json"
    cp -R "$final/e2e/s2000" "$work/night/e2e/s2000"
    status=0
    message="$(NIGHT_CHECK=1 SEED_FOLDER="$seed" RESULTS="$work/night" "$here/night.sh" e2e 2000 2>&1)" || status=$?
    expect "a copied one-run pilot with complete.json is not a finished scale" "$status/$(grep -c 's2000: not finished' <<<"$message")" 1/1
    jq --slurpfile f "$work/night/inputs.json" --arg sha "$(shasum -a 256 "$work/night/inputs.json" | cut -d' ' -f1)" '
        .campaign = {sha256: $sha} | .repetitions = 5 | .toolRevision = $f[0].toolRevision
        | .settings = $f[0].settings | .seedHashes = $f[0].seed | .images = $f[0].images
        ' "$final/e2e/s2000/parameters.json" >"$work/night/e2e/s2000/parameters.json"
    echo '{"repetitions":5,"validA":5,"failedA":0,"validB":3,"failedB":2,"invalid":[]}' >"$work/night/e2e/s2000/complete.json"
    status=0
    NIGHT_CHECK=1 SEED_FOLDER="$seed" RESULTS="$work/night" "$here/night.sh" e2e 2000 >/dev/null 2>&1 || status=$?
    expect "server failures cannot authorize a campaign skip" "$status" 1
    echo '{"repetitions":5,"validA":5,"validB":5,"invalid":[]}' >"$work/night/e2e/s2000/complete.json"
    status=0
    NIGHT_CHECK=1 SEED_FOLDER="$seed" RESULTS="$work/night" "$here/night.sh" e2e 2000 >/dev/null 2>&1 || status=$?
    expect "an inflated completion marker cannot replace actual run records" "$status" 1
    for repetition in 1 2 3 4 5; do
        for side in A B; do
            mkdir -p "$work/night/e2e/s2000/$repetition-$side"
            jq --argjson repetition "$repetition" --arg side "$side" --slurpfile f "$work/night/inputs.json" '
                .repetition = $repetition | .side = $side | .outcome = "valid"
                | .runningImageId = $f[0].images[.measured] | .plannedImageId = .runningImageId
                ' "$final/e2e/s2000/1-$side/run.json" >"$work/night/e2e/s2000/$repetition-$side/run.json"
        done
    done
    status=0
    message="$(NIGHT_CHECK=1 SEED_FOLDER="$seed" RESULTS="$work/night" "$here/night.sh" e2e 2000 2>&1)" || status=$?
    expect "five valid runs matching campaign inputs authorize a skip" "$status/$(grep -c 's2000: finished' <<<"$message")" 0/1
    cp "$work/night/e2e/s2000/parameters.json" "$work/unchanged.json"
    jq '.settings.run.rounds = 1' "$work/unchanged.json" >"$work/night/e2e/s2000/parameters.json"
    status=0
    NIGHT_CHECK=1 SEED_FOLDER="$seed" RESULTS="$work/night" "$here/night.sh" e2e 2000 >/dev/null 2>&1 || status=$?
    expect "a matching campaign hash does not authorize changed settings" "$status" 1
    cp "$work/unchanged.json" "$work/night/e2e/s2000/parameters.json"
    status=0
    NIGHT_CHECK=1 SEED_FOLDER="$seed" RESULTS="$work/night" "$here/night.sh" e2e 1000 2000 >/dev/null 2>&1 || status=$?
    expect "night.sh exits 1 if a requested scale is not finished" "$status" 1
    rm "$work/night/e2e/s2000/complete.json"
    echo '{"failedB":1}' >"$work/night/e2e/s2000/failure.json"
    status=0
    message="$(PATH="$work/bin:$PATH" REAL_DOCKER="$docker_bin" NIGHT_AWAKE=1 SEED_FOLDER="$seed" RESULTS="$work/night" \
        "$here/night.sh" e2e 2000 2>&1)" || status=$?
    expect "matching campaign failures suppress automatic retry" "$status/$(grep -c 'no automatic retry' <<<"$message")" 1/1
    jq '.settings.run.rounds = 1' "$work/unchanged.json" >"$work/night/e2e/s2000/parameters.json"
    status=0
    message="$(PATH="$work/bin:$PATH" REAL_DOCKER="$docker_bin" NIGHT_AWAKE=1 SEED_FOLDER="$seed" RESULTS="$work/night" \
        "$here/night.sh" e2e 2000 2>&1)" || status=$?
    expect "a foreign failure is archived rather than blocking a campaign" \
        "$status/$(grep -c 'earlier attempt moved' <<<"$message")/$(grep -c 'no automatic retry' <<<"$message" || true)" 1/1/0
    jq '.images["artemis-thesis:9.9.3"] = "sha256:other"' "$work/inputs.json" >"$work/night/inputs.json"
    status=0
    message="$(NIGHT_CHECK=1 SEED_FOLDER="$seed" RESULTS="$work/night" "$here/night.sh" e2e 2000 2>&1)" || status=$?
    expect "night.sh refuses changed inputs" "$status/$(grep -c 'inputs differ' <<<"$message")" 1/1
else
    pass "night.sh campaign checks (skipped: track-b/ has uncommitted changes, which night.sh refuses first)"
fi

# 13. freshness.mjs: every expected tutor must be observed; unseen values are censored, not dropped.
freshness_fixture() {
    local folder="$1" tutors_seen="$2" last_shown="$3"
    mkdir -p "$folder"
    echo '{"submissions":3,"tutors":2,"rate":10,"deadline":1800000060000}' >"$folder/phase3.json"
    node -e '
        const [tutorsSeen, lastShown] = process.argv.slice(1).map(Number);
        const point = (metric, ms, value, tags = {}) => JSON.stringify({ type: "Point", metric, data: { time: new Date(ms).toISOString(), value, tags } });
        const base = 1800000000000;
        const lines = [];
        for (let t = 0; t < tutorsSeen; t++) {
            lines.push(point("phase3_subscribed", base, 1, { tutor: String(t) }), point("phase3_seen", base, 0, { tutor: String(t) }));
            lines.push(point("phase3_messages", base + 500, 1, { tutor: String(t) }), point("phase3_seen", base + 500, t === 0 ? lastShown : 3, { tutor: String(t) }));
        }
        for (let n = 0; n < 3; n++) {
            lines.push(point("phase3_practice_sent", base + 100 + n * 100, 1), point("phase3_practice_answered", base + 120 + n * 100, 1));
        }
        process.stdout.write(lines.join("\n") + "\n");
    ' "$tutors_seen" "$last_shown" | gzip >"$folder/raw.json.gz"
}
freshness_fixture "$work/fresh-missing" 1 3
status=0
node "$here/freshness.mjs" "$work/fresh-missing" >/dev/null 2>&1 || status=$?
expect "an absent tutor makes the measurement incomplete" "$status/$(jq '.errors | length' "$work/fresh-missing/freshness.json")" 1/3
freshness_fixture "$work/fresh-censored" 2 2
node "$here/freshness.mjs" "$work/fresh-censored" >/dev/null
expect "an unseen value is censored, the run stays complete" "$(jq -c '[.censored, .complete, .values]' "$work/fresh-censored/freshness.json")" '[1,true,6]'
expect "the censored value enters the maximum" "$(jq .maxMillis "$work/fresh-censored/freshness.json")" 59680
mkdir "$work/fresh-no-sends" "$work/fresh-after-deadline"
for fixture in fresh-no-sends fresh-after-deadline; do
    cp "$work/fresh-censored/phase3.json" "$work/$fixture/"
done
gzip -dc "$work/fresh-censored/raw.json.gz" | jq -c 'select(.metric != "phase3_practice_sent")' | gzip >"$work/fresh-no-sends/raw.json.gz"
status=0
node "$here/freshness.mjs" "$work/fresh-no-sends" >/dev/null 2>&1 || status=$?
expect "missing POST timestamps invalidate freshness despite complete responses" \
    "$status/$(jq -r .complete "$work/fresh-no-sends/freshness.json")" 1/false
{
    gzip -dc "$work/fresh-censored/raw.json.gz"
    node -p 'JSON.stringify({type:"Point", metric:"phase3_seen", data:{time:new Date(1800000060010).toISOString(), value:3, tags:{tutor:"0"}}})'
} | gzip >"$work/fresh-after-deadline/raw.json.gz"
node "$here/freshness.mjs" "$work/fresh-after-deadline" >/dev/null
expect "statistics first visible after the deadline remain censored" "$(jq .censored "$work/fresh-after-deadline/freshness.json")" 1

if ((failures > 0)); then
    echo "$failures checks failed"
    exit 1
fi
echo "all checks passed"
