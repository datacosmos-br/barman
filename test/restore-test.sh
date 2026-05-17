#!/bin/bash
# Teste de RESTORE-VALIDAÇÃO do barman — roda LOCALMENTE com Docker.
#
# Prova que um backup é genuinamente restaurável: faz backup de um PostgreSQL
# fonte, restaura o backup numa SEGUNDA base PostgreSQL paralela e confere que
# um dataset-marcador (contagem + checksum) bate com a fonte.
# Cobre os dois métodos de backup: `postgres` (pg_basebackup) e `rsync` (SSH).
#
# Uso:  IMAGE=ghcr.io/datacosmos-br/barman:<tag> ./test/restore-test.sh
# Sem IMAGE, a imagem é construída do Dockerfile local.
# Nenhuma tag -dc* deve ser publicada sem este script sair com código 0.
set -uo pipefail
cd "$(dirname "$0")/.."

SUFFIX="$$"
NET="barman-rt-${SUFFIX}"
SRC="barman-rt-src-${SUFFIX}"          # PostgreSQL fonte
DST="barman-rt-dst-${SUFFIX}"          # PostgreSQL paralelo (restaurado)
VOL="barman-rt-recover-${SUFFIX}"      # volume com o PGDATA recuperado (postgres)
VOL2="barman-rt-recover2-${SUFFIX}"    # volume com o PGDATA recuperado (rsync)
BARMAN_VERSION="${BARMAN_VERSION:-3.18.0}"
IMAGE="${IMAGE:-}"
ROWS=2000
fail=0

pass() { echo "  [PASS] $1"; }
err()  { echo "  [FAIL] $1"; fail=1; }

