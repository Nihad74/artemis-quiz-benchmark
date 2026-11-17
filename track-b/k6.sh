#!/usr/bin/env bash
# Runs a Track B k6 script (D35) in the pinned k6 image, inside the Docker network of a compose project, on its own CPUs
# with a memory limit and no swap (D36).
#
# Usage: k6.sh <project> <script> <run-folder> [k6 run options...]
#   project     the compose project of the server (docker compose -p)
#   script      a script in this folder, for example phase1.js
#   run-folder  input and output of the run: the script reads manifest.json and sessions.json there and writes
#               summary.json; k6.sh adds raw.json.gz (every sample) and k6.txt (version and image)
# The server is http://artemis:8080 inside the network, so no request passes the host port forwarding. Exit status: the
# exit status of k6; 99 means a threshold failed and the run is invalid.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
source "$here/lib/k6-limits.sh"
project="$1"
script="$2"
run="$(cd "$3" && pwd)"
shift 3
image="docker.io/grafana/k6:2.4.0@sha256:d41bb79cd8de5a7ad619b53570e3712633e8bff0937010a5c6c57a4747e7a276"

docker run --rm "$image" version >"$run/k6.txt"
echo "image $image cpuset $K6_CPUSET memory $K6_MEMORY" >>"$run/k6.txt"

# Every VU keeps its own connection; 2000 VUs need more than the default 1024 file descriptors.
exec docker run --rm \
    --network "${project}_default" \
    --cpuset-cpus "$K6_CPUSET" --memory "$K6_MEMORY" --memory-swap "$K6_MEMORY" \
    --ulimit nofile=65536:65536 \
    --user "$(id -u):$(id -g)" \
    -v "$here:/scripts:ro" -v "$run:/data" \
    "$image" run --quiet -e SERVER=http://artemis:8080 -e OUT=/data --out json=/data/raw.json.gz "$@" "/scripts/$script"
