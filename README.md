# Bitwarden self-hosted on Google Cloud for Free

[Vaultwarden](https://github.com/dani-garcia/vaultwarden) on a Google Cloud `e2-micro`, within the [Always Free](https://cloud.google.com/free/docs/free-cloud-features#compute) tier. Works with every official Bitwarden client.

* HTTPS with no manual certificate renewal
* Scheduled backups, optionally encrypted, to disk, e-mail or cloud storage
* Weekly check for stopped backups and unsupported OS milestones
* Vault data on its own persistent disk, so OS upgrades are a disk reattach

Free while egress stays under 1 GB per month and away from China, Hong Kong and Australia.

## New install

[Installation](https://github.com/dadatuputi/bitwarden_gcloud/wiki/Installation).

## Existing deployment

Behaviour is unchanged until `.env` is changed. `git pull` alone alters nothing.

| Goal | Page |
|---|---|
| (Required for the next steps) Move vault data off the boot disk. | [Migrating to a Data Disk](https://github.com/dadatuputi/bitwarden_gcloud/wiki/Migrating-to-a-Data-Disk) |
| (Recommended) Replace an unsupported OS milestone | [Upgrading Container-Optimized OS](https://github.com/dadatuputi/bitwarden_gcloud/wiki/Upgrading-Container-Optimized-OS) |
| (Recommended) Close ports 80 and 443, retire four containers | [Switching to a Cloudflare Tunnel](https://github.com/dadatuputi/bitwarden_gcloud/wiki/Switching-to-a-Cloudflare-Tunnel) |

Milestone support and backup status:

```
docker exec backup ash /backup.sh check
```

Changed defaults in `.env.template`, affecting only a newly created `.env`: `BACKUP=local` is set, and `BACKUP_EMAIL_NOTIFY` is commented out because enabling it without SMTP configured stops the backup script from running.

## Connectivity

New installs use the tunnel. Both paths are supported.

| | Cloudflare Tunnel (default) | Caddy |
|---|---|---|
| Ports open to the internet | none | 80 and 443 |
| TLS terminates at | Cloudflare's edge | the instance |
| DNS | CNAME created by the tunnel | A record maintained by `ddns` |
| Instance address changes | no effect | unreachable until DNS updates |
| Maximum attachment size | 100 MB | unlimited |
| Containers | 3 | 6 |

On the tunnel path Cloudflare decrypts traffic at its edge. Vault contents are encrypted client-side before transmission; metadata and authentication traffic are not.

[How your vault is reached](https://github.com/dadatuputi/bitwarden_gcloud/wiki/Installation#how-your-vault-is-reached).

## Documentation

| | |
|---|---|
| [Installation](https://github.com/dadatuputi/bitwarden_gcloud/wiki/Installation) | Build from nothing |
| [Cloud Shell Setup](https://github.com/dadatuputi/bitwarden_gcloud/wiki/Cloud-Shell-Setup) | Environment assumed by every other page |
| [Backup](https://github.com/dadatuputi/bitwarden_gcloud/wiki/Backup) | Configuration and restore |
| [Operations](https://github.com/dadatuputi/bitwarden_gcloud/wiki/Operations) | Secrets, image updates, log growth, SSH, resource limits |
| [Migrating to a Data Disk](https://github.com/dadatuputi/bitwarden_gcloud/wiki/Migrating-to-a-Data-Disk) | Move the vault off the boot disk |
| [Upgrading Container-Optimized OS](https://github.com/dadatuputi/bitwarden_gcloud/wiki/Upgrading-Container-Optimized-OS) | Replace the OS, keep the data |
| [Switching to a Cloudflare Tunnel](https://github.com/dadatuputi/bitwarden_gcloud/wiki/Switching-to-a-Cloudflare-Tunnel) | Move to a tunnel, or back to Caddy |
| [Instance Metadata](https://github.com/dadatuputi/bitwarden_gcloud/wiki/Instance-Metadata) | Contents of the cloud-config |

## Feature Container Projects

Containers maintained in other projects. Report issues there.

* [Backup](https://github.com/dadatuputi/bwgc_backup) - automatic backup services
* [Caddy](https://github.com/dadatuputi/bwgc_caddy) - reverse proxy and TLS certificate renewal
* [Countryblock](https://github.com/dadatuputi/bwgc_countryblock) - IP Tables block lists by country

`cloudflared`, `ddclient` and `fail2ban` come from [cloudflare/cloudflared](https://github.com/cloudflare/cloudflared), [linuxserver/ddclient](https://github.com/linuxserver/docker-ddclient) and [crazymax/fail2ban](https://github.com/crazy-max/docker-fail2ban), and are not maintained here.

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
