# Bitwarden self-hosted on Google Cloud for Free

---

## Features

* Bitwarden self-hosted (via Vaultwarden) on Google Cloud 'always free' e2-micro tier 
* Automatic https certificate management through Caddy 2 proxy
* Dynamic DNS updates through ddclient
* Blocking brute-force attempts with fail2ban
* Country-wide blocking through iptables and ipset
* Automatic backups

## Feature Container Projects

This project uses containers maintained in other projects. If you have an issue to report for one of these features, use that project's issue tracker:

* [Backup](https://github.com/dadatuputi/bwgc_backup) - Provides automatic backup services to this project.
* [Caddy](https://github.com/dadatuputi/bwgc_caddy) - Acts as the reverse proxy and handles TLS certificate renewals.
* [Countryblock](https://github.com/dadatuputi/bwgc_countryblock) - Handles IP Tables block lists to block user-defined countries.

## Installation
Follow the [guide in the wiki](https://github.com/dadatuputi/bitwarden_gcloud/wiki/Installation) to install and configure Bitwarden self-hosted on Google Cloud

## Operations

### Secrets

`.env` holds SMTP credentials, the admin token and the backup encryption key.
Restrict it after you create it:

```
$ chmod 600 .env
```

The `backup` container mounts it read-only. Note that `BACKUP_ENV=true` will
include `.env` in a backup, so do not enable that without also setting
`BACKUP_ENCRYPTION_KEY`.

### Automatic image updates

`watchtower` no longer starts by default. It holds the Docker socket and
deploys whatever appears on a floating tag without review, so an upstream
compromise would reach the host. It is still available:

```
$ docker-compose --profile watchtower up -d
```

The reviewed alternative is `renovate.json`, which raises image updates as
pull requests against pinned digests.

If you are upgrading an existing deployment and want watchtower gone, a plain
`docker-compose up -d` leaves the running container orphaned rather than
removing it:

```
$ docker-compose up -d --remove-orphans
```

### Restoring a backup

The `backup` container no longer mounts the Docker socket, so it can no longer
stop and start `bitwarden` on your behalf. Stop it yourself first:

```
$ docker-compose stop bitwarden
$ docker exec -it backup ash /restore.sh
$ docker-compose start bitwarden
```

### Operating system updates

Container-Optimized OS has no cron, and nothing in this repo previously ran
`utilities/reboot-on-update.sh`, so staged OS updates were never applied. Install
the timer that does apply them:

```
$ ./utilities/install-cos-update-reboot.sh
```

See [utilities/README-cos-updates.md](utilities/README-cos-updates.md), which
also explains why this does not move the host across COS milestones.

### Resource limits

Every service sets `mem_limit` and `pids_limit`, sized for an e2-micro with no
swap. They are ceilings, not reservations. If a container is killed under load,
raise its limit rather than removing it, and check usage with:

```
$ docker stats --no-stream
```

## Changelog
Unreleased

* Security headers in `caddy/Caddyfile` now apply to every path. The `header /`
  matcher was an exact match, so `/admin` and `/api/*` were served without
  `X-Frame-Options` and `X-Content-Type-Options`
* `watchtower` is now opt-in behind a compose profile; added `renovate.json` as
  the reviewed replacement
* Removed the Docker socket mount from `backup`; restore now needs the operator
  to stop `bitwarden` first
* Removed `privileged: true` from `countryblock`; `NET_ADMIN` and `NET_RAW` are
  sufficient
* Narrowed the `fail2ban` mounts: dropped the host-wide `/var/log` mount
* Added `mem_limit` and `pids_limit` to every service
* Added a systemd timer that actually applies staged COS updates; deprecated
  `utilities/reboot-on-update.sh`, which nothing ever invoked

2.0.3 - 21 May 2025

* Added backup restore feature to backup image, [documented](https://github.com/dadatuputi/bitwarden_gcloud/wiki/Backup#backup-restore)

2.0.2 - 7 November 2023

* Improve `fail2ban` SMTP env variable documentation in `.env.template` (#79)
* Update IP Header env var (#77)
* Push `fail2ban` logs to STDOUT / docker logging
* Update `docker-compose` to latest version (#76). Requires manual updating of `~/.bash_alias` with the following command:

```bash
$ docker-compose version
$ sed -i "s|docker/compose|docker compose|g" ~/.bash_alias
$ source ~/.bash_alias
$ docker-compose version
```

2.0.1 - 25 October 2023

* Update backup option to include `.env` for full restoration. Off by default. Please encrypt your backup if including `.env`
* Starting new versioning/tagging system to keep track of changes. Arbitrarily starting after 2.0, which was the fully modular approach.

---

> __3 April 2023 Alert__: [Recent changes to Vaultwarden](https://github.com/dani-garcia/vaultwarden/commit/ca417d32578c3b6224c5aa8df56eb776712941b7) may cause Vaultwarden to fail to start due to default environmental variables. `.env.template` has been updated in this repo, however, if you are affected, you must also update `.env` and comment out all `YUBICO_*` variables, so that they appear as:
>
> ```
> #YUBICO_CLIENT_ID=
> #YUBICO_SECRET_KEY=
> #YUBICO_SERVER=
> ```
> Restart with `docker-compose`, and Vaultwarden should come up as normal. Credit to [@AySz88 for reporting this](https://github.com/dadatuputi/bitwarden_gcloud/issues/54).
