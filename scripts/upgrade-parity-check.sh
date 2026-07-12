#!/usr/bin/env bash
# Persistent-upgrade parity: create extensions and graph data on the previous
# public image, restart the same PGDATA on the candidate image, perform the
# supported ALTER EXTENSION updates, and prove AGE data/query compatibility.

set -euxo pipefail

OLD_IMG="${1:?previous image is required}"
NEW_IMG="${2:?candidate image is required}"
SUFFIX="$$"
OLD_CONTAINER="pg-upgrade-old-${SUFFIX}"
NEW_CONTAINER="pg-upgrade-new-${SUFFIX}"
VOLUME="pg-upgrade-data-${SUFFIX}"

cleanup() {
  docker rm -f "${OLD_CONTAINER}" "${NEW_CONTAINER}" >/dev/null 2>&1 || true
  docker volume rm -f "${VOLUME}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker image inspect "${OLD_IMG}" >/dev/null
docker image inspect "${NEW_IMG}" >/dev/null
docker volume create "${VOLUME}" >/dev/null
docker run --rm --user root -v "${VOLUME}:/pgdata" --entrypoint bash "${OLD_IMG}" \
  -c 'install -d -o 26 -g 26 /pgdata'

start_postgres() {
  local image="$1" name="$2"
  docker run -d --name "${name}" --user 26 -v "${VOLUME}:/pgdata" \
    --entrypoint bash "${image}" -c '
      set -e
      export PATH=/usr/lib/postgresql/18/bin:$PATH PGDATA=/pgdata
      if [ ! -s "$PGDATA/PG_VERSION" ]; then
        initdb -D "$PGDATA" --auth=trust --username=postgres >/dev/null
        echo "shared_preload_libraries = '\''timescaledb,age'\''" >> "$PGDATA/postgresql.conf"
        echo "listen_addresses = '\''*'\''" >> "$PGDATA/postgresql.conf"
      fi
      exec postgres -D "$PGDATA"
    '
}

wait_ready() {
  local name="$1"
  for _ in $(seq 1 30); do
    if docker exec "${name}" pg_isready -h localhost -U postgres >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  docker logs "${name}"
  return 1
}

start_postgres "${OLD_IMG}" "${OLD_CONTAINER}"
wait_ready "${OLD_CONTAINER}"

docker exec "${OLD_CONTAINER}" psql -h localhost -U postgres -d postgres -v ON_ERROR_STOP=1 -c "
  CREATE EXTENSION vector;
  CREATE EXTENSION vectorscale CASCADE;
  CREATE EXTENSION postgis;
  CREATE EXTENSION timescaledb;
  CREATE EXTENSION age;
  LOAD 'age';
  SET search_path = ag_catalog, \"\$user\", public;
  SELECT create_graph('upgrade_parity');
  SELECT * FROM cypher('upgrade_parity', \$\$
    CREATE (:Node {release: 'previous'}) RETURN 1
  \$\$) AS (created agtype);
"

docker stop "${OLD_CONTAINER}" >/dev/null
docker rm "${OLD_CONTAINER}" >/dev/null

start_postgres "${NEW_IMG}" "${NEW_CONTAINER}"
wait_ready "${NEW_CONTAINER}"

# Extension SQL/catalog state is database-owned and is not upgraded merely by
# replacing the container image. Update dependencies before dependants, then AGE.
for extension in timescaledb vector vectorscale postgis age; do
  update_sql="$(docker exec "${NEW_CONTAINER}" psql -h localhost -U postgres -d postgres -At -c \
    "SELECT format('ALTER EXTENSION %I UPDATE TO %L;', name, default_version)
       FROM pg_available_extensions
      WHERE name='${extension}' AND installed_version IS DISTINCT FROM default_version")"
  if [ -n "${update_sql}" ]; then
    docker exec "${NEW_CONTAINER}" psql -h localhost -U postgres -d postgres \
      -v ON_ERROR_STOP=1 -c "${update_sql}"
  fi
done

docker exec "${NEW_CONTAINER}" psql -h localhost -U postgres -d postgres -v ON_ERROR_STOP=1 -c "
  LOAD 'age';
  SET search_path = ag_catalog, \"\$user\", public;
  SELECT * FROM cypher('upgrade_parity', \$\$
    MATCH (n:Node) RETURN count(n)
  \$\$) AS (nodes agtype);
  SELECT name, default_version, installed_version
    FROM pg_available_extensions
   WHERE name IN ('vector','vectorscale','postgis','timescaledb','age')
     AND installed_version IS DISTINCT FROM default_version;
"

nodes="$(docker exec "${NEW_CONTAINER}" psql -qAt -h localhost -U postgres -d postgres \
  -v ON_ERROR_STOP=1 -c "
    LOAD 'age';
    SET search_path = ag_catalog, \"\$user\", public;
    SELECT * FROM cypher('upgrade_parity', \$\$
      MATCH (n:Node) RETURN count(n)
    \$\$) AS (nodes agtype);
  ")"
test "${nodes}" = "1"

mismatches="$(docker exec "${NEW_CONTAINER}" psql -h localhost -U postgres -d postgres -At -c \
  "SELECT count(*) FROM pg_available_extensions
    WHERE name IN ('vector','vectorscale','postgis','timescaledb','age')
      AND installed_version IS DISTINCT FROM default_version")"
test "${mismatches}" = "0"

echo "OK: persistent database upgraded cleanly and AGE graph data survived."
