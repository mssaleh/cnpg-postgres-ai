# syntax=docker/dockerfile:1
#
# cnpg-postgres-ai
#
# A CloudNativePG-compatible PostgreSQL image bundling five AI / graph
# extensions on top of the CNPG-official PostgreSQL base:
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
#   - PostgreSQL stays on the selected minor release. The base image and
#     Debian package revisions can update within that release.
#   - APT and the pgvectorscale release feed select compatible extensions
#     subject to the declared version floors.
#   - Raise a *_MIN_VERSION when an upgrade becomes mandatory (a security
#     fix, or an extension SQL version the image must not fall back below).
#   - The *_VERSION build args force one exact release instead, for parity
#     testing and regression bisection. An explicit request is honoured as
#     given and is not floor-checked:
#       --build-arg TIMESCALEDB_VERSION=2.32.1
#       --build-arg PGVECTORSCALE_VERSION=0.9.1
#       --build-arg PGVECTOR_VERSION=0.8.7
#       --build-arg POSTGIS_VERSION=3.7.0
#       --build-arg AGE_VERSION=1.8.0

ARG POSTGRESQL_VERSION=18.7
ARG CNPG_BASE_TAG=${POSTGRESQL_VERSION}-system-trixie
FROM ghcr.io/cloudnative-pg/postgresql:${CNPG_BASE_TAG}

ARG POSTGRESQL_VERSION
LABEL org.opencontainers.image.title="cnpg-postgres-ai"
LABEL org.opencontainers.image.description="CloudNativePG-compatible PostgreSQL ${POSTGRESQL_VERSION} with pgvector, pgvectorscale, PostGIS, TimescaleDB (Community Edition), and Apache AGE."
LABEL org.opencontainers.image.source="https://github.com/mssaleh/cnpg-postgres-ai"
LABEL org.opencontainers.image.licenses="Apache-2.0"
LABEL org.opencontainers.image.vendor="mssaleh"

USER root
SHELL ["/bin/bash", "-euxo", "pipefail", "-c"]

ENV DEBIAN_FRONTEND=noninteractive

ARG CACHE_BUST=manual

# Restrict the server, client and JIT packages to the requested PostgreSQL
# release. PGDG's archive keeps extension revisions for older minor releases.
# https://wiki.postgresql.org/wiki/Apt/FAQ
RUN pg_major="${POSTGRESQL_VERSION%%.*}" \
 && pg_packages="postgresql-${pg_major} postgresql-client-${pg_major} postgresql-${pg_major}-jit" \
 && printf 'Package: %s\nPin: version %s-*\nPin-Priority: 990\n\nPackage: %s\nPin: version *\nPin-Priority: -1\n' \
      "${pg_packages}" "${POSTGRESQL_VERSION}" "${pg_packages}" > /etc/apt/preferences.d/postgresql-release \
 && . /etc/os-release \
 && printf '%s\n' "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.gpg] https://apt-archive.postgresql.org/pub/repos/apt ${VERSION_CODENAME}-pgdg-archive main" \
      > /etc/apt/sources.list.d/pgdg-archive.list \
 && printf '%s\n' 'Package: *' 'Pin: origin "apt-archive.postgresql.org"' 'Pin-Priority: 100' \
      > /etc/apt/preferences.d/pgdg-archive

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
# With no *_VERSION override, APT can select an older package revision when
# the newest requires a different PostgreSQL release.
#
# The comparison runs on the upstream release only, because each repository
# decorates it differently: PGDG appends a Debian revision ("0.8.6-1.pgdg13+1")
# and, for PostGIS, a repackaging suffix ("3.6.4+dfsg-2.pgdg13+1"); Timescale
# appends a distro suffix ("2.29.2~debian13-1806"); AGE keeps upstream's
# release-candidate marker ("1.8.0~rc0-2.pgdg13+1"), which dpkg orders below
# a plain 1.8.0, so the minimum carries the marker too.
#
# The all-libraries TimescaleDB package keeps historical shared libraries
# available until each database runs ALTER EXTENSION timescaledb UPDATE.
# TIMESCALEDB_VERSION selects the single-version package.

ARG PGVECTOR_MIN_VERSION=0.8.7
ARG POSTGIS_MIN_VERSION=3.7.0
# 2.32.1 is compatible with both 18.6 and 18.7.
# https://github.com/timescale/timescaledb/releases/tag/2.32.1
ARG TIMESCALEDB_MIN_VERSION=2.32.1
ARG AGE_MIN_VERSION=1.8.0~rc0

ARG PGVECTOR_VERSION
ARG POSTGIS_VERSION
ARG TIMESCALEDB_VERSION
ARG AGE_VERSION

# Hold TimescaleDB at one minor line (for example 2.27) for an application that
# qualifies a line rather than the newest release. The newest release of that
# line is installed from the same all-libraries package and floor-checked
# against the line's first release.
ARG TIMESCALEDB_LINE

