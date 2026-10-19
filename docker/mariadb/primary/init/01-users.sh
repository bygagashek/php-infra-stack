#!/bin/bash
# Runs once, on the first start of an empty data directory.
# These statements are written to the binlog, so the replica receives the same users.

mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" <<SQL
CREATE USER 'repl'@'%' IDENTIFIED BY '${REPLICATION_PASSWORD}';
GRANT REPLICATION SLAVE ON *.* TO 'repl'@'%';

CREATE USER 'exporter'@'%' IDENTIFIED BY '${EXPORTER_PASSWORD}' WITH MAX_USER_CONNECTIONS 3;
GRANT PROCESS, REPLICATION CLIENT, SLAVE MONITOR, SELECT ON *.* TO 'exporter'@'%';
SQL
