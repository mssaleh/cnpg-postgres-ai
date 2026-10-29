#!/usr/bin/env bash
# Fresh-install parity for all extensions and preloaded AGE graph queries.
# Usage: ./scripts/parity-check.sh [image]

set -euxo pipefail

IMG="${1:-ghcr.io/mssaleh/cnpg-postgres-ai:18-latest}"
CONTAINER_NAME="${PARITY_CONTAINER_NAME:-pg-parity-$$}"

if docker image inspect "${IMG}" >/dev/null 2>&1; then
  echo "Using local image ${IMG}"
else
  docker pull "${IMG}"
fi

cleanup() {
  if [ "$?" -ne 0 ]; then
    docker logs "${CONTAINER_NAME}" || true
  fi
  docker rm -f "${CONTAINER_NAME}" || true
}
trap cleanup EXIT

docker run -d --name "${CONTAINER_NAME}" --entrypoint bash "${IMG}" -c '
  set -e
  export PATH=/usr/lib/postgresql/18/bin:$PATH PGDATA=/tmp/pgdata
  mkdir -p "$PGDATA" && chmod 700 "$PGDATA"
  initdb -D "$PGDATA" --auth=trust --username=postgres >/dev/null
  echo "shared_preload_libraries = '\''timescaledb,age'\''" >> "$PGDATA/postgresql.conf"
  echo "listen_addresses = '\''*'\''" >> "$PGDATA/postgresql.conf"
  exec postgres -D "$PGDATA"
'

ready=false
for _ in $(seq 1 30); do
  if docker exec "${CONTAINER_NAME}" pg_isready -h localhost -U postgres >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 2
done
"${ready}"

docker exec -i "${CONTAINER_NAME}" psql -X -h localhost -U postgres -d postgres -v ON_ERROR_STOP=1 <<'SQL'
CREATE EXTENSION vector;
CREATE EXTENSION vectorscale CASCADE;
CREATE EXTENSION postgis;
CREATE EXTENSION timescaledb;
CREATE EXTENSION age;
SELECT extname, extversion FROM pg_extension
WHERE extname IN ('vector', 'vectorscale', 'postgis', 'timescaledb', 'age')
ORDER BY extname;

SET search_path = ag_catalog, "$user", public;
SELECT create_graph('parity');
SELECT * FROM cypher('parity', $$
  CREATE (a:Node {n: 1})-[:LINK]->(b:Node {n: 2}) RETURN a, b
$$) AS (a agtype, b agtype);
DO $check$
BEGIN
  IF (SELECT c FROM cypher('parity', $$
    MATCH (x:Node) RETURN count(x)
  $$) AS (c agtype)) IS DISTINCT FROM '2'::agtype THEN
    RAISE EXCEPTION 'AGE graph node count differs from 2';
  END IF;
END
$check$;
SELECT drop_graph('parity', true);
SQL

echo "OK: all extensions loaded and preloaded AGE returned the expected graph."
