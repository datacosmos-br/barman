# barman (DataCosmos fork)

DataCosmos fork of [barman-docker](https://github.com/basalam/barman-docker) —
container image **and** Helm chart for [Barman](https://github.com/EnterpriseDB/barman),
the *Backup and Recovery Manager for PostgreSQL*.

This fork adds, on top of upstream:

* a **`-dc` container image** — Debian bookworm, **Barman 3.18** with
  `barman[cloud,zstandard,lz4]` (includes the `barman-cloud-*` tools for
  S3-compatible object storage), built **multi-arch** (`linux/amd64` +
  `linux/arm64`);
* a **Helm chart** (`charts/barman/`) — multi-database, in-cluster **and**
  external PostgreSQL, every Barman capability parameterizable, with a
  **health check** that degrades the workload when a backup is broken;
* a single **publish GitHub Action** and an **upstream-sync** workflow.

---

## Artifacts

| Artifact | Location |
|----------|----------|
| Container image | `ghcr.io/datacosmos-br/barman` — tags `<barman>-dc<N>` (e.g. `3.18.0-dc2`) and `dc`; multi-arch `amd64`/`arm64` |
| Helm chart (OCI) | `oci://ghcr.io/datacosmos-br/charts/barman` |
| GitHub Releases | <https://github.com/datacosmos-br/barman/releases> |

> On the first publish, set both GHCR packages to **Public** in the
> organization package settings.

---

## Helm chart

Full documentation: [`charts/barman/README.md`](./charts/barman/README.md).

```sh
helm install barman oci://ghcr.io/datacosmos-br/charts/barman --version 1.1.0 \
  -n barman --create-namespace -f my-values.yaml
```

The chart backs up **multiple PostgreSQL servers at once**, in-cluster or
external, and ships a readinessProbe **health check** that fails when a
database is unreachable, replication is broken, or a scheduled backup failed.
See the chart README for the per-database setup instructions (plain/external,
Bitnami `postgresql-ha`/repmgr, Patroni/TimescaleDB).

---

## Container image

The image runs Barman as a server (continuous WAL streaming via
`pg_receivewal` + scheduled base backups) and also carries the
`barman-cloud-*` utilities. Build args: `BARMAN_VERSION`, `SOURCE_INSTALL`.

### Docker Compose (standalone)

```yaml
services:
  barman:
    restart: always
    image: ghcr.io/datacosmos-br/barman:dc
    ports:
      - 127.0.0.1:9780:9780   # barman exporter
    environment:
      - DB_HOST=172.17.1.1
      - DB_PORT=5432
      - DB_SUPERUSER=postgres
      - DB_SUPERUSER_PASSWORD=supersecret
      - DB_REPLICATION_USER=replication
      - DB_REPLICATION_PASSWORD=supersecretreplication
    volumes:
      - ./data:/var/lib/barman:rw
      - ./recovery-data:/var/lib/barman/recover:rw
```

---

## CI / branching

* **`Publish (-dc release)`** (`release-dc.yml`) — one Action: a tag matching
  `*-dc*` on `main` builds + pushes the multi-arch image, packages + pushes
  the Helm chart, and creates the GitHub Release.
* **`Sync upstream`** (`upstream-sync.yml`) — scheduled; opens a PR with
  upstream `basalam/barman-docker` changes (never touches `main` directly).
* **`docker-publish.yml`** — the upstream workflow, kept intact.
* Own features land via Pull Request; upstream changes land via the
  automatic sync PR.

---

## Credits

Forked from [basalam/barman-docker](https://github.com/basalam/barman-docker)
(based on [ubc/barman-docker](https://github.com/ubc/barman-docker)). Helm
chart based on [adfinis/helm-charts](https://github.com/adfinis/helm-charts).
[Barman](https://github.com/EnterpriseDB/barman) by EnterpriseDB. GPL-3.0.
