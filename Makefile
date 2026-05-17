# Barman (fork DataCosmos) — automação de operações e testes.
SHELL := /bin/bash

.PHONY: help status status-watch test integration-test restore-test

help:  ## Lista os targets disponíveis
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-18s\033[0m %s\n",$$1,$$2}'

status:  ## Status consolidado de backups/WAL de todos os clusters (snapshot)
	@bash scripts/cluster-status.sh

status-watch:  ## Acompanha o status de backups/WAL (refresh contínuo)
	@WATCH=1 bash scripts/cluster-status.sh

test: integration-test  ## Alias de integration-test

integration-test:  ## Teste de integração local (build, chart, backup real)
	@bash test/integration-test.sh

restore-test:  ## Teste de restauração numa base paralela (postgres + rsync)
	@bash test/restore-test.sh
