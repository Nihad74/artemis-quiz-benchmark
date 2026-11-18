# shellcheck shell=bash
# The inputs of a Track B measurement that must not change between run sets of one result collection (D40): the seed
# files and the server images. Sourced by run.sh (recorded in parameters.json) and night.sh (enforced across nights).

# sha256 <file>: the SHA-256 of a file (sha256sum on Linux, shasum on macOS).
sha256() {
    if command -v sha256sum >/dev/null; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

# seed_hashes <seed-folder>: {"manifest.json": ..., "seed.dump": ..., "artemis-data.tgz": ...}. Fails (status 1, no output)
# if a file is missing or has no SHA-256; call it in an assignment, so that set -e stops the caller.
seed_hashes() {
    local file hash args=()
    for file in manifest.json seed.dump artemis-data.tgz; do
        if [[ ! -f "$1/$file" ]]; then
            echo "seed file missing: $1/$file" >&2
            return 1
        fi
        hash="$(sha256 "$1/$file")"
        if [[ ! "$hash" =~ ^[0-9a-f]{64}$ ]]; then
            echo "no SHA-256 for $1/$file" >&2
            return 1
        fi
        args+=(--arg "$file" "$hash")
    done
    jq -n "${args[@]}" '$ARGS.named'
}

# campaign_inputs <tools-folder> <seed-folder> <image>...: the inputs that night.sh freezes in inputs.json: tool
# revision, seed hashes, image ids, effective settings (settings_json, lib/settings.sh must be sourced), Docker engine.
campaign_inputs() {
    local tools="$1" seed="$2" hashes settings
    shift 2
    hashes="$(seed_hashes "$seed")" || return 1
    settings="$(settings_json)" || return 1
    jq -n --arg toolRevision "$(git -C "$tools" rev-parse HEAD)" --argjson seed "$hashes" \
        --argjson images "$(image_ids "$@")" --argjson settings "$settings" \
        --argjson engine "$(docker info --format '{{json .}}' | jq '{version: .ServerVersion, cpus: .NCPU, memory: .MemTotal}')" \
        '$ARGS.named'
}

# image_ids <image>...: {"<image>": "<id>", ...}; an empty id for a missing image.
image_ids() {
    local image args=()
    for image in "$@"; do
        args+=(--arg "$image" "$(docker image inspect "$image" --format '{{.Id}}' 2>/dev/null || true)")
    done
    jq -n "${args[@]}" '$ARGS.named'
}
