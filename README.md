# cnpg-postgres-ai

CloudNativePG-compatible PostgreSQL 18 image with an AI / graph extension bundle:

- **pgvector** — vector data type + HNSW/IVF indexes
- **pgvectorscale** — DiskANN-backed vector index (Timescale)
- **PostGIS** — geospatial
- **TimescaleDB** — time-series + hypertables (Community Edition, Timescale License)
- **Apache AGE** — graph database extension with openCypher queries on PostgreSQL

## Why this image

CloudNativePG (CNPG) drives Postgres lifecycle as UID 26 and replaces Patroni / Spilo with its own integrated backup + failover. Standard distro `postgres:N` images and the upstream `timescale/timescaledb-ha:pgN-tsM` image don't fit cleanly — this image starts from `ghcr.io/cloudnative-pg/postgresql:18-system-trixie` (CNPG's official baseline) and layers the five extensions on top.

CNPG deprecates the `system` image flavor. This image retains its bundled Barman
Cloud binaries; moving to `standard` requires configuring a backup plugin or
another supported backup solution ([upstream image documentation](https://github.com/cloudnative-pg/postgres-containers#image-types)).

Suitable for: AI-agent platforms (long-term memory backed by pgvector + DiskANN), knowledge-graph workloads (AGE), geospatial + time-series (PostGIS + TimescaleDB) — typically all five together in modern data products.

## Image Tags

Published to GHCR after verification:

- `ghcr.io/mssaleh/cnpg-postgres-ai:<tag>` — public
- `<harbor-registry>/<project>/cnpg-postgres-ai:<tag>` — optional Harbor mirror

Configure the mirror with GitHub repository variables `HARBOR_REGISTRY` and
`HARBOR_PROJECT`, plus repository secrets `HARBOR_USERNAME` and
`HARBOR_PASSWORD`. The registry target is never hardcoded in the repository.
The mirror is best effort; GHCR is the required publish target.

The first GHCR package created under a personal account is private by default. If CI says the image was pushed but is not anonymously readable, open the package settings and change visibility to Public once.

Tag scheme:

- `18-latest` — floating, always newest weekly build
- `18-YYYY-MM-DD-<sha>-<run>-<attempt>` — immutable, **use this in production CNPG `Cluster.spec.imageName`**
- `candidate-<run>-<attempt>` — build artifact awaiting verification; do not deploy

Each workflow run builds one candidate with an SBOM and provenance. The shared
local/CI checks test that candidate by digest. Anonymous access and the GitHub
Actions signing identity are verified before the same image index is promoted to
the release tags. Run and attempt identifiers prevent reruns from overwriting an
immutable release. Harbor receives the verified image as an optional mirror.

## Usage in CloudNativePG

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: my-app-db
spec:
  instances: 1
  # Replace with the immutable tag from a successful build's summary.
  imageName: ghcr.io/mssaleh/cnpg-postgres-ai:18-2026-11-01-8693b7c-41288901922-1

  postgresql:
    # TimescaleDB MUST be in shared_preload_libraries (it's a hard requirement).
    # Apache AGE is preloaded so app sessions can use openCypher without
    # a per-session LOAD, which is friendlier to connection pools.
    shared_preload_libraries:
      - timescaledb
      - age
    parameters:
      # pgvectorscale's DiskANN index builder benefits from generous
      # maintenance_work_mem on initial index creation. Default 64 MB
      # spills to disk for vector tables > ~1M rows.
      maintenance_work_mem: "1GB"
      search_path: 'ag_catalog, "$user", public'

  bootstrap:
    initdb:
      database: app
      owner: app
      postInitApplicationSQL:
        - CREATE EXTENSION IF NOT EXISTS vector;
        - CREATE EXTENSION IF NOT EXISTS vectorscale CASCADE;
        - CREATE EXTENSION IF NOT EXISTS postgis;
        - CREATE EXTENSION IF NOT EXISTS timescaledb;
        - CREATE EXTENSION IF NOT EXISTS age;
```

## Version policy

PostgreSQL and runtime extensions have minimum versions with no upper bound.
Normal builds use the newest available packages and stable pgvectorscale release
compatible with PostgreSQL 18 and the image architecture.

- **PostgreSQL** is held at MAJOR 18 by the `ghcr.io/cloudnative-pg/postgresql:18-system-trixie`
  base tag, with a `POSTGRESQL_MIN_VERSION` floor of 18.6. The tag floats within
  the major, so a rebuild picks up the newest 18.x. PostgreSQL 18.6 supports an
  in-place minor update from earlier 18.x releases without dump/restore; review
  its [migration notes](https://www.postgresql.org/docs/18/release-18-6.html#RELEASE-18-6-MIGRATION)
  for configuration and index maintenance that may apply to existing databases.
- **Extensions** carry a `*_MIN_VERSION` build arg in `Dockerfile`: pgvector 0.8.7,
  pgvectorscale 0.9.1, PostGIS 3.7.0, TimescaleDB 2.31.0, Apache AGE 1.8.0~rc0.
  apt (PGDG, Timescale) and the pgvectorscale GitHub release feed pick the newest
  release; the build fails if resolution lands below the declared minimum.
  Raise a minimum when an upgrade becomes mandatory — a security fix, or an
  extension SQL version the image must never fall back below.
- **pgvector 0.8.7** is required because it fixes an IVFFlat index-build buffer
  overflow ([upstream changelog](https://github.com/pgvector/pgvector/blob/master/CHANGELOG.md)).
- **PostGIS 3.7** supports PostgreSQL 18. Its PGDG package brings GEOS 3.15 or
  newer, which enables new functions such as `ST_CoverageEdges`. Raster,
  topology, and SFCGAL remain available as companion extensions. The address
  standardizer and TIGER geocoder are separate packages and are not bundled
  ([release notes](https://postgis.net/2026/10/PostGIS-3.7.0/),
  [coverage function requirements](https://postgis.net/docs/manual-3.7/en/ST_CoverageEdges.html)).
- **pgvectorscale** falls back to its declared minimum if the latest release API
  is unavailable or the latest release has no matching PostgreSQL 18 asset. The
  build log reports this fallback; a successful build does not imply the newest
  upstream release was used.
- **Apache AGE** reports SQL version 1.8.0, while PGDG's PostgreSQL 18 package
  currently uses version `1.8.0~rc0`. Preserve that distinction when comparing
  package and extension versions.
- **TimescaleDB** is installed from `timescaledb-2-postgresql-18`, which carries
  historical versioned `timescaledb` shared libraries as well as the newest.
  A persistent database needs its installed version's library to remain present
  until `ALTER EXTENSION timescaledb UPDATE` runs. Compatibility is qualified for
  the selected upgrade baseline, not every historical database version.
- The weekly CI rebuild (Sun 02:00 UTC) is how the image reaches each new release.
  Every rebuild is gated on both parity checks below, so an upstream release that
  breaks a persistent database is caught before `18-latest` moves.
- **Cosign** resolves the latest stable binary independently of the installer's
  embedded default. The published v4 installer release is used because upstream
  has no floating `v4` tag. GitHub Actions summaries record package and signing
  tool versions; the build log records dependency resolution and fallbacks.

An application that qualifies one TimescaleDB minor line rather than the newest
release builds with `TIMESCALEDB_LINE`. The newest release of that line is
installed from the same all-libraries package and floor-checked against the
line's first release; the other extensions still float:

```
docker build --build-arg TIMESCALEDB_LINE=2.27 -t <registry>/cnpg-postgres-ai:18-ts2.27 .
```

The same option is available as `TIMESCALEDB_LINE` in local CI and
`timescaledb_line` in workflow dispatch. When both a line and an exact version
are supplied, the exact version must belong to that line.

To pin exact releases instead (parity testing, regression bisection), use the
workflow_dispatch inputs. A pinned version is installed as asked and is not
floor-checked:

```
gh workflow run build.yml \
  -f pgvector_version=0.8.7 \
  -f postgis_version=3.7.0 \
  -f timescaledb_version=2.31.0 \
  -f pgvectorscale_version=0.9.1 \
  -f age_version=1.8.0
```

## Parity check

A parity step runs in CI against the freshly-built image: it initdbs Postgres, sets `shared_preload_libraries='timescaledb,age'`, starts the cluster, and runs `CREATE EXTENSION` for all five plus AGE graph and PostGIS coverage operations. Build fails if any extension is missing or an operation returns an unexpected result.

CI also runs persistent-upgrade parity from the previously published image. This
guards the production distinction between replacing extension binaries in an image
and updating each database's installed extension catalog. It checks surviving
hypertable, graph, spatial, and vector data, upgrades PostGIS core and topology
together, and uses an executed query plan to verify the persisted DiskANN index.
This is a container test; it does not qualify CNPG rolling updates or application
workloads.

Run the same entry point locally with Docker, Buildx, and jq. Source checks use
the upstream Actionlint container, including ShellCheck, in both local runs and CI:

```sh
UPGRADE_FROM_IMAGE=ghcr.io/mssaleh/cnpg-postgres-ai:18-latest \
  ./scripts/local-ci.sh
```

To verify a registry candidate without rebuilding, pass `--verify-only <image>`.
For source checks alone, pass `--check`.
Use an immutable deployed image as `UPGRADE_FROM_IMAGE`, or the workflow's
`upgrade_from_image` input, to qualify that specific upgrade path. Blank workflow
input selects the previous `18-latest`. Repeat for each deployed baseline before
deploying; a passing previous-release test does not cover unknown older versions.

## Upgrading a persistent CNPG database

Replacing `spec.imageName` does **not** run extension upgrade SQL. After CNPG has
rolled all instances onto the new immutable image, update TimescaleDB first in a
fresh connection to each application database as its extension owner:

```sh
psql -X -d app -v ON_ERROR_STOP=1 -c 'ALTER EXTENSION timescaledb UPDATE;'
```

Then compare installed/default versions:

```sql
SELECT name, default_version, installed_version
FROM pg_available_extensions
WHERE name IN ('vector','vectorscale','postgis','timescaledb','age')
ORDER BY name;
```

Apply required upgrades in dependency order during the release window:

```sql
ALTER EXTENSION vector UPDATE;
ALTER EXTENSION vectorscale UPDATE;
SELECT postgis_extensions_upgrade();
ALTER EXTENSION age UPDATE;
```

The [PostGIS upgrade function](https://postgis.net/docs/manual-3.7/en/PostGIS_Extensions_Upgrade.html)
updates the core extension and its installed companion extensions together.
For existing PostGIS databases, review the 3.7 release notes for changed topology
tolerances and removed functions such as `ST_MemCollect`.

Take a backup first, use the immutable image tag, and run an application-specific
smoke test before reopening writes. Never assume a successful fresh-install parity
test proves an existing database is upgrade-safe.

## Apache AGE specifics

AGE provides openCypher graph queries on top of relational PostgreSQL. The default CNPG example above preloads AGE and sets `search_path` cluster-wide. If you remove AGE from `shared_preload_libraries`, run `LOAD 'age'` per session before using `cypher()`:

```sql
LOAD 'age';
SET search_path = ag_catalog, "$user", public;

SELECT create_graph('myapp');

SELECT * FROM cypher('myapp', $$
  CREATE (n:Person {name: 'Alice'})-[:KNOWS]->(m:Person {name: 'Bob'})
  RETURN n, m
$$) AS (n agtype, m agtype);
```

With AGE preloaded, the `LOAD 'age'` line isn't needed. Keep `search_path` in `postgresql.parameters` for cluster-wide effect, or move it to `ALTER ROLE <app> SET search_path` if only selected roles should use AGE.

## License

Apache 2.0
