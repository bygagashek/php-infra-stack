# php-infra-stack

[![CI](https://github.com/bygagashek/php-infra-stack/actions/workflows/ci.yml/badge.svg)](https://github.com/bygagashek/php-infra-stack/actions/workflows/ci.yml)

A production-shaped PHP stack in one `docker compose up`: nginx → php-fpm → MariaDB primary with an
asynchronous GTID replica, Redis, and Prometheus + Grafana with exporters for every component and
ready-made alerts. CI starts the whole stack and runs an end-to-end smoke test against it.

![Grafana dashboard under `make load`](docs/dashboard.png)

```
                ┌──────────┐   FastCGI   ┌──────────┐   writes   ┌─────────────────┐  binlog (GTID)  ┌─────────────────┐
  :8080 ──────▶ │  nginx   │ ──────────▶ │ php-fpm  │ ─────────▶ │ MariaDB primary │ ──────────────▶ │ MariaDB replica │
                └──────────┘             └──────────┘ ─────────▶ └─────────────────┘                 └─────────────────┘
                                              │          reads ──────────────────────────────────────────────▲
                                              ▼
                                         ┌─────────┐
                                         │  Redis  │
                                         └─────────┘

  exporters: nginx · php-fpm · mysqld ×2 · redis  ──▶  Prometheus :9090 (alerts)  ──▶  Grafana :3000
```

## Run

```bash
make up      # docker compose up -d --build --wait
make test    # end-to-end smoke test
make load    # 2000 requests, then look at the dashboard
```

| URL | |
|---|---|
| http://localhost:8080 | demo app: writes a row to the primary, reads it back from the replica |
| http://localhost:8080/health | readiness of primary, replica and Redis; `503` if any is down |
| http://localhost:3000 | Grafana, dashboard "PHP stack" (anonymous view, admin / `admin`) |
| http://localhost:9090/alerts | Prometheus alerts |

Passwords and ports come from environment variables with local defaults (`DB_PASSWORD`, `GRAFANA_PASSWORD`,
`HTTP_PORT`, …); put them in `.env` for anything but a laptop.

## What is configured and why

**Replication.** Row-based binlog with GTIDs and `gtid_strict_mode`. The replica follows by GTID
(`MASTER_USE_GTID = slave_pos`) instead of file + position, so it can be re-pointed to another server after a
failover without calculating offsets. It applies changes with 4 parallel threads in optimistic mode, which keeps
the primary's commit order. `read_only` on the replica stops the application from writing there by mistake;
the smoke test checks that such a write is refused.

Users and the schema are created only on the primary and reach the replica through the binlog. Creating the
application user on both servers looks harmless, but replicating the primary's `CREATE USER` then fails on the
replica with a duplicate and stops replication.

**Replication lag is visible to the application.** `GET /` writes a row and immediately reads it from the
replica, reporting whether it was already there. This is the reason reads that must see the user's own
write go to the primary.

**Durability.** `sync_binlog = 1` and `innodb_flush_log_at_trx_commit = 1` on the primary: a committed
transaction survives a crash and is in the binlog, so the replica will get it.

**php-fpm.** `pm = dynamic` sized by memory (`max_children ≈ memory for PHP / worker RSS`), workers recycled
after 1000 requests, slow log with stack traces for requests over 2 s, status and ping endpoints for the exporter
and the healthcheck. OPcache is on. Timestamps are validated because sources are mounted; an image with baked-in
code should turn that off.

**nginx.** Only `index.php` is ever executed, any other `.php` path is a 404. `stub_status` and the php-fpm
ping live on a second server block that is not published to the host.

**Redis.** A cache, not a store: `maxmemory` with `allkeys-lru`, persistence off.

**Healthchecks and start order.** php-fpm starts only after both databases and Redis are healthy; the replica
starts after the primary. `docker compose up --wait` returns when everything is ready, which is what CI relies on.

## Alerts

| Alert | Condition |
|---|---|
| `TargetDown` | an exporter is not scraped for 1 min |
| `MariaDBDown` | `mysql_up == 0` |
| `ReplicationStopped` | IO or SQL replication thread is not running |
| `ReplicationLag` | replica more than 30 s behind for 2 min |
| `PhpFpmPoolExhausted` | requests wait in the php-fpm listen queue: no free workers |
| `RedisMemoryHigh` | over 90% of `maxmemory`, keys are being evicted |

## Try breaking it

```bash
docker compose exec mariadb-replica mariadb -uroot -proot -e 'STOP REPLICA SQL_THREAD'
make load                     # replica_has_it_immediately: false; ReplicationStopped fires in a minute
docker compose exec mariadb-replica mariadb -uroot -proot -e 'START REPLICA SQL_THREAD'
make replication              # catches up from its GTID position

docker compose stop redis     # /health → 503 with "redis": "down"
```

## Adding a replica to a primary that already has data

Here both servers start empty, so the replica simply reads the binlog from the beginning. With an existing
primary, take a `mariadb-backup` snapshot, restore it on the new replica, set `gtid_slave_pos` to the GTID
recorded in the backup (`xtrabackup_binlog_info`), then `CHANGE MASTER TO … MASTER_USE_GTID = slave_pos`.

## License

MIT
