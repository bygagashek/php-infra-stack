.PHONY: up down reset ps logs test replication load

up:          ## Build and start everything, wait for healthchecks
	docker compose up -d --build --wait

down:        ## Stop, keep data
	docker compose down

reset:       ## Stop and delete all data (replication is re-initialized on next up)
	docker compose down -v

ps:
	docker compose ps

logs:
	docker compose logs -f --tail=100

test:        ## End-to-end smoke test of a running stack
	scripts/smoke-test.sh

replication: ## Replica status
	docker compose exec mariadb-replica mariadb -uroot -p$${DB_ROOT_PASSWORD:-root} -e 'SHOW REPLICA STATUS\G' \
		| grep -E 'Running|Behind|Gtid_IO_Pos|Last_.*Error'

load:        ## 2000 requests, 20 in parallel: watch the Grafana dashboard
	docker run --rm --network php-infra-stack_default alpine:3.20 sh -c \
		'seq 2000 | xargs -P 20 -I{} wget -q -O /dev/null http://nginx/'
