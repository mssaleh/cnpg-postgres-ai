#!/usr/bin/env bash
# Local parity check — run the freshly-built image, init Postgres, and
# verify all five extensions install + AGE round-trips a Cypher query.
#
# This script mirrors the "Parity check" step in .github/workflows/build.yml
# so you can reproduce CI behaviour locally.
#
# Usage:
#   ./scripts/parity-check.sh                     # tests the floating 18-latest
#   ./scripts/parity-check.sh ghcr.io/<repo>:tag  # tests a specific image

set -euxo pipefail

IMG="${1:-ghcr.io/mssaleh/cnpg-postgres-ai:18-latest}"

if docker image inspect "${IMG}" >/dev/null 2>&1; then
  echo "Using local image ${IMG}"
else
  docker pull "${IMG}"
fi

docker run -d --name pg-parity \
  --entrypoint bash \
  "${IMG}" -c '
    set -e
    export PATH=/usr/lib/postgresql/18/bin:$PATH PGDATA=/tmp/pgdata
    mkdir -p "$PGDATA" && chmod 700 "$PGDATA"
    initdb -D "$PGDATA" --auth=trust --username=postgres >/dev/null
    echo "shared_preload_libraries = '"'"'timescaledb,age'"'"'" >> "$PGDATA/postgresql.conf"
    echo "listen_addresses = '"'"'*'"'"'" >> "$PGDATA/postgresql.conf"
    exec postgres -D "$PGDATA"
  '

trap 'docker rm -f pg-parity || true' EXIT

# Wait for ready
for i in $(seq 1 30); do
  if docker exec pg-parity bash -c '/usr/lib/postgresql/18/bin/pg_isready -h localhost -U postgres' >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

# Step 1 — all 5 extensions install + versions
docker exec pg-parity bash -c '
  /usr/lib/postgresql/18/bin/psql -h localhost -U postgres -d postgres -v ON_ERROR_STOP=1 -c "
    CREATE EXTENSION vector;
    CREATE EXTENSION vectorscale CASCADE;
    CREATE EXTENSION postgis;
    CREATE EXTENSION timescaledb;
    CREATE EXTENSION age;
    SELECT extname, extversion FROM pg_extension
      WHERE extname IN ('"'"'vector'"'"','"'"'vectorscale'"'"','"'"'postgis'"'"','"'"'timescaledb'"'"','"'"'age'"'"')
      ORDER BY extname;
  "
'

# Step 2 — AGE round-trip: create graph + Cypher query
docker exec pg-parity bash -c '
  /usr/lib/postgresql/18/bin/psql -h localhost -U postgres -d postgres -v ON_ERROR_STOP=1 -c "
    LOAD '"'"'age'"'"';
    SET search_path = ag_catalog, \"\$user\", public;
    SELECT create_graph('"'"'parity'"'"');
    SELECT * FROM cypher('"'"'parity'"'"', \$\$
      CREATE (a:Node {n: 1})-[:LINK]->(b:Node {n: 2}) RETURN a, b
    \$\$) AS (a agtype, b agtype);
    SELECT * FROM cypher('"'"'parity'"'"', \$\$
      MATCH (x:Node) RETURN count(x)
    \$\$) AS (c agtype);
    SELECT drop_graph('"'"'parity'"'"', true);
  "
'

echo "OK: all 5 extensions loaded + AGE Cypher round-trip succeeded."
