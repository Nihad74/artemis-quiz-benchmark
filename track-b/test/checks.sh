#!/usr/bin/env bash
# Regression checks of the Track B run validity, completion, input freeze, and freshness measurement. No server is
# started; the checks use fixtures and the semantics of the pilot of 2026-11-17 at 2000 students, whose run 1-A missed one
# submission. Needs Bash 5, Node 24, jq, Docker (night.sh reads image ids), and the pilot folder
# (PILOT, default ~/Documents/thesis-benchmark-results/track-b/pilot-mac-2026-11-17).
#
# Usage: test/checks.sh
set -euo pipefail

here="$(cd "$(dirname "$0")/.." && pwd)"
pilot="${PILOT:-$HOME/Documents/thesis-benchmark-results/track-b/pilot-mac-2026-11-17}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0
pass() { printf 'ok   %s\n' "$1"; }
fail() {
    printf 'FAIL %s\n' "$1"
    failures=$((failures + 1))
}
expect() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (got '$2', expected '$3')"; fi; }

# A run folder for judge.mjs: valid workload and provenance, with the semantics of a pilot run.
make_run() {
    local out="$1" name="$2" semantics="$3" exit_status="${4:-0}"
    mkdir -p "$out/$name"
    cp "$semantics" "$out/$name/semantics.json"
    echo '[{"image":"artemis-thesis:x","id":"sha256:abc","head":"83f5370b5d7"}]' >"$out/$name/images.json"
    echo '{"version":"9.9","commit":"83f5370b5d7cee936e6e961d4a5420743144c2b8"}' >"$out/$name/info.json"
    echo '2026-11-17T15:50:00.000Z INFO Thesis benchmark: calculateAllResults quiz=4 participations=2000 durationMillis=1000' >"$out/$name/evaluation.txt"
    jq -n --arg side "${name#*-}" --argjson phase1Exit "$exit_status" '{repetition: 1, side: $side, measured: "artemis-thesis:x",
        runningImageId: "sha256:abc", warmUpPhase1Exit: 0, phase1Exit: $phase1Exit, phase2Exit: 0, semanticsExit: 0,
        evaluated: true, phase3Run: false, controlRun: false}' >"$out/$name/exits.json"
}

new_set() {
    mkdir -p "$1"
    jq -n --arg seed "$pilot/seed-2000" '{seed: $seed, students: 2000}' >"$1/parameters.json"
}

good="$pilot/s2000/1-B/semantics.json"
bad="$pilot/s2000/1-A/semantics.json"

# 1. A failed first run never becomes the reference; the first valid run does.
out="$work/reference"
new_set "$out"
make_run "$out" 1-A "$bad" 99
make_run "$out" 1-B "$good"
node "$here/judge.mjs" run "$out" "$out/1-A" >/dev/null
expect "failed 1-A is invalid" "$(jq .valid "$out/1-A/run.json")" false
expect "failed 1-A sets no reference" "$([[ -e "$out/reference.json" ]] && echo yes || echo no)" no
expect "failed 1-A is not compared" "$(jq .semanticsEqual "$out/1-A/run.json")" null
node "$here/judge.mjs" run "$out" "$out/1-B" >/dev/null
expect "valid 1-B becomes the reference" "$(jq -r .run "$out/reference.json")" 1-B
expect "valid 1-B is valid" "$(jq .valid "$out/1-B/run.json")" true

# 2. Wrong results fail the independent check even with passing thresholds, so they cannot become the reference.
out="$work/expected"
new_set "$out"
make_run "$out" 1-A "$bad" 0
node "$here/judge.mjs" run "$out" "$out/1-A" >/dev/null
expect "wrong scores with passing k6 are invalid" "$(jq .expectedResults "$out/1-A/run.json")" false
expect "wrong scores set no reference" "$([[ -e "$out/reference.json" ]] && echo yes || echo no)" no

# 3. A later run must equal the reference.
out="$work/compare"
new_set "$out"
make_run "$out" 1-A "$good"
node "$here/judge.mjs" run "$out" "$out/1-A" >/dev/null
jq '.textExercise.submittedTexts = ["changed"]' "$good" >"$work/changed.json"
make_run "$out" 1-B "$work/changed.json"
node "$here/judge.mjs" run "$out" "$out/1-B" >/dev/null
expect "semantics unlike the reference are invalid" "$(jq .semanticsEqual "$out/1-B/run.json")" false

