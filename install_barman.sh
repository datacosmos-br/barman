#!/bin/bash

set -exo pipefail
shopt -s nullglob

# Instala o barman + barman-cli-cloud (backup/WAL para object storage S3) +
# extras de compressão (zstd/lz4). pip vem do pacote apt python3-pip
# (Debian bookworm / Python 3.11+). Cria o usuário de sistema 'barman'
# com uid/gid fixos (10001) para casar com o securityContext do Helm chart.

PIP="python3 -m pip install --break-system-packages --no-cache-dir"

if [[ "${SOURCE_INSTALL}" == "1" ]]; then
    apt-get update
    apt-get install -y --no-install-recommends git
    rm -rf /var/lib/apt/lists/*
    ${PIP} "barman[cloud,zstandard,lz4] @ git+${BARMAN_GIT_REPO}"
else
    ${PIP} "barman[cloud,zstandard,lz4]==${BARMAN_VERSION}"
fi

groupadd --gid 10001 barman
useradd --uid 10001 --gid 10001 --shell /bin/bash --create-home barman
install -d -m 0700 -o barman -g barman ~barman/.ssh
gosu barman bash -c 'echo -e "Host *\n\tCheckHostIP no" > ~/.ssh/config'
