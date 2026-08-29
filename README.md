# Bitwarden self-hosted on Google Cloud for Free

Your own Bitwarden server, on hardware that costs nothing to run.

This puts [Vaultwarden](https://github.com/dani-garcia/vaultwarden), a lightweight Bitwarden-compatible server, on a Google Cloud `e2-micro`. That machine type is part of Google's [Always Free](https://cloud.google.com/free/docs/free-cloud-features#compute) tier, so a vault serving a household or a small team runs at no monthly cost. Every official Bitwarden client works against it: browser extensions, mobile apps, desktop, CLI.

Your vault lives on a disk you own, in a project you control, backed up on a schedule you set.

**[Start here: Installation](https://github.com/dadatuputi/bitwarden_gcloud/wiki/Installation).** About an hour, most of it waiting.

---

## What you get

* Vaultwarden on a Google Cloud Always Free `e2-micro`
* HTTPS, handled for you, with no certificate to renew by hand
* Automatic backups, optionally encrypted, that can mail themselves to you or sync to cloud storage
* A weekly check that tells you when a backup has quietly stopped or your OS has left support
* Vault data on its own persistent disk, so replacing the operating system is a disk reattach rather than a data migration

It stays free as long as you keep egress under 1 GB a month and away from China, Hong Kong and Australia. Picking a region near you is the main thing that achieves that.

## Two ways to reach your vault

New installs use the tunnel. Both are fully supported.

| | Cloudflare Tunnel (default) | Caddy |
|---|---|---|
| Ports open to the internet | none | 80 and 443 |
| TLS terminates at | Cloudflare's edge | your instance |
| DNS | a CNAME the tunnel creates | an A record `ddns` keeps updated |
| When Google changes the instance address | nothing happens | unreachable until DNS catches up |
| Largest vault attachment | 100 MB | no limit |
| Containers on a 1 GB instance | 3 | 6 |

The tunnel is simpler to run and exposes nothing. The trade is that Cloudflare decrypts traffic at its edge; Bitwarden encrypts vault contents on your device first, so what they can see is metadata and authentication traffic, not your passwords. If you would rather nobody sit in that position, take the Caddy path.

[How your vault is reached](https://github.com/dadatuputi/bitwarden_gcloud/wiki/Installation#how-your-vault-is-reached) covers the decision in full.

---

## What changed, and what you need to do

This release adds the Cloudflare Tunnel path, moves vault data onto its own disk, and hands container startup to cloud-init. **Nothing changes on an existing deployment until you change it.** Find yourself below.

### You are installing for the first time

Follow [Installation](https://github.com/dadatuputi/bitwarden_gcloud/wiki/Installation). You get the tunnel, the data disk and the new startup arrangement by default, and there is nothing to migrate.

### You have a working vault and do not want to touch it

Do nothing. Your deployment keeps running exactly as it is. The tunnel is selected by one line in `.env` that you do not have, and without it `docker-compose.yml` behaves as it always has.

One thing is worth doing regardless, because it is the failure people discover too late:

```
docker exec backup ash /backup.sh check
```

That reports whether a backup has actually run recently and whether your OS milestone still gets security patches. Both fail silently otherwise. See [Backup](https://github.com/dadatuputi/bitwarden_gcloud/wiki/Backup#status-checks).

### You pull from git occasionally

`git pull` brings in `docker-compose.tunnel.yml` and the utility scripts and changes nothing by itself. Your next `docker-compose up -d` produces the same six containers as before.

Two settings changed their shipped defaults, which only affects a `.env` you create fresh from the template: `BACKUP=local` is now on, and `BACKUP_EMAIL_NOTIFY` is now commented out, because leaving it on with no SMTP configured stopped the backup script from running at all.

### You want the new arrangement

In this order:

1. **[Migrate to a data disk](https://github.com/dadatuputi/bitwarden_gcloud/wiki/Migrating-to-a-Data-Disk).** Once. Your vault moves onto a disk that survives the instance, and OS upgrades stop being data migrations. This is the prerequisite for everything below.
2. **[Upgrade Container-Optimized OS](https://github.com/dadatuputi/bitwarden_gcloud/wiki/Upgrading-Container-Optimized-OS)** if your milestone has left support. The check above tells you.
3. **[Switch to a Cloudflare Tunnel](https://github.com/dadatuputi/bitwarden_gcloud/wiki/Switching-to-a-Cloudflare-Tunnel)** if you want it. This closes both open ports and retires four containers. It is reversible, and that page documents going back.

Each page states what it changes, what it costs you in downtime, and what happens if you stop partway.

---

## Documentation

| | |
|---|---|
| [Installation](https://github.com/dadatuputi/bitwarden_gcloud/wiki/Installation) | Build a vault from nothing |
| [Cloud Shell Setup](https://github.com/dadatuputi/bitwarden_gcloud/wiki/Cloud-Shell-Setup) | The environment every other page assumes |
| [Backup](https://github.com/dadatuputi/bitwarden_gcloud/wiki/Backup) | Configuring backups, and restoring one |
| [Operations](https://github.com/dadatuputi/bitwarden_gcloud/wiki/Operations) | Secrets, image updates, log growth, SSH, resource limits |
| [Migrating to a Data Disk](https://github.com/dadatuputi/bitwarden_gcloud/wiki/Migrating-to-a-Data-Disk) | Move the vault off the boot disk |
| [Upgrading Container-Optimized OS](https://github.com/dadatuputi/bitwarden_gcloud/wiki/Upgrading-Container-Optimized-OS) | Replace the OS, keep the data |
| [Switching to a Cloudflare Tunnel](https://github.com/dadatuputi/bitwarden_gcloud/wiki/Switching-to-a-Cloudflare-Tunnel) | Move an existing vault onto a tunnel, or back |
| [Instance Metadata](https://github.com/dadatuputi/bitwarden_gcloud/wiki/Instance-Metadata) | What the cloud-config contains and why |

## Feature Container Projects

This project uses containers maintained in other projects. If you have an issue to report for one of these features, use that project's issue tracker.

* [Backup](https://github.com/dadatuputi/bwgc_backup) - Provides automatic backup services to this project.
* [Caddy](https://github.com/dadatuputi/bwgc_caddy) - Acts as the reverse proxy and handles TLS certificate renewals.
* [Countryblock](https://github.com/dadatuputi/bwgc_countryblock) - Handles IP Tables block lists to block user-defined countries.

`cloudflared` on the tunnel path, and `ddclient` and `fail2ban` on the Caddy path, come from [cloudflare/cloudflared](https://github.com/cloudflare/cloudflared), [linuxserver/ddclient](https://github.com/linuxserver/docker-ddclient) and [crazymax/fail2ban](https://github.com/crazy-max/docker-fail2ban) upstream, and are not maintained here.

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
