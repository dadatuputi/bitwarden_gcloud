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

If you are upgrading an existing deployment and want watchtower gone, remove it
explicitly:

```
$ docker-compose stop watchtower && docker-compose rm -f watchtower
```

`--remove-orphans` does not do this. Compose v2 reads the `profiles` key and
treats a gated service as one it knows about but was not asked to start, not as
an orphan, so it leaves the running container alone. This was confirmed against
Compose v2.36.1; a plain `docker-compose up -d --remove-orphans` left a running
watchtower untouched.

### Restoring a backup

Restore overwrites `bitwarden/db.sqlite3` in place. **Stop the vault first.**

```
$ docker-compose stop bitwarden
$ docker exec -it backup backup restore /data/backups/<backup-file>
$ docker-compose start bitwarden
```

The `backup` container no longer mounts the Docker socket, so it cannot stop
`bitwarden` for you. It will not stop *you* either: the image still ships
`docker-cli`, so the script's `command -v docker` check still passes, the
`docker stop` call then fails to reach a daemon, and the script logs a warning
and **continues with the restore regardless**. Overwriting the database while
vaultwarden holds it open risks losing writes or corrupting it.

Backups need no such care. `make_backup` uses the SQLite online backup API
(`sqlite3 .backup`) precisely so it can snapshot a live database while writes
are in progress, and it makes no Docker calls at all. Scheduled backups are
completely unaffected by the socket change.

### Operating system updates

Container-Optimized OS has no cron, and nothing in this repo previously ran
`utilities/reboot-on-update.sh`, so staged OS updates were never applied. Install
the timer that does apply them:

```
$ ./utilities/install-cos-update-reboot.sh
```

See [utilities/README-cos-updates.md](utilities/README-cos-updates.md), which
also explains why this does not move the host across COS milestones.

Moving to a newer milestone is a rebuild rather than an update, because a
running instance never changes milestone on its own. The wiki page
[Upgrading Container-Optimized OS](https://github.com/dadatuputi/bitwarden_gcloud/wiki/Upgrading-Container-Optimized-OS)
covers that, including moving the vault onto its own persistent disk so later
upgrades are a disk reattach rather than a data migration.

### Resource limits

Every service sets `mem_limit` and `pids_limit`, sized for an e2-micro with no
swap. They are ceilings, not reservations. If a container is killed under load,
raise its limit rather than removing it, and check usage with:

```
$ docker stats --no-stream
```

### Intrusion blocking

The `fail2ban` container runs two jails against the vault log, `bitwarden` and
`bitwarden-admin`. Both read `/bitwarden/bitwarden.log`, which is mounted
separately and read-only.

Do not add a jail with `backend = systemd`. The image is Alpine-based and ships
no python `systemd` module, so such a jail cannot initialize, and fail2ban
aborts the whole server rather than skipping it. On one host this took the two
working vault jails down with it, leaving the login and admin pages without
brute-force protection for as long as the container crash-looped. The container
reports `Restarting (255)` in that state, and the reason appears only in
`docker logs fail2ban`.

Mounting the journal socket does not help, because the missing piece is the
python module rather than the socket. Container-Optimized OS also logs `sshd`
to journald, so there is no file for a polling backend to read. An sshd jail is
not achievable in this container. See the next section instead.

Check which jails are actually running:

```
$ docker exec fail2ban fail2ban-client status
$ docker exec fail2ban fail2ban-client status bitwarden
```

### SSH access

A new GCE instance allows `tcp:22` from `0.0.0.0/0`. The container changes in
this repository do not address that, and for the reasons above fail2ban cannot
either.

Two approaches, which combine:

- **Identity-Aware Proxy.** Restrict `tcp:22` to `35.235.240.0/20`, IAP's
  forwarding range, and connect with `gcloud compute ssh INSTANCE
  --tunnel-through-iap`. Port 22 stops being reachable from the public
  internet, access is authorised by IAM identity rather than by source address,
  and each tunnel is recorded in Cloud Audit Logs. Because it does not depend
  on where you connect from, it keeps working when your own address changes.
- **Source address allowlist.** Restrict `tcp:22` to a known static address.
  Simpler, and sufficient if that address never moves. It locks you out when it
  does.

Whichever you choose, confirm the new path works from a second terminal while
your existing session is still open, and only then remove the broad rule. The
serial console is the recovery path if that ordering goes wrong.

### Verifying a backup

Check that an archive decrypts and contains the database rather than assuming
it does:

```
$ docker exec backup sh -c 'openssl enc -d -aes256 -salt -pbkdf2 \
    -pass pass:"$BACKUP_ENCRYPTION_KEY" \
    -in /data/backups/<backup-file> | tar tzf - | grep -v attachments/'
```

Expect `db.sqlite3`, the four `rsa_key.*` files, and `.env` when
`BACKUP_ENV=true`.

Run the scheduled job by hand to confirm delivery works end to end:

```
$ docker exec backup ash /backup.sh local,rclone
```

The method argument is required. Invoking `backup` with no argument creates the
archive but attempts no delivery and reports `All backup methods failed`, which
reads as a fault but is not one.

A backup container whose script fails to parse produces no backups and no
console error, because cron discards the output. One deployment ran eight
months that way after a syntax error was introduced into a locally built image.
Set `BACKUP_EMAIL_NOTIFY=true`, and check the newest timestamp in
`bitwarden/backups/` from time to time:

```
$ ls -laht bitwarden/backups/ | head -3
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
