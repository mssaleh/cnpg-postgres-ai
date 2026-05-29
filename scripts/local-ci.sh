#!/usr/bin/env bash
# Local CI preflight used by humans and GitHub Actions.
#
# It intentionally uses Buildx, pulls the current base image, builds the
# same linux/amd64 image shape as CI, then runs the parity smoke test that
# creates every bundled extension and exercises AGE.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

IMAGE="${1:-cnpg-postgres-ai:local-ci}"
PLATFORM="${PLATFORM:-linux/amd64}"
CACHE_BUST="${CACHE_BUST:-$(date -u +%Y%m%d%H%M%S)}"

docker buildx build \
  --pull \
  --platform "${PLATFORM}" \
  --load \
  --tag "${IMAGE}" \
  --build-arg "CACHE_BUST=${CACHE_BUST}" \
  --build-arg "PGVECTOR_VERSION=${PGVECTOR_VERSION:-}" \
  --build-arg "POSTGIS_VERSION=${POSTGIS_VERSION:-}" \
  --build-arg "TIMESCALEDB_VERSION=${TIMESCALEDB_VERSION:-}" \
  --build-arg "PGVECTORSCALE_VERSION=${PGVECTORSCALE_VERSION:-}" \
  --build-arg "AGE_VERSION=${AGE_VERSION:-}" \
  .

./scripts/parity-check.sh "${IMAGE}"

git diff --check
git diff --cached --check
bash -n scripts/parity-check.sh
bash -n scripts/local-ci.sh