# APT's install command fixes each named package to one candidate. Satisfy
# lets the 3.0 solver choose compatible versions under the server constraint.
RUN apt_request() { \
      local package="$1" pattern="$2" versions version separator=""; \
      if [ -z "${pattern}" ]; then \
        printf '%s' "${package}"; \
        return; \
      fi; \
      versions="$(apt-cache madison "${package}")" || return; \
      while IFS='|' read -r _ version _; do \
        version="${version//[[:space:]]/}"; \
        if [[ "${version}" == ${pattern} ]]; then \
          printf '%s%s (= %s)' "${separator}" "${package}" "${version}"; \
          separator=" | "; \
        fi; \
      done <<< "${versions}"; \
      if [ -z "${separator}" ]; then \
        echo "ERROR: no ${package} version matches ${pattern}" >&2; return 1; \
      fi; \
    } \
 && . /etc/os-release \
 && pg_major="${POSTGRESQL_VERSION%%.*}" \
 && pg_revision="$(dpkg-query -W -f='${Version}' "postgresql-${pg_major}")" \
 && apt-get update \
 && pgvector_pkg="postgresql-${pg_major}-pgvector" \
 && postgis_pkg="postgresql-${pg_major}-postgis-3" \
 && age_pkg="postgresql-${pg_major}-age" \
 && timescaledb_pkg="timescaledb-2-postgresql-${pg_major}" \
 && loader_pkg="timescaledb-2-loader-postgresql-${pg_major}" \
 && postgis_abi=() \
 # PGDG's +2 revision needs heap_datum_check from 18.7, absent from Depends.
 && if [ "${POSTGRESQL_VERSION}" = 18.6 ]; then \
      postgis_abi=( "${postgis_pkg} (<< 3.7.0+dfsg-1.pgdg13+2)" \
                    "${postgis_pkg}-scripts (<< 3.7.0+dfsg-1.pgdg13+2)" ); \
    fi \
 && timescaledb_min="${TIMESCALEDB_MIN_VERSION}" \
 && timescaledb_pattern="" loader_pattern="" \
 && if [ -n "${TIMESCALEDB_VERSION:-}" ]; then \
      timescaledb_pkg="timescaledb-2-${TIMESCALEDB_VERSION}-postgresql-${pg_major}"; \
      loader_pattern="${TIMESCALEDB_VERSION}~debian${VERSION_ID}*"; \
    elif [ -n "${TIMESCALEDB_LINE:-}" ]; then \
      timescaledb_pattern="${TIMESCALEDB_LINE}.*"; \
      loader_pattern="${timescaledb_pattern}"; \
      timescaledb_min="${TIMESCALEDB_LINE}.0"; \
    fi \
 && pgvector_request="$(apt_request "${pgvector_pkg}" "${PGVECTOR_VERSION:+${PGVECTOR_VERSION}*}")" \
 && postgis_request="$(apt_request "${postgis_pkg}" "${POSTGIS_VERSION:+${POSTGIS_VERSION}*}")" \
 && age_request="$(apt_request "${age_pkg}" "${AGE_VERSION:+${AGE_VERSION}~rc0*}")" \
 && timescaledb_request="$(apt_request "${timescaledb_pkg}" "${timescaledb_pattern}")" \
 && loader_request="$(apt_request "${loader_pkg}" "${loader_pattern}")" \
 && apt-get --solver 3.0 --no-strict-pinning \
      satisfy -y --no-install-recommends --no-remove --allow-downgrades \
      "postgresql-${pg_major} (= ${pg_revision})" \
      "postgresql-client-${pg_major} (= ${pg_revision})" \
      "postgresql-${pg_major}-jit (= ${pg_revision})" \
      "${pgvector_request}" "${postgis_request}" "${age_request}" \
      "${timescaledb_request}" "${loader_request}" \
      "${postgis_abi[@]}" \
 && if [ -n "${TIMESCALEDB_LINE:-}" ]; then \
      installed="$(dpkg-query -s "${timescaledb_pkg}" | sed -n 's/^Version: //p')"; \
      case "${installed}" in \
        "${TIMESCALEDB_LINE}".*) ;; \
        *) echo "ERROR: ${timescaledb_pkg} resolved to ${installed}, outside line ${TIMESCALEDB_LINE}" >&2; exit 1 ;; \
      esac; \
    fi \
 && for spec in \
      "postgresql-${pg_major}-pgvector ${PGVECTOR_MIN_VERSION} ${PGVECTOR_VERSION:-}" \
      "postgresql-${pg_major}-postgis-3 ${POSTGIS_MIN_VERSION} ${POSTGIS_VERSION:-}" \
      "postgresql-${pg_major}-age ${AGE_MIN_VERSION} ${AGE_VERSION:-}" \
      "${timescaledb_pkg} ${timescaledb_min} ${TIMESCALEDB_VERSION:-}" ; do \
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
# predates the declared minimum, or it ships no asset for this major and
# architecture. Each falls back to the declared minimum.

ARG PGVECTORSCALE_MIN_VERSION=0.9.1
ARG PGVECTORSCALE_VERSION
ARG TARGETARCH=amd64

RUN pg_major="${POSTGRESQL_VERSION%%.*}" \
 && case "${TARGETARCH}" in \
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
      asset="pgvectorscale-${latest}-pg${pg_major}-${pgvs_arch}.zip"; \
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
      "https://github.com/timescale/pgvectorscale/releases/download/${pgvs_tag}/pgvectorscale-${pgvs_tag}-pg${pg_major}-${pgvs_arch}.zip" \
 && unzip -d /tmp/pgvs /tmp/pgvs.zip \
 && dpkg -i "/tmp/pgvs/pgvectorscale-postgresql-${pg_major}_${pgvs_tag}-Linux_${pgvs_arch}.deb" \
 && rm -rf /tmp/pgvs /tmp/pgvs.zip

# --- Cleanup --------------------------------------------------------------
# Drop build-only packages and apt caches. Keep ca-certificates (needed at
# runtime for outbound TLS, e.g. timescaledb-tune or pg extensions making
# outbound HTTPS calls).
RUN apt-get purge -y --auto-remove gnupg jq unzip \
 && rm -rf /var/lib/apt/lists/* /var/cache/apt/* /tmp/* \
 && actual="$(postgres --version | cut -d ' ' -f 3)" \
 && if [ "${actual}" != "${POSTGRESQL_VERSION}" ]; then \
      echo "ERROR: PostgreSQL ${actual} does not match ${POSTGRESQL_VERSION}" >&2; exit 1; \
    fi

# CNPG operator drives postgres lifecycle as UID 26.
USER 26
