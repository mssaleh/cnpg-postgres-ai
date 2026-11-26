#!/usr/bin/env bash

set -euo pipefail

source_image="${1:?source image digest reference is required}"
destination="${2:?destination repository is required}"
shift 2
: "${1:?at least one tag is required}"

digest="${source_image##*@}"
args=()
for tag in "$@"; do
  args+=(--tag "${destination}:${tag}")
done
docker buildx imagetools create "${args[@]}" "${source_image}"

for tag in "$@"; do
  ref="${destination}:${tag}"
  actual="$(docker buildx imagetools inspect --format '{{.Manifest.Digest}}' "${ref}")"
  if [ "${actual}" != "${digest}" ]; then
    echo "${ref} resolved to ${actual}, expected ${digest}" >&2
    exit 1
  fi
done