# 4. Provenance: a container with another image is invalid.
out="$work/provenance"
new_set "$out"
make_run "$out" 1-A "$good"
jq '.runningImageId = "sha256:other"' "$out/1-A/exits.json" >"$work/exits.json" && mv "$work/exits.json" "$out/1-A/exits.json"
node "$here/judge.mjs" run "$out" "$out/1-A" >/dev/null
expect "another running image is invalid" "$(jq .valid "$out/1-A/run.json")" false

# 5. Completion only with enough valid runs per side.
out="$work/complete"
new_set "$out"
make_run "$out" 1-A "$good"
make_run "$out" 1-B "$good"
node "$here/judge.mjs" run "$out" "$out/1-A" >/dev/null
node "$here/judge.mjs" run "$out" "$out/1-B" >/dev/null
status=0
node "$here/judge.mjs" complete "$out" 2 >/dev/null || status=$?
expect "an under-replicated set is not complete" "$status/$([[ -e "$out/complete.json" ]] && echo yes || echo no)" 1/no
node "$here/judge.mjs" complete "$out" 1 >/dev/null
expect "a set with every run valid is complete" "$(jq .validA "$out/complete.json")" 1

# 5b. A complete Phase 3 run whose freshness exceeds the H3 bound stays valid: it is evidence against H3 (D42, D43).
#     An incomplete freshness measurement makes the run invalid.
phase3_pilot="$(dirname "$pilot")/pilot-mac-2026-11-18-control/s2000/1-B"
out="$work/h3"
mkdir -p "$out"
jq -n --arg seed "$(dirname "$pilot")/seed-2000-2026-11-18" '{seed: $seed, students: 2000}' >"$out/parameters.json"
for name in 1-A 1-B; do
    make_run "$out" "$name" "$phase3_pilot/semantics.json"
    jq '.phase3Run = true | .phase3Exit = 0 | .freshnessExit = 0' "$out/$name/exits.json" >"$work/exits.json" && mv "$work/exits.json" "$out/$name/exits.json"
    mkdir -p "$out/$name/phase3"
    cp "$phase3_pilot/phase3/phase3.json" "$out/$name/phase3/"
done
echo '{"complete":true,"errors":[],"p95Millis":3500,"p95Censored":true}' >"$out/1-A/phase3/freshness.json"
echo '{"complete":false,"errors":["tutor 3 never subscribed"]}' >"$out/1-B/phase3/freshness.json"
node "$here/judge.mjs" run "$out" "$out/1-A" >/dev/null
node "$here/judge.mjs" run "$out" "$out/1-B" >/dev/null
expect "a complete run above the H3 bound stays valid" "$(jq .valid "$out/1-A/run.json")" true
expect "an incomplete freshness measurement is invalid" "$(jq .valid "$out/1-B/run.json")" false

# 6. run.sh refuses a used output folder.
mkdir -p "$work/used" && touch "$work/used/old"
status=0
"$here/run.sh" "$pilot/seed-2000" "$work/used" 10 a b >/dev/null 2>&1 || status=$?
expect "run.sh refuses a non-empty output folder" "$status" 2

# 7. night.sh refuses pilot settings and changed inputs.
status=0
ROUNDS=1 NIGHT_AWAKE=1 RESULTS="$work/night" "$here/night.sh" e2e 100 >/dev/null 2>&1 || status=$?
expect "night.sh refuses a settings override" "$status" 1
mkdir -p "$work/seed" "$work/night"
for file in manifest.json seed.dump artemis-data.tgz; do echo "$file" >"$work/seed/$file"; done
echo '{"toolRevision":"x","seed":{},"images":{},"engine":{}}' >"$work/night/inputs.json"
status=0
message="$(SEED_FOLDER="$work/seed" NIGHT_AWAKE=1 RESULTS="$work/night" "$here/night.sh" e2e 100 2>&1 >/dev/null)" || status=$?
if git -C "$here" diff --quiet HEAD -- .; then
    expect "night.sh refuses changed inputs" "$status/$(grep -c 'inputs differ' <<<"$message")" 1/1
else
    pass "night.sh changed inputs (skipped: track-b/ has uncommitted changes, which night.sh refuses first)"
fi

# 8. freshness.mjs: every expected tutor must be observed; unseen values are censored, not dropped.
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

if ((failures > 0)); then
    echo "$failures checks failed"
    exit 1
fi
echo "all checks passed"
