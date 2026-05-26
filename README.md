# cnpg-postgres-ai

CloudNativePG-compatible PostgreSQL 18 image with an AI / graph extension bundle:

- **pgvector** — vector data type + HNSW/IVF indexes
- **pgvectorscale** — DiskANN-backed vector index (Timescale)
- **PostGIS** — geospatial
- **TimescaleDB** — time-series + hypertables (Apache-2.0 OSS variant; no TSL/enterprise)
- **Apache AGE** — graph database extension with openCypher queries on PostgreSQL

## Why this image

CloudNativePG (CNPG) drives Postgres lifecycle as UID 26 and replaces Patroni / Spilo with its own integrated backup + failover. Standard distro `postgres:N` images and the upstream `timescale/timescaledb-ha:pgN-tsM-oss` image don't fit cleanly — this image starts from `ghcr.io/cloudnative-pg/postgresql:18-system-trixie` (CNPG's official baseline) and layers the five extensions on top.

Suitable for: AI-agent platforms (long-term memory backed by pgvector + DiskANN), knowledge-graph workloads (AGE), geospatial + time-series (PostGIS + TimescaleDB) — typically all four together in modern data products.

## Image tags

Published to **both** registries on every build:

- `ghcr.io/mssaleh/cnpg-postgres-ai:<tag>` — public
- `harbor.cluster.nxu.ae/library/cnpg-postgres-ai:<tag>` — internal mirror (for the c1 cluster)

Tag scheme:

- `18-latest` — floating, always newest weekly build
- `18-YYYY-MM-DD-<sha>` — immutable, **use this in production CNPG `Cluster.spec.imageName`**

The Hindsight / kagent / etc. CNPG clusters in c1 pin to the dated tag. The floating tag is for dev/test only — CNPG's webhook validator (RUNBOOK §11 LL-33) requires the tag to start with the PG major (here, `18-`).

## Usage in CloudNativePG

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: my-app-db
spec:
  instances: 1
  imageName: ghcr.io/mssaleh/cnpg-postgres-ai:18-latest

  postgresql:
    # TimescaleDB MUST be in shared_preload_libraries (it's a hard requirement).
    # Apache AGE works without preload (LOAD 'age' per-session) but preloading
    # avoids the per-session LOAD and works better with connection pools.
    # AGE adds ~1MB resident memory per backend whether or not graphs are used,
    # so leave AGE preload off unless your app uses graph queries.
    shared_preload_libraries:
      - timescaledb
      # - age   # uncomment if your app uses openCypher / AGE
    parameters:
      # pgvectorscale's DiskANN index builder benefits from generous
      # maintenance_work_mem on initial index creation. Default 64 MB
      # spills to disk for vector tables > ~1M rows.
      maintenance_work_mem: "1GB"

  bootstrap:
    initdb:
      database: app
      owner: app
      postInitApplicationSQL:
        - CREATE EXTENSION IF NOT EXISTS vector;
        - CREATE EXTENSION IF NOT EXISTS vectorscale CASCADE;
        - CREATE EXTENSION IF NOT EXISTS postgis;
        - CREATE EXTENSION IF NOT EXISTS timescaledb;
        # Apache AGE — uncomment if you want graph features
        # - CREATE EXTENSION IF NOT EXISTS age;
        # - LOAD 'age';
        # - SET search_path = ag_catalog, "$user", public;
```

## Version policy

- **PostgreSQL** is pinned to MAJOR 18 via the CNPG base image tag.
- All five extensions float to the latest patch available in the PGDG / Timescale apt repos / GitHub releases at build time.
- Weekly CI rebuild (Sun 02:00 UTC) picks up security patches automatically.

To pin a specific patch level (parity testing, regression debugging), use the workflow_dispatch inputs:

```
gh workflow run build.yml \
  -f pgvector_version=0.8.2 \
  -f postgis_version=3.6.3 \
  -f timescaledb_version=2.27.1 \
  -f pgvectorscale_version=0.9.0 \
  -f age_version=1.7.0
```

## Parity check

A parity step runs in CI against the freshly-built image: it initdbs Postgres, sets `shared_preload_libraries='timescaledb,age'`, starts the cluster, and runs `CREATE EXTENSION` for all five plus a basic AGE graph operation. Build fails if any extension is missing or fails to load.

## Apache AGE specifics

AGE provides openCypher graph queries on top of relational PostgreSQL. After `CREATE EXTENSION age` you typically run:

```sql
LOAD 'age';
SET search_path = ag_catalog, "$user", public;

SELECT create_graph('myapp');

SELECT * FROM cypher('myapp', $$
  CREATE (n:Person {name: 'Alice'})-[:KNOWS]->(m:Person {name: 'Bob'})
  RETURN n, m
$$) AS (n agtype, m agtype);
```

If you preload AGE via `shared_preload_libraries`, the `LOAD 'age'` line isn't needed. Set `search_path` in `postgresql.parameters` for cluster-wide effect, or via `ALTER ROLE <app> SET search_path` per-user.

## License

Apache 2.0
