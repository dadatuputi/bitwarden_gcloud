# Bitwarden self-hosted on Google Cloud for Free

---

## Features

* Bitwarden self-hosted (via Vaultwarden) on Google Cloud 'always free' e2-micro tier
* Automatic backups, optionally encrypted, with weekly checks that they are still running
* Vault data on its own persistent disk, so OS upgrades are a disk reattach

Two ways to reach the vault. New installs use the tunnel.

| | Cloudflare Tunnel (default) | Caddy |
|---|---|---|
| Containers | `bitwarden`, `backup`, `cloudflared` | `bitwarden`, `backup`, `proxy`, `ddns`, `countryblock`, `fail2ban` |
| Open ports | none | 80 and 443 |
| TLS terminates at | Cloudflare's edge | the instance |
| DNS | a CNAME the tunnel creates | an A record `ddns` keeps updated |
| Brute-force bans | Vaultwarden's rate limiting | `fail2ban`, via iptables |
| Country blocking | Cloudflare WAF, if you want it | `countryblock`, via iptables |

See [How your vault is reached](https://github.com/dadatuputi/bitwarden_gcloud/wiki/Installation#how-your-vault-is-reached).

## Feature Container Projects

This project uses containers maintained in other projects. If you have an issue to report for one of these features, use that project's issue tracker:

* [Backup](https://github.com/dadatuputi/bwgc_backup) - Provides automatic backup services to this project.
* [Caddy](https://github.com/dadatuputi/bwgc_caddy) - Acts as the reverse proxy and handles TLS certificate renewals.
* [Countryblock](https://github.com/dadatuputi/bwgc_countryblock) - Handles IP Tables block lists to block user-defined countries.

`cloudflared` on the tunnel path, `ddclient` and `fail2ban` on the Caddy path come from [cloudflare/cloudflared](https://github.com/cloudflare/cloudflared), [linuxserver/ddclient](https://github.com/linuxserver/docker-ddclient) and [crazymax/fail2ban](https://github.com/crazy-max/docker-fail2ban) upstream, and are not maintained by this project.

## Installation
Follow the [guide in the wiki](https://github.com/dadatuputi/bitwarden_gcloud/wiki/Installation) to install and configure Bitwarden self-hosted on Google Cloud

## Operations

Everything in this section runs on the instance, in the deployment directory,
unless it says otherwise:

```
$ gcloud compute ssh $INSTANCE --zone $ZONE
$ cd "$(ls -d /mnt/disks/bwgc/bitwarden_gcloud ~/bitwarden_gcloud 2>/dev/null | head -1)"
$ . ~/.bwgc-compose.sh
```

`docker-compose` is a shell function from that file, not a binary:
Container-Optimized OS ships no compose. Non-interactive shells and
`ssh --command` have to source it explicitly.

On a data-disk deployment `bwgc-supervise.timer` restarts stopped containers
every five minutes. Stop it before any procedure that stops a container on
purpose, as the ones below do.

### Secrets

`.env` holds SMTP credentials, the admin token, the backup encryption key and, on the tunnel path, the tunnel token.
Restrict it after you create it:

```
$ chmod 600 .env
```

The `backup` container mounts it read-only.

`.env.template` ships `BACKUP_ENV=true`, so `.env` is inside every archive along
with the admin token, the SMTP password and, on the tunnel path, the tunnel
token. Either set `BACKUP_ENCRYPTION_KEY`, or set `BACKUP_ENV=false` and accept
that a restore will not bring your settings back.

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

The `backup` container does not mount the Docker socket, so it cannot stop
`bitwarden` for you and cannot confirm that you have. It refuses to run rather
than overwrite a live database. `RESTORE_FORCE=true` is how you assert the vault
is stopped.

```
$ sudo systemctl stop bwgc-supervise.timer
$ docker-compose stop bitwarden
$ docker exec -it -e RESTORE_FORCE=true backup backup restore /data/backups/<backup-file>
$ docker-compose start bitwarden
$ sudo systemctl start bwgc-supervise.timer
```

Backups do not need the vault stopped. `make_backup` uses the SQLite online
backup API (`sqlite3 .backup`) so it can snapshot a live database while writes
are in progress, and it makes no Docker calls at all.

### Operating system updates

Container-Optimized OS has no cron. Instances built before the data-disk layout
apply staged updates through a GCE `startup-script` that runs
`utilities/reboot-on-update.sh` at every boot; the timer replaces it, and
`migrate-to-data-disk.sh` removes that metadata key.

Instances created by the current Installation page already have the timer, as
part of their `user-data`. Confirm rather than install:

```
$ gcloud compute ssh $INSTANCE --zone $ZONE --command 'systemctl list-timers cos-update-reboot.timer --no-pager'
```

To add it to an older instance, run this from Cloud Shell in the directory you
downloaded the scripts to. It prints a cloud-config and the `gcloud` command to
apply it, and installs nothing itself:

```
$ ~/bwgc/install-cos-update-reboot.sh
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

**Caddy path only.** On the tunnel path `fail2ban` does not run, because its bans
are iptables rules and no attacker packet reaches this host's network stack. See
[fail2ban on the tunnel path](https://github.com/dadatuputi/bitwarden_gcloud/wiki/Switching-to-a-Cloudflare-Tunnel#fail2ban).

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

### Vault log growth

`vaultwarden` writes to `bitwarden/bitwarden.log` on both paths. It has no log
rotation, and at its default `info` level it logs a request/response pair for
every HTTP call, so the file grows without bound. One deployment reached 595 MB
across 5.8 million lines before anyone noticed.

`LOG_LEVEL` now defaults to `warn`, which drops roughly 92% of the volume. Every
line the fail2ban filters match is logged at `ERROR`, so `warn` still matches
them on the Caddy path.

```
[error][ERROR] Username or password is incorrect. Try again. IP: ...
[vaultwarden::api::admin][ERROR] Invalid admin token. IP: ...
```

Set `LOG_LEVEL=info` in `.env` when you need request logging for debugging.

An existing oversized log is not truncated by this change. Clear it with the
vault stopped, so vaultwarden reopens the file cleanly:

```
$ sudo systemctl stop bwgc-supervise.timer
$ docker-compose stop bitwarden
$ : > bitwarden/bitwarden.log
$ docker-compose start bitwarden
$ sudo systemctl start bwgc-supervise.timer
```

This reduces growth rather than bounding it. Bounding it properly needs a
logrotate sidecar using `copytruncate`, since vaultwarden does not reopen its
log file on rename.

### Status checks

Two failures in this stack produce no signal. An unsupported COS milestone keeps
running and keeps looking healthy while receiving no security patches, and the
in-milestone update timer correctly finds nothing. A
backup that stops running raises no error, because cron discards script output.

The `backup` container checks both once a week and e-mails you through the
existing SMTP settings when either is wrong:

```
$ docker exec backup ash /backup.sh check
INFO: Newest backup is within 8 days: bw_backup_YYYY-MM-DD-HHMMSS.tar.gz.aes256
Container-Optimized OS milestone 109 is no longer supported.
...
A newer LTS milestone is available: cos-129-lts (currently on 109).
```

Support is determined by asking whether `cos-<milestone>-lts` still resolves.
Google withdraws the family pointer at end of support, so a 404 is the signal.
Note that this deliberately ignores *image* deprecation, which is set on every
individual build as a newer one supersedes it within a perfectly healthy
family, and would report live milestones as dead.

The check reads the Compute API through the instance's service account and needs
the `compute.readonly` scope. Instances created by the current Installation page
have it, from `--scopes compute-ro`. Adding it to an older instance requires
stopping it first, because scopes cannot be changed while it runs.

Configure with `CHECK_SCHEDULE` and `BACKUP_MAX_AGE_DAYS` in `.env`, or set
`CHECK_SCHEDULE=disabled` to turn it off. Repeat alerts are suppressed until
the situation changes.

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
$ docker exec backup ash /backup.sh local
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

* Cloudflare Tunnel is the default for new installs. `COMPOSE_FILE` in `.env`
  selects it; `proxy`, `ddns`, `countryblock` and `fail2ban` do not run on that
  path. Existing Caddy deployments are unaffected until they set it
* Vault data moves to its own persistent disk
  (`utilities/migrate-to-data-disk.sh`), and OS milestone upgrades become a disk
  reattach (`utilities/upgrade-cos.sh`)
* Startup moves to cloud-init: `bwgc.service` starts the stack once the data
  disk is mounted, and `bwgc-supervise.timer` restarts what stops

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
* Added a systemd timer that applies staged COS updates; deprecated
  `utilities/reboot-on-update.sh` in favour of it

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
