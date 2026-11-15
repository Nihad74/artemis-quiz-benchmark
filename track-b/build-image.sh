#!/usr/bin/env bash
# Builds the Track B server image of one commit: artemis-thesis:<commit>[-<suffix>].
#
# Usage: build-image.sh <worktree> [suffix]
#   worktree  checkout of the commit (its thesis branch, with the D17 timer for measurement images)
#   suffix    appended to the tag, for example "plain" for an image of the unchanged commit
# The measured commit is the merge base with origin/develop, as in Track A, so thesis-only commits on the branch do not
# change the tag. A checkout of a release tag (for example 9.9.3, a step of the official migration path) is tagged with
# the release. A dirty worktree is refused: the image must be reproducible from a commit.
set -euo pipefail

worktree="$(cd "$1" && pwd)"
suffix="${2:-}"
here="$(cd "$(dirname "$0")" && pwd)"

if [[ -n "$(git -C "$worktree" status --porcelain --untracked-files=no)" ]]; then
    echo "worktree $worktree has uncommitted changes" >&2
    exit 1
fi
if release="$(git -C "$worktree" describe --exact-match --tags HEAD 2>/dev/null)"; then
    commit="$release"
else
    commit="$(git -C "$worktree" merge-base HEAD origin/develop | cut -c1-11)"
fi
head="$(git -C "$worktree" rev-parse --short=11 HEAD)"
tag="artemis-thesis:${commit}${suffix:+-$suffix}"

(cd "$worktree" && rm -rf build/libs && ./gradlew -Pprod -Pwar bootWar -x webapp --no-daemon --console=plain -q)
context="$(mktemp -d)"
trap 'rm -rf "$context"' EXIT
cp "$worktree"/build/libs/Artemis-*.war "$context/Artemis.war"

docker build -q -f "$here/artemis.Dockerfile" --build-arg COMMIT="$commit" \
    --label thesis.head="$head" -t "$tag" "$context" >/dev/null
echo "$tag $(docker image inspect "$tag" --format '{{.Id}}')"