cleanup() {
  docker rm -f "${SRC}" "${DST}" >/dev/null 2>&1 || true
  docker volume rm "${VOL}" "${VOL2}" >/dev/null 2>&1 || true
  docker network rm "${NET}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "=================================================================="
echo " barman — teste de restore-validação (base paralela)"
echo "=================================================================="

if [ -z "${IMAGE}" ]; then
  IMAGE="barman:rt-${SUFFIX}"
  echo "== Build da imagem (${IMAGE}) =="
  if docker build --build-arg BARMAN_VERSION="${BARMAN_VERSION}" \
        --build-arg SOURCE_INSTALL=0 -t "${IMAGE}" . >/dev/null 2>&1; then
    pass "docker build"
  else
    err "docker build"; echo "RESULTADO: TESTES FALHARAM"; exit 1
  fi
fi
echo "Imagem sob teste: ${IMAGE}"

docker network create "${NET}" >/dev/null 2>&1
docker volume create "${VOL}" >/dev/null 2>&1
docker volume create "${VOL2}" >/dev/null 2>&1

# ---- PostgreSQL fonte + dataset-marcador --------------------------------
echo "== Preparando PostgreSQL fonte + dataset-marcador (${ROWS} linhas) =="
docker run -d --name "${SRC}" --network "${NET}" \
  -e POSTGRES_PASSWORD=rt -e POSTGRES_HOST_AUTH_METHOD=trust \
  postgres:16 >/dev/null 2>&1

ready=0
for _ in $(seq 1 45); do
  docker exec "${SRC}" pg_isready -U postgres >/dev/null 2>&1 && { ready=1; break; }
  sleep 2
done
[ "${ready}" = 1 ] || { err "PostgreSQL fonte não ficou pronto"; echo "RESULTADO: TESTES FALHARAM"; exit 1; }

docker exec "${SRC}" bash -c 'echo "host replication all all trust" >> "${PGDATA}/pg_hba.conf"' >/dev/null 2>&1
docker exec "${SRC}" psql -U postgres -tAc 'SELECT pg_reload_conf()' >/dev/null 2>&1
docker exec "${SRC}" psql -U postgres -tAc \
  "CREATE TABLE barman_validation AS SELECT g AS id, md5(g::text) AS payload FROM generate_series(1, ${ROWS}) g" >/dev/null 2>&1
SRC_SUM=$(docker exec "${SRC}" psql -U postgres -tAc \
  "SELECT count(*) || ':' || md5(string_agg(payload, '' ORDER BY id)) FROM barman_validation" 2>/dev/null | tr -d '[:space:]')
echo "  marcador na fonte: ${SRC_SUM}"
[ -n "${SRC_SUM}" ] && pass "dataset-marcador criado" || err "falha ao criar marcador"

# ---- Função: backup + recover + validação numa base paralela ------------
# $1 = método (postgres|rsync) ; $2 = ssh_command extra (vazio p/ postgres)
run_method() {
  local method="$1" extra_conf="$2"
  echo "== Método '${method}': backup -> recover -> base paralela =="

  docker run --rm --network "${NET}" -v "${VOL}":/recover --entrypoint bash "${IMAGE}" -c "
    set -e
    cat > /etc/barman.conf <<EOF
[barman]
barman_home = /var/lib/barman
barman_user = barman
configuration_files_directory = /etc/barman/barman.d
log_file = \"\"
EOF
    mkdir -p /etc/barman/barman.d
    cat > /etc/barman/barman.d/rt.conf <<EOF
[rt]
active = true
description = \"restore test\"
conninfo = host=${SRC} port=5432 user=postgres dbname=postgres
streaming_conninfo = host=${SRC} port=5432 user=postgres
backup_method = ${method}
streaming_archiver = on
slot_name = barman_rt
create_slot = auto
${extra_conf}
EOF
    chown -R barman:barman /etc/barman /var/lib/barman /recover
    su barman -c 'barman cron' >/dev/null 2>&1
    sleep 8
    su barman -c 'barman switch-wal --force --archive rt' >/dev/null 2>&1
    sleep 4
    su barman -c 'barman backup rt' 2>&1 | grep -iE 'Backup (completed|size)|ERROR' || true
    bid=\$(su barman -c 'barman list-backup rt' 2>/dev/null | awk '{print \$2; exit}')
    echo \"backup-id=\${bid}\"
    su barman -c \"barman recover rt \${bid} /recover\" 2>&1 | grep -iE 'Your PostgreSQL server|ERROR|recovery' | tail -2 || true
    # PostgreSQL roda como uid 999 na imagem oficial
    chown -R 999:999 /recover && chmod 700 /recover
    rm -f /recover/recovery.signal /recover/standby.signal 2>/dev/null || true
  " 2>&1 | grep -vE '^[0-9]{4}-[0-9]{2}.*(INFO|DEBUG)' | sed 's/^/    /' | tail -8

  # sobe a base paralela sobre o PGDATA recuperado
  docker rm -f "${DST}" >/dev/null 2>&1 || true
  docker run -d --name "${DST}" --network "${NET}" \
    -e POSTGRES_HOST_AUTH_METHOD=trust \
    -v "${VOL}":/var/lib/postgresql/data postgres:16 >/dev/null 2>&1

  local dready=0
  for _ in $(seq 1 60); do
    docker exec "${DST}" pg_isready -U postgres >/dev/null 2>&1 && { dready=1; break; }
    sleep 2
  done
  if [ "${dready}" != 1 ]; then
    err "[${method}] base paralela não abriu após o restore"
    docker logs "${DST}" 2>&1 | tail -6 | sed 's/^/    /'
    return
  fi

  local dst_sum
  dst_sum=$(docker exec "${DST}" psql -U postgres -tAc \
    "SELECT count(*) || ':' || md5(string_agg(payload, '' ORDER BY id)) FROM barman_validation" 2>/dev/null | tr -d '[:space:]')
  echo "  marcador na base paralela: ${dst_sum}"
  if [ -n "${dst_sum}" ] && [ "${dst_sum}" = "${SRC_SUM}" ]; then
    pass "[${method}] restore validado — base paralela idêntica à fonte"
  else
    err "[${method}] marcador divergente (fonte=${SRC_SUM} restore=${dst_sum})"
  fi
}

# ---- Caso 1: backup_method = postgres -----------------------------------
run_method postgres ""

# ---- Caso 2: backup_method = rsync (sobre SSH) --------------------------
echo "== Preparando SSH no PostgreSQL fonte (caso rsync) =="
KEYDIR=$(mktemp -d)
ssh-keygen -t ed25519 -f "${KEYDIR}/id" -N '' -q
if docker exec "${SRC}" bash -c '
      apt-get update >/dev/null 2>&1 && \
      apt-get install -y --no-install-recommends openssh-server rsync >/dev/null 2>&1 && \
      mkdir -p /run/sshd ~postgres/.ssh && \
      ssh-keygen -A >/dev/null 2>&1 && \
      usermod -s /bin/bash -p "*" postgres >/dev/null 2>&1 && \
      chmod 755 ~postgres && \
      chown postgres:postgres ~postgres/.ssh && chmod 700 ~postgres/.ssh' >/dev/null 2>&1; then
  docker exec -i "${SRC}" bash -c 'cat >> ~postgres/.ssh/authorized_keys && chown postgres:postgres ~postgres/.ssh/authorized_keys && chmod 600 ~postgres/.ssh/authorized_keys' < "${KEYDIR}/id.pub" >/dev/null 2>&1
  docker exec -d "${SRC}" /usr/sbin/sshd >/dev/null 2>&1
  sleep 3
  pass "sshd + rsync instalados no PostgreSQL fonte"
  # injeta a chave privada num run do barman e roda o caso rsync
  PRIV=$(cat "${KEYDIR}/id")
  RSYNC_CONF="ssh_command = ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR postgres@${SRC}
reuse_backup = link
parallel_jobs = 2
network_compression = true"
  # o run_method usa /etc/barman/barman.d/rt.conf; para rsync precisamos da
  # chave — recriamos o run aqui com a chave instalada.
  docker exec "${SRC}" psql -U postgres -tAc \
    "INSERT INTO barman_validation SELECT g, md5(g::text) FROM generate_series($((ROWS+1)), $((ROWS*2))) g" >/dev/null 2>&1
  SRC_SUM=$(docker exec "${SRC}" psql -U postgres -tAc \
    "SELECT count(*) || ':' || md5(string_agg(payload, '' ORDER BY id)) FROM barman_validation" 2>/dev/null | tr -d '[:space:]')
  docker run --rm --network "${NET}" -v "${VOL2}":/recover -e PRIV="${PRIV}" --entrypoint bash "${IMAGE}" -c "
    set -e
    install -d -m 0700 -o barman -g barman ~barman/.ssh
    printf '%s\n' \"\$PRIV\" > ~barman/.ssh/id_rsa
    chown barman:barman ~barman/.ssh/id_rsa && chmod 600 ~barman/.ssh/id_rsa
    cat > /etc/barman.conf <<EOF
[barman]
barman_home = /var/lib/barman
barman_user = barman
configuration_files_directory = /etc/barman/barman.d
log_file = \"\"
EOF
    mkdir -p /etc/barman/barman.d
    cat > /etc/barman/barman.d/rt.conf <<EOF
[rt]
active = true
description = \"restore test rsync\"
conninfo = host=${SRC} port=5432 user=postgres dbname=postgres
streaming_conninfo = host=${SRC} port=5432 user=postgres
backup_method = rsync
${RSYNC_CONF}
streaming_archiver = on
slot_name = barman_rt
create_slot = auto
EOF
    chown -R barman:barman /etc/barman /var/lib/barman /recover
    su barman -c 'barman cron' >/dev/null 2>&1; sleep 8
    su barman -c 'barman switch-wal --force --archive rt' >/dev/null 2>&1; sleep 4
    su barman -c 'barman backup rt' 2>&1 | grep -iE 'Backup (completed|size)|ERROR' || true
    bid=\$(su barman -c 'barman list-backup rt 2>/dev/null' | awk 'NF>1{print \$2; exit}')
    if [ -z \"\${bid}\" ]; then echo 'RSYNC-BACKUP-FALHOU (sem backup p/ recuperar)'; exit 1; fi
    su barman -c \"barman recover rt \${bid} /recover\" 2>&1 | grep -iE 'ERROR|prepared for recovery' | tail -1 || true
    chown -R 999:999 /recover && chmod 700 /recover
    rm -f /recover/recovery.signal /recover/standby.signal 2>/dev/null || true
  " 2>&1 | grep -vE '^[0-9]{4}-[0-9]{2}.*(INFO|DEBUG)' | sed 's/^/    /' | tail -6
  docker rm -f "${DST}" >/dev/null 2>&1 || true
  docker run -d --name "${DST}" --network "${NET}" -e POSTGRES_HOST_AUTH_METHOD=trust \
    -v "${VOL2}":/var/lib/postgresql/data postgres:16 >/dev/null 2>&1
  dready=0
  for _ in $(seq 1 60); do
    docker exec "${DST}" pg_isready -U postgres >/dev/null 2>&1 && { dready=1; break; }
    sleep 2
  done
  if [ "${dready}" = 1 ]; then
    dst_sum=$(docker exec "${DST}" psql -U postgres -tAc \
      "SELECT count(*) || ':' || md5(string_agg(payload, '' ORDER BY id)) FROM barman_validation" 2>/dev/null | tr -d '[:space:]')
    if [ -n "${dst_sum}" ] && [ "${dst_sum}" = "${SRC_SUM}" ]; then
      pass "[rsync] restore validado — base paralela idêntica à fonte"
    else
      err "[rsync] marcador divergente (fonte=${SRC_SUM} restore=${dst_sum})"
    fi
  else
    err "[rsync] base paralela não abriu após o restore"
    docker logs "${DST}" 2>&1 | tail -6 | sed 's/^/    /'
  fi
else
  err "não foi possível preparar sshd no PostgreSQL fonte (caso rsync)"
fi
rm -rf "${KEYDIR}" 2>/dev/null || true

echo "=================================================================="
if [ "${fail}" -eq 0 ]; then
  echo " RESULTADO: TODOS OS TESTES PASSARAM"
  exit 0
else
  echo " RESULTADO: TESTES FALHARAM"
  exit 1
fi
