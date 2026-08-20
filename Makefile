.DEFAULT_GOAL := help
.PHONY: help up down logs validate test drill reload clean

help:
	@echo "up        start prometheus, grafana, alertmanager and the exporters"
	@echo "down      stop everything"
	@echo "logs      follow the logs of every service"
	@echo "validate  check every config and unit test the alert rules"
	@echo "test      unit test the alert rules only"
	@echo "drill     stop an exporter and prove the alert fires end to end"
	@echo "reload    reload prometheus without restarting it"
	@echo "clean     stop everything and remove the volumes"

up:
	docker compose up -d

down:
	docker compose down

logs:
	docker compose logs -f

validate:
	./scripts/validate.sh

test:
	docker run --rm -v "$$PWD/prometheus:/etc/prometheus:ro" --entrypoint promtool \
		prom/prometheus:v2.54.1 test rules /etc/prometheus/tests/alert_tests.yml

drill:
	./scripts/trigger-alert.sh node-exporter

reload:
	curl -sf -X POST http://localhost:9090/-/reload && echo "prometheus reloaded"

clean:
	docker compose down -v
