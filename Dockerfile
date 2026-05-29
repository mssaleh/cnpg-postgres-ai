# syntax=docker/dockerfile:1
#
# cnpg-postgres-ai
#
# A CloudNativePG-compatible PostgreSQL image bundling five AI / graph
# extensions on top of the CNPG-official Postgres 18 base:
#
#   - pgvector       (vector data type + HNSW/IVF indexes)
#   - pgvectorscale  (DiskANN-backed vector index, Timescale)
#   - PostGIS        (geospatial)
#   - TimescaleDB    (Apache-2.0 OSS variant — no TSL extras)
#   - Apache AGE     (graph database extension, openCypher)
#
# Why we don't just use the upstream timescaledb-ha image:
#   - It runs as UID 1000 with a Patroni/Spilo lifecycle that fights the
#     CNPG operator (CNPG expects UID 26 and owns the HA stack itself).
#   - CNPG replaces pgBackRest/Patroni with its own integrated backup +
#     failover, so 2/3 of the upstream image's payload is dead weight.
#
# Versioning policy:
#   - PostgreSQL MAJOR is pinned to 18 via the CNPG base image tag.
#   - All five extensions float to the LATEST patch available in the apt
#     repos / GitHub releases at build time. Weekly CI re-builds pull the
#     latest CNPG base and apply available package updates.
#   - To pin a specific patch level (e.g., for parity testing against an
#     upstream Timescale image), pass build args:
#       --build-arg TIMESCALEDB_VERSION=2.27.1
#       --build-arg PGVECTORSCALE_VERSION=0.9.0
#       --build-arg PGVECTOR_VERSION=0.8.2
#       --build-arg POSTGIS_VERSION=3.6.3
#       --build-arg AGE_VERSION=1.7.0

ARG CNPG_BASE_TAG=18-system-trixie
FROM ghcr.io/cloudnative-pg/postgresql:${CNPG_BASE_TAG}

LABEL org.opencontainers.image.title="cnpg-postgres-ai"
LABEL org.opencontainers.image.description="CloudNativePG-compatible Postgres 18 + pgvector + pgvectorscale + PostGIS + TimescaleDB (Apache-2.0 OSS) + Apache AGE."
LABEL org.opencontainers.image.source="https://github.com/mssaleh/cnpg-postgres-ai"
LABEL org.opencontainers.image.licenses="Apache-2.0"
LABEL org.opencontainers.image.vendor="mssaleh"

USER root
SHELL ["/bin/bash", "-euxo", "pipefail", "-c"]

ENV DEBIAN_FRONTEND=noninteractive

ARG CACHE_BUST=manual

# --- Timescale apt repo (for timescaledb-2-postgresql-18) -----------------
# pgvector + PostGIS + Apache AGE come from PGDG, which the CNPG base
# already wires up.
# pgvectorscale ships as a GitHub-release .deb (no apt repo for trixie yet)
# and is installed in a second stage below.

RUN echo "cache-bust=${CACHE_BUST}" >/dev/null \
 && apt-get update \
 && apt-get upgrade -y --no-install-recommends \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg unzip \
 && install -d /usr/share/keyrings \
 && curl -fsSL https://packagecloud.io/timescale/timescaledb/gpgkey \
      | gpg --dearmor -o /usr/share/keyrings/timescaledb.gpg \
 && . /etc/os-release \
 && echo "deb [signed-by=/usr/share/keyrings/timescaledb.gpg] https://packagecloud.io/timescale/timescaledb/debian/ ${VERSION_CODENAME} main" \
      > /etc/apt/sources.list.d/timescaledb.list

# --- pgvector + PostGIS + Apache AGE (PGDG) and TimescaleDB ---------------
# Versions default to "latest" — if you pass *_VERSION build args, we pin.
# apt versions in PGDG look like "0.8.2-1.pgdg13+1" — we anchor on the
# upstream version and let the packaging suffix float (the +1 changes per
# distro rebuild but not per upstream release).
# AGE packages use Debian's rc suffix, so AGE_VERSION=1.7.0 pins
# "1.7.0~rc0-*".

