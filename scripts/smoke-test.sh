#!/usr/bin/env bash
# Checks a running stack end to end: HTTP through nginx and php-fpm, replication, every Prometheus target.
# Usage: docker compose up -d --build --wait && scripts/smoke-test.sh
set -euo pipefail

HTTP="http://localhost:${HTTP_PORT:-8080}"
PROMETHEUS="http://localhost:${PROMETHEUS_PORT:-9090}"
compose() { docker compose "$@"; }

fail() { echo "FAIL: $*" >&2; exit 1; }
retry() { # retry <attempts> <command...>
    local n=$1; shift
    for _ in $(seq "$n"); do "$@" && return 0; sleep 2; done
    return 1
}

echo "== health"
retry 30 curl -fsS "$HTTP/health" || fail "/health is not 200"
echo

echo "== write to primary, read from replica"
curl -fsS "$HTTP/" || fail "GET / failed"
for _ in 1 2 3 4; do curl -fsS -o /dev/null "$HTTP/"; done

replica_count() {
    compose exec -T mariadb-replica mariadb -uroot -p"${DB_ROOT_PASSWORD:-root}" -N -e 'SELECT COUNT(*) FROM app.visits'
}
primary_count=$(compose exec -T mariadb-primary mariadb -uroot -p"${DB_ROOT_PASSWORD:-root}" -N -e 'SELECT COUNT(*) FROM app.visits')
retry 10 bash -c "[ \"\$(docker compose exec -T mariadb-replica mariadb -uroot -p'${DB_ROOT_PASSWORD:-root}' -N -e 'SELECT COUNT(*) FROM app.visits')\" = '$primary_count' ]" \
    || fail "replica has $(replica_count) visits, primary has $primary_count"
echo "primary and replica both have $primary_count visits"

echo "== replication threads"
status=$(compose exec -T mariadb-replica mariadb -uroot -p"${DB_ROOT_PASSWORD:-root}" -e 'SHOW REPLICA STATUS\G')
grep -q 'Slave_IO_Running: Yes' <<<"$status" || fail "IO thread is not running: $status"
grep -q 'Slave_SQL_Running: Yes' <<<"$status" || fail "SQL thread is not running: $status"
grep -E 'Gtid_IO_Pos|Seconds_Behind_Master' <<<"$status"

echo "== replica rejects application writes"
if compose exec -T mariadb-replica mariadb -uapp -p"${DB_PASSWORD:-app}" app -e "INSERT INTO visits (path) VALUES ('/x')" 2>/dev/null; then
    fail "the application user could write to the replica"
fi
echo "read_only works"

echo "== prometheus targets"
targets_up() {
    local down
    down=$(curl -fsS "$PROMETHEUS/api/v1/targets" \
        | python3 -c 'import json,sys; t=json.load(sys.stdin)["data"]["activeTargets"]; print(" ".join(x["labels"]["job"] + "/" + x["labels"]["instance"] for x in t if x["health"] != "up")); sys.exit(0 if t else 1)') || return 1
    [ -z "$down" ] || { echo "not up yet: $down"; return 1; }
}
retry 30 targets_up || fail "some Prometheus targets are down"

echo "== metrics carry data"
query() { curl -fsS "$PROMETHEUS/api/v1/query" --data-urlencode "query=$1" | python3 -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print(r[0]["value"][1] if r else "")'; }
for expr in 'nginx_connections_active' 'phpfpm_up' 'mysql_up{role="replica"}' 'mysql_slave_status_slave_sql_running' 'redis_up'; do
    value=$(query "$expr")
    [ -n "$value" ] || fail "no data for $expr"
    printf '%-45s %s\n' "$expr" "$value"
done

echo "OK"
