# cnpg-postgres-ai

CloudNativePG-compatible PostgreSQL images with an AI and graph extension bundle.
The build targets PostgreSQL 18.6, 18.7, and 19.0.

- **pgvector** — vector data type + HNSW/IVF indexes
- **pgvectorscale** — DiskANN-backed vector index (Timescale)
- **PostGIS** — geospatial
- **TimescaleDB** — time-series + hypertables (Community Edition, Timescale License)
- **Apache AGE** — graph database extension with openCypher queries on PostgreSQL

## Why this image

CloudNativePG (CNPG) manages PostgreSQL as UID 26 and provides its own backup
and failover. Each build layers five extensions on the official CNPG
`ghcr.io/cloudnative-pg/postgresql:<version>-system-trixie` image.

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

| Tag | Example | What it selects |
| --- | --- | --- |
| Mutable minor | `18.6`, `18.7`, `19.0` | Latest verified build of that PostgreSQL release. Only the base package revisions and extensions can change. |
| Mutable major | `18`, `19` | Latest verified build of the default release for that major. The defaults are 18.7 and 19.0. |
| Immutable build | `18.7-20261126-build-45001874321.1` | One build of that release. The suffix contains the UTC build date, GitHub Actions run ID, and attempt. |
| Candidate | `candidate-18.7-45001874321-1` | Image awaiting verification. Use a release tag to deploy. |

The legacy `18-latest` tag follows `18`. The 18.7 build also publishes
`18-YYYY-MM-DD-<sha>-<run>-<attempt>` and `candidate-<run>-<attempt>` in their
existing formats. Previously published immutable tags remain valid.