ARG PGVECTOR_VERSION=
ARG POSTGIS_VERSION=
ARG TIMESCALEDB_VERSION=
ARG AGE_VERSION=

RUN apt-get update \
 && PGVECTOR_PKG="postgresql-18-pgvector${PGVECTOR_VERSION:+=${PGVECTOR_VERSION}*}" \
 && POSTGIS_PKG="postgresql-18-postgis-3${POSTGIS_VERSION:+=${POSTGIS_VERSION}*}" \
 && AGE_PKG="postgresql-18-age${AGE_VERSION:+=${AGE_VERSION}~rc0*}" \
 && if [ -n "${TIMESCALEDB_VERSION}" ]; then \
      TS_PKG="timescaledb-2-${TIMESCALEDB_VERSION}-postgresql-18"; \
      TS_LOADER_PKG="timescaledb-2-loader-postgresql-18=${TIMESCALEDB_VERSION}~debian13*"; \
    else \
      TS_PKG="timescaledb-2-postgresql-18"; \
      TS_LOADER_PKG="timescaledb-2-loader-postgresql-18"; \
    fi \
 && apt-get install -y --no-install-recommends --allow-downgrades \
      "${PGVECTOR_PKG}" \
      "${POSTGIS_PKG}" \
      "${AGE_PKG}" \
      "${TS_PKG}" \
      "${TS_LOADER_PKG}"

# --- pgvectorscale (GitHub release .deb) ----------------------------------
# Upstream ships per-PG-version, per-arch zips containing a runtime .deb
# plus a dbgsym .deb. We dpkg -i the runtime; dbgsym is skipped to keep
# the image lean.

ARG PGVECTORSCALE_VERSION=
ARG TARGETARCH=amd64

RUN if [ -z "${PGVECTORSCALE_VERSION}" ]; then \
      PGVS_TAG=$(curl -fsSL -o /dev/null -w '%{url_effective}' \
          https://github.com/timescale/pgvectorscale/releases/latest \
        | sed -E 's#.*/tag/([^/?#]+).*#\1#'); \
    else \
      PGVS_TAG="${PGVECTORSCALE_VERSION}"; \
    fi \
 && case "${PGVS_TAG}" in \
      ""|http*) echo "failed to resolve pgvectorscale release tag: ${PGVS_TAG}"; exit 1 ;; \
    esac \
 && case "${TARGETARCH}" in \
      amd64|arm64) PGVS_ARCH="${TARGETARCH}" ;; \
      *) echo "unsupported TARGETARCH=${TARGETARCH}"; exit 1 ;; \
    esac \
 && echo "pgvectorscale ${PGVS_TAG} / ${PGVS_ARCH}" \
 && curl -fsSL -o /tmp/pgvs.zip \
      "https://github.com/timescale/pgvectorscale/releases/download/${PGVS_TAG}/pgvectorscale-${PGVS_TAG}-pg18-${PGVS_ARCH}.zip" \
 && unzip -d /tmp/pgvs /tmp/pgvs.zip \
 && dpkg -i "/tmp/pgvs/pgvectorscale-postgresql-18_${PGVS_TAG}-Linux_${PGVS_ARCH}.deb" \
 && rm -rf /tmp/pgvs /tmp/pgvs.zip

# --- Cleanup --------------------------------------------------------------
# Drop build-only packages and apt caches. Keep ca-certificates (needed at
# runtime for outbound TLS, e.g. timescaledb-tune or pg extensions making
# outbound HTTPS calls).
RUN apt-get purge -y --auto-remove gnupg unzip \
 && rm -rf /var/lib/apt/lists/* /var/cache/apt/* /tmp/*

# CNPG operator drives postgres lifecycle as UID 26.
USER 26
