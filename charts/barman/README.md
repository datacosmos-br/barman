# Barman Helm chart

Helm chart to deploy [Barman](https://www.pgbarman.org/) — *Backup and Recovery
Manager for PostgreSQL* — on Kubernetes.

A single Barman deployment backs up **multiple PostgreSQL servers at the same
time**; each may run **inside the Kubernetes cluster** or **outside of it** (any
reachable host / FQDN / IP). A built-in **health check** turns the pod NotReady
(and the Deployment / Argo CD app degraded) whenever a database is unreachable,
replication is broken, or a scheduled backup has failed.

Based on the [Adfinis `barman` chart](https://github.com/adfinis/helm-charts/tree/main/charts/barman),
shipping the [`ghcr.io/datacosmos-br/barman`](https://github.com/datacosmos-br/barman)
image (Barman 3.x + the `barman-cloud-*` tools, multi-arch `amd64`/`arm64`).

---

## How it works

* One **Deployment** runs `barman cron` continuously — it keeps a
  `pg_receivewal` stream open for every server (continuous WAL archiving,
  RPO ≈ 0) and auto-creates the replication slots.
* A **cron** entry per server runs `barman backup <scope>` on a schedule.
* A **readinessProbe** runs the health check (`barman check`) — see below.
* Backups + WAL are stored on the **`data` PVC**; an optional **`recover` PVC**
  is scratch space for restores.
* Every server is one entry in `barman.backups[]`.

```
              ┌────────────────────────────┐
  in-cluster  │ postgresql.ns.svc:5432     │──┐
  PostgreSQL  └────────────────────────────┘  │  streaming + base backup
                                              ├─▶  Barman pod  ─▶  PVC (data)
  external    ┌────────────────────────────┐  │   (cron + health check)
  PostgreSQL  │ db.example.com:5432        │──┘
              └────────────────────────────┘
```

---

## Health check

When `healthCheck.enabled` (default), a **readinessProbe** runs `barman check`
for every configured server. The pod becomes **NotReady** — making the
Deployment and any Argo CD Application show **degraded** — when:

* no PostgreSQL server is configured (`barman.backups[]` empty);
* a database connection fails;
* replication / streaming is broken (`pg_receivexlog`, `receive-wal running`,
  `replication slot` checks);
* the WAL archive is broken (`archiver errors`, `WAL archive`);
* **a scheduled backup has failed** (`failed backups` check).

It does **not** fail merely because the first backup has not run yet — the
`minimum redundancy` and `backup maximum age` checks are ignored by default
(`healthCheck.ignoreChecks`, fully parameterizable). Set `ignoreChecks: ""` to
require at least one healthy, recent backup.

A `startupProbe` gives Barman time to load before the readinessProbe starts.

---

## Requirements

* Kubernetes 1.23+, Helm 3.8+
* A `ReadWriteOnce` StorageClass for the backup volume
* For every PostgreSQL server — see **Database setup** below

---

## Database setup — depends on the database "form"

Barman needs, for each server, a connection that can do **physical
replication** (`pg_basebackup` and `pg_receivewal`). PostgreSQL requires an
explicit `pg_hba.conf` line of type `replication` — a `host all all` rule does
**not** cover replication. What to do depends on how the database is run:

### A. Plain / external PostgreSQL (on-prem or self-managed)

You control `postgresql.conf` and `pg_hba.conf`:

```sql
CREATE ROLE barman WITH REPLICATION LOGIN PASSWORD '<override>';
ALTER SYSTEM SET wal_level = 'replica';        -- or 'logical'
ALTER SYSTEM SET max_wal_senders = 10;
ALTER SYSTEM SET max_replication_slots = 10;
```
`pg_hba.conf` (adjust the source CIDR to the cluster egress / pod range):
```
host  replication  barman  10.0.0.0/8  scram-sha-256
host  all          barman  10.0.0.0/8  scram-sha-256
```
Reload (`SELECT pg_reload_conf()`); a `wal_level` change needs a restart.
Ensure network egress from the cluster to the host:port.
Use `superUser: barman` / `replicationUser: barman` in the values.

### B. Bitnami `postgresql-ha` (repmgr) chart

The repmgr image **regenerates `pg_hba.conf`** and only allows replication for
its own `repmgr` user (`host replication repmgr ...`). `pgHbaConfiguration` is
**ignored** by this image. Therefore **connect Barman as the `repmgr` user** —
it has the `REPLICATION` attribute, which is all Barman needs:

```yaml
postgresql:
  superUser: repmgr
  replicationUser: repmgr
  superUserDatabase: postgres
```
The `repmgr` password is in the chart's existing secret (`repmgr-password`
key). No change to the PostgreSQL cluster is required.

### C. Patroni-managed PostgreSQL / TimescaleDB

Patroni manages `pg_hba.conf` and already includes `replication` entries.
Create (or reuse) a replication-capable user and add it to the Patroni
`pg_hba` list (`postgresql.pg_hba` in the Patroni config) if a dedicated user
is wanted; otherwise use the existing superuser. Point `postgresql.host` at
the Patroni primary Service.

> Never commit real passwords. Override `superUserPassword` /
> `replicationPassword` via `--set`, a private values file, or a secrets
> manager (e.g. External Secrets) that supplies the `.pgpass` Secret — set
> `secret.create: false` and provide `<release>-pgpass-secret` yourself.

---

## Backup methods

Barman supports two backup methods, set **per server** via
`barman.backups[].configuration.backup_method` (default: `postgres`).

### `backup_method: postgres` — pg_basebackup (default, no SSH)

Barman runs `pg_basebackup` over the normal PostgreSQL connection. **No SSH
required**; works identically for in-cluster and external databases.

| Option (in `configuration`) | Effect |
|---|---|
| `backup_method: postgres` | Use pg_basebackup |
| `parallel_jobs: N` | **Parallel** pg_basebackup streams — faster (PostgreSQL 13+) |
| `backup_options: concurrent_backup` | Non-blocking backup (recommended; default) |
| `backup_options: exclusive_backup` | Legacy exclusive mode (PostgreSQL < 15 only) |
| `immediate_checkpoint: true` | Immediate checkpoint — faster start, more I/O |
| `streaming_archiver: "on"` | Continuous WAL via `pg_receivewal` (RPO ≈ 0) |
| `bandwidth_limit: KBPS` | Throttle the transfer |

```yaml
barman:
  backups:
    - scopeName: "orders-db"
      configuration:
        backup_method: postgres
        parallel_jobs: 4
        backup_options: concurrent_backup
        immediate_checkpoint: true
        streaming_archiver: "on"
      postgresql:
        host: orders-postgresql.apps.svc.cluster.local
        superUser: barman
        replicationUser: barman
```

* **Pros:** simple; no SSH; same for in-cluster and external databases.
* **Cons:** every base backup copies the whole cluster (no file-level incremental).

### `backup_method: rsync` — rsync over SSH

Barman runs `rsync` over **SSH** against the PostgreSQL host's data directory.
Supports **file-level incremental** backups, is faster for large databases, and
the stored backup can seed a standby clone (e.g. `repmgr standby clone --barman`).
Requires SSH from the Barman pod to the PostgreSQL host.

**SSH prerequisite** — set `ssh.enabled: true` and provide a keypair:

1. Generate a keypair: `ssh-keygen -t ed25519 -f barman -N ''`.
2. Create a Secret with keys `id_rsa` (private), `id_rsa.pub`, `known_hosts`
   (entries for the PostgreSQL hosts); set `ssh.existingSecret` to its name.
   For local tests only, `ssh.secret.create` accepts inline material.
3. On every PostgreSQL host, add `barman.pub` to the `postgres` OS user's
   `~/.ssh/authorized_keys`.

```yaml
ssh:
  enabled: true
  existingSecret: barman-ssh
barman:
  backups:
    - scopeName: "orders-db"
      configuration:
        backup_method: rsync
        ssh_command: "ssh postgres@orders-postgresql.apps.svc.cluster.local"
        reuse_backup: link            # incremental — hard-links unchanged files
        parallel_jobs: 4
        network_compression: true
      postgresql:
        host: orders-postgresql.apps.svc.cluster.local
        superUser: barman
        replicationUser: barman
```

| Option (in `configuration`) | Effect |
|---|---|
| `backup_method: rsync` | Use rsync over SSH |
| `ssh_command: "ssh <user>@<host>"` | SSH command Barman uses (**required**) |
| `reuse_backup: off` | Full backup every time |
| `reuse_backup: link` | **Incremental** — unchanged files hard-linked from the previous backup (fast, space-efficient) |
| `reuse_backup: copy` | Incremental by copy (no hard-links) |
| `parallel_jobs: N` | Parallel rsync streams |
| `network_compression: true` | Compress the rsync stream |
| `bandwidth_limit: KBPS` | Throttle the transfer |

* **Pros:** file-level incremental (`reuse_backup: link`); fast for large DBs;
  parallel; the backup can seed a standby clone.
* **Cons:** requires SSH access to the PostgreSQL host.

### Which to use

| | `postgres` | `rsync` |
|---|---|---|
| SSH required | no | yes |
| File-level incremental | no | yes (`reuse_backup: link`) |
| External DB friendly | yes | yes (if SSH reachable) |
| Best for | simple setups, managed DBs | large DBs, fast incremental, standby seeding |

---

## Restore & validation

```sh
export POD=$(kubectl -n barman get pod -l app.kubernetes.io/name=barman \
  -o jsonpath='{.items[0].metadata.name}')

# list backups
kubectl -n barman exec "$POD" -- su barman -c 'barman list-backup <scope>'

# recover the latest backup into a directory
kubectl -n barman exec "$POD" -- su barman -c \
  'barman recover <scope> latest /var/lib/barman/recover'

# point-in-time recovery
kubectl -n barman exec "$POD" -- su barman -c \
  'barman recover --target-time "2026-05-17 03:00:00" <scope> latest /var/lib/barman/recover'
```

To **prove** a backup is genuinely restorable, the project ships
[`test/restore-test.sh`](../../test/restore-test.sh): it backs up a source
PostgreSQL, recovers the backup into a **separate, parallel** PostgreSQL
instance, and asserts that a marker dataset (row count + checksum) matches the
source. Run it locally before publishing any release.

---

## Configuration — multiple databases

Every server is one entry in `barman.backups[]`; they are backed up
**simultaneously and independently** (own slot, schedule, retention):

```yaml
barman:
  backups:
    - scopeName: "orders-db"
      backupSchedule: "0 2 * * *"
      databaseSlotName: "barman_orders"
      createDatabaseSlot: true
      postgresql:
        host: "orders-postgresql.apps.svc.cluster.local"
        port: 5432
        superUser: barman
        superUserPassword: "<override>"
        superUserDatabase: postgres
        replicationUser: barman
        replicationPassword: "<override>"
      configuration:
        retention_policy: "RECOVERY WINDOW of 1 MONTH"
    - scopeName: "billing-db"
      backupSchedule: "0 3 * * *"
      databaseSlotName: "barman_billing"
      createDatabaseSlot: true
      postgresql:
        host: "db.billing.example.com"   # external server
        port: 5432
        superUser: barman
        superUserPassword: "<override>"
        superUserDatabase: postgres
        replicationUser: barman
        replicationPassword: "<override>"
```

Every Barman option is parameterizable: `barman.globalConfiguration` (the
`[barman]` section) and `barman.backups[].configuration` (per-server) are maps
rendered verbatim into `barman.conf` — any valid key works. Replication slots
and cron jobs are configured automatically from `barman.backups[]`.

---

## Deploy

### With Helm directly

```sh
helm install barman oci://ghcr.io/datacosmos-br/charts/barman --version 1.2.0 \
  -n barman --create-namespace -f my-values.yaml
```

### With Argo CD

Point an Application/ApplicationSet at the chart — either the OCI registry
(`oci://ghcr.io/datacosmos-br/charts/barman`) or the Git repo path
(`charts/barman` of `https://github.com/datacosmos-br/barman.git`, tag-pinned).
Allow that repo in the AppProject's `sourceRepos`.

### First backup / restore

```sh
export POD=$(kubectl -n barman get pod \
  -l app.kubernetes.io/name=barman -o jsonpath='{.items[0].metadata.name}')

kubectl -n barman exec -it "$POD" -- su barman -c 'barman cron'
kubectl -n barman exec -it "$POD" -- su barman -c 'barman backup all'
kubectl -n barman exec -it "$POD" -- su barman -c 'barman check all'
# restore
kubectl -n barman exec -it "$POD" -- su barman -c 'barman list-backup <scope>'
kubectl -n barman exec -it "$POD" -- su barman -c \
  'barman recover <scope> <backupId> /var/lib/barman/recover'
```

---

## Packages & releases

| Artifact | Location |
|----------|----------|
| Container image | `ghcr.io/datacosmos-br/barman` — tags `<barman>-dc<N>` and `dc`; multi-arch `linux/amd64` + `linux/arm64` |
| Helm chart (OCI) | `oci://ghcr.io/datacosmos-br/charts/barman` |
| GitHub Releases | <https://github.com/datacosmos-br/barman/releases> (chart `.tgz` attached) |

Publishing is automated by the **`Publish (-dc release)`** GitHub Action: any
tag matching `*-dc*` pushed on `main` builds + pushes the multi-arch image,
packages + pushes the Helm chart, and creates the matching GitHub Release —
all in one run. The upstream-managed workflow (`docker-publish.yml`) is kept
intact, and a scheduled `Sync upstream` workflow opens a PR for upstream
changes. On the very first publish, set both GHCR packages to **Public** in
the org package settings.

---

## Values

See [`values.yaml`](./values.yaml) — every key is documented inline.

| Group | Purpose |
|-------|---------|
| `image` | Barman container image |
| `barman.backups[]` | PostgreSQL servers to protect (multi-DB) |
| `barman.globalConfiguration` / `backups[].configuration` | Any `barman.conf` option (incl. `backup_method`, `parallel_jobs`, `reuse_backup`) |
| `ssh` | SSH keypair mount — required for `backup_method: rsync` |
| `healthCheck` | readinessProbe-based health check + thresholds |
| `persistence.data` / `persistence.recover` | Backup and restore volumes |
| `prometheus` | Barman exporter + ServiceMonitor / alert rules |
| `rbac` | ClusterRole/binding (in-cluster integrations only) |
| `secret.create` | Manage the generated `.pgpass` secret |

---

## Credits

Based on the [Adfinis Helm charts](https://github.com/adfinis/helm-charts) and
[Barman](https://github.com/EnterpriseDB/barman) by EnterpriseDB. GPL-3.0.
