# Bitwarden self-hosted on Google Cloud for Free

[Vaultwarden](https://github.com/dani-garcia/vaultwarden) on a Google Cloud `e2-micro`, within the [Always Free](https://cloud.google.com/free/docs/free-cloud-features#compute) tier. Works with every official Bitwarden client.

* HTTPS with no manual certificate renewal
* Scheduled backups, optionally encrypted, to disk, e-mail or cloud storage
* Weekly check for stopped backups and unsupported OS milestones
* Vault data on its own persistent disk, so OS upgrades are a disk reattach

Free on the Caddy path while egress stays under 1 GB per month and away from China, Hong Kong and Australia. The Cloudflare Tunnel path costs a little every month: see [Connectivity](#connectivity).

## New install

[Installation](https://github.com/dadatuputi/bitwarden_gcloud/wiki/Installation).

## Existing deployment

Your vault, your `.env` and your data are untouched by a pull.

One thing does change on its own: `watchtower` was on by default and is now
behind a compose profile, so it stops after a pull and image updates end
silently. Put it back with `COMPOSE_PROFILES=watchtower` in `.env`, or leave it
off and use `renovate.json`, which raises image updates as pull requests.
[Operations](https://github.com/dadatuputi/bitwarden_gcloud/wiki/Operations#automatic-image-updates)
covers both.

Everything else below is opt-in.

| Goal | Page |
|---|---|
| (Required for the next steps) Move vault data off the boot disk. | [Migrating to a Data Disk](https://github.com/dadatuputi/bitwarden_gcloud/wiki/Migrating-to-a-Data-Disk) |
| (Recommended) Replace an unsupported OS milestone | [Upgrading Container-Optimized OS](https://github.com/dadatuputi/bitwarden_gcloud/wiki/Upgrading-Container-Optimized-OS) |
| Close ports 80 and 443 and retire four containers, in exchange for a small monthly egress charge | [Switching to a Cloudflare Tunnel](https://github.com/dadatuputi/bitwarden_gcloud/wiki/Switching-to-a-Cloudflare-Tunnel) |

## Connectivity

Caddy is the default and the recommended path. The tunnel is a supported
alternative that is not free.

| | Caddy (default) | Cloudflare Tunnel |
|---|---|---|
| Monthly cost on the free tier | none: egress within the allowance, `countryblock` keeps the non-free destinations off the bill | small but non-zero: every byte the vault sends is carrier-peering egress, about $0.10 to $0.20 a month observed for one user |
| Ports open to the internet | 80 and 443 | none |
| TLS terminates at | the instance | Cloudflare's edge |
| DNS | A record maintained by `ddns` | CNAME created by the tunnel |
| Instance address changes | unreachable until DNS updates | no effect |
| Maximum attachment size | unlimited | 100 MB |
| Containers | 6 | 3 |

On the tunnel path Cloudflare decrypts traffic at its edge. Vault contents are encrypted client-side before transmission; metadata and authentication traffic are not.

### What the free tier includes for network traffic

From Google's [free tier page](https://cloud.google.com/free/docs/free-cloud-features#compute) and [network pricing](https://cloud.google.com/network-connectivity/pricing), checked September 2026. Google changes both, so check them before you rely on a number here.

* 1 GB per month of outbound data transfer from North American regions to all
  destinations except China and Australia. Those two are billed from the first
  byte, which is what `countryblock` exists to prevent on the Caddy path.
* The allowance is per billing account, not per project or per instance.
* Data transfer to networks Google reaches by Direct or Carrier Peering is a
  separate SKU with no free allowance, about $0.08 per GiB in the Americas.
  Cloudflare's edge is such a network, so on the tunnel path every byte the vault
  sends (client syncs, web vault assets, `cloudflared` keepalives) is billed at
  that rate. On the Caddy path responses go to your clients' ISPs as ordinary
  internet egress, inside the allowance.
* Inbound data transfer is free, and so is data transfer to Google services.

Observed on one deployment with one user, September 2026: 1.37 GiB on the SKU
"Network Data Transfer Out via Carrier Peering Network - Americas Based", $0.11,
while every other line on the bill netted to zero. To check your own: Billing,
Reports, group by SKU, and look for "Carrier Peering".

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

* 29 September 2026: Caddy is the recommended path again, and the tunnel is a
  documented alternative. Google bills egress to Cloudflare's edge on the
  carrier-peering SKU ("Network Data Transfer Out via Carrier Peering Network"),
  which has no free allowance, so a tunnel deployment is not free: about $0.10
  a month for one user, scaling with traffic. Nothing in the compose files
  changes; `COMPOSE_FILE` still selects the tunnel, and a deployment on either
  path keeps working as it did. See [Connectivity](#connectivity)
* Cloudflare Tunnel was made the default for new installs (reversed above). `COMPOSE_FILE` in `.env`
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
