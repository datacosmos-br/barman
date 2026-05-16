# Barman Helm chart

Helm chart to deploy [Barman](https://www.pgbarman.org/) — *Backup and Recovery
Manager for PostgreSQL* — on Kubernetes.

A single Barman deployment can back up **multiple PostgreSQL servers at the same
time**, and each server may run either **inside the same Kubernetes cluster** or
**outside of it** (any reachable host / FQDN / IP).

The chart is based on the [Adfinis `barman` chart](https://github.com/adfinis/helm-charts/tree/main/charts/barman)
and ships the [`ghcr.io/datacosmos-br/barman`](https://github.com/datacosmos-br/barman)
image (Barman 3.x including the `barman-cloud-*` tools for object storage).

---

## How it works

* One Barman **Deployment** runs `barman cron` continuously — it keeps a
  `pg_receivewal` stream open for every configured server (continuous WAL
  archiving, RPO close to zero).
* A **cron** entry per server runs `barman backup <scope>` on a schedule
  (periodic base backups).
* Backups and WAL are stored on the **`data` PersistentVolumeClaim**; an
  optional **`recover` PVC** provides scratch space for restores.
* Each server is an independent Barman *scope* declared under
  `barman.backups[]` — add one entry per database you want to protect.

```
              ┌────────────────────────────┐
  in-cluster  │ postgresql.ns.svc:5432     │──┐
  PostgreSQL  └────────────────────────────┘  │  streaming + base backup
                                              ├─▶  Barman pod  ─▶  PVC (data)
  external    ┌────────────────────────────┐  │
  PostgreSQL  │ postgres.example.com:5432  │──┘
              └────────────────────────────┘
```

---

## Requirements

* Kubernetes 1.23+
* Helm 3.8+
* A `ReadWriteOnce` StorageClass for the backup volume
* For each PostgreSQL server (in-cluster or external):
  * `wal_level = replica` (or `logical`)
  * `max_wal_senders` and `max_replication_slots` high enough for one slot
    per Barman scope
  * A **replication user** and a **superuser** reachable from the Barman pod
  * `pg_hba.conf` allowing both the replication and the regular connection
    from the Barman pod's address/range

---

## Installation

```sh
# from the chart directory
helm install barman ./charts/barman -n barman --create-namespace -f my-values.yaml

# or from a packaged / OCI registry release
helm install barman oci://ghcr.io/datacosmos-br/charts/barman -n barman --create-namespace -f my-values.yaml
```

---

## Configuration — multiple databases

Every PostgreSQL server is one entry in `barman.backups[]`. They are backed up
**simultaneously and independently** (own slot, own schedule, own retention).

```yaml
barman:
  backups:
    - scopeName: "orders-db"            # unique Barman server id
      retentionPolicy: "RECOVERY WINDOW of 1 MONTH"
      backupMethod: postgres
      databaseSlotName: "barman_orders" # unique slot per scope
      createDatabaseSlot: true
      backupSchedule: "0 2 * * *"
      postgresql:
        host: "orders-postgresql.apps.svc.cluster.local"
        port: 5432
        superUser: postgres
        superUserPassword: "<override>"
        superUserDatabase: postgres
        replicationUser: "streaming_barman"
        replicationPassword: "<override>"

    - scopeName: "billing-db"
      retentionPolicy: "RECOVERY WINDOW of 2 WEEKS"
      backupMethod: postgres
      databaseSlotName: "barman_billing"
      createDatabaseSlot: true
      backupSchedule: "0 3 * * *"
      postgresql:
        host: "db.billing.example.com"  # external server
        port: 5432
        superUser: postgres
        superUserPassword: "<override>"
        superUserDatabase: postgres
        replicationUser: "streaming_barman"
        replicationPassword: "<override>"
```

> **Never commit real passwords.** Override `superUserPassword` /
> `replicationPassword` per environment via `--set`, a private values file,
> or a secrets manager that renders the values at deploy time.

### In-cluster PostgreSQL

* Set `postgresql.host` to the Service FQDN, e.g.
  `postgresql.<namespace>.svc.cluster.local`.
* `pg_hba.conf` must allow the Barman pod's cluster IP range for both the
  `replication` and the regular database connection.

### External PostgreSQL (outside Kubernetes)

* Set `postgresql.host` to the reachable FQDN or IP.
* Ensure network egress from the cluster to that host/port is allowed.
* `pg_hba.conf` on the external server must allow the cluster's egress
  address for `replication` and regular connections.
* `rbac.create` is not needed; leave `namespace` / `serviceaccount` empty.

---

## PostgreSQL setup (per server)

```sql
-- replication user used for WAL streaming
CREATE ROLE streaming_barman WITH REPLICATION LOGIN PASSWORD '<override>';

-- ensure WAL streaming is possible
ALTER SYSTEM SET wal_level = 'replica';
ALTER SYSTEM SET max_wal_senders = 10;
ALTER SYSTEM SET max_replication_slots = 10;
-- reload / restart as required
```

`pg_hba.conf` (adjust the source range to your cluster / network):

```
host    replication   streaming_barman   10.0.0.0/8   scram-sha-256
host    all           postgres           10.0.0.0/8   scram-sha-256
```

---

## First backup

```sh
export POD=$(kubectl -n barman get pod \
  -l app.kubernetes.io/name=barman -o jsonpath='{.items[0].metadata.name}')

kubectl -n barman exec -it "$POD" -- su barman -c 'barman cron'
kubectl -n barman exec -it "$POD" -- su barman -c 'barman switch-wal --force --archive all'
kubectl -n barman exec -it "$POD" -- su barman -c 'barman backup all'
kubectl -n barman exec -it "$POD" -- su barman -c 'barman check all'
```

## Restore

```sh
kubectl -n barman exec -it "$POD" -- su barman -c 'barman list-backup <scopeName>'
kubectl -n barman exec -it "$POD" -- su barman -c \
  'barman recover <scopeName> <backupId> /var/lib/barman/recover'
```

---

## Object storage (`barman-cloud`)

The image also ships the `barman-cloud-*` utilities (`barman-cloud-backup`,
`barman-cloud-wal-archive`, `barman-cloud-backup-delete`, ...). To offload
backups and WAL to S3-compatible object storage, set
`barman.postBackupRetryScript` to a `barman-cloud-backup` wrapper and provide
the cloud credentials via `deployment.additionalENVs` / mounted secrets.
See the Barman cloud documentation: <https://docs.pgbarman.org/>.

---

## Values

See [`values.yaml`](./values.yaml) — every key is documented inline.

| Group | Purpose |
|-------|---------|
| `image` | Barman container image |
| `barman.backups[]` | List of PostgreSQL servers to protect (multi-DB) |
| `barman.*` | Global Barman defaults (compression, retention, schedule) |
| `persistence.data` / `persistence.recover` | Backup and restore volumes |
| `prometheus` | Barman exporter + ServiceMonitor / alert rules |
| `rbac` | ClusterRole/binding (only for in-cluster integrations) |
| `secret.create` | Manage the generated `.pgpass` secret |
| `service` | Optional Service for the Barman pod |

---

## Credits

Based on the [Adfinis Helm charts](https://github.com/adfinis/helm-charts) and
[Barman](https://github.com/EnterpriseDB/barman) by EnterpriseDB. Licensed under
GPL-3.0.
