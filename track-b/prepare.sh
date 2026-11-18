#!/usr/bin/env bash
# Creates the worktree of every Track B commit and builds its server image (build-image.sh), on any host.
#
# Usage: prepare.sh <worktree-root> [<commit>...]
#   worktree-root  folder for one worktree per commit, <worktree-root>/<commit> (created if missing)
#   commit         a commit with a patch in patches/ (11 characters, for example 43bafcee17c) or a release in releases;
#                  default: all of them
#
# The measured commits get their D17 timer from patches/<commit>.patch, on a detached worktree of the commit; the
# releases (migration steps only) are built without a change. The script runs in the repository that contains it,
# which needs the remote `origin` (ls1intum/Artemis): it fetches develop (build-image.sh tags by the merge base with
# origin/develop) and the release tags. The patch commits get a fixed committer and the author date, so the worktree
# HEAD is the same on every host.
#
# It can run again: an existing worktree is reused if it holds the commit and its patch and has no uncommitted changes,
# else the script stops. An existing image is kept if its label thesis.head names a commit of this repository with the
# same base and the same patch; delete the image to build it again.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
releases=(9.9.3)

if (($# < 1)); then
    sed -n '3,9p' "$0" >&2
    exit 2
fi
mkdir -p "$1"
root="$(cd "$1" && pwd)"
shift
if (($# > 0)); then
    commits=("$@")
else
    commits=()
    for patch in "$here"/patches/*.patch; do
        commits+=("$(basename "$patch" .patch)")
    done
    commits+=("${releases[@]}")
fi

git() { command git -C "$here" "$@"; }
log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*"; }

# The patch of <commit>, or nothing for a release; stops for an unknown commit.
patch_of() {
    local commit="$1" release
    if [[ -f "$here/patches/$commit.patch" ]]; then
        echo "$here/patches/$commit.patch"
        return
    fi
    for release in "${releases[@]}"; do
        [[ "$commit" == "$release" ]] && return
    done
    echo "no patch in $here/patches and no release: $commit" >&2
    exit 1
}

patch_id() { command git patch-id --stable | cut -d' ' -f1; }

# matches <head> <base> <patch>: whether commit <head> is <base>, or <base> plus the change of <patch>.
matches() {
    local head="$1" base="$2" patch="$3"
    git cat-file -e "$head^{commit}" 2>/dev/null || return 1
    if [[ -z "$patch" ]]; then
        [[ "$(git rev-parse "$head")" == "$base" ]]
    else
        [[ "$(git rev-parse "$head^")" == "$base" ]] && [[ "$(git diff "$head^" "$head" | patch_id)" == "$(patch_id <"$patch")" ]]
    fi
}

for commit in "${commits[@]}"; do
    patch_of "$commit" >/dev/null
done
log "fetching develop and ${releases[*]} from origin"
git fetch --quiet --no-tags origin develop
for release in "${releases[@]}"; do
    git fetch --quiet --no-tags origin tag "$release"
done

for commit in "${commits[@]}"; do
    patch="$(patch_of "$commit")"
    base="$(git rev-parse --verify --quiet "$commit^{commit}")" || {
        echo "$commit is not in develop or the release tags of origin" >&2
        exit 1
    }
    dir="$root/$commit"

    if [[ -e "$dir" ]]; then
        if ! head="$(command git -C "$dir" rev-parse HEAD 2>/dev/null)" || ! matches "$head" "$base" "$patch"; then
            echo "$dir exists but is not $commit${patch:+ with its patch}; remove it (git worktree remove)" >&2
            exit 1
        fi
        log "$commit: worktree $dir exists"
    else
        git worktree add --quiet --detach "$dir" "$base"
        if [[ -n "$patch" ]]; then
            GIT_COMMITTER_NAME="Track B prepare.sh" GIT_COMMITTER_EMAIL="track-b@thesis.invalid" \
                command git -C "$dir" am --quiet --committer-date-is-author-date "$patch"
        fi
        log "$commit: worktree $dir at $(command git -C "$dir" rev-parse --short=11 HEAD)"
    fi
    if [[ -n "$(command git -C "$dir" status --porcelain --untracked-files=no)" ]]; then
        echo "$dir has uncommitted changes" >&2
        exit 1
    fi

    image="artemis-thesis:$commit"
    built="$(docker image inspect "$image" --format '{{index .Config.Labels "thesis.head"}}' 2>/dev/null || true)"
    if [[ -n "$built" ]] && matches "$built" "$base" "$patch"; then
        log "$commit: image $image exists (thesis.head $built)"
        continue
    fi
    log "$commit: building $image"
    "$here/build-image.sh" "$dir"
done
