#!/usr/bin/env bash
# Checks that the Docker engine can hold the Track B containers (D36) and records the host facts.
#
# Usage: check-host.sh [<facts.json>]
#
# The Artemis and PostgreSQL limits come from compose.yml with the same variables (ARTEMIS_CPUSET, ARTEMIS_MEMORY,
# POSTGRES_CPUSET, POSTGRES_MEMORY). The load generator gets K6_CPUSET (default 10-13) and K6_MEMORY (default 3g), and the
# Docker VM itself VM_RESERVE (default 1g). Writes the facts as JSON to the given file, else to stdout.
#
# Exit status 1 if a CPU set names a CPU the engine does not have, two CPU sets overlap, or the memory limits plus the
# reserve exceed the engine's memory: limits that do not fit make the engine swap or kill a container during a run.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
source "$here/lib/k6-limits.sh"
source "$here/lib/stack.sh"
k6_cpuset="$K6_CPUSET"
k6_memory="$K6_MEMORY"
vm_reserve="${VM_RESERVE:-1g}"

# "6g", "512m", "2048k" or bytes -> bytes.
bytes() {
    local value="${1,,}"
    case "$value" in
        *g) echo $((${value%g} * 1024 * 1024 * 1024)) ;;
        *m) echo $((${value%m} * 1024 * 1024)) ;;
        *k) echo $((${value%k} * 1024)) ;;
        *) echo "$value" ;;
    esac
}

# "0-5,8" -> "0 1 2 3 4 5 8".
cpus() {
    local part out=()
    IFS=',' read -ra parts <<<"$1"
    for part in "${parts[@]}"; do
        if [[ "$part" == *-* ]]; then
            out+=($(seq "${part%-*}" "${part#*-}"))
        else
            out+=("$part")
        fi
    done
    echo "${out[@]}"
}

config="$(ARTEMIS_IMAGE=check compose_cli -f "$here/compose.yml" config --format json)"
artemis_cpuset="$(jq -r '.services.artemis.cpuset' <<<"$config")"
postgres_cpuset="$(jq -r '.services.postgres.cpuset' <<<"$config")"
artemis_memory="$(jq -r '.services.artemis.mem_limit' <<<"$config")"
postgres_memory="$(jq -r '.services.postgres.mem_limit' <<<"$config")"
engine_cpus="$(docker info --format '{{.NCPU}}')"
engine_memory="$(docker info --format '{{.MemTotal}}')"
needed_memory=$((artemis_memory + postgres_memory + $(bytes "$k6_memory") + $(bytes "$vm_reserve")))

problems=()
declare -A owner=()
for entry in "artemis:$artemis_cpuset" "postgres:$postgres_cpuset" "k6:$k6_cpuset"; do
    name="${entry%%:*}"
    for cpu in $(cpus "${entry#*:}"); do
        if ((cpu >= engine_cpus)); then
            problems+=("$name uses CPU $cpu, but the engine has CPUs 0-$((engine_cpus - 1))")
        elif [[ -n "${owner[$cpu]:-}" ]]; then
            problems+=("CPU $cpu is in the sets of ${owner[$cpu]} and $name")
        else
            owner[$cpu]="$name"
        fi
    done
done
if ((needed_memory > engine_memory)); then
    problems+=("the limits need $((needed_memory / 1048576)) MiB (Artemis, PostgreSQL, k6, VM reserve), the engine has $((engine_memory / 1048576)) MiB")
fi

if [[ "$(uname -s)" == Darwin ]]; then
    cpu_model="$(sysctl -n machdep.cpu.brand_string)"
    host_memory="$(sysctl -n hw.memsize)"
else
    cpu_model="$(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ *//')"
    host_memory=$(($(grep -m1 MemTotal /proc/meminfo | awk '{print $2}') * 1024))
fi

facts="$(jq -n \
    --arg checkedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg kernel "$(uname -srm)" \
    --arg cpuModel "$cpu_model" \
    --argjson hostCpus "$(getconf _NPROCESSORS_ONLN)" \
    --argjson hostMemory "$host_memory" \
    --arg engine "$(docker info --format '{{.OperatingSystem}} {{.ServerVersion}} {{.Architecture}}')" \
    --argjson engineCpus "$engine_cpus" \
    --argjson engineMemory "$engine_memory" \
    --arg artemisCpuset "$artemis_cpuset" --argjson artemisMemory "$artemis_memory" \
    --arg postgresCpuset "$postgres_cpuset" --argjson postgresMemory "$postgres_memory" \
    --arg k6Cpuset "$k6_cpuset" --argjson k6Memory "$(bytes "$k6_memory")" \
    --argjson vmReserve "$(bytes "$vm_reserve")" \
    --argjson neededMemory "$needed_memory" \
    '$ARGS.named + {problems: $ARGS.positional}' --args "${problems[@]}")"
if (($# > 0)); then
    echo "$facts" >"$1"
else
    echo "$facts"
fi

if ((${#problems[@]} > 0)); then
    printf 'check-host: %s\n' "${problems[@]}" >&2
    exit 1
fi
echo "check-host: the engine can hold the limits ($((needed_memory / 1048576)) of $((engine_memory / 1048576)) MiB)" >&2
