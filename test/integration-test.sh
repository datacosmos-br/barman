#!/bin/bash
# Teste de integração do barman (imagem + Helm chart).
# Roda LOCALMENTE com Docker — nenhuma versão deve ser publicada (tag -dc*)
# sem este script sair com código 0.
#
# Uso:   IMAGE=ghcr.io/datacosmos-br/barman:<tag> ./test/integration-test.sh
# Se IMAGE não for passada, a imagem é construída do Dockerfile local.
set -uo pipefail
cd "$(dirname "$0")/.."

CHART="charts/barman"
SUFFIX="$$"
NET="barman-it-${SUFFIX}"
PG="barman-it-pg-${SUFFIX}"
BARMAN_VERSION="${BARMAN_VERSION:-3.18.0}"
IMAGE="${IMAGE:-}"
fail=0

pass() { echo "  [PASS] $1"; }
err()  { echo "  [FAIL] $1"; fail=1; }

cleanup() {
  docker rm -f "${PG}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "=================================================================="
echo " barman — teste de integração"
echo "=================================================================="

# ---- Build da imagem (se IMAGE não foi passada) -------------------------
if [ -z "${IMAGE}" ]; then
  IMAGE="barman:it-${SUFFIX}"
  echo "== Build da imagem (${IMAGE}) =="
  if docker build --build-arg BARMAN_VERSION="${BARMAN_VERSION}" \
        --build-arg SOURCE_INSTALL=0 -t "${IMAGE}" . >/dev/null 2>&1; then
    pass "docker build"
  else
    err "docker build"; echo "TESTS FAILED"; exit 1
  fi
fi
echo "Imagem sob teste: ${IMAGE}"

# ---- Teste 1: helm lint -------------------------------------------------
echo "== Teste 1: helm lint =="
if helm lint "${CHART}" >/dev/null 2>&1; then pass "helm lint"; else err "helm lint"; fi

# ---- Teste 2: helm template renderiza -----------------------------------
echo "== Teste 2: helm template =="
if helm template t "${CHART}" >/dev/null 2>&1; then pass "helm template"; else err "helm template"; fi

# ---- Teste 3: ferramentas presentes na imagem ---------------------------
echo "== Teste 3: ferramentas na imagem =="
if docker run --rm --entrypoint bash "${IMAGE}" -c \
     'command -v barman && command -v barman-cloud-backup && command -v barman-cloud-wal-archive && command -v pg_receivewal && command -v psql' \
     >/dev/null 2>&1; then
  pass "barman + barman-cloud-* + pg_receivewal + psql"
else
  err "ferramentas ausentes na imagem"
fi

# ---- Teste 4: versão do barman ------------------------------------------
echo "== Teste 4: versão do barman =="
if docker run --rm --entrypoint barman "${IMAGE}" --version 2>/dev/null | grep -q "${BARMAN_VERSION}"; then
  pass "barman ${BARMAN_VERSION}"
else
  err "versão do barman inesperada"
fi

# ---- Teste 5: backup real contra um PostgreSQL --------------------------
echo "== Teste 5: backup real (PostgreSQL + barman backup) =="
docker network create "${NET}" >/dev/null 2>&1
docker run -d --name "${PG}" --network "${NET}" \
  -e POSTGRES_PASSWORD=citest -e POSTGRES_HOST_AUTH_METHOD=trust \
  postgres:16 >/dev/null 2>&1

ready=0
for _ in $(seq 1 45); do
  if docker exec "${PG}" pg_isready -U postgres >/dev/null 2>&1; then ready=1; break; fi
  sleep 2
done

if [ "${ready}" != "1" ]; then
  err "PostgreSQL não ficou pronto"
else
  # garante pg_hba de replicação
  docker exec "${PG}" bash -c \
    'echo "host replication all all trust" >> "${PGDATA}/pg_hba.conf"' >/dev/null 2>&1
  docker exec "${PG}" psql -U postgres -tAc 'SELECT pg_reload_conf()' >/dev/null 2>&1

  out=$(docker run --rm --network "${NET}" --entrypoint bash "${IMAGE}" -c "
    set -e
    cat > /etc/barman.conf <<EOF
[barman]
barman_home = /var/lib/barman
barman_user = barman
configuration_files_directory = /etc/barman/barman.d
log_file = \"\"
EOF
    mkdir -p /etc/barman/barman.d
    cat > /etc/barman/barman.d/citest.conf <<EOF
[citest]
active = true
description = \"integration test\"
conninfo = host=${PG} port=5432 user=postgres dbname=postgres
streaming_conninfo = host=${PG} port=5432 user=postgres
backup_method = postgres
streaming_archiver = on
slot_name = barman_ci
create_slot = auto
EOF
    chown -R barman:barman /etc/barman /var/lib/barman
    # barman cron cria o slot e inicia o streamer pg_receivewal
    su barman -c 'barman cron' 2>&1
    sleep 6
    # força um segmento WAL e espera ele ser arquivado pelo streamer
    su barman -c 'barman switch-wal --force --archive citest' 2>&1
    sleep 4
    su barman -c 'barman backup citest' 2>&1
    su barman -c 'barman list-backup citest' 2>&1
  " 2>&1)

  if echo "${out}" | grep -q 'Backup completed'; then
    pass "barman backup concluído (backup físico real)"
  else
    err "barman backup não concluiu"
    echo "${out}" | tail -12 | sed 's/^/    /'
  fi
fi

# ---- Teste 6: restore-validação (base paralela) -------------------------
# Encadeia test/restore-test.sh — prova que o backup é restauravel (restore
# numa base paralela + conferencia de checksum), nos dois metodos.
echo "== Teste 6: restore-validação (test/restore-test.sh) =="
if IMAGE="${IMAGE}" BARMAN_VERSION="${BARMAN_VERSION}" bash test/restore-test.sh; then
  pass "restore-test.sh — backup restaurável validado"
else
  err "restore-test.sh"
fi

echo "=================================================================="
if [ "${fail}" -eq 0 ]; then
  echo " RESULTADO: TODOS OS TESTES PASSARAM"
  exit 0
else
  echo " RESULTADO: TESTES FALHARAM"
  exit 1
fi
