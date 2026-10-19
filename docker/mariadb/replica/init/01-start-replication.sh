#!/bin/bash
# Runs once, on the first start of an empty data directory.
# Both servers start empty, so the replica can stream the primary's binlog from the very beginning
# (empty gtid_slave_pos). For an existing primary, restore a backup first and set gtid_slave_pos to
# the GTID position recorded in it (mariadb-backup writes it to xtrabackup_binlog_info).

mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" <<SQL
CHANGE MASTER TO
    MASTER_HOST = 'mariadb-primary',
    MASTER_PORT = 3306,
    MASTER_USER = 'repl',
    MASTER_PASSWORD = '${REPLICATION_PASSWORD}',
    MASTER_USE_GTID = slave_pos,
    MASTER_CONNECT_RETRY = 5;
START SLAVE;
SQL