Each release job builds a candidate with an SBOM and provenance. It tests the
image by digest and verifies anonymous access and the GitHub Actions signature
before assigning release tags to that same digest. Each build tag is unique
within the workflow, including reruns. For production, use the build tag and
digest from the successful job summary in `Cluster.spec.imageName`. The digest
pins the image content and the tag lets CNPG detect the PostgreSQL major.
[CloudNativePG image requirements](https://cloudnative-pg.io/docs/current/container_images/)

## Usage in CloudNativePG

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: my-app-db
spec:
  instances: 1
  # Replace with the build tag and digest from a successful job summary.
  imageName: ghcr.io/mssaleh/cnpg-postgres-ai:18.7-YYYYMMDD-build-RUN.ATTEMPT@sha256:DIGEST

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

- **PostgreSQL** stays on the selected minor release. The matching CNPG base tag
  and APT preferences allow package revisions within that release, and the build
  checks the resulting server version. APT can select compatible package
  revisions from the PGDG archive where needed.
- **PostgreSQL 18.6** is available for workloads that require it and for
  preparing an upgrade to 18.7. PostgreSQL 18.7 includes security fixes and
  migration steps for indexes and incremental backups.
  [PostgreSQL 18.7 release notes](https://www.postgresql.org/docs/release/18.7/)
- **PostgreSQL 19.0** has a build target. Publishing the full bundle requires
  PostgreSQL 19 packages for TimescaleDB and Apache AGE and a matching
  pgvectorscale release asset. Those are currently missing from the configured
  sources. The 19.0 job can fail independently of the 18.6 and 18.7 jobs.
  [TimescaleDB package feed](https://packagecloud.io/timescale/timescaledb)
  [PGDG package feed](https://apt.postgresql.org/pub/repos/apt/dists/trixie-pgdg/)
  [pgvectorscale releases](https://github.com/timescale/pgvectorscale/releases)
- **Extensions** carry a `*_MIN_VERSION` build arg in `Dockerfile`: pgvector 0.8.7,
  pgvectorscale 0.9.1, PostGIS 3.7.0, TimescaleDB 2.32.1, Apache AGE 1.8.0~rc0.
  APT (PGDG, Timescale) selects compatible packages. The build fails if
  resolution lands below the declared minimum.
  Raise a minimum when an upgrade becomes mandatory — a security fix, or an
  extension SQL version the image must never fall back below.
- **TimescaleDB 2.32.1** supports PostgreSQL 18.6 and 18.7. The package feed
  provides builds for both minor releases. Upgrade TimescaleDB before moving
  an existing PostgreSQL 18.6 database to 18.7.
  [TimescaleDB 2.32.1 release notes](https://github.com/timescale/timescaledb/releases/tag/2.32.1)
- **pgvector 0.8.7** is required because it fixes an IVFFlat index-build buffer
  overflow ([upstream changelog](https://github.com/pgvector/pgvector/blob/master/CHANGELOG.md)).
- **PostGIS 3.7** supports PostgreSQL 18. Its PGDG package brings GEOS 3.15 or
  newer, which enables new functions such as `ST_CoverageEdges`. Raster,
  topology, and SFCGAL remain available as companion extensions. The address
  standardizer and TIGER geocoder are separate packages and are not bundled
  ([release notes](https://postgis.net/2026/10/PostGIS-3.7.0/),
  [coverage function requirements](https://postgis.net/docs/manual-3.7/en/ST_CoverageEdges.html)).
- **PostGIS on 18.6** uses PGDG package revisions before
  `3.7.0+dfsg-1.pgdg13+2`. That rebuild links against `heap_datum_check`,
  a symbol introduced in PostgreSQL 18.7.
  [PGDG PostGIS packages](https://apt.postgresql.org/pub/repos/apt/pool/main/p/postgis/)
- **pgvectorscale** falls back to its declared minimum if the latest release
  API is unavailable or the release has no asset for the selected major and
  architecture. The build log reports the fallback.
- **Apache AGE** reports SQL version 1.8.0, while PGDG's PostgreSQL 18 package
  currently uses version `1.8.0~rc0`. Preserve that distinction when comparing
  package and extension versions.
- **TimescaleDB** is installed from `timescaledb-2-postgresql-<major>`, which carries
  historical versioned `timescaledb` shared libraries as well as the newest.
  A persistent database needs its installed version's library to remain present
  until `ALTER EXTENSION timescaledb UPDATE` runs. Compatibility is qualified for
  the selected upgrade baseline, not every historical database version.
- Pushes to `main` and the weekly rebuild (Sun 02:00 UTC) run all three jobs.
  Manual dispatch defaults to 18.7 and accepts `postgresql_version` to select
  another release. Each job must pass both parity checks before its aliases move.
- **Cosign** resolves the latest stable binary independently of the installer's
  embedded default. The published v4 installer release is used because upstream
  has no floating `v4` tag. GitHub Actions summaries record package and signing
  tool versions; the build log records dependency resolution and fallbacks.

An application that qualifies one TimescaleDB minor line rather than the newest
release builds with `TIMESCALEDB_LINE`. The newest release of that line is
installed from the same all-libraries package and floor-checked against the
line's first release; the other extensions still float:

```
docker build --build-arg POSTGRESQL_VERSION=18.6 --build-arg TIMESCALEDB_LINE=2.27 \
  -t <registry>/cnpg-postgres-ai:18.6-ts2.27 .
```

The same option is available as `TIMESCALEDB_LINE` in local CI and
`timescaledb_line` in workflow dispatch. When both a line and an exact version
are supplied, the exact version must belong to that line.

To pin exact releases instead (parity testing, regression bisection), use the
workflow_dispatch inputs. A pinned version is installed as asked and is not
floor-checked:

```
gh workflow run build.yml \
  -f postgresql_version=18.7 \
  -f pgvector_version=0.8.7 \
  -f postgis_version=3.7.0 \
  -f timescaledb_version=2.32.1 \
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
POSTGRESQL_VERSION=18.7 UPGRADE_FROM_IMAGE=ghcr.io/mssaleh/cnpg-postgres-ai:18-latest \
  ./scripts/local-ci.sh
```

To verify a registry candidate without rebuilding, pass `--verify-only <image>`.
For source checks alone, pass `--check`.
Use an immutable deployed image as `UPGRADE_FROM_IMAGE`, or pass it as the
workflow's `upgrade_from_image`, to qualify that upgrade path. By default CI
tests the previous image of the selected minor release. The first 18.6 release
uses a published 18.6 build and the first 18.7 release uses `18-latest`. The
first 19.0 release verifies restart with persistent data using the candidate
itself. PostgreSQL major upgrades require their own migration and qualification.

## Upgrading a persistent CNPG database

For a database on PostgreSQL 18.6 or earlier, first upgrade its installed
TimescaleDB extension to 2.32.1 or newer on a PostgreSQL version supported by that
TimescaleDB release. Restart PostgreSQL to load the updated loader, as required
by the [TimescaleDB release notes](https://github.com/timescale/timescaledb/releases/tag/2.32.0),
before moving to PostgreSQL 18.7. The 18.6 image provides that intermediate step.
Qualify the prepared 18.6 baseline with the persistent-upgrade check before
moving the database.

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
