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

# seed_hashes <seed-folder>: {"manifest.json": ..., "seed.dump": ..., "artemis-data.tgz": ...}.
seed_hashes() {
    local file args=()
    for file in manifest.json seed.dump artemis-data.tgz; do
        args+=(--arg "$file" "$(sha256 "$1/$file")")
    done
    jq -n "${args[@]}" '$ARGS.named'
}

# image_ids <image>...: {"<image>": "<id>", ...}; an empty id for a missing image.
image_ids() {
    local image args=()
    for image in "$@"; do
        args+=(--arg "$image" "$(docker image inspect "$image" --format '{{.Id}}' 2>/dev/null || true)")
    done
    jq -n "${args[@]}" '$ARGS.named'
}
