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
#   - TimescaleDB    (Community Edition, Timescale License)
#   - Apache AGE     (graph database extension, openCypher)
#
# Why we don't just use the upstream timescaledb-ha image:
#   - It runs as UID 1000 with a Patroni/Spilo lifecycle that fights the
#     CNPG operator (CNPG expects UID 26 and owns the HA stack itself).
#   - CNPG replaces pgBackRest/Patroni with its own integrated backup +
#     failover, so 2/3 of the upstream image's payload is dead weight.
#
# Versioning policy:
#   - PostgreSQL MAJOR is held at 18 via the CNPG base image tag. The tag
#     itself floats, so a rebuild picks up the newest 18.x on Debian trixie.
#   - Every extension is declared as a minimum version with no upper bound.
#     apt and the pgvectorscale release feed resolve the newest stable
#     release at build time; the build fails if resolution lands below the
#     declared minimum. Nothing is pinned to an exact patch or a digest.
#   - Raise a *_MIN_VERSION when an upgrade becomes mandatory (a security
#     fix, or an extension SQL version the image must not fall back below).
#   - The *_VERSION build args force one exact release instead, for parity
#     testing and regression bisection. An explicit request is honoured as
#     given and is not floor-checked:
#       --build-arg TIMESCALEDB_VERSION=2.29.0
#       --build-arg PGVECTORSCALE_VERSION=0.9.0
#       --build-arg PGVECTOR_VERSION=0.8.5
#       --build-arg POSTGIS_VERSION=3.6.4
#       --build-arg AGE_VERSION=1.8.0

ARG CNPG_BASE_TAG=18-system-trixie
FROM ghcr.io/cloudnative-pg/postgresql:${CNPG_BASE_TAG}

LABEL org.opencontainers.image.title="cnpg-postgres-ai"
LABEL org.opencontainers.image.description="CloudNativePG-compatible Postgres 18 + pgvector + pgvectorscale + PostGIS + TimescaleDB (Community Edition) + Apache AGE."
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
      ca-certificates curl gnupg jq unzip \
 && install -d /usr/share/keyrings \
 && curl -fsSL https://packagecloud.io/timescale/timescaledb/gpgkey \
      | gpg --dearmor -o /usr/share/keyrings/timescaledb.gpg \
 && . /etc/os-release \
 && echo "deb [signed-by=/usr/share/keyrings/timescaledb.gpg] https://packagecloud.io/timescale/timescaledb/debian/ ${VERSION_CODENAME} main" \
      > /etc/apt/sources.list.d/timescaledb.list

# --- pgvector + PostGIS + Apache AGE (PGDG) and TimescaleDB ---------------
# With no *_VERSION override, each package is installed unversioned so apt
# resolves its newest candidate, then checked against the declared minimum.
#
# The comparison runs on the upstream release only, because each repository
# decorates it differently: PGDG appends a Debian revision ("0.8.6-1.pgdg13+1")
# and, for PostGIS, a repackaging suffix ("3.6.4+dfsg-2.pgdg13+1"); Timescale
# appends a distro suffix ("2.29.2~debian13-1806"); AGE keeps upstream's
# release-candidate marker ("1.8.0~rc0-2.pgdg13+1"), which dpkg orders below
# a plain 1.8.0, so the minimum carries the marker too.
#
# timescaledb-2-postgresql-18 is not a thin metapackage: it carries every
# historical timescaledb .so (~333 MB installed, against ~40 MB for the
# single-version timescaledb-2-<version>-postgresql-18). That is deliberate.
# TimescaleDB's loader resolves the library matching each database's *installed*
# extension version, which an image swap does not change, so a persistent CNPG
# database on an older version needs its old library present to start at all --
# before ALTER EXTENSION timescaledb UPDATE can run. Pinning a *_VERSION picks
# the single-version package instead and gives up that headroom.

ARG PGVECTOR_MIN_VERSION=0.8.6
ARG POSTGIS_MIN_VERSION=3.6.4
ARG TIMESCALEDB_MIN_VERSION=2.29.2
ARG AGE_MIN_VERSION=1.8.0~rc0

ARG PGVECTOR_VERSION
ARG POSTGIS_VERSION
ARG TIMESCALEDB_VERSION
ARG AGE_VERSION

