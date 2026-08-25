# Applying Container-Optimized OS updates

A systemd timer checks once a day whether `update-engine` has staged an OS
update, and reboots the host if it has. Containers return on their own,
because every service in `docker-compose.yml` sets `restart: always` or
`restart: on-failure`.

## Why the previous script did not apply updates

`reboot-on-update.sh` blocks on `update_engine_client
--block_until_reboot_is_needed` and then calls `shutdown -r`. The logic is
sound, but nothing ever invoked it:

- Container-Optimized OS ships no `cron`. `crontab` is not on the box at all.
- No systemd unit referenced the script.

So the script only ran if someone started it by hand, in a shell that stayed
open until an update landed. On a host observed in August 2026 the updater
itself was healthy — `update-engine.service` active, polling roughly every 15
minutes, reporting `ErrorCode::kNoUpdate` — while the box sat on milestone 109
with no mechanism to reboot into anything it staged.

The script is kept for reference and no longer uses `eval`, but it is not
wired to anything. Prefer the timer.

## Install

```sh
./utilities/install-cos-update-reboot.sh
```

This copies `cos-update-reboot.sh` to `/var/lib/bitwarden_gcloud/`, installs
the unit and timer into `/etc/systemd/system/`, and enables the timer. Both
paths are on the stateful partition, which is writable on COS.

To change the reboot window, edit `OnCalendar` in
`/etc/systemd/system/cos-update-reboot.timer` and run `sudo systemctl
daemon-reload && sudo systemctl restart cos-update-reboot.timer`. The time is
interpreted in the host timezone; check it with `timedatectl`.

## Verify

```sh
systemctl list-timers cos-update-reboot.timer --no-pager
sudo systemctl start cos-update-reboot.service   # forces one check now
journalctl -u cos-update-reboot.service --no-pager | tail -20
```

With nothing staged, expect `nothing staged, not rebooting` and a clean exit.
A real end-to-end test needs a genuine staged update, which cannot be forced
on demand — so plan to confirm the first real reboot brings the whole stack
back healthy.

Two things are worth checking after the first update actually applies, neither
of which has been verified here:

- that the unit files in `/etc/systemd/system/` survived the update, and
- that the timer is still enabled.

## What this does not cover

This applies updates **within the current COS milestone only**. COS does not
automatically move a running instance from one milestone to the next, so a box
on milestone 109 stays on 109 no matter how reliably this timer runs. Moving to
a newer milestone means recreating the instance from a current
`cos-cloud/cos-stable` image with the data disk re-attached.

If the goal is to stay on a supported milestone rather than merely patched
within an old one, treat instance rebuild as the primary mechanism and this
timer as the thing that keeps you current in between.

## Removal

```sh
sudo systemctl disable --now cos-update-reboot.timer
sudo rm /etc/systemd/system/cos-update-reboot.{timer,service}
sudo rm -rf /var/lib/bitwarden_gcloud
sudo systemctl daemon-reload
```

The host simply stops rebooting itself. No container or vault data is affected.
