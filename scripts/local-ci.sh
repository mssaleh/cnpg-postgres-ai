#!/usr/bin/env bash
# Build and verify, check sources with --check, or test an image with --verify-only.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

VERIFY_ONLY=false
CHECK_ONLY=false
if [ "${1:-}" = "--verify-only" ]; then
  VERIFY_ONLY=true
  shift
  : "${1:?--verify-only requires an image}"
elif [ "${1:-}" = "--check" ]; then
  CHECK_ONLY=true
  shift
fi

IMAGE="${1:-cnpg-postgres-ai:local-ci}"
PLATFORM="${PLATFORM:-linux/amd64}"
CACHE_BUST="${CACHE_BUST:-$(date -u +%Y%m%d%H%M%S)}"
UPGRADE_BASE=""

git diff --check
git diff --cached --check
bash -n scripts/parity-check.sh scripts/upgrade-parity-check.sh scripts/local-ci.sh
docker run --rm -v "${ROOT_DIR}:/repo:ro" -w /repo --entrypoint sh \
  rhysd/actionlint:latest -c 'set -eu; actionlint; shellcheck scripts/*.sh'

if "${CHECK_ONLY}"; then
  exit 0
fi

# Keep the baseline's local image ID even if its registry tag moves.
if [ -n "${UPGRADE_FROM_IMAGE:-}" ]; then
  docker pull --platform "${PLATFORM}" "${UPGRADE_FROM_IMAGE}"
  UPGRADE_BASE="$(docker image inspect --format '{{.Id}}' "${UPGRADE_FROM_IMAGE}")"
fi

if "${VERIFY_ONLY}"; then
  if ! docker image inspect "${IMAGE}" >/dev/null 2>&1; then
    docker pull --platform "${PLATFORM}" "${IMAGE}"
  fi
else
  docker buildx build \
    --pull \
    --platform "${PLATFORM}" \
    --load \
    --tag "${IMAGE}" \
    --build-arg "CACHE_BUST=${CACHE_BUST}" \
    --build-arg "PGVECTOR_VERSION=${PGVECTOR_VERSION:-}" \
    --build-arg "POSTGIS_VERSION=${POSTGIS_VERSION:-}" \
    --build-arg "TIMESCALEDB_VERSION=${TIMESCALEDB_VERSION:-}" \
    --build-arg "TIMESCALEDB_LINE=${TIMESCALEDB_LINE:-}" \
    --build-arg "PGVECTORSCALE_VERSION=${PGVECTORSCALE_VERSION:-}" \
    --build-arg "AGE_VERSION=${AGE_VERSION:-}" \
    .
fi

./scripts/parity-check.sh "${IMAGE}"

if [ -n "${UPGRADE_BASE}" ]; then
  ./scripts/upgrade-parity-check.sh "${UPGRADE_BASE}" "${IMAGE}"
fi
