#!/bin/bash
# Status consolidado dos servidores Barman em todos os clusters.
#
# Uso:
#   scripts/cluster-status.sh            # snapshot único
#   WATCH=1 scripts/cluster-status.sh    # acompanha (refresh contínuo)
#
# Variáveis (override opcional):
#   BARMAN_CONTEXTS  contexts kubectl, separados por espaço
#                    (default: current-context do kubeconfig)
#   BARMAN_NS        namespace do barman (default: barman)
#   WATCH            se setada, entra em modo de acompanhamento
#   WATCH_INTERVAL   segundos entre refreshs no modo WATCH (default: 30)
set -uo pipefail

CONTEXTS="${BARMAN_CONTEXTS:-$(kubectl config current-context 2>/dev/null)}"
NS="${BARMAN_NS:-barman}"
INTERVAL="${WATCH_INTERVAL:-30}"

# Snippet executado dentro do pod barman: por servidor emite uma linha
# pipe-separada  servidor|qtd_backups|health|linha_do_ultimo_backup
POD_SNIPPET='
for s in $(barman list-server --minimal 2>/dev/null); do
  line=$(barman list-backup "$s" 2>/dev/null | head -1)
  cnt=$(barman list-backup "$s" 2>/dev/null | grep -c .)
  chk=$(barman check "$s" 2>/dev/null | grep "FAILED" | sed "s/^[[:space:]]*//;s/:.*//" | paste -sd, -)
  [ -z "$chk" ] && chk="OK"
  echo "${s}|${cnt}|${chk}|${line}"
done
'

snapshot() {
  printf '%-20s %-15s %-17s %-9s %-10s %-6s %-10s %s\n' \
    CLUSTER SERVER "ULTIMO BACKUP" STATUS SIZE QTD WAL HEALTH
  printf '%.0s-' {1..110}; echo
  for ctx in $CONTEXTS; do
    pod=$(kubectl --context="$ctx" -n "$NS" get pod \
            -l app.kubernetes.io/name=barman \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ -z "$pod" ]; then
      printf '%-20s %s\n' "$ctx" "(sem pod barman acessivel)"
      continue
    fi
    kubectl --context="$ctx" -n "$NS" exec "$pod" -- \
      su barman -c "$POD_SNIPPET" 2>/dev/null \
    | while IFS='|' read -r srv cnt health line; do
        [ -z "$srv" ] && continue
        id=$(awk '{print $2}' <<<"$line"); [ -z "$id" ] && id="-"
        case "$line" in
          *STARTED*)            st="STARTED" ;;
          *EMPTY*)              st="EMPTY" ;;
          *WAITING_FOR_WALS*)   st="WAITING" ;;
          *Size:*)              st="DONE" ;;
          *)                    st="NENHUM" ;;
        esac
        size=$(sed -n 's/.* - Size: \([0-9.]* [A-Za-z]*\) - WAL Size:.*/\1/p' <<<"$line")
        [ -z "$size" ] && size="-"
        wal=$(sed -n 's/.*WAL Size: \(.*\)$/\1/p' <<<"$line")
        [ -z "$wal" ] && wal="-"
        printf '%-20s %-15s %-17s %-9s %-10s %-6s %-10s %s\n' \
          "$ctx" "$srv" "$id" "$st" "$size" "$cnt" "$wal" "$health"
      done
  done
}

if [ -n "${WATCH:-}" ]; then
  while true; do
    clear
    echo "Barman — status dos backups   ($(date '+%Y-%m-%d %H:%M:%S'))   refresh ${INTERVAL}s"
    echo
    snapshot
    sleep "$INTERVAL"
  done
else
  echo "Barman — status dos backups   ($(date '+%Y-%m-%d %H:%M:%S'))"
  echo
  snapshot
fi