RUN . /etc/os-release \
 && apt-get update \
 && pgvector_pkg="postgresql-18-pgvector${PGVECTOR_VERSION:+=${PGVECTOR_VERSION}*}" \
 && postgis_pkg="postgresql-18-postgis-3${POSTGIS_VERSION:+=${POSTGIS_VERSION}*}" \
 && age_pkg="postgresql-18-age${AGE_VERSION:+=${AGE_VERSION}~rc0*}" \
 && if [ -n "${TIMESCALEDB_VERSION:-}" ]; then \
      timescaledb_pkg="timescaledb-2-${TIMESCALEDB_VERSION}-postgresql-18"; \
      loader_pkg="timescaledb-2-loader-postgresql-18=${TIMESCALEDB_VERSION}~debian${VERSION_ID}*"; \
    else \
      timescaledb_pkg="timescaledb-2-postgresql-18"; \
      loader_pkg="timescaledb-2-loader-postgresql-18"; \
    fi \
 && apt-get install -y --no-install-recommends --allow-downgrades \
      "${pgvector_pkg}" \
      "${postgis_pkg}" \
      "${age_pkg}" \
      "${timescaledb_pkg}" \
      "${loader_pkg}" \
 && for spec in \
      "postgresql-18-pgvector ${PGVECTOR_MIN_VERSION} ${PGVECTOR_VERSION:-}" \
      "postgresql-18-postgis-3 ${POSTGIS_MIN_VERSION} ${POSTGIS_VERSION:-}" \
      "postgresql-18-age ${AGE_MIN_VERSION} ${AGE_VERSION:-}" \
      "${timescaledb_pkg} ${TIMESCALEDB_MIN_VERSION} ${TIMESCALEDB_VERSION:-}" ; do \
      set -- ${spec}; \
      installed="$(dpkg-query -s "$1" | sed -n 's/^Version: //p')"; \
      if [ -n "${3:-}" ]; then \
        echo "resolved $1 ${installed} (pinned to $3)"; \
        continue; \
      fi; \
      upstream="${installed%-*}"; \
      upstream="${upstream%%+dfsg*}"; \
      upstream="${upstream%%~debian*}"; \
      if ! dpkg --compare-versions "${upstream}" ge "$2"; then \
        echo "ERROR: $1 resolved to ${installed} (upstream ${upstream}), below the declared minimum $2" >&2; \
        exit 1; \
      fi; \
      echo "resolved $1 ${installed} (>= $2)"; \
    done

# --- pgvectorscale (GitHub release .deb) ----------------------------------
# Upstream ships per-PG-version, per-arch zips containing a runtime .deb
# plus a dbgsym .deb. We dpkg -i the runtime; dbgsym is skipped to keep
# the image lean.
#
# There is no apt repo, so "newest stable" comes from the GitHub releases
# feed, which excludes drafts and prereleases. Three things make the newest
# release unusable: the API is unreachable or rate-limited, the release
# predates the declared minimum, or it ships no pg18 asset for this arch.
# Each falls back to the declared minimum, which is a published release
# known to carry that asset.

ARG PGVECTORSCALE_MIN_VERSION=0.9.1
ARG PGVECTORSCALE_VERSION
ARG TARGETARCH=amd64

RUN case "${TARGETARCH}" in \
      amd64|arm64) pgvs_arch="${TARGETARCH}" ;; \
      *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac \
 && pgvs_tag="${PGVECTORSCALE_VERSION:-}" \
 && if [ -n "${pgvs_tag}" ]; then \
      echo "resolved pgvectorscale ${pgvs_tag} (pinned)"; \
    else \
      release="$(curl -fsSL -H 'Accept: application/vnd.github+json' \
        https://api.github.com/repos/timescale/pgvectorscale/releases/latest || true)"; \
      latest="$(printf '%s' "${release}" | jq -r '.tag_name // empty' 2>/dev/null || true)"; \
      asset="pgvectorscale-${latest}-pg18-${pgvs_arch}.zip"; \
      if [ -n "${latest}" ] \
         && dpkg --compare-versions "${latest}" ge "${PGVECTORSCALE_MIN_VERSION}" \
         && printf '%s' "${release}" | jq -e --arg n "${asset}" '[.assets[].name] | index($n)' >/dev/null; then \
        pgvs_tag="${latest}"; \
        echo "resolved pgvectorscale ${pgvs_tag} (>= ${PGVECTORSCALE_MIN_VERSION})"; \
      else \
        pgvs_tag="${PGVECTORSCALE_MIN_VERSION}"; \
        echo "WARNING: could not use pgvectorscale release '${latest:-<none>}'; using the declared minimum ${pgvs_tag}" >&2; \
      fi; \
    fi \
 && curl -fsSL -o /tmp/pgvs.zip \
      "https://github.com/timescale/pgvectorscale/releases/download/${pgvs_tag}/pgvectorscale-${pgvs_tag}-pg18-${pgvs_arch}.zip" \
 && unzip -d /tmp/pgvs /tmp/pgvs.zip \
 && dpkg -i "/tmp/pgvs/pgvectorscale-postgresql-18_${pgvs_tag}-Linux_${pgvs_arch}.deb" \
 && rm -rf /tmp/pgvs /tmp/pgvs.zip

# --- Cleanup --------------------------------------------------------------
# Drop build-only packages and apt caches. Keep ca-certificates (needed at
# runtime for outbound TLS, e.g. timescaledb-tune or pg extensions making
# outbound HTTPS calls).
RUN apt-get purge -y --auto-remove gnupg jq unzip \
 && rm -rf /var/lib/apt/lists/* /var/cache/apt/* /tmp/*

# CNPG operator drives postgres lifecycle as UID 26.
USER 26
